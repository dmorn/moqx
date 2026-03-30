# moqx

> Elixir bindings for [Media over QUIC (MOQ)](https://moq.dev) via Rustler NIFs on top of `moq-lite` / `moq-native`.

**Status:** early library with explicit split roles and basic protocol-matrix controls.

## Supported path

Today `moqx` supports:

- explicit split roles
  - publisher session for publish operations
  - subscriber session for subscribe operations
- relay connections over WebTransport and raw QUIC
- connect-time version pinning
- compiled-backend selection
- broadcasts, tracks, and frame delivery
- relay-backed integration tests against a local `moq-relay`

Still not in scope:

- production TLS posture
- broader production hardening
- backends or transports not compiled into the native crate

## Public API

The intended API is the single `MOQX` module.

### Connect

Connections are asynchronous. `connect_publisher/1`, `connect_publisher/2`,
`connect_subscriber/1`, and `connect_subscriber/2` return `:ok` immediately,
then the caller receives `{:moqx_connected, session}` or `{:error, reason}`.

```elixir
:ok = MOQX.connect_publisher("https://localhost:4443")

publisher =
  receive do
    {:moqx_connected, session} -> session
    {:error, reason} -> raise "publisher connect failed: #{inspect(reason)}"
  end

:ok = MOQX.connect_subscriber("https://localhost:4443")

subscriber =
  receive do
    {:moqx_connected, session} -> session
    {:error, reason} -> raise "subscriber connect failed: #{inspect(reason)}"
  end
```

If you need dynamic role selection or connect-time protocol controls, use:

```elixir
:ok = MOQX.connect(url, role: :publisher)

:ok =
  MOQX.connect(url,
    role: :subscriber,
    backend: :quinn,
    transport: :raw_quic,
    version: "moq-transport-14"
  )
```

Supported connect options:

- `:role` - required, `:publisher` or `:subscriber`
- `:backend` - optional compiled backend, such as `:quinn`
- `:transport` - optional `:auto`, `:raw_quic`, `:webtransport`, or `:websocket`
- `:version` - optional version string or list of version strings

You can inspect the compiled native support at runtime:

```elixir
MOQX.supported_backends()
MOQX.supported_transports()
```

### Publish

```elixir
{:ok, broadcast} = MOQX.publish(publisher, "anon/demo")
{:ok, track} = MOQX.create_track(broadcast, "video")

:ok = MOQX.write_frame(track, "frame-1")
:ok = MOQX.write_frame(track, "frame-2")
:ok = MOQX.finish_track(track)
```

A broadcast is announced lazily on the first successful `write_frame/2`.

### Subscribe

Subscriptions are asynchronous. `subscribe/3` returns `:ok` immediately, then
messages arrive in the caller process.

```elixir
:ok = MOQX.subscribe(subscriber, "anon/demo", "video")

receive do
  {:moqx_subscribed, "anon/demo", "video"} -> :ok
end

receive do
  {:moqx_frame, group_seq, payload} ->
    IO.inspect({group_seq, payload}, label: "frame")
end

receive do
  {:moqx_track_ended} -> :ok
  {:moqx_error, reason} -> raise "subscription failed: #{inspect(reason)}"
end
```

## Local development

### Prerequisites

- Rust toolchain (`rustup`)
- Elixir / Erlang
- local relay artifacts under `.moq-dev`

### Run tests

```bash
mix deps.get
mix test
```

Integration tests are relay-backed and are skipped automatically when the local
relay setup is unavailable.

## Notes

- local relay tests currently disable TLS verification in the Rust client to
  support self-signed `localhost` certificates used for local development
- that is acceptable for local tests only, not production configuration

## License

MIT
