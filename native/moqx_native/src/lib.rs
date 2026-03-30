use std::sync::{Arc, OnceLock};

use moq_lite::Origin;
use moq_native::ClientConfig;
use rustler::{Atom, Encoder, Env, OwnedEnv, Resource, ResourceArc};
use tokio::runtime::Runtime;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        moqx_connected,
        moqx_session_closed,
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

pub struct SessionRes {
    session: tokio::sync::Mutex<Option<moq_lite::Session>>,
    origin: Arc<OriginRes>,
}

#[rustler::resource_impl]
impl Resource for SessionRes {}

pub struct OriginRes {
    producer: moq_lite::OriginProducer,
}

#[rustler::resource_impl]
impl Resource for OriginRes {}

// ---------------------------------------------------------------------------
// NIF functions
// ---------------------------------------------------------------------------

/// Connects to a MOQ relay asynchronously.
///
/// Returns `{:ok, :ok}` immediately. When the connection is established,
/// the calling process receives `{:moqx_connected, session_resource}`
/// or `{:error, reason}`.
#[rustler::nif]
fn connect(env: Env, url: String) -> rustler::NifResult<Atom> {
    let caller_pid = env.pid();

    let parsed_url = url::Url::parse(&url)
        .map_err(|e| rustler::Error::Term(Box::new(format!("{}", e))))?;

    runtime().spawn(async move {
        let result = do_connect(parsed_url).await;

        let mut msg_env = OwnedEnv::new();
        let _ = msg_env.send_and_clear(&caller_pid, |env| match result {
            Ok((session, origin)) => {
                let origin_arc = Arc::new(origin);
                let session_resource = ResourceArc::new(SessionRes {
                    session: tokio::sync::Mutex::new(Some(session)),
                    origin: origin_arc,
                });
                (atoms::moqx_connected(), session_resource).encode(env)
            }
            Err(e) => (atoms::error(), format!("{:#}", e)).encode(env),
        });
    });

    Ok(atoms::ok())
}

async fn do_connect(url: url::Url) -> anyhow::Result<(moq_lite::Session, OriginRes)> {
    let mut config = ClientConfig::default();
    config.tls.disable_verify = Some(true);

    let origin = Origin::produce();
    let origin_consumer = origin.consume();

    let client = config
        .init()?
        .with_publish(origin_consumer)
        .with_consume(origin.clone());

    let session = client.connect(url).await?;

    Ok((session, OriginRes { producer: origin }))
}

/// Returns the negotiated protocol version as a string.
#[rustler::nif]
fn session_version(session: ResourceArc<SessionRes>) -> String {
    let guard = runtime().block_on(session.session.lock());
    match guard.as_ref() {
        Some(s) => format!("{:?}", s.version()),
        None => "closed".to_string(),
    }
}

/// Closes a session.
#[rustler::nif]
fn session_close(session: ResourceArc<SessionRes>) -> Atom {
    let mut guard = runtime().block_on(session.session.lock());
    if let Some(mut s) = guard.take() {
        s.close(moq_lite::Error::Cancel);
    }
    atoms::ok()
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

rustler::init!("Elixir.MOQX.Native");
