use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};

use bytes::Bytes;
use rustler::env::SavedTerm;
use rustler::types::reference::Reference;
use rustler::{Atom, Binary, Encoder, Env, LocalPid, NewBinary, OwnedEnv, Resource, ResourceArc};
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot, watch};
use tokio::time::{sleep, Duration, Instant};

use moqtail::model::common::location::Location;
use moqtail::model::common::pair::KeyValuePair;
use moqtail::model::common::tuple::{Tuple, TupleField};
use moqtail::model::control::client_setup::ClientSetup;
use moqtail::model::control::constant::{
    GroupOrder as MoqGroupOrder, PublishDoneStatusCode, SubscribeErrorCode, DRAFT_14,
};
use moqtail::model::control::control_message::ControlMessage;
use moqtail::model::control::fetch::{Fetch as MoqFetch, StandAloneFetchProps};
use moqtail::model::control::publish_namespace::PublishNamespace;
use moqtail::model::control::subscribe::Subscribe as MoqSubscribe;
use moqtail::model::control::subscribe_ok::SubscribeOk;
use moqtail::model::control::unsubscribe::Unsubscribe as MoqUnsubscribe;
use moqtail::model::data::constant::{
    ObjectForwardingPreference, ObjectStatus, SubgroupHeaderType,
};
use moqtail::model::data::fetch_object::FetchObject;
use moqtail::model::data::subgroup_header::SubgroupHeader;
use moqtail::transport::control_stream_handler::ControlStreamHandler;
use moqtail::transport::data_stream_handler::{HeaderInfo, SendDataStream};

mod atoms {
    rustler::atoms! {
        ok,
        error,
        moqx_connect_ok,
        moqx_session_closed,
        moqx_publish_ok,
        moqx_subscribe_ok,
        moqx_track_init,
        moqx_object,
        moqx_end_of_group,
        moqx_flush_ok,
        moqx_track_active,
        moqx_track_closed,
        moqx_publish_done,
        moqx_request_error,
        moqx_transport_error,
        moqx_fetch_ok,
        moqx_fetch_object,
        moqx_fetch_done,
        connect,
        publish,
        subscribe,
        fetch,
        open_subgroup,
        write_object,
        close_subgroup,
        flush_subgroup,
        track_not_active,
        track_closed,
        runtime,
        publisher,
        subscriber,
        ended,
        unsubscribe_ack,
        expired,
        unknown,
        normal,
        does_not_exist,
        end_of_group,
        end_of_track,
        internal_error,
        unauthorized,
        timeout,
        not_supported,
        track_does_not_exist,
        invalid_range,
        malformed_auth_token,
        expired_auth_token,
    }
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.Object"]
struct MoqxObjectOut<'a> {
    group_id: u64,
    subgroup_id: u64,
    object_id: u64,
    priority: u8,
    status: Atom,
    extensions: Vec<rustler::Term<'a>>,
    payload: rustler::Term<'a>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.ConnectOk"]
struct ConnectOkOut<'a> {
    r#ref: rustler::Term<'a>,
    session: rustler::Term<'a>,
    role: Atom,
    version: String,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.PublishOk"]
struct PublishOkOut<'a> {
    r#ref: rustler::Term<'a>,
    broadcast: rustler::Term<'a>,
    namespace: String,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.FlushDone"]
struct FlushDoneOut<'a> {
    r#ref: rustler::Term<'a>,
    handle: rustler::Term<'a>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.RequestError"]
struct RequestErrorOut<'a> {
    op: Atom,
    message: String,
    code: Option<Atom>,
    r#ref: rustler::Term<'a>,
    handle: rustler::Term<'a>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.TransportError"]
struct TransportErrorOut<'a> {
    op: Atom,
    message: String,
    kind: Option<Atom>,
    r#ref: rustler::Term<'a>,
    handle: rustler::Term<'a>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.SubscribeOk"]
struct SubscribeOkOut<'a> {
    handle: rustler::Term<'a>,
    namespace: String,
    track_name: String,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.TrackInit"]
struct TrackInitOut<'a> {
    handle: rustler::Term<'a>,
    init_data: rustler::Term<'a>,
    track_meta: rustler::Term<'a>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.ObjectReceived"]
struct ObjectReceivedOut<'a> {
    handle: rustler::Term<'a>,
    object: rustler::Term<'a>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.EndOfGroup"]
struct EndOfGroupOut<'a> {
    handle: rustler::Term<'a>,
    group_id: u64,
    subgroup_id: u64,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.TrackActive"]
struct TrackActiveOut<'a> {
    track: rustler::Term<'a>,
    namespace: String,
    track_name: String,
    track_alias: u64,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.TrackClosed"]
struct TrackClosedOut<'a> {
    track: rustler::Term<'a>,
    namespace: String,
    track_name: String,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.PublishDone"]
struct PublishDoneOut<'a> {
    handle: rustler::Term<'a>,
    status: Atom,
    code: Option<u64>,
    message: Option<String>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.FetchOk"]
struct FetchOkOut<'a> {
    r#ref: rustler::Term<'a>,
    namespace: String,
    track_name: String,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.FetchObject"]
struct FetchObjectOut<'a> {
    r#ref: rustler::Term<'a>,
    group_id: u64,
    object_id: u64,
    payload: rustler::Term<'a>,
}

#[derive(rustler::NifStruct)]
#[module = "MOQX.FetchDone"]
struct FetchDoneOut<'a> {
    r#ref: rustler::Term<'a>,
}

fn status_to_atom(status: ObjectStatus) -> Atom {
    match status {
        ObjectStatus::Normal => atoms::normal(),
        ObjectStatus::DoesNotExist => atoms::does_not_exist(),
        ObjectStatus::EndOfGroup => atoms::end_of_group(),
        ObjectStatus::EndOfTrack => atoms::end_of_track(),
    }
}

fn publish_done_status_to_atom(status: PublishDoneStatusCode) -> Atom {
    match status {
        PublishDoneStatusCode::TrackEnded => atoms::ended(),
        PublishDoneStatusCode::SubscriptionEnded => atoms::unsubscribe_ack(),
        _ => atoms::unknown(),
    }
}

fn subscribe_error_code_to_atom(code: SubscribeErrorCode) -> Atom {
    match code {
        SubscribeErrorCode::InternalError => atoms::internal_error(),
        SubscribeErrorCode::Unauthorized => atoms::unauthorized(),
        SubscribeErrorCode::Timeout => atoms::timeout(),
        SubscribeErrorCode::NotSupported => atoms::not_supported(),
        SubscribeErrorCode::TrackDoesNotExist => atoms::track_does_not_exist(),
        SubscribeErrorCode::InvalidRange => atoms::invalid_range(),
        SubscribeErrorCode::MalformedAuthToken => atoms::malformed_auth_token(),
        SubscribeErrorCode::ExpiredAuthToken => atoms::expired_auth_token(),
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
    term_env: OwnedEnv,
    subscription_ref_term: SavedTerm,
    track_meta_term: SavedTerm,
    init_data: Option<Vec<u8>>,
}

struct ActiveSubscription {
    caller_pid: LocalPid,
    request_id: u64,
    #[allow(dead_code)]
    broadcast_path: String,
    #[allow(dead_code)]
    track_name: String,
    ref_env: OwnedEnv,
    subscription_ref_term: SavedTerm,
}

struct PendingPublish {
    caller_pid: LocalPid,
    ref_env: OwnedEnv,
    publish_ref_term: SavedTerm,
    namespace: String,
}

struct TrackNotifier {
    caller_pid: LocalPid,
    term_env: OwnedEnv,
    track_term: SavedTerm,
    namespace: String,
    track_name: String,
    active_notified: bool,
    closed_notified: bool,
}

struct TrackLifecycle {
    created: bool,
    active_alias: Option<u64>,
    closed: bool,
    notifiers: Vec<TrackNotifier>,
}

impl TrackLifecycle {
    fn created() -> Self {
        Self {
            created: true,
            active_alias: None,
            closed: false,
            notifiers: Vec::new(),
        }
    }

    fn pending() -> Self {
        Self {
            created: false,
            active_alias: None,
            closed: false,
            notifiers: Vec::new(),
        }
    }
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
    /// Publisher-side track lifecycle keyed by "namespace/track_name".
    track_lifecycle: std::sync::Mutex<HashMap<String, TrackLifecycle>>,
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

    fn register_track(
        &self,
        key: &str,
        caller_pid: LocalPid,
        track_term_env: OwnedEnv,
        track_term: SavedTerm,
        namespace: String,
        track_name: String,
    ) -> (Option<u64>, bool) {
        let mut guard = self.track_lifecycle.lock().unwrap();
        let entry = guard.entry(key.to_string()).or_insert_with(TrackLifecycle::pending);
        entry.created = true;
        entry.closed = false;

        let mut notifier = TrackNotifier {
            caller_pid,
            term_env: track_term_env,
            track_term,
            namespace,
            track_name,
            active_notified: false,
            closed_notified: false,
        };

        notifier.active_notified = entry.active_alias.is_some();
        notifier.closed_notified = entry.closed;

        let active_alias = entry.active_alias;
        let closed = entry.closed;

        entry.notifiers.push(notifier);

        (active_alias, closed)
    }

    fn activate_track(&self, key: &str, track_alias: u64) {
        let mut guard = self.track_lifecycle.lock().unwrap();
        let entry = guard.entry(key.to_string()).or_insert_with(TrackLifecycle::pending);
        if entry.closed {
            return;
        }

        entry.active_alias = Some(track_alias);

        for notifier in entry.notifiers.iter_mut() {
            if !notifier.active_notified {
                send_track_active(notifier, track_alias);
                notifier.active_notified = true;
            }
        }
    }

    fn write_track_alias(&self, key: &str) -> Result<u64, Atom> {
        let guard = self.track_lifecycle.lock().unwrap();
        let Some(entry) = guard.get(key) else {
            return Err(atoms::track_not_active());
        };

        if entry.closed {
            return Err(atoms::track_closed());
        }

        if !entry.created {
            return Err(atoms::track_not_active());
        }

        entry.active_alias.ok_or(atoms::track_not_active())
    }

    fn close_track(&self, key: &str) -> Vec<TrackNotifier> {
        let mut guard = self.track_lifecycle.lock().unwrap();
        let entry = guard.entry(key.to_string()).or_insert_with(TrackLifecycle::created);

        if entry.closed {
            return Vec::new();
        }

        entry.closed = true;
        entry.active_alias = None;

        for notifier in entry.notifiers.iter_mut() {
            notifier.closed_notified = true;
        }

        std::mem::take(&mut entry.notifiers)
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

pub struct SubscriptionHandle {
    session: Arc<SessionInner>,
    request_id: u64,
    canceled: AtomicBool,
}

struct SubgroupNotify {
    caller_pid: LocalPid,
    ref_env: OwnedEnv,
    subgroup_ref_term: SavedTerm,
}

/// Operation dispatched to a subgroup's single consumer task.
enum SubgroupOp {
    Write {
        object_id: u64,
        payload: Bytes,
        extensions: Vec<KeyValuePair>,
        status: ObjectStatus,
    },
    Close {
        emit_end_of_group_marker: bool,
    },
    Flush {
        tx: oneshot::Sender<Result<(), String>>,
    },
}

/// A handle to an open subgroup on a publishing track.
/// Owns the underlying QUIC uni-stream. Dropping (GC or explicit close) finishes the stream.
/// All operations (write/close/flush) are dispatched through an mpsc queue so they are
/// processed in strict FIFO order by a single consumer task. This matches the v0.4.x
/// semantics where one Tokio task per write handled open+write+finish atomically.
pub struct SubgroupRes {
    #[allow(dead_code)]
    session: Arc<SessionInner>,
    #[allow(dead_code)]
    group_id: u64,
    header_type: SubgroupHeaderType,
    // When None, the resource is unusable (consumer task exited). Operations become no-ops.
    op_tx: std::sync::Mutex<Option<tokio::sync::mpsc::UnboundedSender<SubgroupOp>>>,
    // Mutex<Option<_>> provides Sync around the !Sync OwnedEnv inside SubgroupNotify.
    // Populated exactly once by `open_subgroup` right after the resource is created.
    notify: std::sync::Mutex<Option<SubgroupNotify>>,
    closed: AtomicBool,
}

impl Resource for SessionRes {}
impl Resource for BroadcastProducerRes {}
impl Resource for TrackProducerRes {}
impl Resource for SubscriptionHandle {}
impl Resource for SubgroupRes {}

impl Drop for SubscriptionHandle {
    fn drop(&mut self) {
        if self.canceled.swap(true, Ordering::SeqCst) {
            return;
        }
        cleanup_subscription(&self.session, self.request_id);
    }
}

impl Drop for SubgroupRes {
    fn drop(&mut self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        // Dropping the Sender causes the consumer task to observe end-of-stream and
        // finish the QUIC uni-stream. No explicit Close op is needed here.
        let _ = self.op_tx.lock().unwrap().take();
    }
}

fn cleanup_subscription(session: &Arc<SessionInner>, request_id: u64) {
    let pending = session
        .pending_subscribes
        .lock()
        .unwrap()
        .remove(&request_id);

    let active = {
        let mut guard = session.active_subscriptions.lock().unwrap();
        let alias = guard
            .iter()
            .find(|(_, sub)| sub.request_id == request_id)
            .map(|(alias, _)| *alias);
        alias.and_then(|a| guard.remove(&a))
    };

    // OwnedEnv::run and send_and_clear must execute on a non-scheduler
    // thread, so do all environment work inside the Tokio runtime spawn
    // rather than on the calling NIF/Drop thread.
    let tx = session.control_tx.clone();
    runtime().spawn(async move {
        if let Some(p) = pending {
            let mut msg_env = OwnedEnv::new();
            let pid = p.caller_pid;
            p.term_env.run(|term_env| {
                let sub_ref = p.subscription_ref_term.load(term_env);
                let _ = msg_env.send_and_clear(&pid, |env| {
                    let payload = PublishDoneOut {
                        handle: sub_ref.in_env(env),
                        status: atoms::unsubscribe_ack(),
                        code: None,
                        message: None,
                    };
                    (atoms::moqx_publish_done(), payload).encode(env)
                });
            });
        } else if let Some(a) = active {
            let mut msg_env = OwnedEnv::new();
            let pid = a.caller_pid;
            a.ref_env.run(|ref_env| {
                let sub_ref = a.subscription_ref_term.load(ref_env);
                let _ = msg_env.send_and_clear(&pid, |env| {
                    let payload = PublishDoneOut {
                        handle: sub_ref.in_env(env),
                        status: atoms::unsubscribe_ack(),
                        code: None,
                        message: None,
                    };
                    (atoms::moqx_publish_done(), payload).encode(env)
                });
            });
        }

        let _ = tx
            .send(ControlMessage::Unsubscribe(Box::new(MoqUnsubscribe::new(
                request_id,
            ))))
            .await;
    });
}

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
    connect_ref: Reference,
) -> rustler::NifResult<Atom> {
    let parsed_url = url::Url::parse(&url)
        .map_err(|e| rustler::Error::Term(Box::new(format!("invalid url: {e}"))))?;
    let role = ConnectRole::from_str(&role)?;
    let tls = ConnectTls {
        disable_verify: tls_verify == "insecure",
        root: tls_cacertfile.into_iter().map(PathBuf::from).collect(),
    };

    let caller_pid = env.pid();
    let ref_env = OwnedEnv::new();
    let ref_term = ref_env.save(connect_ref);

    runtime().spawn(async move {
        match do_connect(parsed_url, role, tls).await {
            Ok(session_res) => {
                let mut msg_env = OwnedEnv::new();
                let resource = ResourceArc::new(session_res);
                ref_env.run(|saved_env| {
                    let connect_ref_term = ref_term.load(saved_env);
                    let role_atom = match resource.role {
                        ConnectRole::Publisher => atoms::publisher(),
                        ConnectRole::Subscriber => atoms::subscriber(),
                    };

                    let _ = msg_env.send_and_clear(&caller_pid, |env| {
                        let payload = ConnectOkOut {
                            r#ref: connect_ref_term.in_env(env),
                            session: resource.encode(env),
                            role: role_atom,
                            version: resource.version.clone(),
                        };
                        (atoms::moqx_connect_ok(), payload).encode(env)
                    });
                });
            }
            Err(e) => {
                let reason = format!("{e:#}");
                let mut msg_env = OwnedEnv::new();
                ref_env.run(|saved_env| {
                    let connect_ref_term = ref_term.load(saved_env);
                    let _ = msg_env.send_and_clear(&caller_pid, |env| {
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = TransportErrorOut {
                            op: atoms::connect(),
                            message: reason.clone(),
                            kind: Some(atoms::runtime()),
                            r#ref: connect_ref_term.in_env(env),
                            handle: nil,
                        };
                        (atoms::moqx_transport_error(), payload).encode(env)
                    });
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
        track_lifecycle: std::sync::Mutex::new(HashMap::new()),
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
                let ref_env = OwnedEnv::new();
                let subscription_ref_term = p.term_env.run(|term_env| {
                    let sub_ref = p.subscription_ref_term.load(term_env);
                    ref_env.save(sub_ref)
                });

                inner.active_subscriptions.lock().unwrap().insert(
                    ok.track_alias,
                    ActiveSubscription {
                        caller_pid: p.caller_pid,
                        request_id: ok.request_id,
                        broadcast_path: p.broadcast_path.clone(),
                        track_name: p.track_name.clone(),
                        ref_env,
                        subscription_ref_term,
                    },
                );

                let mut msg_env = OwnedEnv::new();
                let init_data = p.init_data.clone();
                p.term_env.run(|term_env| {
                    let sub_ref = p.subscription_ref_term.load(term_env);
                    let track_meta = p.track_meta_term.load(term_env);

                    let _ = msg_env.send_and_clear(&p.caller_pid, |env| {
                        let payload = SubscribeOkOut {
                            handle: sub_ref.in_env(env),
                            namespace: p.broadcast_path.clone(),
                            track_name: p.track_name.clone(),
                        };
                        (atoms::moqx_subscribe_ok(), payload).encode(env)
                    });

                    let _ = msg_env.send_and_clear(&p.caller_pid, |env| {
                        let init_data_term: rustler::Term = match &init_data {
                            Some(data) => {
                                let mut bin = NewBinary::new(env, data.len());
                                bin.as_mut_slice().copy_from_slice(data);
                                bin.into()
                            }
                            None => rustler::types::atom::nil().encode(env),
                        };

                        let payload = TrackInitOut {
                            handle: sub_ref.in_env(env),
                            init_data: init_data_term,
                            track_meta: track_meta.in_env(env),
                        };

                        (atoms::moqx_track_init(), payload).encode(env)
                    });
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
                p.term_env.run(|term_env| {
                    let sub_ref = p.subscription_ref_term.load(term_env);
                    let _ = msg_env.send_and_clear(&p.caller_pid, |env| {
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = RequestErrorOut {
                            op: atoms::subscribe(),
                            message: reason.clone(),
                            code: Some(subscribe_error_code_to_atom(err.error_code)),
                            r#ref: nil,
                            handle: sub_ref.in_env(env),
                        };
                        (atoms::moqx_request_error(), payload).encode(env)
                    });
                });
            }
        }
        ControlMessage::PublishDone(done) => {
            let removed = {
                let mut guard = inner.active_subscriptions.lock().unwrap();
                let alias = guard
                    .iter()
                    .find(|(_, sub)| sub.request_id == done.request_id)
                    .map(|(alias, _)| *alias);
                alias.and_then(|a| guard.remove(&a))
            };
            if let Some(active) = removed {
                let mut msg_env = OwnedEnv::new();
                let pid = active.caller_pid;
                active.ref_env.run(|ref_env| {
                    let sub_ref = active.subscription_ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        let payload = PublishDoneOut {
                            handle: sub_ref.in_env(env),
                            status: publish_done_status_to_atom(done.status_code),
                            code: None,
                            message: Some(format!("{:?}", done.reason_phrase)),
                        };
                        (atoms::moqx_publish_done(), payload).encode(env)
                    });
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
                        let payload = FetchOkOut {
                            r#ref: ref_term.in_env(env),
                            namespace: ns,
                            track_name: tn,
                        };
                        (atoms::moqx_fetch_ok(), payload).encode(env)
                    });
                });
            }
        }
        ControlMessage::FetchError(err) => {
            let pending = inner
                .pending_fetches
                .lock()
                .unwrap()
                .remove(&err.request_id);
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
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = RequestErrorOut {
                            op: atoms::fetch(),
                            message: reason,
                            code: None,
                            r#ref: ref_term.in_env(env),
                            handle: nil,
                        };
                        (atoms::moqx_request_error(), payload).encode(env)
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
                let mut msg_env = OwnedEnv::new();
                let pid = pp.caller_pid;
                let namespace = pp.namespace.clone();
                let broadcast = ResourceArc::new(BroadcastProducerRes {
                    session: inner.clone(),
                    namespace,
                });

                pp.ref_env.run(|ref_env| {
                    let publish_ref = pp.publish_ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        let payload = PublishOkOut {
                            r#ref: publish_ref.in_env(env),
                            broadcast: broadcast.encode(env),
                            namespace: pp.namespace.clone(),
                        };
                        (atoms::moqx_publish_ok(), payload).encode(env)
                    });
                });
            }
        }
        ControlMessage::PublishError(err) => {
            let pending = inner
                .pending_publishes
                .lock()
                .unwrap()
                .remove(&err.request_id);
            if let Some(pp) = pending {
                let reason = format!(
                    "publish rejected: error={:?} reason={:?}",
                    err.error_code, err.reason_phrase
                );
                let mut msg_env = OwnedEnv::new();
                let pid = pp.caller_pid;

                pp.ref_env.run(|ref_env| {
                    let publish_ref = pp.publish_ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = RequestErrorOut {
                            op: atoms::publish(),
                            message: reason.clone(),
                            code: None,
                            r#ref: publish_ref.in_env(env),
                            handle: nil,
                        };
                        (atoms::moqx_request_error(), payload).encode(env)
                    });
                });
            }
        }
        ControlMessage::PublishNamespaceOk(ok) => {
            let pending = inner
                .pending_publishes
                .lock()
                .unwrap()
                .remove(&ok.request_id);
            if let Some(pp) = pending {
                let mut msg_env = OwnedEnv::new();
                let pid = pp.caller_pid;
                let namespace = pp.namespace.clone();
                let broadcast = ResourceArc::new(BroadcastProducerRes {
                    session: inner.clone(),
                    namespace,
                });

                pp.ref_env.run(|ref_env| {
                    let publish_ref = pp.publish_ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        let payload = PublishOkOut {
                            r#ref: publish_ref.in_env(env),
                            broadcast: broadcast.encode(env),
                            namespace: pp.namespace.clone(),
                        };
                        (atoms::moqx_publish_ok(), payload).encode(env)
                    });
                });
            }
        }
        ControlMessage::PublishNamespaceError(err) => {
            let pending = inner
                .pending_publishes
                .lock()
                .unwrap()
                .remove(&err.request_id);
            if let Some(pp) = pending {
                let reason = format!(
                    "publish namespace rejected: error={:?} reason={:?}",
                    err.error_code, err.reason_phrase
                );
                let mut msg_env = OwnedEnv::new();
                let pid = pp.caller_pid;

                pp.ref_env.run(|ref_env| {
                    let publish_ref = pp.publish_ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = RequestErrorOut {
                            op: atoms::publish(),
                            message: reason.clone(),
                            code: None,
                            r#ref: publish_ref.in_env(env),
                            handle: nil,
                        };
                        (atoms::moqx_request_error(), payload).encode(env)
                    });
                });
            }
        }
        ControlMessage::Subscribe(sub) => {
            // Relay is forwarding a subscriber's Subscribe to us (publisher).
            // Respond with SubscribeOk and track this as an incoming subscription.
            let track_alias = inner.allocate_track_alias();
            let track_name = sub.track_name.as_str();
            let namespace = sub.track_namespace.to_utf8_path();

            let key = format!("{}/{}", namespace.trim_matches('/'), track_name);
            inner.activate_track(&key, track_alias);

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
                                let payload = FetchObjectOut {
                                    r#ref: ref_term.in_env(env),
                                    group_id: gid,
                                    object_id: oid,
                                    payload: bin_term,
                                };
                                (atoms::moqx_fetch_object(), payload).encode(env)
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
                let payload = FetchDoneOut {
                    r#ref: ref_term.in_env(env),
                };
                (atoms::moqx_fetch_done(), payload).encode(env)
            });
        });
    }

    Ok(())
}

async fn wait_for_active_subscription(
    inner: &Arc<SessionInner>,
    track_alias: u64,
    timeout: Duration,
    poll_interval: Duration,
) -> bool {
    let deadline = Instant::now() + timeout;

    loop {
        let has_subscription = {
            let guard = inner.active_subscriptions.lock().unwrap();
            guard.contains_key(&track_alias)
        };

        if has_subscription {
            return true;
        }

        if Instant::now() >= deadline {
            return false;
        }

        sleep(poll_interval).await;
    }
}

async fn handle_subgroup_stream(
    mut recv: wtransport::RecvStream,
    inner: &Arc<SessionInner>,
    header_type_byte: u8,
) -> anyhow::Result<()> {
    let header_type = SubgroupHeaderType::try_from(header_type_byte as u64).map_err(|e| {
        anyhow::anyhow!("invalid subgroup header type {header_type_byte:#x}: {e:?}")
    })?;

    let track_alias = read_varint_from_stream(&mut recv).await?;
    let group_id = read_varint_from_stream(&mut recv).await?;

    let explicit_subgroup_id = if header_type.has_explicit_subgroup_id() {
        Some(read_varint_from_stream(&mut recv).await?)
    } else {
        None
    };

    let mut prio_buf = [0u8; 1];
    recv.read_exact(&mut prio_buf).await?;
    let publisher_priority = prio_buf[0];

    let has_extensions = header_type.has_extensions();
    let header_marks_eog = header_type.contains_end_of_group();

    // Control and data travel on independent streams. A subgroup stream may arrive
    // just before the control loop processes the matching SubscribeOk(track_alias).
    // Wait briefly for local activation before deciding this alias is unknown.
    let has_subscription =
        wait_for_active_subscription(inner, track_alias, Duration::from_millis(2_000), Duration::from_millis(5)).await;

    if !has_subscription {
        return Ok(());
    }

    let mut prev_object_id: Option<u64> = None;
    let mut resolved_subgroup_id: Option<u64> = if header_type.subgroup_id_is_zero() {
        Some(0)
    } else {
        explicit_subgroup_id
    };
    let mut emitted_eog = false;

    loop {
        match read_subgroup_object(&mut recv, &prev_object_id, has_extensions).await {
            Ok(Some(obj)) => {
                let object_id = obj.object_id;
                if resolved_subgroup_id.is_none() {
                    resolved_subgroup_id = Some(object_id);
                }
                let subgroup_id = resolved_subgroup_id.unwrap();
                prev_object_id = Some(object_id);

                match obj.status {
                    // EndOfGroup / EndOfTrack are purely control markers. Collapse each
                    // into its corresponding control event; do not also emit a data-object
                    // message with an empty payload — that would force subscribers to
                    // filter status tags themselves.
                    ObjectStatus::EndOfGroup => {
                        if !emitted_eog {
                            send_end_of_group(inner, track_alias, group_id, subgroup_id);
                            emitted_eog = true;
                        }
                    }
                    ObjectStatus::EndOfTrack => {
                        send_track_ended(inner, track_alias);
                    }
                    // Normal (data) and DoesNotExist (an informational gap) surface as
                    // :moqx_object. The subscriber can branch on :status if needed.
                    ObjectStatus::Normal | ObjectStatus::DoesNotExist => {
                        send_subgroup_object(
                            inner,
                            track_alias,
                            group_id,
                            subgroup_id,
                            object_id,
                            publisher_priority,
                            &obj.extensions,
                            obj.status,
                            obj.payload.as_ref(),
                        );
                    }
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    if header_marks_eog && !emitted_eog {
        if let Some(sg) = resolved_subgroup_id {
            send_end_of_group(inner, track_alias, group_id, sg);
        }
    }

    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn send_subgroup_object(
    inner: &Arc<SessionInner>,
    track_alias: u64,
    group_id: u64,
    subgroup_id: u64,
    object_id: u64,
    priority: u8,
    extensions: &[KeyValuePair],
    status: ObjectStatus,
    payload: Option<&Bytes>,
) {
    let guard = inner.active_subscriptions.lock().unwrap();
    let Some(active) = guard.get(&track_alias) else {
        return;
    };
    let pid = active.caller_pid;
    let mut msg_env = OwnedEnv::new();
    let payload_bytes = payload.cloned().unwrap_or_default();
    let ext_owned: Vec<KeyValuePair> = extensions.to_vec();

    active.ref_env.run(|ref_env| {
        let sub_ref = active.subscription_ref_term.load(ref_env);
        let _ = msg_env.send_and_clear(&pid, |env| {
            let mut bin = NewBinary::new(env, payload_bytes.len());
            bin.as_mut_slice().copy_from_slice(&payload_bytes);
            let payload_term: rustler::Term = bin.into();

            let ext_terms: Vec<rustler::Term> = ext_owned
                .iter()
                .map(|kv| match kv {
                    KeyValuePair::VarInt { type_value, value } => (*type_value, *value).encode(env),
                    KeyValuePair::Bytes { type_value, value } => {
                        let mut b = NewBinary::new(env, value.len());
                        b.as_mut_slice().copy_from_slice(value);
                        let b_term: rustler::Term = b.into();
                        (*type_value, b_term).encode(env)
                    }
                })
                .collect();

            let obj = MoqxObjectOut {
                group_id,
                subgroup_id,
                object_id,
                priority,
                status: status_to_atom(status),
                extensions: ext_terms,
                payload: payload_term,
            };

            let payload = ObjectReceivedOut {
                handle: sub_ref.in_env(env),
                object: obj.encode(env),
            };
            (atoms::moqx_object(), payload).encode(env)
        });
    });
}

fn send_end_of_group(inner: &Arc<SessionInner>, track_alias: u64, group_id: u64, subgroup_id: u64) {
    let guard = inner.active_subscriptions.lock().unwrap();
    let Some(active) = guard.get(&track_alias) else {
        return;
    };
    let pid = active.caller_pid;
    let mut msg_env = OwnedEnv::new();
    active.ref_env.run(|ref_env| {
        let sub_ref = active.subscription_ref_term.load(ref_env);
        let _ = msg_env.send_and_clear(&pid, |env| {
            let payload = EndOfGroupOut {
                handle: sub_ref.in_env(env),
                group_id,
                subgroup_id,
            };
            (atoms::moqx_end_of_group(), payload).encode(env)
        });
    });
}

fn send_track_ended(inner: &Arc<SessionInner>, track_alias: u64) {
    let guard = inner.active_subscriptions.lock().unwrap();
    let Some(active) = guard.get(&track_alias) else {
        return;
    };
    let pid = active.caller_pid;
    let mut msg_env = OwnedEnv::new();
    active.ref_env.run(|ref_env| {
        let sub_ref = active.subscription_ref_term.load(ref_env);
        let _ = msg_env.send_and_clear(&pid, |env| {
            let payload = PublishDoneOut {
                handle: sub_ref.in_env(env),
                status: atoms::ended(),
                code: None,
                message: None,
            };
            (atoms::moqx_publish_done(), payload).encode(env)
        });
    });
}

fn send_track_active(notifier: &TrackNotifier, track_alias: u64) {
    let mut msg_env = OwnedEnv::new();
    let pid = notifier.caller_pid;

    notifier.term_env.run(|term_env| {
        let track_ref = notifier.track_term.load(term_env);
        let _ = msg_env.send_and_clear(&pid, |env| {
            let payload = TrackActiveOut {
                track: track_ref.in_env(env),
                namespace: notifier.namespace.clone(),
                track_name: notifier.track_name.clone(),
                track_alias,
            };
            (atoms::moqx_track_active(), payload).encode(env)
        });
    });
}

fn send_track_closed(notifier: &TrackNotifier) {
    let mut msg_env = OwnedEnv::new();
    let pid = notifier.caller_pid;

    notifier.term_env.run(|term_env| {
        let track_ref = notifier.track_term.load(term_env);
        let _ = msg_env.send_and_clear(&pid, |env| {
            let payload = TrackClosedOut {
                track: track_ref.in_env(env),
                namespace: notifier.namespace.clone(),
                track_name: notifier.track_name.clone(),
            };
            (atoms::moqx_track_closed(), payload).encode(env)
        });
    });
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

struct ParsedObject {
    object_id: u64,
    extensions: Vec<KeyValuePair>,
    status: ObjectStatus,
    payload: Option<Bytes>,
}

async fn read_subgroup_object(
    recv: &mut wtransport::RecvStream,
    prev_object_id: &Option<u64>,
    has_extensions: bool,
) -> anyhow::Result<Option<ParsedObject>> {
    use bytes::Buf;

    let delta = match read_varint_maybe(recv).await? {
        Some(v) => v,
        None => return Ok(None),
    };

    let object_id = match prev_object_id {
        Some(prev) => prev + delta + 1,
        None => delta,
    };

    let extensions = if has_extensions {
        let ext_len = read_varint_from_stream(recv).await? as usize;
        if ext_len > 0 {
            let mut buf = vec![0u8; ext_len];
            recv.read_exact(&mut buf).await?;
            let mut cursor = Bytes::from(buf);
            let mut pairs = Vec::new();
            while cursor.has_remaining() {
                match KeyValuePair::deserialize(&mut cursor) {
                    Ok(p) => pairs.push(p),
                    Err(e) => {
                        return Err(anyhow::anyhow!("invalid extension header: {e:?}"));
                    }
                }
            }
            pairs
        } else {
            Vec::new()
        }
    } else {
        Vec::new()
    };

    let payload_len = read_varint_from_stream(recv).await? as usize;
    let (status, payload) = if payload_len == 0 {
        let status_raw = read_varint_from_stream(recv).await?;
        let status = ObjectStatus::try_from(status_raw).unwrap_or(ObjectStatus::Normal);
        (status, None)
    } else {
        let mut data = vec![0u8; payload_len];
        recv.read_exact(&mut data).await?;
        (ObjectStatus::Normal, Some(Bytes::from(data)))
    };

    Ok(Some(ParsedObject {
        object_id,
        extensions,
        status,
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
fn publish(
    env: Env,
    session: ResourceArc<SessionRes>,
    broadcast_path: String,
    publish_ref: Reference,
) -> rustler::NifResult<Atom> {
    if !session.role.can_publish() {
        return Err(rustler::Error::Term(Box::new(
            "publish requires a publisher session; use MOQX.connect_publisher/1".to_string(),
        )));
    }

    let caller_pid = env.pid();
    let namespace = normalize_path(&session.root, &broadcast_path);
    let inner = session.inner.clone();

    let request_id = inner.allocate_request_id();
    let ref_env = OwnedEnv::new();
    let publish_ref_term = ref_env.save(publish_ref);

    inner.pending_publishes.lock().unwrap().insert(
        request_id,
        PendingPublish {
            caller_pid,
            ref_env,
            publish_ref_term,
            namespace: namespace.clone(),
        },
    );

    runtime().spawn(async move {
        let msg = PublishNamespace::new(request_id, Tuple::from_utf8_path(&namespace), &[]);
        if inner
            .control_tx
            .send(ControlMessage::PublishNamespace(Box::new(msg)))
            .await
            .is_err()
        {
            let pending = inner.pending_publishes.lock().unwrap().remove(&request_id);
            if let Some(pp) = pending {
                let mut msg_env = OwnedEnv::new();
                let pid = pp.caller_pid;

                pp.ref_env.run(|ref_env| {
                    let publish_ref = pp.publish_ref_term.load(ref_env);
                    let _ = msg_env.send_and_clear(&pid, |env| {
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = TransportErrorOut {
                            op: atoms::publish(),
                            message: "control channel closed".to_string(),
                            kind: Some(atoms::runtime()),
                            r#ref: publish_ref.in_env(env),
                            handle: nil,
                        };
                        (atoms::moqx_transport_error(), payload).encode(env)
                    });
                });
            }
        }
    });

    Ok(atoms::ok())
}

#[rustler::nif]
fn create_track<'a>(
    env: Env<'a>,
    broadcast: ResourceArc<BroadcastProducerRes>,
    track_name: String,
) -> rustler::NifResult<rustler::Term<'a>> {
    let key = format!("{}/{}", broadcast.namespace.trim_matches('/'), track_name);

    let res = ResourceArc::new(TrackProducerRes {
        session: broadcast.session.clone(),
        namespace: broadcast.namespace.clone(),
        track_name: track_name.clone(),
        group_seq: AtomicU64::new(0),
    });

    let caller_pid = env.pid();
    let term_env = OwnedEnv::new();
    let track_term = term_env.save(res.clone());

    let (active_alias, closed) = broadcast.session.register_track(
        &key,
        caller_pid,
        term_env,
        track_term,
        broadcast.namespace.clone(),
        track_name.clone(),
    );

    if let Some(track_alias) = active_alias {
        let pid = caller_pid;
        let namespace = broadcast.namespace.clone();
        let track_name_clone = track_name.clone();
        let track_res = res.clone();

        runtime().spawn(async move {
            let mut msg_env = OwnedEnv::new();
            let term_env = OwnedEnv::new();
            let track_term_saved = term_env.save(track_res);
            term_env.run(|saved_env| {
                let track_term = track_term_saved.load(saved_env);
                let _ = msg_env.send_and_clear(&pid, |env| {
                    let payload = TrackActiveOut {
                        track: track_term.in_env(env),
                        namespace: namespace.clone(),
                        track_name: track_name_clone.clone(),
                        track_alias,
                    };
                    (atoms::moqx_track_active(), payload).encode(env)
                });
            });
        });
    }

    if closed {
        let pid = caller_pid;
        let namespace = broadcast.namespace.clone();
        let track_name_clone = track_name.clone();
        let track_res = res.clone();

        runtime().spawn(async move {
            let mut msg_env = OwnedEnv::new();
            let term_env = OwnedEnv::new();
            let track_term_saved = term_env.save(track_res);
            term_env.run(|saved_env| {
                let track_term = track_term_saved.load(saved_env);
                let _ = msg_env.send_and_clear(&pid, |env| {
                    let payload = TrackClosedOut {
                        track: track_term.in_env(env),
                        namespace: namespace.clone(),
                        track_name: track_name_clone.clone(),
                    };
                    (atoms::moqx_track_closed(), payload).encode(env)
                });
            });
        });
    }

    Ok((atoms::ok(), res).encode(env))
}

/// Reserves the next group_id for a track (auto-increments the track's internal counter).
/// Used by the Elixir-side `MOQX.write_frame/2` sugar to pick a group without callers having
/// to manage group state. Callers using `MOQX.open_subgroup/3` directly pass explicit group_ids.
#[rustler::nif]
fn track_next_group_id(track: ResourceArc<TrackProducerRes>) -> u64 {
    track.group_seq.fetch_add(1, Ordering::Relaxed)
}

// ---------------------------------------------------------------------------
// NIF: open_subgroup / write_object / close_subgroup / flush_subgroup
// ---------------------------------------------------------------------------

/// Decode `[{type :: non_neg_integer, value :: non_neg_integer | binary}]` from an Elixir
/// term into `Vec<KeyValuePair>`. Enforces the MoQ parity rule (even types carry varints;
/// odd types carry binaries) via `KeyValuePair::try_new_*`.
fn decode_extensions<'a>(term: rustler::Term<'a>) -> rustler::NifResult<Vec<KeyValuePair>> {
    let list: Vec<rustler::Term<'a>> = term.decode()?;
    let mut out = Vec::with_capacity(list.len());
    for item in list {
        let (type_value, value_term): (u64, rustler::Term<'a>) = item.decode()?;
        let kv = if let Ok(v) = value_term.decode::<u64>() {
            KeyValuePair::try_new_varint(type_value, v).map_err(|e| {
                rustler::Error::Term(Box::new(format!(
                    "invalid varint extension type={type_value}: {e:?}"
                )))
            })?
        } else if let Ok(b) = value_term.decode::<rustler::Binary<'a>>() {
            let bytes = Bytes::copy_from_slice(b.as_slice());
            KeyValuePair::try_new_bytes(type_value, bytes).map_err(|e| {
                rustler::Error::Term(Box::new(format!(
                    "invalid bytes extension type={type_value}: {e:?}"
                )))
            })?
        } else {
            return Err(rustler::Error::Term(Box::new(format!(
                "extension value for type {type_value} must be a non-negative integer or a binary"
            ))));
        };
        out.push(kv);
    }
    Ok(out)
}

fn pick_subgroup_header_type(
    subgroup_id: Option<u64>,
    has_extensions: bool,
    end_of_group: bool,
) -> SubgroupHeaderType {
    match (subgroup_id, has_extensions, end_of_group) {
        (Some(0), false, false) => SubgroupHeaderType::Type0x10,
        (Some(0), true, false) => SubgroupHeaderType::Type0x11,
        (None, false, false) => SubgroupHeaderType::Type0x12,
        (None, true, false) => SubgroupHeaderType::Type0x13,
        (Some(_), false, false) => SubgroupHeaderType::Type0x14,
        (Some(_), true, false) => SubgroupHeaderType::Type0x15,
        (Some(0), false, true) => SubgroupHeaderType::Type0x18,
        (Some(0), true, true) => SubgroupHeaderType::Type0x19,
        (None, false, true) => SubgroupHeaderType::Type0x1A,
        (None, true, true) => SubgroupHeaderType::Type0x1B,
        (Some(_), false, true) => SubgroupHeaderType::Type0x1C,
        (Some(_), true, true) => SubgroupHeaderType::Type0x1D,
    }
}

fn build_subgroup_header(
    track_alias: u64,
    group_id: u64,
    subgroup_id: Option<u64>,
    priority: u8,
    has_extensions: bool,
    end_of_group: bool,
) -> SubgroupHeader {
    match subgroup_id {
        Some(0) => SubgroupHeader::new_fixed_zero_id(
            track_alias,
            group_id,
            priority,
            has_extensions,
            end_of_group,
        ),
        None => SubgroupHeader::new_first_object_id(
            track_alias,
            group_id,
            priority,
            has_extensions,
            end_of_group,
        ),
        Some(id) => SubgroupHeader::new_with_explicit_id(
            track_alias,
            group_id,
            id,
            priority,
            has_extensions,
            end_of_group,
        ),
    }
}

fn status_from_atom(status: Atom) -> Result<ObjectStatus, String> {
    // Compare atoms by encoding to string — rustler doesn't allow `==` on Atom directly.
    // Use the fact that the atom module already defined each status atom; decode via match.
    // Simplest approach: compare to the atom constants using Atom::to_term.
    // But we don't have an Env here, so stringify instead.
    let s = status_atom_to_str(status);
    match s.as_deref() {
        Some("normal") => Ok(ObjectStatus::Normal),
        Some("does_not_exist") => Ok(ObjectStatus::DoesNotExist),
        Some("end_of_group") => Ok(ObjectStatus::EndOfGroup),
        Some("end_of_track") => Ok(ObjectStatus::EndOfTrack),
        other => Err(format!("invalid status atom: {other:?}")),
    }
}

fn status_atom_to_str(atom: Atom) -> Option<String> {
    // Rustler's Atom doesn't expose a name getter without an Env. We rely on Encoder round-trip
    // via a scratch OwnedEnv.
    let env = OwnedEnv::new();
    let out = std::sync::Mutex::new(None);
    env.run(|e| {
        let term = atom.to_term(e);
        if let Ok(name) = term.atom_to_string() {
            *out.lock().unwrap() = Some(name);
        }
    });
    out.into_inner().unwrap()
}

/// Send {:moqx_transport_error, %MOQX.TransportError{...}} for subgroup failures.
fn send_subgroup_error(res: &SubgroupRes, reason: String) {
    let guard = res.notify.lock().unwrap();
    let Some(notify) = guard.as_ref() else {
        return;
    };
    let pid = notify.caller_pid;
    let mut msg_env = OwnedEnv::new();
    notify.ref_env.run(|ref_env| {
        let sg_ref = notify.subgroup_ref_term.load(ref_env);
        let _ = msg_env.send_and_clear(&pid, |env| {
            let nil = rustler::types::atom::nil().to_term(env);
            let payload = TransportErrorOut {
                op: atoms::write_object(),
                message: reason.clone(),
                kind: Some(atoms::runtime()),
                r#ref: nil,
                handle: sg_ref.in_env(env),
            };
            (atoms::moqx_transport_error(), payload).encode(env)
        });
    });
}

/// Try to send an Op into the subgroup's queue. No-op if the sender is already
/// taken (either because the subgroup was closed or the consumer task finished).
fn try_send_op(res: &SubgroupRes, op: SubgroupOp) -> bool {
    let guard = res.op_tx.lock().unwrap();
    if let Some(tx) = guard.as_ref() {
        tx.send(op).is_ok()
    } else {
        false
    }
}

#[rustler::nif]
fn open_subgroup<'a>(
    env: Env<'a>,
    track: ResourceArc<TrackProducerRes>,
    group_id: u64,
    subgroup_id: Option<u64>,
    priority: u8,
    end_of_group: bool,
    extensions_present: bool,
) -> rustler::NifResult<rustler::Term<'a>> {
    let has_extensions = extensions_present;
    let header_type = pick_subgroup_header_type(subgroup_id, has_extensions, end_of_group);

    let key = format!("{}/{}", track.namespace.trim_matches('/'), track.track_name);
    let track_alias = track
        .session
        .write_track_alias(&key)
        .map_err(|reason| rustler::Error::Term(Box::new(reason)))?;

    let (op_tx, op_rx) = tokio::sync::mpsc::unbounded_channel::<SubgroupOp>();

    let res = ResourceArc::new(SubgroupRes {
        session: track.session.clone(),
        group_id,
        header_type,
        op_tx: std::sync::Mutex::new(Some(op_tx)),
        notify: std::sync::Mutex::new(None),
        closed: AtomicBool::new(false),
    });

    // Populate the notify channel so the consumer task can reach the caller pid.
    let caller_pid = env.pid();
    let ref_env = OwnedEnv::new();
    let subgroup_ref_term = ref_env.save(res.clone());
    *res.notify.lock().unwrap() = Some(SubgroupNotify {
        caller_pid,
        ref_env,
        subgroup_ref_term,
    });

    let res_for_task = res.clone();
    runtime().spawn(async move {
        subgroup_consumer_loop(
            res_for_task,
            track_alias,
            group_id,
            subgroup_id,
            priority,
            has_extensions,
            end_of_group,
            op_rx,
        )
        .await;
    });

    Ok((atoms::ok(), res).encode(env))
}

#[allow(clippy::too_many_arguments)]
async fn subgroup_consumer_loop(
    res: ResourceArc<SubgroupRes>,
    track_alias: u64,
    group_id: u64,
    subgroup_id: Option<u64>,
    priority: u8,
    has_extensions: bool,
    end_of_group: bool,
    mut op_rx: tokio::sync::mpsc::UnboundedReceiver<SubgroupOp>,
) {
    let header = build_subgroup_header(
        track_alias,
        group_id,
        subgroup_id,
        priority,
        has_extensions,
        end_of_group,
    );

    // Open the QUIC uni-stream + write the subgroup header.
    let mut stream = match async {
        let send = res
            .session
            .connection
            .open_uni()
            .await
            .map_err(|e| format!("open_uni: {e:?}"))?
            .await
            .map_err(|e| format!("open_uni (accept): {e:?}"))?;
        let send = Arc::new(tokio::sync::Mutex::new(send));
        SendDataStream::new(send, HeaderInfo::Subgroup { header })
            .await
            .map_err(|e| format!("create data stream: {e:?}"))
    }
    .await
    {
        Ok(s) => s,
        Err(reason) => {
            send_subgroup_error(&res, reason);
            while op_rx.recv().await.is_some() {}
            return;
        }
    };

    let mut previous_object_id: Option<u64> = None;
    let mut finished = false;

    while let Some(op) = op_rx.recv().await {
        match op {
            SubgroupOp::Write {
                object_id,
                payload,
                extensions,
                status,
            } => {
                let payload_opt = match status {
                    ObjectStatus::Normal => Some(payload),
                    _ => None,
                };
                // When the subgroup header declared has_extensions=true, every object on
                // the wire MUST carry an extensions block (possibly empty) or the receiver's
                // parser falls out of sync. Respect that invariant even if the caller passes
                // an empty list.
                let extensions_opt = if has_extensions {
                    Some(extensions)
                } else if extensions.is_empty() {
                    None
                } else {
                    // Caller passed extensions but the header was opened without
                    // extensions_present: true. Surface as an explicit error rather than
                    // silently corrupting the stream.
                    send_subgroup_error(
                        &res,
                        "write_object: cannot attach extensions to a subgroup opened without extensions_present: true"
                            .to_string(),
                    );
                    continue;
                };
                let object = moqtail::model::data::object::Object {
                    track_alias,
                    location: Location::new(group_id, object_id),
                    publisher_priority: 0,
                    forwarding_preference: ObjectForwardingPreference::Subgroup,
                    subgroup_id: Some(0),
                    status,
                    extensions: extensions_opt,
                    payload: payload_opt,
                };
                if let Err(e) = stream.send_object(&object, previous_object_id).await {
                    send_subgroup_error(&res, format!("send_object: {e:?}"));
                } else {
                    previous_object_id = Some(object_id);
                }
            }

            SubgroupOp::Close {
                emit_end_of_group_marker,
            } => {
                if emit_end_of_group_marker {
                    let next_id = previous_object_id.map(|p| p + 1).unwrap_or(0);
                    let eog_obj = moqtail::model::data::object::Object {
                        track_alias,
                        location: Location::new(group_id, next_id),
                        publisher_priority: 0,
                        forwarding_preference: ObjectForwardingPreference::Subgroup,
                        subgroup_id: Some(0),
                        status: ObjectStatus::EndOfGroup,
                        extensions: if has_extensions {
                            Some(Vec::new())
                        } else {
                            None
                        },
                        payload: None,
                    };
                    if let Err(e) = stream.send_object(&eog_obj, previous_object_id).await {
                        send_subgroup_error(&res, format!("send eog marker: {e:?}"));
                    }
                }
                if let Err(e) = stream.finish().await {
                    send_subgroup_error(&res, format!("finish stream: {e:?}"));
                }
                finished = true;
                break;
            }

            SubgroupOp::Flush { tx } => {
                let result = stream
                    .flush()
                    .await
                    .map_err(|e| format!("flush stream: {e:?}"));
                let _ = tx.send(result);
            }
        }
    }

    if !finished {
        // Sender dropped without an explicit Close (resource GC path).
        let _ = stream.finish().await;
    }
}

#[rustler::nif]
fn write_object<'a>(
    subgroup: ResourceArc<SubgroupRes>,
    object_id: u64,
    payload: Binary,
    extensions: rustler::Term<'a>,
    status_atom: Atom,
) -> rustler::NifResult<Atom> {
    let status = status_from_atom(status_atom).map_err(|e| rustler::Error::Term(Box::new(e)))?;
    let ext_kv = decode_extensions(extensions)?;
    let payload_bytes = Bytes::copy_from_slice(payload.as_slice());

    try_send_op(
        &subgroup,
        SubgroupOp::Write {
            object_id,
            payload: payload_bytes,
            extensions: ext_kv,
            status,
        },
    );
    Ok(atoms::ok())
}

#[rustler::nif]
fn close_subgroup(
    subgroup: ResourceArc<SubgroupRes>,
    emit_end_of_group_marker: bool,
) -> rustler::NifResult<Atom> {
    if subgroup.closed.swap(true, Ordering::SeqCst) {
        return Ok(atoms::ok());
    }

    let header_type = subgroup.header_type;
    if emit_end_of_group_marker && !header_type.contains_end_of_group() {
        return Err(rustler::Error::Term(Box::new(
            "emit_end_of_group_marker=true requires subgroup opened with end_of_group: true"
                .to_string(),
        )));
    }

    try_send_op(
        &subgroup,
        SubgroupOp::Close {
            emit_end_of_group_marker,
        },
    );
    // Dropping the sender signals the consumer task to finish after draining.
    let _ = subgroup.op_tx.lock().unwrap().take();
    Ok(atoms::ok())
}

#[rustler::nif]
fn flush_subgroup(
    env: Env,
    subgroup: ResourceArc<SubgroupRes>,
    flush_ref: Reference,
) -> rustler::NifResult<Atom> {
    let _ = env;
    let (tx, rx) = oneshot::channel::<Result<(), String>>();

    if !try_send_op(&subgroup, SubgroupOp::Flush { tx }) {
        return Err(rustler::Error::Term(Box::new(
            "subgroup is closed or unavailable".to_string(),
        )));
    }

    let ref_env = OwnedEnv::new();
    let ref_term = ref_env.save(flush_ref);
    let subgroup_for_task = subgroup.clone();

    runtime().spawn(async move {
        match rx.await {
            Ok(Ok(())) => {
                let mut msg_env = OwnedEnv::new();
                let guard = subgroup_for_task.notify.lock().unwrap();
                let Some(notify) = guard.as_ref() else {
                    return;
                };
                let pid = notify.caller_pid;

                notify.ref_env.run(|sub_env| {
                    let subgroup_ref = notify.subgroup_ref_term.load(sub_env);
                    ref_env.run(|saved_env| {
                        let flush_ref_term = ref_term.load(saved_env);
                        let _ = msg_env.send_and_clear(&pid, |env| {
                            let payload = FlushDoneOut {
                                r#ref: flush_ref_term.in_env(env),
                                handle: subgroup_ref.in_env(env),
                            };
                            (atoms::moqx_flush_ok(), payload).encode(env)
                        });
                    });
                });
            }
            Ok(Err(reason)) => {
                let mut msg_env = OwnedEnv::new();
                let guard = subgroup_for_task.notify.lock().unwrap();
                let Some(notify) = guard.as_ref() else {
                    return;
                };
                let pid = notify.caller_pid;

                notify.ref_env.run(|sub_env| {
                    let subgroup_ref = notify.subgroup_ref_term.load(sub_env);
                    ref_env.run(|saved_env| {
                        let flush_ref_term = ref_term.load(saved_env);
                        let _ = msg_env.send_and_clear(&pid, |env| {
                            let payload = TransportErrorOut {
                                op: atoms::flush_subgroup(),
                                message: reason.clone(),
                                kind: Some(atoms::runtime()),
                                r#ref: flush_ref_term.in_env(env),
                                handle: subgroup_ref.in_env(env),
                            };
                            (atoms::moqx_transport_error(), payload).encode(env)
                        });
                    });
                });
            }
            Err(_) => {
                let mut msg_env = OwnedEnv::new();
                let guard = subgroup_for_task.notify.lock().unwrap();
                let Some(notify) = guard.as_ref() else {
                    return;
                };
                let pid = notify.caller_pid;

                notify.ref_env.run(|sub_env| {
                    let subgroup_ref = notify.subgroup_ref_term.load(sub_env);
                    ref_env.run(|saved_env| {
                        let flush_ref_term = ref_term.load(saved_env);
                        let _ = msg_env.send_and_clear(&pid, |env| {
                            let payload = TransportErrorOut {
                                op: atoms::flush_subgroup(),
                                message: "flush operation canceled".to_string(),
                                kind: Some(atoms::runtime()),
                                r#ref: flush_ref_term.in_env(env),
                                handle: subgroup_ref.in_env(env),
                            };
                            (atoms::moqx_transport_error(), payload).encode(env)
                        });
                    });
                });
            }
        }
    });

    Ok(atoms::ok())
}

#[rustler::nif]
fn finish_track(track: ResourceArc<TrackProducerRes>) -> rustler::NifResult<Atom> {
    let key = format!("{}/{}", track.namespace.trim_matches('/'), track.track_name);
    let notifiers = track.session.close_track(&key);

    runtime().spawn(async move {
        for notifier in notifiers.iter() {
            send_track_closed(notifier);
        }
    });

    Ok(atoms::ok())
}

// ---------------------------------------------------------------------------
// NIF: subscribe
// ---------------------------------------------------------------------------

#[rustler::nif]
fn subscribe<'a>(
    env: Env<'a>,
    session: ResourceArc<SessionRes>,
    broadcast_path: String,
    track_name: String,
    rendezvous_timeout_ms: Option<u64>,
    init_data: Option<Binary>,
    track_meta: rustler::Term,
) -> rustler::NifResult<rustler::Term<'a>> {
    if !session.role.can_consume() {
        return Err(rustler::Error::Term(Box::new(
            "subscribe requires a subscriber session; use MOQX.connect_subscriber/1".to_string(),
        )));
    }

    let caller_pid = env.pid();
    let inner = session.inner.clone();
    let namespace = normalize_path(&session.root, &broadcast_path);

    let subscribe_parameters = match rendezvous_timeout_ms {
        Some(timeout_ms) => {
            vec![KeyValuePair::try_new_varint(0x02, timeout_ms).map_err(|e| {
                rustler::Error::Term(Box::new(format!(
                    "invalid rendezvous timeout parameter: {:?}",
                    e
                )))
            })?]
        }
        None => vec![],
    };

    let init_data = init_data.map(|bin| bin.as_slice().to_vec());
    let request_id = inner.allocate_request_id();

    let handle = ResourceArc::new(SubscriptionHandle {
        session: inner.clone(),
        request_id,
        canceled: AtomicBool::new(false),
    });

    let term_env = OwnedEnv::new();
    let subscription_ref_term = term_env.save(handle.clone());
    let track_meta_term = term_env.save(track_meta);

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
            term_env,
            subscription_ref_term,
            track_meta_term,
            init_data,
        },
    );

    let inner_send = inner.clone();
    runtime().spawn(async move {
        if inner_send
            .control_tx
            .send(ControlMessage::Subscribe(Box::new(subscribe_msg)))
            .await
            .is_err()
        {
            let pending = inner_send
                .pending_subscribes
                .lock()
                .unwrap()
                .remove(&request_id);
            if let Some(p) = pending {
                let mut msg_env = OwnedEnv::new();
                p.term_env.run(|term_env| {
                    let sub_ref = p.subscription_ref_term.load(term_env);
                    let _ = msg_env.send_and_clear(&caller_pid, |env| {
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = TransportErrorOut {
                            op: atoms::subscribe(),
                            message: "control channel closed".to_string(),
                            kind: Some(atoms::runtime()),
                            r#ref: nil,
                            handle: sub_ref.in_env(env),
                        };
                        (atoms::moqx_transport_error(), payload).encode(env)
                    });
                });
            }
        }
    });

    Ok(handle.encode(env))
}

// ---------------------------------------------------------------------------
// NIF: unsubscribe
// ---------------------------------------------------------------------------

#[rustler::nif]
fn unsubscribe(handle: ResourceArc<SubscriptionHandle>) -> rustler::NifResult<Atom> {
    if handle.canceled.swap(true, Ordering::SeqCst) {
        return Ok(atoms::ok());
    }
    cleanup_subscription(&handle.session, handle.request_id);
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
                        let nil = rustler::types::atom::nil().to_term(env);
                        let payload = TransportErrorOut {
                            op: atoms::fetch(),
                            message: "control channel closed".to_string(),
                            kind: Some(atoms::runtime()),
                            r#ref: ref_term.in_env(env),
                            handle: nil,
                        };
                        (atoms::moqx_transport_error(), payload).encode(env)
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
        && env.register::<SubscriptionHandle>().is_ok()
        && env.register::<SubgroupRes>().is_ok()
}

rustler::init!("Elixir.MOQX.Native", load = load);
