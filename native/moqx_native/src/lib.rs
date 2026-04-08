use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use bytes::Bytes;
use rustler::env::SavedTerm;
use rustler::types::reference::Reference;
use rustler::{Atom, Binary, Encoder, Env, LocalPid, NewBinary, OwnedEnv, Resource, ResourceArc};
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot, watch};

use moqtail::model::common::pair::KeyValuePair;
use moqtail::model::common::tuple::{Tuple, TupleField};
use moqtail::model::control::client_setup::ClientSetup;
use moqtail::model::control::constant::{DRAFT_14, GroupOrder as MoqGroupOrder};
use moqtail::model::control::control_message::ControlMessage;
use moqtail::model::control::fetch::{Fetch as MoqFetch, StandAloneFetchProps};
use moqtail::model::control::publish_namespace::PublishNamespace;
use moqtail::model::control::subscribe::Subscribe as MoqSubscribe;
use moqtail::model::control::subscribe_ok::SubscribeOk;
use moqtail::model::data::constant::{ObjectForwardingPreference, ObjectStatus};
use moqtail::model::data::fetch_object::FetchObject;
use moqtail::model::data::subgroup_header::SubgroupHeader;
use moqtail::model::data::subgroup_object::SubgroupObject;
use moqtail::transport::control_stream_handler::ControlStreamHandler;
use moqtail::transport::data_stream_handler::{HeaderInfo, SendDataStream};

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

struct PendingFetch {
    caller_pid: LocalPid,
    ref_env: OwnedEnv,
    ref_term: SavedTerm,
    namespace: String,
    track_name: String,
}

struct PendingSubscribe {
    caller_pid: LocalPid,
    broadcast_path: String,
    track_name: String,
}

struct ActiveSubscription {
    caller_pid: LocalPid,
    #[allow(dead_code)]
    broadcast_path: String,
    #[allow(dead_code)]
    track_name: String,
}

struct PendingPublish {
    tx: oneshot::Sender<Result<(), String>>,
}

/// A track that a remote subscriber has subscribed to via the relay.
/// The publisher needs to send data for this track.
struct IncomingSubscription {
    #[allow(dead_code)]
    request_id: u64,
    track_alias: u64,
    #[allow(dead_code)]
    track_name: String,
}

/// Shared session state behind Arc, accessed by background tasks and NIF calls.
struct SessionInner {
    control_tx: mpsc::Sender<ControlMessage>,
    connection: wtransport::Connection,
    next_request_id: AtomicU64,
    next_track_alias: AtomicU64,
    pending_subscribes: std::sync::Mutex<HashMap<u64, PendingSubscribe>>,
    active_subscriptions: std::sync::Mutex<HashMap<u64, ActiveSubscription>>,
    pending_fetches: std::sync::Mutex<HashMap<u64, PendingFetch>>,
    pending_publishes: std::sync::Mutex<HashMap<u64, PendingPublish>>,
    /// Incoming subscriptions from the relay (subscriber → relay → publisher).
    /// Keyed by "namespace/track_name" so write_frame can find the correct track_alias.
    incoming_subscriptions: std::sync::Mutex<HashMap<String, IncomingSubscription>>,
    #[allow(dead_code)]
    shutdown_tx: watch::Sender<bool>,
}

impl SessionInner {
    fn allocate_request_id(&self) -> u64 {
        // Client uses even IDs: 0, 2, 4, ...
        self.next_request_id.fetch_add(2, Ordering::Relaxed)
    }

    fn allocate_track_alias(&self) -> u64 {
        self.next_track_alias.fetch_add(1, Ordering::Relaxed)
    }
}

pub struct SessionRes {
    inner: Arc<SessionInner>,
    role: ConnectRole,
    root: String,
    version: String,
}

pub struct BroadcastProducerRes {
    session: Arc<SessionInner>,
    namespace: String,
}

pub struct TrackProducerRes {
    session: Arc<SessionInner>,
    namespace: String,
    track_name: String,
    group_seq: AtomicU64,
}

impl Resource for SessionRes {}
impl Resource for BroadcastProducerRes {}
impl Resource for TrackProducerRes {}

// ---------------------------------------------------------------------------
// Role
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq)]
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
                "invalid role: {other}"
            )))),
        }
    }
}

// ---------------------------------------------------------------------------
// TLS configuration
// ---------------------------------------------------------------------------

struct ConnectTls {
    disable_verify: bool,
    root: Vec<PathBuf>,
}

fn build_tls_config(tls: &ConnectTls) -> anyhow::Result<rustls::ClientConfig> {
    let mut root_store = rustls::RootCertStore::empty();

    if !tls.disable_verify {
        // Load system certs
        let native = rustls_native_certs::load_native_certs();
        for cert in native.certs {
            let _ = root_store.add(cert);
        }
        // Load custom CA certs
        for path in &tls.root {
            let pem = std::fs::read(path)?;
            let mut cursor = std::io::BufReader::new(pem.as_slice());
            for cert in rustls_pemfile::certs(&mut cursor) {
                root_store.add(cert?)?;
            }
        }
    }

    let mut config = if tls.disable_verify {
        rustls::ClientConfig::builder()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(InsecureVerifier))
            .with_no_client_auth()
    } else {
        rustls::ClientConfig::builder()
            .with_root_certificates(root_store)
            .with_no_client_auth()
    };

    // WebTransport requires h3 ALPN
    config.alpn_protocols = vec![b"h3".to_vec()];

    Ok(config)
}

#[derive(Debug)]
struct InsecureVerifier;

impl rustls::client::danger::ServerCertVerifier for InsecureVerifier {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _: &[u8],
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

// ---------------------------------------------------------------------------
// Path normalization
// ---------------------------------------------------------------------------

fn normalize_path(root: &str, path: &str) -> String {
    let trimmed = path.trim_matches('/');
    if root.is_empty() {
        return trimmed.to_string();
    }
    let root_trimmed = root.trim_matches('/');
    trimmed
        .strip_prefix(root_trimmed)
        .unwrap_or(trimmed)
        .trim_matches('/')
        .to_string()
}

fn extract_root(url: &url::Url) -> String {
    url.path().trim_matches('/').to_string()
}

// ---------------------------------------------------------------------------
// NIF: connect
// ---------------------------------------------------------------------------

#[rustler::nif]
fn connect(
    env: Env,
    url: String,
    role: String,
    tls_verify: String,
    tls_cacertfile: Option<String>,
) -> rustler::NifResult<Atom> {
    let parsed_url = url::Url::parse(&url)
        .map_err(|e| rustler::Error::Term(Box::new(format!("invalid url: {e}"))))?;
    let role = ConnectRole::from_str(&role)?;
    let tls = ConnectTls {
        disable_verify: tls_verify == "insecure",
        root: tls_cacertfile.into_iter().map(PathBuf::from).collect(),
    };

    let caller_pid = env.pid();

    runtime().spawn(async move {
        match do_connect(parsed_url, role, tls).await {
            Ok(session_res) => {
                let mut msg_env = OwnedEnv::new();
                let resource = ResourceArc::new(session_res);
                let _ = msg_env.send_and_clear(&caller_pid, |env| {
                    (atoms::moqx_connected(), resource.encode(env)).encode(env)
                });
            }
            Err(e) => {
                let reason = format!("{e:#}");
                let mut msg_env = OwnedEnv::new();
                let _ = msg_env.send_and_clear(&caller_pid, |env| {
                    (atoms::error(), reason).encode(env)
                });
            }
        }
    });

    Ok(atoms::ok())
}

async fn do_connect(
    url: url::Url,
    role: ConnectRole,
    tls: ConnectTls,
) -> anyhow::Result<SessionRes> {
    let root = extract_root(&url);
    let _ = rustls::crypto::ring::default_provider().install_default();
    let tls_config = build_tls_config(&tls)?;

    let config = wtransport::ClientConfig::builder()
        .with_bind_default()
        .with_custom_tls(tls_config)
        .build();

    let endpoint = wtransport::Endpoint::client(config)?;
    let connection = endpoint.connect(&url.to_string()).await?;

    // Open bidi control stream
    let (send, recv) = connection.open_bi().await?.await?;
    let mut handler = ControlStreamHandler::new(send, recv);

    // Send ClientSetup
    let max_req_id = KeyValuePair::try_new_varint(0x02, u32::MAX as u64)
        .map_err(|e| anyhow::anyhow!("MaxRequestId param: {e:?}"))?;
    let client_setup = ClientSetup {
        supported_versions: vec![DRAFT_14],
        setup_parameters: vec![max_req_id],
    };
    handler
        .send(&ControlMessage::ClientSetup(Box::new(client_setup)))
        .await
        .map_err(|e| anyhow::anyhow!("send ClientSetup: {e:?}"))?;

    // Receive ServerSetup
    let server_msg = handler
        .next_message()
        .await
        .map_err(|e| anyhow::anyhow!("recv ServerSetup: {e:?}"))?;
    let version = match server_msg {
        ControlMessage::ServerSetup(setup) => {
            format!("moq-transport-{}", setup.selected_version & 0xFF)
        }
        other => anyhow::bail!("expected ServerSetup, got: {other:?}"),
    };

    // Set up shared state
    let (control_tx, control_rx) = mpsc::channel::<ControlMessage>(64);
    let (shutdown_tx, shutdown_rx) = watch::channel(false);

    let inner = Arc::new(SessionInner {
        control_tx,
        connection: connection.clone(),
        next_request_id: AtomicU64::new(0),
        next_track_alias: AtomicU64::new(0),
        pending_subscribes: std::sync::Mutex::new(HashMap::new()),
        active_subscriptions: std::sync::Mutex::new(HashMap::new()),
        pending_fetches: std::sync::Mutex::new(HashMap::new()),
        pending_publishes: std::sync::Mutex::new(HashMap::new()),
        incoming_subscriptions: std::sync::Mutex::new(HashMap::new()),
        shutdown_tx,
    });

    // Spawn control loop (Task 1)
    {
        let inner = inner.clone();
        let mut shutdown_rx = shutdown_rx.clone();
        tokio::spawn(async move {
            control_loop(handler, control_rx, inner, &mut shutdown_rx).await;
        });
    }

    // Spawn data stream acceptor (Task 2)
    {
        let inner = inner.clone();
        let conn = connection.clone();
        let mut shutdown_rx = shutdown_rx.clone();
        tokio::spawn(async move {
            data_stream_acceptor(conn, inner, &mut shutdown_rx).await;
        });
    }

    Ok(SessionRes {
        inner,
        role,
        root,
        version,
    })
}

// ---------------------------------------------------------------------------
// Background task: control loop
// ---------------------------------------------------------------------------

async fn control_loop(
    mut handler: ControlStreamHandler,
    mut control_rx: mpsc::Receiver<ControlMessage>,
    inner: Arc<SessionInner>,
    shutdown_rx: &mut watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            _ = shutdown_rx.changed() => break,
            msg = control_rx.recv() => {
                match msg {
                    Some(msg) => {
                        if handler.send(&msg).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
            result = handler.next_message() => {
                match result {
                    Ok(msg) => dispatch_control_response(msg, &inner),
                    Err(_) => break,
                }
            }
        }
    }
}

fn dispatch_control_response(msg: ControlMessage, inner: &Arc<SessionInner>) {
    match msg {
        ControlMessage::SubscribeOk(ok) => {
            let pending = inner
                .pending_subscribes
                .lock()
                .unwrap()
                .remove(&ok.request_id);
            if let Some(p) = pending {
                inner.active_subscriptions.lock().unwrap().insert(
                    ok.track_alias,
                    ActiveSubscription {
                        caller_pid: p.caller_pid,
                        broadcast_path: p.broadcast_path.clone(),
                        track_name: p.track_name.clone(),
                    },
                );
                let mut msg_env = OwnedEnv::new();
                let _ = msg_env.send_and_clear(&p.caller_pid, |env| {
                    (atoms::moqx_subscribed(), p.broadcast_path, p.track_name).encode(env)
                });
            }
        }
        ControlMessage::SubscribeError(err) => {
            let pending = inner
                .pending_subscribes
                .lock()
                .unwrap()
                .remove(&err.request_id);
            if let Some(p) = pending {
                let reason = format!(
                    "subscribe error: code={:?} reason={:?}",
                    err.error_code, err.reason_phrase
                );
                let mut msg_env = OwnedEnv::new();
                let _ = msg_env.send_and_clear(&p.caller_pid, |env| {
                    (atoms::moqx_error(), reason).encode(env)
                });
            }
        }
        ControlMessage::FetchOk(ok) => {
            let guard = inner.pending_fetches.lock().unwrap();
            if let Some(pf) = guard.get(&ok.request_id) {
                let ns = pf.namespace.clone();
                let tn = pf.track_name.clone();
                let mut msg_env = OwnedEnv::new();
                let pid = pf.caller_pid;
                pf.ref_env.run(|ref_env| {
                    let ref_term = pf.ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        (atoms::moqx_fetch_started(), ref_term.in_env(env), ns, tn).encode(env)
                    });
                });
            }
        }
        ControlMessage::FetchError(err) => {
            let pending = inner.pending_fetches.lock().unwrap().remove(&err.request_id);
            if let Some(pf) = pending {
                let reason = format!(
                    "fetch rejected: error={:?} reason={:?}",
                    err.error_code, err.reason_phrase
                );
                let mut msg_env = OwnedEnv::new();
                let pid = pf.caller_pid;
                pf.ref_env.run(|ref_env| {
                    let ref_term = pf.ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        (atoms::moqx_fetch_error(), ref_term.in_env(env), reason).encode(env)
                    });
                });
            }
        }
        ControlMessage::PublishOk(ok) => {
            let pending = inner
                .pending_publishes
                .lock()
                .unwrap()
                .remove(&ok.request_id);
            if let Some(pp) = pending {
                let _ = pp.tx.send(Ok(()));
            }
        }
        ControlMessage::PublishError(err) => {
            let pending = inner
                .pending_publishes
                .lock()
                .unwrap()
                .remove(&err.request_id);
            if let Some(pp) = pending {
                let _ = pp.tx.send(Err(format!("publish error: {:?}", err)));
            }
        }
        ControlMessage::PublishNamespaceOk(ok) => {
            // Treat as publish confirmation (same request_id flow)
            let pending = inner
                .pending_publishes
                .lock()
                .unwrap()
                .remove(&ok.request_id);
            if let Some(pp) = pending {
                let _ = pp.tx.send(Ok(()));
            }
        }
        ControlMessage::PublishNamespaceError(err) => {
            let pending = inner
                .pending_publishes
                .lock()
                .unwrap()
                .remove(&err.request_id);
            if let Some(pp) = pending {
                let _ = pp.tx.send(Err(format!("publish namespace error: {:?}", err)));
            }
        }
        ControlMessage::Subscribe(sub) => {
            // Relay is forwarding a subscriber's Subscribe to us (publisher).
            // Respond with SubscribeOk and track this as an incoming subscription.
            let track_alias = inner.allocate_track_alias();
            let track_name = sub.track_name.as_str();
            let namespace = sub.track_namespace.to_utf8_path();

            let key = format!("{}/{}", namespace.trim_matches('/'), track_name);
            inner.incoming_subscriptions.lock().unwrap().insert(
                key,
                IncomingSubscription {
                    request_id: sub.request_id,
                    track_alias,
                    track_name: track_name.clone(),
                },
            );

            // Send SubscribeOk back to the relay
            let ok = SubscribeOk::new_ascending_no_content(
                sub.request_id,
                track_alias,
                0, // expires
                None,
            );
            let inner_clone = inner.clone();
            tokio::spawn(async move {
                let _ = inner_clone
                    .control_tx
                    .send(ControlMessage::SubscribeOk(Box::new(ok)))
                    .await;
            });
        }
        _ => {
            // MaxRequestId, GoAway, etc. -- ignore for now
        }
    }
}

// ---------------------------------------------------------------------------
// Background task: data stream acceptor
// ---------------------------------------------------------------------------

async fn data_stream_acceptor(
    connection: wtransport::Connection,
    inner: Arc<SessionInner>,
    shutdown_rx: &mut watch::Receiver<bool>,
) {
    loop {
        tokio::select! {
            _ = shutdown_rx.changed() => break,
            result = connection.accept_uni() => {
                match result {
                    Ok(recv) => {
                        let inner = inner.clone();
                        tokio::spawn(async move {
                            if let Err(e) = handle_data_stream(recv, &inner).await {
                                // Stream-level error, not session-fatal
                                let _ = e;
                            }
                        });
                    }
                    Err(_) => break,
                }
            }
        }
    }
}

async fn handle_data_stream(
    mut recv: wtransport::RecvStream,
    inner: &Arc<SessionInner>,
) -> anyhow::Result<()> {
    // Read the first bytes to determine stream type
    let mut peek_buf = [0u8; 1];
    recv.read_exact(&mut peek_buf).await?;
    let first_byte = peek_buf[0];

    // Determine header type from first byte's varint value
    // FetchHeader type = 0x05
    // SubgroupHeader types = 0x10..=0x1D
    if first_byte == 0x05 {
        handle_fetch_stream(recv, inner, first_byte).await
    } else if (0x10..=0x1D).contains(&first_byte) {
        handle_subgroup_stream(recv, inner, first_byte).await
    } else {
        // Unknown stream type, skip
        Ok(())
    }
}

async fn handle_fetch_stream(
    mut recv: wtransport::RecvStream,
    inner: &Arc<SessionInner>,
    _header_type_byte: u8,
) -> anyhow::Result<()> {
    // Read request_id (varint) from stream
    let request_id = read_varint_from_stream(&mut recv).await?;

    // Read fetch objects until stream ends
    loop {
        match read_fetch_object(&mut recv).await {
            Ok(Some(obj)) => {
                // Send {:moqx_fetch_object, ref, group_id, object_id, payload}
                let guard = inner.pending_fetches.lock().unwrap();
                if let Some(pf) = guard.get(&request_id) {
                    if let Some(payload) = &obj.payload {
                        let gid = obj.group_id;
                        let oid = obj.object_id;
                        let data = payload.clone();
                        let pid = pf.caller_pid;
                        let mut msg_env = OwnedEnv::new();
                        pf.ref_env.run(|ref_env| {
                            let ref_term = pf.ref_term.load(ref_env);
                            let _ = msg_env.send_and_clear(&pid, |env| {
                                let mut bin = NewBinary::new(env, data.len());
                                bin.as_mut_slice().copy_from_slice(&data);
                                let bin_term: rustler::Term = bin.into();
                                (
                                    atoms::moqx_fetch_object(),
                                    ref_term.in_env(env),
                                    gid,
                                    oid,
                                    bin_term,
                                )
                                    .encode(env)
                            });
                        });
                    }
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    // Send {:moqx_fetch_done, ref} and cleanup
    let pending = inner.pending_fetches.lock().unwrap().remove(&request_id);
    if let Some(pf) = pending {
        let mut msg_env = OwnedEnv::new();
        let pid = pf.caller_pid;
        pf.ref_env.run(|ref_env| {
            let ref_term = pf.ref_term.load(ref_env);
            let _ = msg_env.send_and_clear(&pid, |env| {
                (atoms::moqx_fetch_done(), ref_term.in_env(env)).encode(env)
            });
        });
    }

    Ok(())
}

async fn handle_subgroup_stream(
    mut recv: wtransport::RecvStream,
    inner: &Arc<SessionInner>,
    header_type_byte: u8,
) -> anyhow::Result<()> {
    // Parse SubgroupHeader: we already read the type byte
    // Read remaining header fields
    let track_alias = read_varint_from_stream(&mut recv).await?;
    let group_id = read_varint_from_stream(&mut recv).await?;

    // Determine if subgroup_id is present based on header type
    let has_explicit_subgroup = matches!(header_type_byte, 0x14 | 0x15 | 0x1C | 0x1D);
    let _subgroup_id = if has_explicit_subgroup {
        Some(read_varint_from_stream(&mut recv).await?)
    } else {
        None
    };

    // Publisher priority
    let mut prio_buf = [0u8; 1];
    recv.read_exact(&mut prio_buf).await?;

    // Check if this header type has extensions
    let has_extensions = matches!(
        header_type_byte,
        0x11 | 0x13 | 0x15 | 0x19 | 0x1B | 0x1D
    );

    // Look up subscription by track_alias
    let caller_pid = {
        let guard = inner.active_subscriptions.lock().unwrap();
        guard.get(&track_alias).map(|s| s.caller_pid)
    };

    let Some(caller_pid) = caller_pid else {
        return Ok(()); // Unknown track alias, skip
    };

    // Read SubgroupObjects
    let mut prev_object_id: Option<u64> = None;

    loop {
        match read_subgroup_object(&mut recv, &prev_object_id, has_extensions).await {
            Ok(Some(obj)) => {
                let object_id = obj.object_id;
                prev_object_id = Some(object_id);

                if let Some(payload) = &obj.payload {
                    let data = payload.clone();
                    let gid = group_id;
                    let mut msg_env = OwnedEnv::new();
                    let _ = msg_env.send_and_clear(&caller_pid, |env| {
                        let mut bin = NewBinary::new(env, data.len());
                        bin.as_mut_slice().copy_from_slice(&data);
                        let bin_term: rustler::Term = bin.into();
                        (atoms::moqx_frame(), gid, bin_term).encode(env)
                    });
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Stream reading helpers
// ---------------------------------------------------------------------------

async fn read_varint_from_stream(recv: &mut wtransport::RecvStream) -> anyhow::Result<u64> {
    let mut first = [0u8; 1];
    recv.read_exact(&mut first).await?;
    let tag = first[0] >> 6;
    let len = 1usize << tag;
    let mut buf = vec![0u8; len];
    buf[0] = first[0];
    if len > 1 {
        recv.read_exact(&mut buf[1..]).await?;
    }
    let bytes = bytes::Bytes::from(buf);
    // Clear the tag bits from the first byte
    let first_byte = bytes[0] & (0xFF >> (tag + 1));
    let mut result: u64 = first_byte as u64;
    for i in 1..len {
        result = (result << 8) | bytes[i] as u64;
    }
    Ok(result)
}

async fn read_fetch_object(
    recv: &mut wtransport::RecvStream,
) -> anyhow::Result<Option<FetchObject>> {
    // Read group_id
    let group_id = match read_varint_maybe(recv).await? {
        Some(v) => v,
        None => return Ok(None),
    };
    let subgroup_id = read_varint_from_stream(recv).await?;
    let object_id = read_varint_from_stream(recv).await?;

    let mut prio = [0u8; 1];
    recv.read_exact(&mut prio).await?;
    let publisher_priority = prio[0];

    // Extension headers length
    let ext_len = read_varint_from_stream(recv).await? as usize;
    if ext_len > 0 {
        let mut skip = vec![0u8; ext_len];
        recv.read_exact(&mut skip).await?;
    }

    // Payload length
    let payload_len = read_varint_from_stream(recv).await? as usize;
    let (payload, _object_status) = if payload_len == 0 {
        let status = read_varint_from_stream(recv).await?;
        (None, Some(status))
    } else {
        let mut data = vec![0u8; payload_len];
        recv.read_exact(&mut data).await?;
        (Some(Bytes::from(data)), None)
    };

    Ok(Some(FetchObject {
        group_id,
        subgroup_id,
        object_id,
        publisher_priority,
        extension_headers: None,
        object_status: None, // We handle status above but FetchObject needs the enum
        payload,
    }))
}

async fn read_subgroup_object(
    recv: &mut wtransport::RecvStream,
    prev_object_id: &Option<u64>,
    has_extensions: bool,
) -> anyhow::Result<Option<SubgroupObject>> {
    // Read object_id_delta
    let delta = match read_varint_maybe(recv).await? {
        Some(v) => v,
        None => return Ok(None),
    };

    let object_id = match prev_object_id {
        Some(prev) => prev + delta + 1,
        None => delta,
    };

    // Extension headers (if present)
    if has_extensions {
        let ext_len = read_varint_from_stream(recv).await? as usize;
        if ext_len > 0 {
            let mut skip = vec![0u8; ext_len];
            recv.read_exact(&mut skip).await?;
        }
    }

    // Payload length
    let payload_len = read_varint_from_stream(recv).await? as usize;
    let payload = if payload_len == 0 {
        // Object status follows
        let _status = read_varint_from_stream(recv).await?;
        None
    } else {
        let mut data = vec![0u8; payload_len];
        recv.read_exact(&mut data).await?;
        Some(Bytes::from(data))
    };

    Ok(Some(SubgroupObject {
        object_id,
        extension_headers: None,
        object_status: None,
        payload,
    }))
}

async fn read_varint_maybe(recv: &mut wtransport::RecvStream) -> anyhow::Result<Option<u64>> {
    let mut first = [0u8; 1];
    match recv.read(&mut first).await {
        Ok(Some(0)) | Ok(None) => return Ok(None),
        Ok(Some(_)) => {}
        Err(_) => return Ok(None),
    }
    let tag = first[0] >> 6;
    let len = 1usize << tag;
    let first_byte = first[0] & (0xFF >> (tag + 1));
    let mut result: u64 = first_byte as u64;
    if len > 1 {
        let mut rest = vec![0u8; len - 1];
        recv.read_exact(&mut rest).await?;
        for b in rest {
            result = (result << 8) | b as u64;
        }
    }
    Ok(Some(result))
}

// ---------------------------------------------------------------------------
// NIF: session_version / session_role / session_close
// ---------------------------------------------------------------------------

#[rustler::nif]
fn session_version(session: ResourceArc<SessionRes>) -> String {
    session.version.clone()
}

#[rustler::nif]
fn session_role(session: ResourceArc<SessionRes>) -> String {
    session.role.as_str().to_string()
}

#[rustler::nif]
fn session_close(session: ResourceArc<SessionRes>) -> Atom {
    let _ = session.inner.shutdown_tx.send(true);
    atoms::ok()
}

// ---------------------------------------------------------------------------
// NIF: publish / create_track / write_frame / finish_track
// ---------------------------------------------------------------------------

#[rustler::nif]
fn publish<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionRes>,
    broadcast_path: String,
) -> rustler::NifResult<rustler::Term<'a>> {
    if !session.role.can_publish() {
        return Err(rustler::Error::Term(Box::new(
            "publish requires a publisher session; use MOQX.connect_publisher/1".to_string(),
        )));
    }

    let namespace = normalize_path(&session.root, &broadcast_path);
    let inner = session.inner.clone();

    // Send PublishNamespace to announce availability to the relay.
    // This is fire-and-forget from the NIF perspective; the relay will
    // respond with PublishNamespaceOk which is handled by the control loop.
    let ns_clone = namespace.clone();
    runtime().spawn(async move {
        let request_id = inner.allocate_request_id();
        let (tx, _rx) = oneshot::channel();
        inner
            .pending_publishes
            .lock()
            .unwrap()
            .insert(request_id, PendingPublish { tx });

        let msg = PublishNamespace::new(
            request_id,
            Tuple::from_utf8_path(&ns_clone),
            &[],
        );
        let _ = inner
            .control_tx
            .send(ControlMessage::PublishNamespace(Box::new(msg)))
            .await;
    });

    let res = ResourceArc::new(BroadcastProducerRes {
        session: session.inner.clone(),
        namespace,
    });
    Ok((atoms::ok(), res).encode(env))
}

#[rustler::nif]
fn create_track<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastProducerRes>,
    track_name: String,
) -> rustler::NifResult<rustler::Term<'a>> {
    let res = ResourceArc::new(TrackProducerRes {
        session: broadcast.session.clone(),
        namespace: broadcast.namespace.clone(),
        track_name,
        group_seq: AtomicU64::new(0),
    });
    Ok((atoms::ok(), res).encode(env))
}

#[rustler::nif]
fn write_frame(track: ResourceArc<TrackProducerRes>, data: Binary) -> rustler::NifResult<Atom> {
    let payload = Bytes::copy_from_slice(data.as_slice());
    let session = track.session.clone();
    let namespace = track.namespace.clone();
    let track_name_str = track.track_name.clone();
    let group_seq = track.group_seq.fetch_add(1, Ordering::Relaxed);

    runtime().spawn(async move {
        if let Err(e) = do_write_frame(
            &session,
            &namespace,
            &track_name_str,
            group_seq,
            payload,
        )
        .await
        {
            let _ = e;
        }
    });

    Ok(atoms::ok())
}

async fn do_write_frame(
    session: &Arc<SessionInner>,
    namespace: &str,
    track_name: &str,
    group_seq: u64,
    payload: Bytes,
) -> anyhow::Result<()> {
    // Look up the track_alias from the incoming subscription.
    // The relay assigned this alias when it forwarded the subscriber's Subscribe.
    let key = format!("{}/{}", namespace.trim_matches('/'), track_name);
    let track_alias = {
        let guard = session.incoming_subscriptions.lock().unwrap();
        guard
            .get(&key)
            .map(|s| s.track_alias)
            .ok_or_else(|| anyhow::anyhow!("no subscriber for {key}"))?
    };

    let send = session.connection.open_uni().await?.await?;
    let send = Arc::new(tokio::sync::Mutex::new(send));

    let header = SubgroupHeader::new_fixed_zero_id(
        track_alias,
        group_seq,
        0,     // priority
        false, // no extensions
        false, // no end-of-group marker
    );
    let header_info = HeaderInfo::Subgroup { header };

    let mut data_stream = SendDataStream::new(send, header_info)
        .await
        .map_err(|e| anyhow::anyhow!("create data stream: {e:?}"))?;

    let object = moqtail::model::data::object::Object {
        track_alias,
        location: moqtail::model::common::location::Location::new(group_seq, 0),
        publisher_priority: 0,
        forwarding_preference: ObjectForwardingPreference::Subgroup,
        subgroup_id: Some(0),
        status: ObjectStatus::Normal,
        extensions: None,
        payload: Some(payload),
    };

    data_stream
        .send_object(&object, None)
        .await
        .map_err(|e| anyhow::anyhow!("send object: {e:?}"))?;

    data_stream
        .finish()
        .await
        .map_err(|e| anyhow::anyhow!("finish stream: {e:?}"))?;

    Ok(())
}

#[rustler::nif]
fn finish_track(track: ResourceArc<TrackProducerRes>) -> rustler::NifResult<Atom> {
    let key = format!(
        "{}/{}",
        track.namespace.trim_matches('/'),
        track.track_name
    );
    track
        .session
        .incoming_subscriptions
        .lock()
        .unwrap()
        .remove(&key);

    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// NIF: subscribe
// ---------------------------------------------------------------------------

#[rustler::nif]
fn subscribe(
    env: Env,
    session: ResourceArc<SessionRes>,
    broadcast_path: String,
    track_name: String,
    delivery_timeout_ms: Option<u64>,
) -> rustler::NifResult<Atom> {
    if !session.role.can_consume() {
        return Err(rustler::Error::Term(Box::new(
            "subscribe requires a subscriber session; use MOQX.connect_subscriber/1".to_string(),
        )));
    }

    let caller_pid = env.pid();
    let inner = session.inner.clone();
    let namespace = normalize_path(&session.root, &broadcast_path);

    let subscribe_parameters = match delivery_timeout_ms {
        Some(timeout_ms) => {
            vec![KeyValuePair::try_new_varint(0x02, timeout_ms).map_err(|e| {
                rustler::Error::Term(Box::new(format!(
                    "invalid delivery_timeout_ms parameter: {:?}",
                    e
                )))
            })?]
        }
        None => vec![],
    };

    runtime().spawn(async move {
        let request_id = inner.allocate_request_id();
        let subscribe_msg = MoqSubscribe::new_latest_object(
            request_id,
            Tuple::from_utf8_path(&namespace),
            TupleField::from_utf8(&track_name),
            0, // subscriber_priority
            MoqGroupOrder::Ascending,
            true, // forward
            subscribe_parameters,
        );

        inner.pending_subscribes.lock().unwrap().insert(
            request_id,
            PendingSubscribe {
                caller_pid,
                broadcast_path: broadcast_path.clone(),
                track_name: track_name.clone(),
            },
        );

        if inner
            .control_tx
            .send(ControlMessage::Subscribe(Box::new(subscribe_msg)))
            .await
            .is_err()
        {
            inner.pending_subscribes.lock().unwrap().remove(&request_id);
            let mut msg_env = OwnedEnv::new();
            let _ = msg_env.send_and_clear(&caller_pid, |env| {
                (atoms::moqx_error(), "control channel closed").encode(env)
            });
        }
    });

    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// NIF: fetch
// ---------------------------------------------------------------------------

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

    let caller_pid = env.pid();
    let inner = session.inner.clone();
    let normalized_ns = normalize_path(&session.root, &namespace);

    let moq_group_order = match group_order.as_str() {
        "original" => MoqGroupOrder::Original,
        "ascending" => MoqGroupOrder::Ascending,
        "descending" => MoqGroupOrder::Descending,
        other => {
            return Err(rustler::Error::Term(Box::new(format!(
                "invalid group order: {other}"
            ))))
        }
    };

    let start_loc = moqtail::model::common::location::Location::new(start.0, start.1);
    let end_loc = match end {
        Some((g, o)) => moqtail::model::common::location::Location::new(g, o),
        None => moqtail::model::common::location::Location::new(u64::MAX, u64::MAX),
    };

    let ref_env = OwnedEnv::new();
    let ref_term = ref_env.save(fetch_ref);

    runtime().spawn(async move {
        let request_id = inner.allocate_request_id();

        let fetch_props = StandAloneFetchProps {
            track_namespace: Tuple::from_utf8_path(&normalized_ns),
            track_name: TupleField::from_utf8(&track_name),
            start_location: start_loc,
            end_location: end_loc,
        };

        let fetch_msg =
            MoqFetch::new_standalone(request_id, priority, moq_group_order, fetch_props, vec![]);

        inner.pending_fetches.lock().unwrap().insert(
            request_id,
            PendingFetch {
                caller_pid,
                ref_env,
                ref_term,
                namespace: namespace.clone(),
                track_name: track_name.clone(),
            },
        );

        if inner
            .control_tx
            .send(ControlMessage::Fetch(Box::new(fetch_msg)))
            .await
            .is_err()
        {
            let pending = inner.pending_fetches.lock().unwrap().remove(&request_id);
            if let Some(pf) = pending {
                let mut msg_env = OwnedEnv::new();
                let pid = pf.caller_pid;
                pf.ref_env.run(|ref_env| {
                    let ref_term = pf.ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        (
                            atoms::moqx_fetch_error(),
                            ref_term.in_env(env),
                            "control channel closed",
                        )
                            .encode(env)
                    });
                });
            }
        }
    });

    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// NIF: normalize_fetch_namespace (test helper)
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_path() {
        assert_eq!(normalize_path("", "moqtail"), "moqtail");
        assert_eq!(normalize_path("room/demo", "room/demo/stream"), "stream");
        assert_eq!(normalize_path("room/demo", "other/path"), "other/path");
        assert_eq!(normalize_path("root", "/root/sub/"), "sub");
    }
}

// ---------------------------------------------------------------------------
// NIF init
// ---------------------------------------------------------------------------

fn load(env: Env, _: rustler::Term) -> bool {
    env.register::<SessionRes>().is_ok()
        && env.register::<BroadcastProducerRes>().is_ok()
        && env.register::<TrackProducerRes>().is_ok()
}

rustler::init!("Elixir.MOQX.Native", load = load);
