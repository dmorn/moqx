# MOQ Relay — Local Experiments

> Historical exploration notes from 2026-03-19 while evaluating upstream relay
> behavior. These notes are useful for background, but they are **not** the
> authoritative `moqx` API or TLS guidance.
>
> For the current supported `moqx` surface, secure-by-default TLS behavior, and
> the preferred local `mkcert` workflow, see the top-level `README.md`.

Tests run on 2026-03-19, using [moq-dev/moq](https://github.com/moq-dev/moq) at HEAD.
Platform: MNT Reform 2020 (aarch64, Rust 1.94.0).

---

## Setup

### Build

```bash
git clone https://github.com/moq-dev/moq
cd moq
cargo build --release -p moq-relay -p moq-cli -p moq-clock
```

### Start the relay

The repo ships a ready-to-use local config at `dev/relay.toml`:

```bash
./target/release/moq-relay dev/relay.toml
```

Key settings in `dev/relay.toml` at the time:
- Listens on `[::]:4443` for both QUIC and HTTP/WebSocket
- Self-signed TLS certificate generated for `localhost`
- Anonymous access enabled (`auth.public = ""`)
- Serves `GET /certificate.sha256` so clients can pin the cert fingerprint

For current `moqx` development, treat that generated localhost certificate as
untrusted by default unless you explicitly opt into insecure mode or replace it
with a locally trusted certificate chain.

---

## Experiment 1: Clock pub/sub (moq-clock)

`moq-clock` is a minimal example app in the repo — publishes current time as a
text track every second. Perfect for protocol validation.

### Publisher

```bash
./target/release/moq-clock \
  --url http://localhost:4443/ \
  --broadcast anon/clock-test \
  --tls-disable-verify \
  publish
```

> Historical upstream experiment note: this used an insecure local-dev flow.
> Current `moqx` guidance is to prefer trusted local certificates and keep
> verification on by default.

### Subscriber (separate terminal)

```bash
./target/release/moq-clock \
  --url http://localhost:4443/ \
  --broadcast anon/clock-test \
  --tls-disable-verify \
  subscribe
```

### Observed output

Subscriber receives frames ~1s after publisher produces them:

```
2026-03-19 16:39:03
2026-03-19 16:39:04
2026-03-19 16:39:05
...
```

### Log analysis

Both publisher and subscriber connect via **QUIC** (moq-lite-03):

```
WARN moq_native::websocket: WebSocket connection failed err=failed to connect WebSocket
INFO moq_native::client: connected version=moq-lite-03
```

The WebSocket fallback always fails locally because QUIC wins the race (200ms delay).
The relay serves both on the same port 4443 — QUIC via UDP, WebSocket via TCP.

**Broadcast lifecycle in the logs:**
```
INFO moq_clock: waiting for broadcast to be online broadcast=anon/clock-test
INFO moq_clock: broadcast is online, subscribing to track broadcast=anon/clock-test
INFO moq_lite::lite::subscriber: subscribe started id=0 broadcast=anon/clock-test track=seconds
INFO moq_lite::lite::publisher: subscribed started id=0 broadcast=anon/clock-test track=seconds
```

The subscriber *waits* for the broadcast to be announced — no polling, pure event-driven.

---

## Experiment 2: Video publish (ffmpeg → moq-cli)

Publish a looping fMP4 file via ffmpeg piped to `moq-cli`.

The correct ffmpeg movflags for MOQ (from the justfile):

```bash
ffmpeg -stream_loop -1 -re -i dev/test.fmp4 \
  -c copy \
  -f mp4 -movflags cmaf+separate_moof+delay_moov+skip_trailer+frag_every_frame \
  - \
| ./target/release/moq-cli \
  --log-level info \
  publish \
  --url http://localhost:4443/ \
  --name anon/my-stream \
  --websocket-enabled \
  --tls-disable-verify \
  fmp4
```

> ⚠️ The flag `frag_keyframe+empty_moov+default_base_moof` (generic fMP4) does NOT work.
> MOQ requires CMAF fragmentation: `cmaf+separate_moof+delay_moov+skip_trailer+frag_every_frame`.

The subscribe side has been removed from `moq-cli` and moved to the
[GStreamer plugin](https://github.com/moq-dev/gstreamer) (`hang-gst`).

---

## Protocol observations

### URL scheme and TLS

- `http://` URL → client fetches `GET /certificate.sha256` first (insecure pin), then
  connects via QUIC using the pinned fingerprint
- `https://` URL → standard TLS verification against system roots

This section describes the upstream experiment setup at the time. In `moqx`, the
intentional library posture is now:

- verification on by default
- explicit insecure mode only for local development
- preferred local trusted-cert workflow via `mkcert`

### Connection negotiation

The client simultaneously attempts:
1. **QUIC** (WebTransport over UDP)
2. **WebSocket** fallback (TCP) — with a 200ms delay by default

Whoever connects first wins. In LAN, QUIC always wins. WebSocket is useful for
environments where UDP is blocked.

### moq-lite-03 vs moq-transport-14+

- The relay negotiates the version automatically
- moq-lite is a simplified subset
- moq-transport (IETF draft) is supported by Cloudflare CDN and MOQtail

Current `moqx` integration coverage is more specific than this historical note:
raw QUIC and WebTransport support a broader version set than the relay-backed
WebSocket path, which intentionally tracks the upstream-compatible subset.

### Broadcast addressing

- Broadcasts are addressed by path: e.g. `anon/clock-test`
- The `anon/` prefix is the public (unauthenticated) namespace configured in `dev/relay.toml`
- A broadcast contains multiple **tracks** (e.g. `seconds`, `video`, `audio`)
- A subscriber first waits for the **broadcast announcement**, then subscribes to individual tracks

---

## Public relay test

> Historical TODO section. Validate current upstream/public relay behavior before
> treating any version claims here as present-day `moqx` guidance.

Cloudflare hosts a public MoQ relay:

```
https://draft-14.cloudflare.mediaoverquic.com
```

> Supports moq-transport-14+ (not moq-lite). Use `--client-version moq-transport-14`
> to force the right version when testing against it.

TODO: test pub/sub against Cloudflare relay.

For current `moqx` defaults, we commonly target:

```
https://ord.abr.moqtail.dev
```

A browser demo player is available at:

```
https://abr.moqtail.dev/demo
```

Use it as a quick external sanity check when relay-based tests/tasks fail, to
differentiate local client regressions from relay availability issues.

---

## moq-clock source — key patterns for the Elixir binding

Source: `rs/moq-clock/src/clock.rs`. The actual subscriber loop:

```rust
// Publisher side — Groups are per-minute, Frames are per-second
pub async fn run(mut self) -> anyhow::Result<()> {
    loop {
        let mut group = self.track.create_group(sequence.into()).unwrap();
        // First frame: base timestamp prefix "2026-03-19 16:39:"
        group.write_frame(base.clone())?;
        // Subsequent frames: just the seconds "05", "06", ...
        loop {
            group.write_frame(delta)?;
            tokio::time::sleep(one_second).await;
            if minute_changed() { break; }
        }
        group.finish()?;
    }
}

// Subscriber side — pure async pull
pub async fn run(mut self) -> anyhow::Result<()> {
    while let Some(mut group) = self.track.recv_group().await? {
        // First frame is the base prefix
        let base = group.read_frame().await?.context("empty group")?;
        // Subsequent frames are the per-second delta
        while let Some(delta) = group.read_frame().await? {
            println!("{}{}", String::from_utf8_lossy(&base), String::from_utf8_lossy(&delta));
        }
    }
    Ok(())
}
```

### Key observations for moqx

1. **Group = keyframe boundary** — a new Group starts a decodable unit. For the clock it's
   per-minute; for video it's per-GOP. Groups can arrive out-of-order (QUIC streams are
   independent), but Frames within a group are always in-order.

2. **Pull model** — `recv_group()` and `read_frame()` are blocking awaits. No callbacks,
   no channels — pure Rust async. Maps cleanly to Rustler dirty scheduler threads.

3. **Backpressure is QUIC-native** — if a subscriber is slow, QUIC flow control kicks in
   automatically. No application-level backpressure needed at the moq-lite layer.

4. **Elixir mapping:**
   - Each `Track` → one `GenServer` (or supervised Task) holding a `ResourceArc<TrackConsumer>`
   - `recv_group()` → dirty NIF thread blocks, sends `{:moq_group, group_ref}` to the owner PID
   - `read_frame()` → dirty NIF thread blocks, sends `{:moq_frame, group_ref, payload}` to owner
   - Group sequence numbers → can be used for latency monitoring (detect skipped groups)
