# moqx

> Elixir bindings for [Media over QUIC (MOQ)](https://moq.dev) via Rustler NIFs on top of `moq-lite` / `moq-native`.

**Status:** early client library with a deliberately narrow, documented support contract.

## Installation

```elixir
# mix.exs
{:moqx, "~> 0.1.0"}
```

Release metadata:

- source: <https://github.com/dmorn/moqx>
- changelog: <https://github.com/dmorn/moqx/blob/main/CHANGELOG.md>
- license: MIT

## Stable supported client contract

Today `moqx` supports a single client-side path:

- explicit split roles only
  - publisher sessions publish only
  - subscriber sessions subscribe only
- Quinn-backed client connections only
- these transports only:
  - `:auto`
  - `:raw_quic`
  - `:webtransport`
  - `:websocket`
- connect-time version pinning
- broadcasts, tracks, and frame delivery
- raw fetch for retrieving track objects by range (subscriber sessions only)
- raw catalog retrieval via `fetch_catalog/2`
- relay authentication through the connect URL query, using `?jwt=...`
- path-rooted relay authorization, where the connect URL path must match the token `root`
- minimal client TLS controls:
  - verification is on by default
  - `tls: [verify: :insecure]` is an explicit local-development escape hatch
  - `tls: [cacertfile: "/path/to/rootCA.pem"]` trusts a custom root CA

Not planned:

- Quiche backend support
- Noq backend support
- Iroh transport support
- merged publisher/subscriber sessions

Out of scope for `v0.1`:

- relay/server listener APIs
- embedding or managing a relay from Elixir
- broader server-side feature surface beyond relay-backed client connections
- broader production hardening beyond the current minimal client TLS controls
- CMSF catalog parsing and track discovery (planned for issue #8)

## Public API

The intended API is the single `MOQX` module.

### Connect

Connections are asynchronous. `connect_publisher/1`, `connect_publisher/2`,
`connect_subscriber/1`, and `connect_subscriber/2` return `:ok` immediately,
then the caller receives exactly one connect result message:

- `{:moqx_connected, session}` on success
- `{:error, reason}` if the async connect attempt fails

The stable, intended connect surface is:

- `MOQX.connect_publisher/1,2`
- `MOQX.connect_subscriber/1,2`
- `MOQX.connect/2` with required `role: :publisher | :subscriber`

There is no supported `:both` session mode.

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

For an auth-enabled relay, keep using the same connect APIs and pass the token in
the URL query. `moqx` does not add a separate auth API; auth stays part of the
connect URL:

```elixir
jwt = "eyJhbGciOiJIUzI1NiIs..."

:ok =
  MOQX.connect_publisher(
    "https://relay.example.com/room/123?jwt=#{jwt}",
    tls: [cacertfile: "/path/to/rootCA.pem"]
  )

:ok =
  MOQX.connect_subscriber(
    "https://relay.example.com/room/123?jwt=#{jwt}",
    tls: [cacertfile: "/path/to/rootCA.pem"]
  )
```

When you connect to a rooted URL like `/room/123`, relay authorization is rooted at
that path. Publish and subscribe paths can stay relative to that root:

```elixir
{:ok, broadcast} = MOQX.publish(publisher, "alice")
:ok = MOQX.subscribe(subscriber, "alice", "video")
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

:ok =
  MOQX.connect_subscriber(
    "https://relay.internal.example/anon",
    tls: [cacertfile: "/path/to/rootCA.pem"]
  )

:ok =
  MOQX.connect_publisher(
    "http://localhost:4443/anon",
    transport: :websocket,
    version: "moq-lite-02"
  )
```

Supported connect options:

- `:role` - required, `:publisher` or `:subscriber`
- `:backend` - optional compiled backend, currently only `:quinn`
- `:transport` - optional `:auto`, `:raw_quic`, `:webtransport`, or `:websocket`
- `:version` - optional version string or list of version strings
- `:tls` - optional TLS controls:
  - `verify: :verify_peer | :insecure` - defaults to `:verify_peer`
  - `cacertfile: "/path/to/rootCA.pem"` - trust a custom root CA PEM

Notes:

- relay authentication currently rides on the URL itself: pass the JWT as `?jwt=...`
- relay authorization is path-rooted: the connect URL path must match the token `root`
- listener/server APIs remain out of scope
- TLS verification is enabled by default; `tls: [verify: :insecure]` is a local-development escape hatch only
- local relay WebSocket connections use the relay's plain HTTP endpoint, so local examples use `http://.../anon`
- the current relay-backed WebSocket path negotiates the upstream-compatible subset `moq-lite-01`, `moq-lite-02`, and `moq-transport-14`
- transport parity coverage includes relay-backed WebSocket round trips, an isolated WebSocket fallback harness, and auth-enabled relay integration coverage
- the `cacertfile` option is intended for private/local roots; default verification otherwise uses system/native roots
- synchronous option/usage problems raise or return immediately; network/runtime failures are delivered asynchronously as process messages

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

The supported subscription message contract is:

- `{:moqx_subscribed, broadcast_path, track_name}` when the subscription becomes active
- `{:moqx_frame, group_seq, payload}` for each frame
- `:moqx_track_ended` when the track finishes cleanly
- `{:moqx_error, reason}` for asynchronous subscription/runtime failures

Error expectations are intentionally split:

- immediate misuse errors return `{:error, reason}` from the API call itself
  - for example, `publish/2` on a subscriber session or `subscribe/3` on a publisher session
- asynchronous connect/relay/runtime failures arrive later as mailbox messages
  - `{:error, reason}` for connect failures
  - `{:moqx_error, reason}` for subscription/runtime failures

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
  :moqx_track_ended -> :ok
  {:moqx_error, reason} -> raise "subscription failed: #{inspect(reason)}"
end
```

### Fetch

Fetch retrieves raw track objects by range from a subscriber session.
`fetch/4` returns `{:ok, ref}` immediately, then delivers messages to the
caller's mailbox correlated by `ref`.

The fetch message contract is:

- `{:moqx_fetch_started, ref, namespace, track_name}` when the fetch begins
- `{:moqx_fetch_object, ref, group_id, object_id, payload}` for each object
- `{:moqx_fetch_done, ref}` when the fetch completes
- `{:moqx_fetch_error, ref, reason}` on failure

Options:

- `priority` — integer `0..255` (default `0`)
- `group_order` — `:original`, `:ascending`, or `:descending` (default `:original`)
- `start` — `{group_id, object_id}` (default `{0, 0}`)
- `end` — `{group_id, object_id}` (default: open-ended)

```elixir
{:ok, ref} = MOQX.fetch(subscriber, "my-namespace", "video", start: {0, 0}, end: {5, 0})

receive do
  {:moqx_fetch_started, ^ref, _ns, _track} -> :ok
end

# Collect all objects
objects = collect_objects(ref, [])

defp collect_objects(ref, acc) do
  receive do
    {:moqx_fetch_object, ^ref, _gid, _oid, payload} ->
      collect_objects(ref, [payload | acc])
    {:moqx_fetch_done, ^ref} ->
      Enum.reverse(acc)
  end
end
```

`fetch_catalog/2` is a convenience wrapper that fetches the first catalog
object with sensible defaults (namespace `"moqtail"`, track `"catalog"`,
range `{0,0}..{0,1}`):

```elixir
{:ok, ref} = MOQX.fetch_catalog(subscriber)

receive do
  {:moqx_fetch_started, ^ref, _ns, _track} -> :ok
end

payload =
  receive do
    {:moqx_fetch_object, ^ref, _gid, _oid, data} -> data
  end

receive do
  {:moqx_fetch_done, ^ref} -> :ok
end

# payload is raw UTF-8 JSON CMSF bytes — parsing is left to your application
# (CMSF parsing and track discovery are planned for issue #8)
IO.puts(payload)
```

> **Scope boundary:** `fetch/4` and `fetch_catalog/2` deliver raw bytes only
> (issue #7). CMSF catalog parsing and track discovery are a separate concern
> (issue #8).

## Relay authentication

Upstream relay auth currently expects JWTs in the `jwt` query parameter, and the
URL path must match the token `root`. `moqx` intentionally keeps this model in
the URL rather than introducing a separate public auth API. Follow the
implementation claim names, not older prose that still says `pub` / `sub`.

Use these claims:

- `root`
- `put` for publish permissions
- `get` for subscribe permissions
- `cluster` when needed by relay clustering
- `iat`
- `exp`

A typical authenticated URL looks like:

```text
https://localhost:4443/room/123?jwt=eyJhbGciOiJIUzI1NiIs...
```

### Minting relay-compatible tokens with JOSE

Add JOSE to your project if you want to mint tokens from Elixir:

```elixir
# mix.exs
{:jose, "~> 1.11"}
```

Example using a symmetric `oct` JWK:

```elixir
jwk =
  JOSE.JWK.from(%{
    "alg" => "HS256",
    "key_ops" => ["sign", "verify"],
    "kty" => "oct",
    "k" => Base.url_encode64("replace-with-a-strong-shared-secret", padding: false),
    "kid" => "relay-dev-root"
  })

now = System.system_time(:second)

claims = %{
  "root" => "room/123",
  "put" => [""],
  "get" => [""],
  "iat" => now,
  "exp" => now + 3600
}

{_jws, jwt} =
  jwk
  |> JOSE.JWT.sign(%{"alg" => "HS256", "kid" => "relay-dev-root", "typ" => "JWT"}, claims)
  |> JOSE.JWS.compact()

url = "https://localhost:4443/room/123?jwt=#{jwt}"
```

A few practical patterns:

- publish-only token: `put: [""]`, `get: []`
- subscribe-only token: `put: []`, `get: [""]`
- full room access: `put: [""], get: [""]`
- narrower access can use rooted suffixes like `put: ["alice"]`, `get: ["viewers"]`

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

Most integration tests are relay-backed and are skipped automatically when the local
relay setup is unavailable. The suite also includes isolated relay configurations
used to verify WebSocket fallback, TLS trust behavior, and authenticated rooted paths.

For an explicit split between fast checks and relay-backed coverage:

```bash
mix ci
mix test.integration
```

- `mix ci` runs formatting, Credo, and non-integration tests
- `mix test.integration` runs only the relay-backed integration suite

### CI strategy

`moqx` treats relay-backed integration coverage as a first-class CI job, not as an
optional best-effort step.

The intended CI split is:

- a fast job for formatting, Credo, and non-integration tests
- a dedicated relay-backed integration job that builds `.moq-dev`'s `moq-relay`
  binary and then runs `mix test.integration`

That keeps the default job fast while ensuring auth, TLS, transport, and rooted-path
coverage is exercised in CI without depending on any public relay.

### Local relay TLS

Secure verification is the default in `moqx`.

That means the upstream dev relay config under `.moq-dev/dev/relay.toml`, which uses
`tls.generate = ["localhost"]`, will not verify successfully unless you either:

- opt into local-only insecure mode:

  ```elixir
  MOQX.connect_publisher("https://localhost:4443", tls: [verify: :insecure])
  ```

- or run the relay with a certificate chain trusted by your machine

For example, if you already have a local CA PEM for your relay:

```elixir
MOQX.connect_publisher(
  "https://localhost:4443",
  tls: [cacertfile: "/absolute/path/to/rootCA.pem"]
)
```

For the best local developer experience, use [`mkcert`](https://github.com/filosottile/mkcert)
to install a local development CA and generate a trusted `localhost` certificate:

```bash
mkcert -install
mkcert -cert-file localhost.pem -key-file localhost-key.pem localhost 127.0.0.1 ::1
```

Then configure the relay to use file-based TLS instead of `tls.generate`, for example:

```toml
[server]
listen = "[::]:4443"
tls.cert = ["/absolute/path/to/localhost.pem"]
tls.key = ["/absolute/path/to/localhost-key.pem"]
```

With that setup, default `moqx` connections can verify the relay certificate without
falling back to `verify: :insecure`.

## License

MIT
