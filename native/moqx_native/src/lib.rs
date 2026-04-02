use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use anyhow::Context;
use moq_lite::Origin;
use moq_native::ClientConfig;
use rustler::env::SavedTerm;
use rustler::{Atom, Binary, Encoder, Env, LocalPid, NewBinary, OwnedEnv, Resource, ResourceArc};
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        moqx_connected,
        moqx_session_closed,
        moqx_subscribed,
        moqx_frame,
        moqx_track_ended,
        moqx_error,
        moqx_fetch_started,
        moqx_fetch_object,
        moqx_fetch_done,
        moqx_fetch_error,
    }
}

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .thread_name("moqx-tokio")
            .build()
            .expect("failed to create Tokio runtime")
    })
}

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

#[allow(dead_code)]
struct PendingFetch {
    caller_pid: LocalPid,
    ref_env: OwnedEnv,
    ref_term: SavedTerm,
    namespace: String,
    track_name: String,
}

#[allow(dead_code)]
struct FetchState {
    next_request_id: AtomicU64,
    pending: std::sync::Mutex<HashMap<u64, PendingFetch>>,
}

#[allow(dead_code)]
impl FetchState {
    fn new() -> Self {
        Self {
            next_request_id: AtomicU64::new(1),
            pending: std::sync::Mutex::new(HashMap::new()),
        }
    }

    fn allocate_request_id(&self) -> u64 {
        self.next_request_id.fetch_add(1, Ordering::Relaxed)
    }

    fn insert_pending(&self, request_id: u64, pending: PendingFetch) -> anyhow::Result<()> {
        let mut guard = self
            .pending
            .lock()
            .map_err(|_| anyhow::anyhow!("fetch state lock poisoned"))?;

        guard.insert(request_id, pending);
        Ok(())
    }

    fn remove_pending(&self, request_id: u64) -> anyhow::Result<Option<PendingFetch>> {
        let mut guard = self
            .pending
            .lock()
            .map_err(|_| anyhow::anyhow!("fetch state lock poisoned"))?;

        Ok(guard.remove(&request_id))
    }
}

pub struct SessionRes {
    session: tokio::sync::Mutex<Option<moq_lite::Session>>,
    origin: Arc<OriginRes>,
    role: ConnectRole,
    root: String,
    #[allow(dead_code)]
    fetch: Option<FetchState>,
}

impl Drop for SessionRes {
    fn drop(&mut self) {
        let _enter = runtime().enter();
        let mut guard = runtime().block_on(self.session.lock());
        if let Some(mut s) = guard.take() {
            s.close(moq_lite::Error::Cancel);
        }
    }
}

#[rustler::resource_impl]
impl Resource for SessionRes {}

pub struct OriginRes {
    producer: Option<moq_lite::OriginProducer>,
}

impl Drop for OriginRes {
    fn drop(&mut self) {
        let _enter = runtime().enter();
        let _ = self.producer.take();
    }
}

#[rustler::resource_impl]
impl Resource for OriginRes {}

struct BroadcastState {
    broadcast: moq_lite::BroadcastProducer,
    origin: Arc<OriginRes>,
    path: String,
    announced: bool,
}

type SharedBroadcastState = Arc<std::sync::Mutex<Option<BroadcastState>>>;

pub struct BroadcastProducerRes {
    inner: SharedBroadcastState,
}

impl Drop for BroadcastProducerRes {
    fn drop(&mut self) {
        let _guard = runtime().enter();
        if let Ok(mut inner) = self.inner.lock() {
            let _ = inner.take();
        }
    }
}

#[rustler::resource_impl]
impl Resource for BroadcastProducerRes {}

pub struct TrackProducerRes {
    inner: std::sync::Mutex<Option<moq_lite::TrackProducer>>,
    parent: SharedBroadcastState,
}

impl Drop for TrackProducerRes {
    fn drop(&mut self) {
        let _guard = runtime().enter();
        if let Ok(mut inner) = self.inner.lock() {
            let _ = inner.take();
        }
    }
}

#[rustler::resource_impl]
impl Resource for TrackProducerRes {}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum ConnectRole {
    Publisher,
    Subscriber,
}

impl ConnectRole {
    fn as_str(self) -> &'static str {
        match self {
            Self::Publisher => "publisher",
            Self::Subscriber => "subscriber",
        }
    }

    fn can_publish(self) -> bool {
        matches!(self, Self::Publisher)
    }

    fn can_consume(self) -> bool {
        matches!(self, Self::Subscriber)
    }

    fn from_str(role: &str) -> rustler::NifResult<Self> {
        match role {
            "publisher" => Ok(Self::Publisher),
            "subscriber" => Ok(Self::Subscriber),
            other => Err(rustler::Error::Term(Box::new(format!(
                "invalid connect role: {}",
                other
            )))),
        }
    }
}

#[rustler::nif]
fn connect(
    env: Env,
    url: String,
    role: String,
    backend: Option<String>,
    transport: String,
    versions: Vec<String>,
    tls_verify: String,
    tls_cacertfile: Option<String>,
) -> rustler::NifResult<Atom> {
    let caller_pid = env.pid();

    let parsed_url =
        url::Url::parse(&url).map_err(|e| rustler::Error::Term(Box::new(format!("{}", e))))?;
    let role = ConnectRole::from_str(&role)?;
    let backend = parse_backend(backend)?;
    let transport = ConnectTransport::from_str(&transport)?;
    let versions = parse_versions(versions)?;
    let tls = ConnectTls::new(&tls_verify, tls_cacertfile)?;

    runtime().spawn(async move {
        let result = do_connect(parsed_url, role, backend, transport, versions, tls).await;

        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&caller_pid, |env| match result {
            Ok((session, origin, root)) => {
                let origin_arc = Arc::new(origin);
                let session_resource = ResourceArc::new(SessionRes {
                    session: tokio::sync::Mutex::new(Some(session)),
                    origin: origin_arc,
                    role,
                    root,
                    fetch: role.can_consume().then(FetchState::new),
                });
                (atoms::moqx_connected(), session_resource).encode(env)
            }
            Err(e) => (atoms::error(), format!("{:#}", e)).encode(env),
        });
    });

    Ok(atoms::ok())
}

#[derive(Clone, Copy)]
enum ConnectTransport {
    Auto,
    RawQuic,
    WebTransport,
    WebSocket,
}

#[derive(Clone)]
struct ConnectTls {
    disable_verify: bool,
    root: Vec<PathBuf>,
}

impl ConnectTls {
    fn new(verify: &str, cacertfile: Option<String>) -> rustler::NifResult<Self> {
        let disable_verify = match verify {
            "verify_peer" => false,
            "insecure" => true,
            other => {
                return Err(rustler::Error::Term(Box::new(format!(
                    "invalid tls verify mode: {}",
                    other
                ))))
            }
        };

        let root = cacertfile.into_iter().map(PathBuf::from).collect();

        Ok(Self {
            disable_verify,
            root,
        })
    }
}

impl ConnectTransport {
    fn from_str(transport: &str) -> rustler::NifResult<Self> {
        match transport {
            "auto" => Ok(Self::Auto),
            "raw_quic" => Ok(Self::RawQuic),
            "webtransport" => Ok(Self::WebTransport),
            "websocket" => Ok(Self::WebSocket),
            other => Err(rustler::Error::Term(Box::new(format!(
                "invalid connect transport: {}",
                other
            )))),
        }
    }
}

fn parse_backend(backend: Option<String>) -> rustler::NifResult<Option<moq_native::QuicBackend>> {
    match backend.as_deref() {
        None => Ok(None),
        Some("quinn") => {
            #[cfg(feature = "quinn")]
            {
                Ok(Some(moq_native::QuicBackend::Quinn))
            }
            #[cfg(not(feature = "quinn"))]
            {
                Err(rustler::Error::Term(Box::new(
                    "backend not compiled: quinn".to_string(),
                )))
            }
        }
        Some("quiche") => {
            #[cfg(feature = "quiche")]
            {
                Ok(Some(moq_native::QuicBackend::Quiche))
            }
            #[cfg(not(feature = "quiche"))]
            {
                Err(rustler::Error::Term(Box::new(
                    "backend not compiled: quiche".to_string(),
                )))
            }
        }
        Some("noq") => {
            #[cfg(feature = "noq")]
            {
                Ok(Some(moq_native::QuicBackend::Noq))
            }
            #[cfg(not(feature = "noq"))]
            {
                Err(rustler::Error::Term(Box::new(
                    "backend not compiled: noq".to_string(),
                )))
            }
        }
        Some(other) => Err(rustler::Error::Term(Box::new(format!(
            "invalid connect backend: {}",
            other
        )))),
    }
}

fn parse_versions(versions: Vec<String>) -> rustler::NifResult<Vec<moq_lite::Version>> {
    versions
        .into_iter()
        .map(|version| {
            version.parse::<moq_lite::Version>().map_err(|err| {
                rustler::Error::Term(Box::new(format!(
                    "invalid connect version {}: {}",
                    version, err
                )))
            })
        })
        .collect()
}

fn rewrite_url_for_transport(
    url: url::Url,
    transport: ConnectTransport,
) -> anyhow::Result<url::Url> {
    let target_scheme = match transport {
        ConnectTransport::Auto => return Ok(url),
        ConnectTransport::RawQuic => "moqt",
        ConnectTransport::WebTransport => "https",
        ConnectTransport::WebSocket => match url.scheme() {
            "http" | "ws" => "ws",
            _ => "wss",
        },
    };

    let host = url.host_str().context("missing hostname")?;
    let mut rewritten = format!("{}://{}", target_scheme, host);

    if let Some(port) = url.port() {
        rewritten.push(':');
        rewritten.push_str(&port.to_string());
    }

    rewritten.push_str(url.path());

    if let Some(query) = url.query() {
        rewritten.push('?');
        rewritten.push_str(query);
    }

    if let Some(fragment) = url.fragment() {
        rewritten.push('#');
        rewritten.push_str(fragment);
    }

    Ok(url::Url::parse(&rewritten)?)
}

async fn do_connect(
    url: url::Url,
    role: ConnectRole,
    backend: Option<moq_native::QuicBackend>,
    transport: ConnectTransport,
    versions: Vec<moq_lite::Version>,
    tls: ConnectTls,
) -> anyhow::Result<(moq_lite::Session, OriginRes, String)> {
    let mut config = ClientConfig::default();
    if tls.disable_verify {
        config.tls.disable_verify = Some(true);
    }
    config.tls.root = tls.root;
    config.backend = backend;
    config.version = versions;

    let url = rewrite_url_for_transport(url, transport)?;
    let root = url.path().trim_matches('/').to_string();
    let origin = Origin::produce();
    let client = config.init()?;

    let client = match role {
        ConnectRole::Publisher => client.with_publish(origin.consume()),
        ConnectRole::Subscriber => client.with_consume(origin.clone()),
    };

    let session = client.connect(url).await?;

    Ok((
        session,
        OriginRes {
            producer: Some(origin),
        },
        root,
    ))
}

fn normalize_broadcast_path(root: &str, broadcast_path: &str) -> String {
    let root = root.trim_matches('/');
    let broadcast_path = broadcast_path.trim_matches('/');

    if root.is_empty() {
        broadcast_path.to_string()
    } else if broadcast_path == root {
        String::new()
    } else if let Some(stripped) = broadcast_path.strip_prefix(&format!("{}/", root)) {
        stripped.to_string()
    } else {
        broadcast_path.to_string()
    }
}

#[allow(dead_code)]
fn normalize_fetch_namespace(root: &str, namespace: &str) -> String {
    let root = root.trim_matches('/');
    let namespace = namespace.trim_matches('/');

    if root.is_empty() {
        namespace.to_string()
    } else if namespace.is_empty() || namespace == root {
        String::new()
    } else if let Some(stripped) = namespace.strip_prefix(&format!("{}/", root)) {
        stripped.to_string()
    } else {
        namespace.to_string()
    }
}

#[rustler::nif]
fn supported_backends() -> Vec<String> {
    let mut backends = Vec::new();

    #[cfg(feature = "quinn")]
    backends.push("quinn".to_string());
    #[cfg(feature = "quiche")]
    backends.push("quiche".to_string());
    #[cfg(feature = "noq")]
    backends.push("noq".to_string());

    backends
}

#[rustler::nif]
fn supported_transports() -> Vec<String> {
    let mut transports = vec![
        "auto".to_string(),
        "raw_quic".to_string(),
        "webtransport".to_string(),
    ];

    #[cfg(feature = "websocket")]
    transports.push("websocket".to_string());

    transports
}

#[rustler::nif]
fn session_version(session: ResourceArc<SessionRes>) -> String {
    let guard = runtime().block_on(session.session.lock());
    match guard.as_ref() {
        Some(s) => s.version().to_string(),
        None => "closed".to_string(),
    }
}

#[rustler::nif]
fn session_role(session: ResourceArc<SessionRes>) -> String {
    session.role.as_str().to_string()
}

#[rustler::nif]
fn session_close(session: ResourceArc<SessionRes>) -> Atom {
    let _enter = runtime().enter();
    let mut guard = runtime().block_on(session.session.lock());
    if let Some(mut s) = guard.take() {
        s.close(moq_lite::Error::Cancel);
    }
    atoms::ok()
}

// ---------------------------------------------------------------------------
// Publish
// ---------------------------------------------------------------------------

/// Creates and announces a broadcast on the session's origin.
///
/// Returns `{:ok, broadcast}` or raises `{:error, reason}`.
#[rustler::nif]
fn publish(
    session: ResourceArc<SessionRes>,
    broadcast_path: String,
) -> rustler::NifResult<(Atom, ResourceArc<BroadcastProducerRes>)> {
    if !session.role.can_publish() {
        return Err(rustler::Error::Term(Box::new(
            "publish requires a publisher session; use MOQX.connect_publisher/1".to_string(),
        )));
    }

    // Enter the Tokio runtime context — needed because create_broadcast
    // internally spawns a monitoring task via web_async::spawn.
    let _guard = runtime().enter();

    let res = ResourceArc::new(BroadcastProducerRes {
        inner: Arc::new(std::sync::Mutex::new(Some(BroadcastState {
            broadcast: moq_lite::Broadcast::produce(),
            origin: session.origin.clone(),
            path: normalize_broadcast_path(&session.root, &broadcast_path),
            announced: false,
        }))),
    });

    Ok((atoms::ok(), res))
}

/// Creates a named track on a broadcast.
///
/// Returns `{:ok, track}` or raises `{:error, reason}`.
#[rustler::nif]
fn create_track(
    broadcast: ResourceArc<BroadcastProducerRes>,
    track_name: String,
) -> rustler::NifResult<(Atom, ResourceArc<TrackProducerRes>)> {
    let _guard = runtime().enter();

    let mut guard = broadcast
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned".to_string())))?;

    let state = guard
        .as_mut()
        .ok_or_else(|| rustler::Error::Term(Box::new("broadcast closed".to_string())))?;

    let track = state
        .broadcast
        .create_track(moq_lite::Track::new(&track_name))
        .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;

    let res = ResourceArc::new(TrackProducerRes {
        inner: std::sync::Mutex::new(Some(track)),
        parent: broadcast.inner.clone(),
    });

    Ok((atoms::ok(), res))
}

/// Writes a single frame as a new group on the track.
///
/// Each call creates a new group with a single frame containing `data`.
/// Returns `:ok` or raises `{:error, reason}`.
#[rustler::nif]
fn write_frame(track: ResourceArc<TrackProducerRes>, data: Binary) -> rustler::NifResult<Atom> {
    let _guard = runtime().enter();

    let mut guard = track
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned".to_string())))?;

    let track_inner = guard
        .as_mut()
        .ok_or_else(|| rustler::Error::Term(Box::new("track closed".to_string())))?;

    track_inner
        .write_frame(bytes::Bytes::copy_from_slice(data.as_slice()))
        .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;

    // Announce lazily on the first successfully written frame so the relay
    // only sees a broadcast once it already contains track data.
    // This mirrors the upstream tests more closely, where the broadcast is
    // fully populated before the session starts publishing it.
    let mut parent = track
        .parent
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned".to_string())))?;

    if let Some(state) = parent.as_mut() {
        if !state.announced {
            let producer = state
                .origin
                .producer
                .as_ref()
                .ok_or_else(|| rustler::Error::Term(Box::new("origin closed".to_string())))?;

            if !producer.publish_broadcast(&state.path, state.broadcast.consume()) {
                return Err(rustler::Error::Term(Box::new(format!(
                    "broadcast path not allowed: {}",
                    state.path
                ))));
            }

            state.announced = true;
        }
    }

    Ok(atoms::ok())
}

/// Marks a track as finished. No more frames can be written after this.
///
/// Returns `:ok` or raises `{:error, reason}`.
#[rustler::nif]
fn finish_track(track: ResourceArc<TrackProducerRes>) -> rustler::NifResult<Atom> {
    let _guard = runtime().enter();

    let mut guard = track
        .inner
        .lock()
        .map_err(|_| rustler::Error::Term(Box::new("lock poisoned".to_string())))?;

    let track = guard
        .as_mut()
        .ok_or_else(|| rustler::Error::Term(Box::new("track closed".to_string())))?;

    track
        .finish()
        .map_err(|e| rustler::Error::Term(Box::new(format!("{:?}", e))))?;

    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// Subscribe / Consume
// ---------------------------------------------------------------------------

/// Subscribes to a track on a broadcast, receiving frames as messages.
///
/// Returns `:ok` immediately. The calling process will receive:
/// - `{:moqx_subscribed, broadcast_path, track_name}` when subscribed
/// - `{:moqx_frame, group_seq, binary_data}` for each frame
/// - `:moqx_track_ended` when the track is finished
/// - `{:moqx_error, reason}` on error
#[rustler::nif]
fn subscribe(
    env: Env,
    session: ResourceArc<SessionRes>,
    broadcast_path: String,
    track_name: String,
) -> rustler::NifResult<Atom> {
    if !session.role.can_consume() {
        return Err(rustler::Error::Term(Box::new(
            "subscribe requires a subscriber session; use MOQX.connect_subscriber/1".to_string(),
        )));
    }

    let caller_pid = env.pid();
    let origin = session.origin.clone();
    let normalized_broadcast_path = normalize_broadcast_path(&session.root, &broadcast_path);

    runtime().spawn(async move {
        if let Err(e) = do_subscribe(
            origin,
            &broadcast_path,
            &normalized_broadcast_path,
            &track_name,
            caller_pid,
        )
        .await
        {
            let mut msg_env = OwnedEnv::new();
            let _ = msg_env.send_and_clear(&caller_pid, |env| {
                (atoms::moqx_error(), format!("{:#}", e)).encode(env)
            });
        }
    });

    Ok(atoms::ok())
}

async fn do_subscribe(
    origin: Arc<OriginRes>,
    broadcast_path: &str,
    normalized_broadcast_path: &str,
    track_name: &str,
    caller_pid: LocalPid,
) -> anyhow::Result<()> {
    // Create a consumer from the origin — this immediately replays all existing
    // announcements and then yields new ones, avoiding the race between
    // consume_broadcast() and a not-yet-announced broadcast.
    let broadcast = {
        let producer = origin
            .producer
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("origin closed"))?;
        let mut consumer = producer.consume();
        loop {
            match consumer.announced().await {
                Some((path, Some(bc))) => {
                    if path.as_str() == normalized_broadcast_path {
                        break bc;
                    }
                }
                Some(_) => continue, // unannounce or different path
                None => anyhow::bail!("origin consumer closed while waiting for broadcast"),
            }
        }
    };

    // Subscribe to the specific track
    let track_info = moq_lite::Track::new(track_name);
    let mut track_consumer = broadcast
        .subscribe_track(&track_info)
        .map_err(|e| anyhow::anyhow!("subscribe_track failed: {:?}", e))?;

    // Notify caller that subscription is active
    {
        let bp = broadcast_path.to_string();
        let tn = track_name.to_string();
        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&caller_pid, |env| {
            (atoms::moqx_subscribed(), bp, tn).encode(env)
        });
    }

    // Read groups and frames, sending each frame to the caller.
    // Some relay-backed WebSocket paths currently surface track completion as
    // `Cancel` instead of a clean end-of-stream, so normalize that to the same
    // `:moqx_track_ended` signal the Elixir side expects.
    let mut cancelled = false;

    loop {
        let next_group = match track_consumer.next_group().await {
            Ok(next_group) => next_group,
            Err(moq_lite::Error::Cancel | moq_lite::Error::Transport) => break,
            Err(e) => return Err(anyhow::anyhow!("next_group: {:?}", e)),
        };

        let Some(mut group) = next_group else {
            break;
        };

        let group_seq = group.info.sequence;

        loop {
            let frame = match group.read_frame().await {
                Ok(frame) => frame,
                Err(moq_lite::Error::Cancel | moq_lite::Error::Transport) => {
                    cancelled = true;
                    break;
                }
                Err(e) => return Err(anyhow::anyhow!("read_frame: {:?}", e)),
            };

            let Some(data) = frame else {
                break;
            };

            let mut msg_env = OwnedEnv::new();
            let _ = msg_env.send_and_clear(&caller_pid, |env| {
                let mut binary = NewBinary::new(env, data.len());
                binary.as_mut_slice().copy_from_slice(&data);
                let binary_term: rustler::Term = binary.into();
                rustler::types::tuple::make_tuple(
                    env,
                    &[
                        atoms::moqx_frame().encode(env),
                        group_seq.encode(env),
                        binary_term,
                    ],
                )
            });
        }

        if cancelled {
            break;
        }
    }

    // Track ended cleanly
    {
        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&caller_pid, |env| atoms::moqx_track_ended().encode(env));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{normalize_broadcast_path, normalize_fetch_namespace, FetchState};

    #[test]
    fn fetch_state_allocates_monotonic_request_ids() {
        let state = FetchState::new();

        assert_eq!(state.allocate_request_id(), 1);
        assert_eq!(state.allocate_request_id(), 2);
        assert_eq!(state.allocate_request_id(), 3);
    }

    #[test]
    fn fetch_state_remove_missing_request_is_none() {
        let state = FetchState::new();

        assert!(state.remove_pending(42).unwrap().is_none());
    }

    #[test]
    fn normalize_broadcast_path_keeps_relative_paths_under_root() {
        assert_eq!(normalize_broadcast_path("room/demo", "stream"), "stream");
    }

    #[test]
    fn normalize_broadcast_path_strips_matching_root_prefix() {
        assert_eq!(
            normalize_broadcast_path("room/demo", "room/demo/stream"),
            "stream"
        );
        assert_eq!(
            normalize_broadcast_path("/room/demo/", "/room/demo/stream/"),
            "stream"
        );
    }

    #[test]
    fn normalize_broadcast_path_maps_exact_root_to_empty_suffix() {
        assert_eq!(normalize_broadcast_path("room/demo", "room/demo"), "");
    }

    #[test]
    fn normalize_broadcast_path_does_not_strip_non_matching_prefixes() {
        assert_eq!(
            normalize_broadcast_path("room/demo", "room/demo-extra/stream"),
            "room/demo-extra/stream"
        );
    }

    #[test]
    fn normalize_fetch_namespace_keeps_relative_namespaces_under_root() {
        assert_eq!(normalize_fetch_namespace("room/demo", "catalog"), "catalog");
    }

    #[test]
    fn normalize_fetch_namespace_strips_matching_root_prefix() {
        assert_eq!(
            normalize_fetch_namespace("room/demo", "room/demo/catalog"),
            "catalog"
        );
        assert_eq!(
            normalize_fetch_namespace("/room/demo/", "/room/demo/catalog/"),
            "catalog"
        );
    }

    #[test]
    fn normalize_fetch_namespace_maps_root_namespace_to_empty_suffix() {
        assert_eq!(normalize_fetch_namespace("room/demo", "room/demo"), "");
        assert_eq!(normalize_fetch_namespace("room/demo", "/room/demo/"), "");
    }

    #[test]
    fn normalize_fetch_namespace_keeps_non_matching_prefixes() {
        assert_eq!(
            normalize_fetch_namespace("room/demo", "room/demo-extra/catalog"),
            "room/demo-extra/catalog"
        );
    }
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

rustler::init!("Elixir.MOQX.Native");
