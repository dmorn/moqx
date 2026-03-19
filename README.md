# moqx

> Elixir bindings for [Media over QUIC (MOQ)](https://moq.dev) via Rustler + moq-lite.

**Status:** Research / Early Exploration 🧪

---

## What is MOQ?

Media over QUIC (MoQ) is a next-generation live media protocol designed to deliver WebRTC-like
latency at CDN scale — without the complexity of WebRTC.

The protocol stack looks like this:

```
Application     → your business logic (auth, signaling, etc.)
hang            → media-specific layer (codecs, catalog, container)
moq-lite        → generic pub/sub transport (broadcasts, tracks, groups, frames)
WebTransport    → browser-compatible QUIC
QUIC / UDP      → the actual network
```

Key properties:
- **Sub-second latency** via QUIC stream prioritization and partial reliability
- **Massive fan-out** — relay is intentionally dumb, no business logic at the CDN
- **Generic** — any live data, not just media (text chat is a first-class citizen)
- **Multi-language** — Rust (native) and TypeScript (browser) libraries exist; C bindings (`libmoq`) bridge to everything else

References:
- Spec: [moq-lite draft](https://moq-dev.github.io/drafts/draft-lcurley-moq-lite.html)
- Reference impl: [moq-dev/moq](https://github.com/moq-dev/moq) (Rust + TypeScript)
- Alternative impl: [moqtail/moqtail](https://github.com/moqtail/moqtail) (Draft 14, Rust + TypeScript)
- Public relay (Cloudflare): `https://draft-14.cloudflare.mediaoverquic.com`

---

## Why Elixir?

Elixir/Erlang is exceptional for:
- Massive concurrency (one process per subscriber, no problem)
- Fault tolerance and supervision trees
- Live media pipelines (see: [Membrane Framework](https://membrane.stream))
- Fan-out at scale

MOQ's pub/sub model maps naturally onto OTP processes. A `Broadcast` becomes a `GenServer`,
tracks become streams, and subscribers are just processes receiving messages. The relay's
"dumb fan-out" philosophy aligns perfectly with Elixir's share-nothing message passing.

---

## Integration Strategy

### Why not libmoq (C bindings)?

`libmoq` exposes a C API with opaque integer handles and async callbacks:

```c
moq_session_connect(url, url_len, origin_pub, origin_consume, on_status, user_data);
moq_consume_video_ordered(catalog, index, max_latency_ms, on_frame, user_data);
```

The problem: callbacks are invoked from Tokio threads — **not** from BEAM scheduler threads.
Calling BEAM functions from a foreign thread crashes the VM. You'd need a pipe/channel
intermediary, defeating the ergonomics.

### Why Rustler + moq-lite directly?

[Rustler](https://github.com/rusterlium/rustler) lets you write Erlang NIFs in Rust.
Instead of going through the C layer, we link `moq-lite` directly as a Rust crate and
use Rustler's `OwnedEnv::send_and_clear` to deliver frames as messages to Elixir processes.

```
moq-lite (Rust crate)
    ↓ async Tokio runtime (separate from ERTS)
Rustler NIF
    ↓ OwnedEnv::send_and_clear → pid
Elixir process
    ↓ receive {:moq_frame, track_ref, payload, timestamp_us}
Your application
```

This gives us:
- **Direct access** to the full `moq-lite` API without a C translation layer
- **Async safety** — Tokio runtime is initialized once in the NIF and runs in its own threads
- **Zero-copy** potential for frame payloads via Elixir Binaries
- **Idiomatic Elixir** — frames arrive as messages, no polling

### Considered alternatives

| Approach | Isolation | Latency | Ergonomics | Verdict |
|---|---|---|---|---|
| Rustler + moq-lite | None (NIF crash = VM crash) | Minimal | Excellent | ✅ **Chosen** |
| C NIF via libmoq | None | Minimal | Awkward (callbacks) | ❌ |
| Port (external process) | Full | ~µs overhead | Good | Consider for production |
| Port Driver | Partial | Minimal | Complex to write | ❌ Overkill |

> **Note on crash safety:** A NIF crash takes down the whole BEAM VM. For a production
> media server, consider wrapping this library in a supervised OS process (Port) that
> communicates via a binary protocol. This repo targets the NIF approach first for
> ergonomics; the Port wrapper can be layered on top.

---

## Planned API (Elixir)

```elixir
# Connect to a relay
{:ok, session} = Moqx.Session.connect("https://relay.example.com/anon")

# Subscribe to a broadcast
{:ok, broadcast} = Moqx.Origin.consume(session, "my/stream")
{:ok, catalog}   = Moqx.Consume.catalog(broadcast)

# Subscribe to a video track — frames arrive as messages to self()
{:ok, _track} = Moqx.Consume.video(catalog, 0, max_latency_ms: 500)

receive do
  {:moq_frame, track_ref, payload, timestamp_us} ->
    handle_video_frame(payload)
end

# Publish
{:ok, pub} = Moqx.Publish.create(session, "my/stream")
Moqx.Publish.frame(pub, payload, timestamp_us: System.os_time(:microsecond))
```

---

## Roadmap

- [ ] Set up Rustler NIF skeleton (mix project + Rust crate)
- [ ] Tokio runtime initialization in NIF load hook
- [ ] `Moqx.Session.connect/1` — connect to relay, return session handle
- [ ] `Moqx.Publish` — create broadcast, publish frames
- [ ] `Moqx.Consume` — subscribe to broadcast, receive frames as messages
- [ ] Integration test against local `moq-relay`
- [ ] Integration test against Cloudflare public relay
- [ ] `hang` format support (catalog, codec negotiation)
- [ ] Membrane Framework source/sink elements

---

## Local Development

### Prerequisites

- Rust toolchain (`rustup`)
- Elixir / Erlang (via `mise`)
- A running `moq-relay` for integration tests

### Run a local relay

```bash
# Clone moq-dev/moq and build the relay
git clone https://github.com/moq-dev/moq
cd moq
cargo run -p moq-relay -- --port 4433 \
  --cert-file apps/relay/cert/cert.pem \
  --key-file apps/relay/cert/key.pem

# Or via Docker
docker run --rm \
  -p 4433:4433/udp \
  -v "$PWD/cert.pem:/certs/cert.pem:ro" \
  -v "$PWD/key.pem:/certs/key.pem:ro" \
  ghcr.io/moqtail/relay:latest
```

### Build moqx

```bash
mix deps.get
mix compile
```

---

## License

MIT
