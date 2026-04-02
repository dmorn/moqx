use std::collections::HashMap;
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use anyhow::Context;
use bytes::{Buf, BufMut, BytesMut};
use moq_lite::Origin;
use moq_native::ClientConfig;
use rustler::env::SavedTerm;
use rustler::types::reference::Reference;
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

#[derive(Clone)]
struct FetchConnectConfig {
    url: url::Url,
    backend: Option<String>,
    transport: ConnectTransport,
    tls: ConnectTls,
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
    fetch: Option<FetchState>,
    fetch_connect: Option<FetchConnectConfig>,
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
        let fetch_connect = FetchConnectConfig {
            url: parsed_url.clone(),
            backend: backend.as_ref().map(|backend| match backend {
                moq_native::QuicBackend::Quinn => "quinn".to_string(),
                #[cfg(feature = "quiche")]
                moq_native::QuicBackend::Quiche => "quiche".to_string(),
                #[cfg(feature = "noq")]
                moq_native::QuicBackend::Noq => "noq".to_string(),
                #[allow(unreachable_patterns)]
                _ => "unknown".to_string(),
            }),
            transport,
            tls: tls.clone(),
        };

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
                    fetch_connect: role.can_consume().then_some(fetch_connect),
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

// ---------------------------------------------------------------------------
// Fetch
// ---------------------------------------------------------------------------

#[derive(Clone, Copy)]
enum FetchGroupOrder {
    Original,
    Ascending,
    Descending,
}

impl FetchGroupOrder {
    fn parse(group_order: &str) -> anyhow::Result<Self> {
        match group_order {
            "original" => Ok(Self::Original),
            "ascending" => Ok(Self::Ascending),
            "descending" => Ok(Self::Descending),
            other => anyhow::bail!("invalid fetch group order: {other}"),
        }
    }

    /// v14 group order: 0=any/original, 1=ascending, 2=descending
    fn encode_v14(self) -> u8 {
        match self {
            Self::Original => 0,
            Self::Ascending => 1,
            Self::Descending => 2,
        }
    }

    fn encode_v17(self) -> u8 {
        match self {
            Self::Original => 0,
            Self::Ascending => 1,
            Self::Descending => 2,
        }
    }
}

#[derive(Clone, Copy)]
struct FetchLocation {
    group: u64,
    object: u64,
}

#[rustler::nif]
fn fetch(
    env: Env,
    session: ResourceArc<SessionRes>,
    fetch_ref: Reference,
    namespace: String,
    track_name: String,
    priority: u8,
    group_order: String,
    start: (u64, u64),
    end: Option<(u64, u64)>,
) -> rustler::NifResult<Atom> {
    if !session.role.can_consume() {
        return Err(rustler::Error::Term(Box::new(
            "fetch requires a subscriber session; use MOQX.connect_subscriber/1".to_string(),
        )));
    }

    let fetch_state = session
        .fetch
        .as_ref()
        .ok_or_else(|| rustler::Error::Term(Box::new("fetch state unavailable".to_string())))?;

    let connect = session.fetch_connect.clone().ok_or_else(|| {
        rustler::Error::Term(Box::new("fetch transport configuration unavailable".to_string()))
    })?;

    let normalized_namespace = normalize_fetch_namespace(&session.root, &namespace);
    let negotiated_version = {
        let guard = runtime().block_on(session.session.lock());
        let session = guard
            .as_ref()
            .ok_or_else(|| rustler::Error::Term(Box::new("session closed".to_string())))?;
        session.version().to_string()
    };

    let request_seq = fetch_state.allocate_request_id();
    let wire_request_id = (request_seq - 1) * 2;

    let ref_env = OwnedEnv::new();
    let ref_term = ref_env.save(fetch_ref);

    fetch_state
        .insert_pending(
            wire_request_id,
            PendingFetch {
                caller_pid: env.pid(),
                ref_env,
                ref_term,
                namespace: namespace.clone(),
                track_name: track_name.clone(),
            },
        )
        .map_err(|err| rustler::Error::Term(Box::new(format!("{err:#}"))))?;

    let group_order = FetchGroupOrder::parse(&group_order)
        .map_err(|err| rustler::Error::Term(Box::new(format!("{err:#}"))))?;
    let start = FetchLocation {
        group: start.0,
        object: start.1,
    };
    let end = end.map(|(group, object)| FetchLocation { group, object });
    let session_ref = session.clone();

    runtime().spawn(async move {
        let result = do_fetch(
            session_ref.clone(),
            wire_request_id,
            connect,
            &negotiated_version,
            &normalized_namespace,
            &track_name,
            priority,
            group_order,
            start,
            end,
        )
        .await;

        if let Err(err) = result {
            let _ = send_fetch_error_and_cleanup(&session_ref, wire_request_id, &format!("{err:#}"));
        }
    });

    Ok(atoms::ok())
}

async fn do_fetch(
    session: ResourceArc<SessionRes>,
    request_id: u64,
    connect: FetchConnectConfig,
    _negotiated_version: &str,
    namespace: &str,
    track_name: &str,
    priority: u8,
    group_order: FetchGroupOrder,
    start: FetchLocation,
    end: Option<FetchLocation>,
) -> anyhow::Result<()> {
    if connect.backend.as_deref().unwrap_or("quinn") != "quinn" {
        anyhow::bail!("fetch currently supports only the quinn backend")
    }

    let url = rewrite_url_for_transport(connect.url.clone(), connect.transport)?;
    let end = end.unwrap_or(start);

    match url.scheme() {
        "https" => {
            // WebTransport: connect with h3 ALPN, negotiate version via SETUP (v14-style)
            let transport_session = connect_fetch_transport(&connect, 14).await?;
            perform_fetch_v14(
                &session, request_id, transport_session,
                namespace, track_name, priority, group_order, start, end,
            ).await
        }
        "moqt" | "moql" => {
            // Raw QUIC: connect with version-specific ALPN, v17 setup
            let transport_session = connect_fetch_transport(&connect, 17).await?;
            perform_fetch_v17(
                &session, request_id, transport_session,
                namespace, track_name, priority, group_order, start, end,
            ).await
        }
        other => anyhow::bail!("unsupported fetch URL scheme: {other}"),
    }
}

async fn connect_fetch_transport(
    connect: &FetchConnectConfig,
    version: u8,
) -> anyhow::Result<web_transport_quinn::Session> {
    let url = rewrite_url_for_transport(connect.url.clone(), connect.transport)?;
    let host = url.host_str().context("invalid DNS name")?.to_string();
    let port = url.port().unwrap_or(443);
    let ip = tokio::net::lookup_host((host.clone(), port))
        .await
        .context("failed DNS lookup")?
        .next()
        .context("no DNS entries")?;

    let socket = std::net::UdpSocket::bind("[::]:0").context("failed to bind UDP socket")?;
    let runtime = quinn::default_runtime().context("no async runtime")?;
    let endpoint = quinn::Endpoint::new(quinn::EndpointConfig::default(), None, socket, runtime)
        .context("failed to create QUIC endpoint")?;

    let mut tls = build_fetch_tls(&connect.tls)?;

    tls.alpn_protocols = match url.scheme() {
        "https" => vec![web_transport_quinn::ALPN.as_bytes().to_vec()],
        "moqt" | "moql" => {
            let alpn = match version {
                17 => moq_lite::ALPN_17,
                _ => anyhow::bail!("unsupported raw QUIC fetch ALPN for version {version}"),
            };
            vec![alpn.as_bytes().to_vec()]
        }
        other => anyhow::bail!("unsupported fetch url scheme: {other}"),
    };
    tls.key_log = Arc::new(rustls::KeyLogFile::new());

    let client_crypto: quinn::crypto::rustls::QuicClientConfig = tls.try_into()?;
    let mut client_config = quinn::ClientConfig::new(Arc::new(client_crypto));
    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(Some(std::time::Duration::from_secs(10).try_into().unwrap()));
    transport.keep_alive_interval(Some(std::time::Duration::from_secs(4)));
    transport.mtu_discovery_config(None);
    let max_streams = quinn::VarInt::from_u64(1024).unwrap_or(quinn::VarInt::MAX);
    transport.max_concurrent_bidi_streams(max_streams);
    transport.max_concurrent_uni_streams(max_streams);
    client_config.transport_config(Arc::new(transport));

    let connection = endpoint.connect_with(client_config, ip, &host)?.await?;

    let mut request = web_transport_quinn::proto::ConnectRequest::new(url.clone());

    match url.scheme() {
        "https" => {
            request = request.with_protocol(web_transport_quinn::ALPN.to_string());
            Ok(web_transport_quinn::Session::connect(connection, request).await?)
        }
        "moqt" | "moql" => {
            let handshake = connection
                .handshake_data()
                .context("missing handshake data")?
                .downcast::<quinn::crypto::rustls::HandshakeData>()
                .map_err(|_| anyhow::anyhow!("failed to decode handshake data"))?;
            let negotiated_alpn = handshake.protocol.context("missing ALPN")?;
            let negotiated_alpn = String::from_utf8(negotiated_alpn).context("failed to decode ALPN")?;
            request = request.with_protocol(negotiated_alpn.clone());
            let response = web_transport_quinn::proto::ConnectResponse::OK.with_protocol(negotiated_alpn);
            Ok(web_transport_quinn::Session::raw(connection, request, response))
        }
        _ => unreachable!(),
    }
}

fn build_fetch_tls(tls: &ConnectTls) -> anyhow::Result<rustls::ClientConfig> {
    // Ensure a CryptoProvider is available for rustls when building our own TLS config.
    let _ = rustls::crypto::ring::default_provider().install_default();

    let mut roots = rustls::RootCertStore::empty();

    if tls.root.is_empty() {
        let native = rustls_native_certs::load_native_certs();
        for cert in native.certs {
            roots.add(cert).context("failed to add root cert")?;
        }
    } else {
        for root in &tls.root {
            let root = std::fs::File::open(root).context("failed to open root cert file")?;
            let mut root = std::io::BufReader::new(root);
            let cert = rustls_pemfile::certs(&mut root)
                .next()
                .context("no roots found")?
                .context("failed to read root cert")?;
            roots.add(cert).context("failed to add root cert")?;
        }
    }

    let config = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();

    if tls.disable_verify {
        anyhow::bail!("fetch does not support tls verify: :insecure yet")
    }

    Ok(config)
}

/// Perform a fetch over WebTransport using v14-style SETUP negotiation.
///
/// In v14, the first bidi stream is the control stream. CLIENT_SETUP and
/// SERVER_SETUP are exchanged, then FETCH is written as a control message
/// on the same stream. FetchOk/FetchError arrive on the same stream.
/// Object data arrives on a uni stream prefixed with FetchHeader.
async fn perform_fetch_v14(
    session: &ResourceArc<SessionRes>,
    request_id: u64,
    transport_session: web_transport_quinn::Session,
    namespace: &str,
    track_name: &str,
    priority: u8,
    group_order: FetchGroupOrder,
    start: FetchLocation,
    end: FetchLocation,
) -> anyhow::Result<()> {
    // Open the control bidi stream
    let (send, recv) = web_transport_trait::Session::open_bi(&transport_session)
        .await
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let mut writer = send;
    let mut reader = recv;

    // --- CLIENT_SETUP (v14) ---
    // type 0x20, u16 length, body = versions + params
    let mut setup_body = BytesMut::new();
    // 1 supported version
    encode_varint(&mut setup_body, 1);
    // Draft14 version code: 0xff00000e
    encode_varint(&mut setup_body, 0xff00000e);
    // 2 parameters (v14 encoding: <count> (<key> <value>)...)
    encode_varint(&mut setup_body, 2);
    // Param: MaxRequestId (key=2, varint param) = u32::MAX
    encode_varint(&mut setup_body, 2);
    encode_varint(&mut setup_body, 0xFFFF_FFFF_u64);
    // Param: Implementation (key=7, bytes param) = "moqx-native"
    encode_varint(&mut setup_body, 7);
    encode_string_v17(&mut setup_body, "moqx-native"); // len-prefixed bytes

    let mut setup_msg = BytesMut::new();
    setup_msg.put_u8(0x20); // CLIENT_SETUP type
    setup_msg.put_u16(setup_body.len() as u16);
    setup_msg.extend_from_slice(&setup_body);
    write_all_send(&mut writer, setup_msg.freeze()).await?;

    // --- SERVER_SETUP (v14) ---
    let server_type = read_u8_recv(&mut reader).await?;
    if server_type != 0x21 {
        anyhow::bail!("expected SERVER_SETUP (0x21), got 0x{server_type:02x}");
    }
    let server_size = read_u16_recv(&mut reader).await? as usize;
    let server_body = read_exact_recv(&mut reader, server_size).await?;
    let mut cursor = Cursor::new(server_body.as_ref());
    let _server_version = read_varint_buf(&mut cursor)?; // selected version code
    // Remaining bytes are server parameters, skip them.

    // --- FETCH (v14) ---
    // Body: request_id, priority, group_order, fetch_type=1(standalone),
    //       namespace, track, start, end, 0 params
    let mut fetch_body = BytesMut::new();
    encode_varint(&mut fetch_body, request_id);
    fetch_body.put_u8(priority);
    fetch_body.put_u8(group_order.encode_v14());
    fetch_body.put_u8(1); // FetchType::Standalone
    encode_namespace_v17(&mut fetch_body, namespace); // same tuple encoding
    encode_string_v17(&mut fetch_body, track_name);   // same string encoding
    encode_varint(&mut fetch_body, start.group);
    encode_varint(&mut fetch_body, start.object);
    encode_varint(&mut fetch_body, end.group);
    encode_varint(&mut fetch_body, end.object);
    encode_varint(&mut fetch_body, 0); // 0 parameters

    let mut fetch_msg = BytesMut::new();
    encode_varint(&mut fetch_msg, 0x16); // FETCH type
    fetch_msg.put_u16(fetch_body.len() as u16);
    fetch_msg.extend_from_slice(&fetch_body);
    write_all_send(&mut writer, fetch_msg.freeze()).await?;

    // --- Read response (FetchOk 0x18 or FetchError 0x19) ---
    let response_type = read_varint_recv(&mut reader).await?;
    let response_size = read_u16_recv(&mut reader).await? as usize;
    let response = read_exact_recv(&mut reader, response_size).await?;
    match response_type {
        0x18 => {
            // FetchOk v14: request_id, group_order, end_of_track, end_location, params
            // We don't need the details, just confirm success.
        }
        0x19 => {
            // FetchError v14: request_id, error_code, reason_phrase
            let mut cursor = Cursor::new(response.as_ref());
            let _rid = read_varint_buf(&mut cursor)?;
            let error_code = read_varint_buf(&mut cursor)?;
            let reason = read_string_buf(&mut cursor)?;
            anyhow::bail!("fetch rejected: error={error_code} reason={reason}");
        }
        other => anyhow::bail!("unexpected fetch response type: 0x{other:x}"),
    }

    send_fetch_started(session, request_id)?;

    // --- Accept uni stream for FetchHeader + objects ---
    loop {
        let mut uni_reader = match web_transport_trait::Session::accept_uni(&transport_session).await {
            Ok(recv) => recv,
            Err(err) => return Err(anyhow::anyhow!(err.to_string())),
        };

        let header_type = read_varint_recv(&mut uni_reader).await?;
        if header_type != 0x5 { // FetchHeader type
            continue;
        }
        let header_request_id = read_varint_recv(&mut uni_reader).await?;
        if header_request_id != request_id {
            continue;
        }

        send_fetch_started(session, request_id)?;
        read_fetch_v14_objects(session, request_id, &mut uni_reader).await?;
        send_fetch_done_and_cleanup(session, request_id)?;
        return Ok(());
    }
}

async fn perform_fetch_v17(
    session: &ResourceArc<SessionRes>,
    request_id: u64,
    transport_session: web_transport_quinn::Session,
    namespace: &str,
    track_name: &str,
    priority: u8,
    group_order: FetchGroupOrder,
    start: FetchLocation,
    end: FetchLocation,
) -> anyhow::Result<()> {
    send_client_setup_v17(&transport_session).await?;
    recv_server_setup_v17(&transport_session).await?;

    let (send, recv) = web_transport_trait::Session::open_bi(&transport_session)
        .await
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let mut writer = send;
    let mut reader = recv;

    let mut body = BytesMut::new();
    encode_varint(&mut body, request_id);
    encode_varint(&mut body, 0);
    body.put_u8(1);
    encode_namespace_v17(&mut body, namespace);
    encode_string_v17(&mut body, track_name);
    encode_varint(&mut body, start.group);
    encode_varint(&mut body, start.object);
    encode_varint(&mut body, end.group);
    encode_varint(&mut body, end.object);
    encode_varint(&mut body, 2);
    encode_varint(&mut body, 0x20);
    body.put_u8(priority);
    encode_varint(&mut body, 0x02);
    encode_varint(&mut body, 0x22);
    body.put_u8(group_order.encode_v17());
    encode_varint(&mut body, 0x01);

    let mut request = BytesMut::new();
    encode_varint(&mut request, 0x16);
    request.put_u16(body.len() as u16);
    request.extend_from_slice(&body);
    write_all_send(&mut writer, request.freeze()).await?;
    web_transport_trait::SendStream::finish(&mut writer).map_err(|e| anyhow::anyhow!(e.to_string()))?;

    let response_type = read_varint_recv(&mut reader).await?;
    let response_size = read_u16_recv(&mut reader).await? as usize;
    let response = read_exact_recv(&mut reader, response_size).await?;
    match response_type {
        0x07 => {}
        0x05 => {
            let mut cursor = Cursor::new(response.as_ref());
            let error_code = read_varint_buf(&mut cursor)?;
            let retry_interval = read_varint_buf(&mut cursor)?;
            let reason = read_string_buf(&mut cursor)?;
            anyhow::bail!("fetch request rejected: {error_code} {retry_interval} {reason}")
        }
        other => anyhow::bail!("unexpected fetch response type: {other}"),
    }

    send_fetch_started(session, request_id)?;

    loop {
        let mut reader = match web_transport_trait::Session::accept_uni(&transport_session).await {
            Ok(recv) => recv,
            Err(err) => return Err(anyhow::anyhow!(err.to_string())),
        };

        let header_type = read_varint_recv(&mut reader).await?;
        if header_type != 0x5 {
            continue;
        }
        let header_request_id = read_varint_recv(&mut reader).await?;
        if header_request_id != request_id {
            continue;
        }

        read_fetch_stream_objects(session, request_id, &mut reader).await?;
        send_fetch_done_and_cleanup(session, request_id)?;
        return Ok(());
    }
}

async fn send_client_setup_v17(session: &web_transport_quinn::Session) -> anyhow::Result<()> {
    let mut send = web_transport_trait::Session::open_uni(session)
        .await
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let mut body = BytesMut::new();
    encode_varint(&mut body, 7);
    encode_bytes_v17(&mut body, b"moqx-native" );

    let mut message = BytesMut::new();
    encode_varint(&mut message, 0x2F00);
    message.put_u16(body.len() as u16);
    message.extend_from_slice(&body);
    write_all_send(&mut send, message.freeze()).await?;
    web_transport_trait::SendStream::finish(&mut send).map_err(|e| anyhow::anyhow!(e.to_string()))?;
    Ok(())
}

async fn recv_server_setup_v17(session: &web_transport_quinn::Session) -> anyhow::Result<()> {
    let mut recv = web_transport_trait::Session::accept_uni(session)
        .await
        .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    let kind = read_varint_recv(&mut recv).await?;
    if kind != 0x2F00 {
        anyhow::bail!("expected server setup stream, got type {kind}")
    }
    let size = read_u16_recv(&mut recv).await? as usize;
    let _body = read_exact_recv(&mut recv, size).await?;
    Ok(())
}

/// Read objects from a v14 FETCH uni stream after FetchHeader.
///
/// The v14 format repeats per-object entries until the stream ends:
///   group_id (varint)
///   sub_group_id (varint)
///   object_id (varint)
///   publisher_priority (u8)
///   object_status (varint) — 0 = normal payload
///   payload_length (varint)
///   payload (bytes)
async fn read_fetch_v14_objects<R>(
    session: &ResourceArc<SessionRes>,
    request_id: u64,
    recv: &mut R,
) -> anyhow::Result<()>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    loop {
        // Try to read the next object's group_id; if the stream ends, we're done.
        let group_id = match read_varint_maybe_recv(recv).await? {
            Some(v) => v,
            None => return Ok(()),
        };
        let _sub_group_id = read_varint_recv(recv).await?;
        let object_id = read_varint_recv(recv).await?;
        let _publisher_priority = read_u8_recv(recv).await?;
        let object_status = read_varint_recv(recv).await?;

        if object_status != 0 {
            // Non-zero status means end-of-group/track or error; no payload follows.
            continue;
        }

        let payload_length = read_varint_recv(recv).await? as usize;
        let payload = read_exact_recv(recv, payload_length).await?;
        send_fetch_object(session, request_id, group_id, object_id, payload)?;
    }
}

/// Read objects from a v17 FETCH uni stream using GroupFlags framing.
async fn read_fetch_stream_objects<R>(
    session: &ResourceArc<SessionRes>,
    request_id: u64,
    recv: &mut R,
) -> anyhow::Result<()>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    let group_flags = read_varint_recv(recv).await?;
    let flags = decode_group_flags(group_flags)?;
    let _track_alias = read_varint_recv(recv).await?;
    let group_id = read_varint_recv(recv).await?;
    let _sub_group_id = if flags.has_subgroup {
        read_varint_recv(recv).await?
    } else {
        0
    };
    if flags.has_priority {
        let _publisher_priority = read_u8_recv(recv).await?;
    }

    let mut object_id = 0u64;
    while let Some(id_delta) = read_varint_maybe_recv(recv).await? {
        object_id = object_id.saturating_add(id_delta);

        if flags.has_extensions {
            let ext_len = read_varint_recv(recv).await? as usize;
            skip_exact_recv(recv, ext_len).await?;
        }

        let size = read_varint_recv(recv).await? as usize;
        let payload = if size == 0 {
            let _status = read_varint_recv(recv).await?;
            bytes::Bytes::new()
        } else {
            read_exact_recv(recv, size).await?
        };

        send_fetch_object(session, request_id, group_id, object_id, payload)?;
    }

    Ok(())
}

fn decode_group_flags(id: u64) -> anyhow::Result<GroupFlagsState> {
    let (has_priority, base_id) = if (0x10..=0x1d).contains(&id) {
        (true, id)
    } else if (0x30..=0x3d).contains(&id) {
        (false, id - 0x20)
    } else {
        anyhow::bail!("invalid group flags: {id}")
    };

    let has_extensions = (base_id & 0x01) != 0;
    let has_subgroup_object = (base_id & 0x02) != 0;
    let has_subgroup = (base_id & 0x04) != 0;
    if has_subgroup && has_subgroup_object {
        anyhow::bail!("unsupported group flags")
    }

    Ok(GroupFlagsState {
        has_extensions,
        has_subgroup,
        has_priority,
    })
}

struct GroupFlagsState {
    has_extensions: bool,
    has_subgroup: bool,
    has_priority: bool,
}

fn send_fetch_started(session: &ResourceArc<SessionRes>, request_id: u64) -> anyhow::Result<()> {
    let fetch_state = session
        .fetch
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("fetch state unavailable"))?;
    let guard = fetch_state
        .pending
        .lock()
        .map_err(|_| anyhow::anyhow!("fetch state lock poisoned"))?;
    let pending = guard
        .get(&request_id)
        .ok_or_else(|| anyhow::anyhow!("pending fetch not found for request_id {request_id}"))?;

    pending.ref_env.run(|env| {
        let _ = env.send(
            &pending.caller_pid,
            (
                atoms::moqx_fetch_started(),
                pending.ref_term.load(env),
                pending.namespace.clone(),
                pending.track_name.clone(),
            ),
        );
    });

    Ok(())
}

fn send_fetch_object(
    session: &ResourceArc<SessionRes>,
    request_id: u64,
    group_id: u64,
    object_id: u64,
    payload: bytes::Bytes,
) -> anyhow::Result<()> {
    let fetch_state = session
        .fetch
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("fetch state unavailable"))?;
    let guard = fetch_state
        .pending
        .lock()
        .map_err(|_| anyhow::anyhow!("fetch state lock poisoned"))?;
    let pending = guard
        .get(&request_id)
        .ok_or_else(|| anyhow::anyhow!("pending fetch not found for request_id {request_id}"))?;

    pending.ref_env.run(|env| {
        let mut binary = NewBinary::new(env, payload.len());
        binary.as_mut_slice().copy_from_slice(&payload);
        let payload_term: rustler::Term = binary.into();
        let message = rustler::types::tuple::make_tuple(
            env,
            &[
                atoms::moqx_fetch_object().encode(env),
                pending.ref_term.load(env),
                group_id.encode(env),
                object_id.encode(env),
                payload_term,
            ],
        );
        let _ = env.send(&pending.caller_pid, message);
    });

    Ok(())
}

fn send_fetch_done_and_cleanup(session: &ResourceArc<SessionRes>, request_id: u64) -> anyhow::Result<()> {
    let pending = take_pending_fetch(session, request_id)?
        .ok_or_else(|| anyhow::anyhow!("pending fetch not found for request_id {request_id}"))?;

    pending.ref_env.run(|env| {
        let _ = env.send(
            &pending.caller_pid,
            (atoms::moqx_fetch_done(), pending.ref_term.load(env)),
        );
    });

    Ok(())
}

fn send_fetch_error_and_cleanup(
    session: &ResourceArc<SessionRes>,
    request_id: u64,
    reason: &str,
) -> anyhow::Result<()> {
    if let Some(pending) = take_pending_fetch(session, request_id)? {
        let reason = reason.to_string();
        pending.ref_env.run(|env| {
            let _ = env.send(
                &pending.caller_pid,
                (atoms::moqx_fetch_error(), pending.ref_term.load(env), reason).encode(env),
            );
        });
    }

    Ok(())
}

fn take_pending_fetch(
    session: &ResourceArc<SessionRes>,
    request_id: u64,
) -> anyhow::Result<Option<PendingFetch>> {
    session
        .fetch
        .as_ref()
        .ok_or_else(|| anyhow::anyhow!("fetch state unavailable"))?
        .remove_pending(request_id)
}

fn encode_varint(buf: &mut BytesMut, value: u64) {
    if value < (1 << 6) {
        buf.put_u8(value as u8);
    } else if value < (1 << 14) {
        buf.put_u16(((1 << 14) | value as u16) as u16);
    } else if value < (1 << 30) {
        buf.put_u32((2u32 << 30) | value as u32);
    } else {
        buf.put_u64((3u64 << 62) | value);
    }
}

fn encode_string_v17(buf: &mut BytesMut, value: &str) {
    encode_bytes_v17(buf, value.as_bytes())
}

fn encode_bytes_v17(buf: &mut BytesMut, value: &[u8]) {
    encode_varint(buf, value.len() as u64);
    buf.extend_from_slice(value);
}

fn encode_namespace_v17(buf: &mut BytesMut, namespace: &str) {
    let parts: Vec<&str> = namespace.split('/').filter(|part| !part.is_empty()).collect();
    encode_varint(buf, parts.len() as u64);
    for part in parts {
        encode_string_v17(buf, part);
    }
}

fn read_varint_buf<B: Buf>(buf: &mut B) -> anyhow::Result<u64> {
    if !buf.has_remaining() {
        anyhow::bail!("short buffer")
    }

    let first = buf.chunk()[0];
    let tag = first >> 6;
    let bytes = 1usize << tag;
    if buf.remaining() < bytes {
        anyhow::bail!("short buffer")
    }

    let value = match bytes {
        1 => buf.get_u8() as u64 & 0x3f,
        2 => buf.get_u16() as u64 & 0x3fff,
        4 => buf.get_u32() as u64 & 0x3fff_ffff,
        8 => buf.get_u64() & 0x3fff_ffff_ffff_ffff,
        _ => unreachable!(),
    };

    Ok(value)
}

fn read_string_buf<B: Buf>(buf: &mut B) -> anyhow::Result<String> {
    let len = read_varint_buf(buf)? as usize;
    if buf.remaining() < len {
        anyhow::bail!("short buffer")
    }
    let bytes = buf.copy_to_bytes(len);
    Ok(String::from_utf8(bytes.to_vec()).context("invalid utf-8")?)
}

async fn write_all_send<S>(send: &mut S, data: bytes::Bytes) -> anyhow::Result<()>
where
    S: web_transport_trait::SendStream + Unpin,
{
    let mut data = data;
    while data.has_remaining() {
        web_transport_trait::SendStream::write_buf(send, &mut data)
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;
    }
    Ok(())
}

async fn read_exact_recv<R>(recv: &mut R, len: usize) -> anyhow::Result<bytes::Bytes>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    let mut out = BytesMut::with_capacity(len);
    while out.len() < len {
        match web_transport_trait::RecvStream::read_chunk(recv, len - out.len())
            .await
            .map_err(|e| anyhow::anyhow!(e.to_string()))?
        {
            Some(chunk) => out.extend_from_slice(&chunk),
            None => anyhow::bail!("stream closed"),
        }
    }
    Ok(out.freeze())
}

async fn skip_exact_recv<R>(recv: &mut R, len: usize) -> anyhow::Result<()>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    let _ = read_exact_recv(recv, len).await?;
    Ok(())
}

async fn read_varint_recv<R>(recv: &mut R) -> anyhow::Result<u64>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    let first = read_exact_recv(recv, 1).await?;
    let tag = first[0] >> 6;
    let bytes = 1usize << tag;
    if bytes == 1 {
        return Ok((first[0] & 0x3f) as u64);
    }

    let rest = read_exact_recv(recv, bytes - 1).await?;
    let mut buf = BytesMut::with_capacity(bytes);
    buf.extend_from_slice(&first);
    buf.extend_from_slice(&rest);
    let mut cursor = Cursor::new(buf.freeze());
    read_varint_buf(&mut cursor)
}

async fn read_varint_maybe_recv<R>(recv: &mut R) -> anyhow::Result<Option<u64>>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    match web_transport_trait::RecvStream::read_chunk(recv, 1)
        .await
        .map_err(|e| anyhow::anyhow!(e.to_string()))?
    {
        None => Ok(None),
        Some(first) => {
            let tag = first[0] >> 6;
            let bytes = 1usize << tag;
            if bytes == 1 {
                Ok(Some((first[0] & 0x3f) as u64))
            } else {
                let rest = read_exact_recv(recv, bytes - 1).await?;
                let mut buf = BytesMut::with_capacity(bytes);
                buf.extend_from_slice(&first);
                buf.extend_from_slice(&rest);
                let mut cursor = Cursor::new(buf.freeze());
                Ok(Some(read_varint_buf(&mut cursor)?))
            }
        }
    }
}

async fn read_u16_recv<R>(recv: &mut R) -> anyhow::Result<u16>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    let bytes = read_exact_recv(recv, 2).await?;
    let mut cursor = Cursor::new(bytes.as_ref());
    Ok(cursor.get_u16())
}

async fn read_u8_recv<R>(recv: &mut R) -> anyhow::Result<u8>
where
    R: web_transport_trait::RecvStream + Unpin,
{
    Ok(read_exact_recv(recv, 1).await?[0])
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
