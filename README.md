# moqx

> Elixir bindings for [Media over QUIC (MOQ)](https://moq.dev) via Rustler NIFs on top of [`moqtail-rs`](https://github.com/moqtail/moqtail).

**Status:** early client library with a deliberately narrow, documented support contract.

## Spec references (RFCs and drafts)

`moqx` (through `moqtail-rs` / moqtail) is aligned with the current MOQ/WebTransport stack.
At the time of writing, that means a mix of published RFCs and active IETF drafts:

- [RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 — Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9002 — QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002)
- [RFC 9114 — HTTP/3](https://www.rfc-editor.org/rfc/rfc9114)
- [RFC 9221 — QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221)
- [RFC 9297 — HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297)
- [draft-ietf-webtrans-http3 — WebTransport over HTTP/3](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
- [draft-ietf-moq-transport — Media over QUIC Transport](https://datatracker.ietf.org/doc/draft-ietf-moq-transport/)

For MOQ-specific behavior, treat the active MOQ transport draft and moqtail interoperability behavior as the practical reference until final RFC publication.

## Installation

```elixir
# mix.exs
{:moqx, "~> 0.2.0"}
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
- WebTransport over QUIC (Draft 14)
- broadcasts, tracks, and frame delivery
- live subscription via SUBSCRIBE with `FilterType::LatestObject`
- raw fetch for retrieving track objects by range (subscriber sessions only)
- raw catalog retrieval via `fetch_catalog/2` and `await_catalog/2`
- CMSF catalog parsing and track discovery via `MOQX.Catalog`
- relay authentication through the connect URL query, using `?jwt=...`
- path-rooted relay authorization, where the connect URL path must match the token `root`
- minimal client TLS controls:
  - verification is on by default
  - `tls: [verify: :insecure]` is an explicit local-development escape hatch
  - `tls: [cacertfile: "/path/to/rootCA.pem"]` trusts a custom root CA

Not planned:

- merged publisher/subscriber sessions

Out of scope for `v0.1`:

- relay/server listener APIs
- embedding or managing a relay from Elixir
- automatic subscription orchestration from a parsed catalog

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
:ok = MOQX.connect_publisher("https://relay.example.com")

publisher =
  receive do
    {:moqx_connected, session} -> session
    {:error, reason} -> raise "publisher connect failed: #{inspect(reason)}"
  end

:ok = MOQX.connect_subscriber("https://relay.example.com")

subscriber =
  receive do
    {:moqx_connected, session} -> session
    {:error, reason} -> raise "subscriber connect failed: #{inspect(reason)}"
  end
```

For an auth-enabled relay, pass the token in the URL query:

```elixir
jwt = "eyJhbGciOiJIUzI1NiIs..."

:ok =
  MOQX.connect_publisher(
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

If you need dynamic role selection:

```elixir
:ok = MOQX.connect(url, role: :publisher)

:ok =
  MOQX.connect_subscriber(
    "https://relay.internal.example/anon",
    tls: [cacertfile: "/path/to/rootCA.pem"]
  )
```

Supported connect options:

- `:role` - required, `:publisher` or `:subscriber`
- `:tls` - optional TLS controls:
  - `verify: :verify_peer | :insecure` - defaults to `:verify_peer`
  - `cacertfile: "/path/to/rootCA.pem"` - trust a custom root CA PEM

Notes:

- relay authentication currently rides on the URL itself: pass the JWT as `?jwt=...`
- relay authorization is path-rooted: the connect URL path must match the token `root`
- listener/server APIs remain out of scope
- TLS verification is enabled by default; `tls: [verify: :insecure]` is a local-development escape hatch only
- the `cacertfile` option is intended for private/local roots; default verification otherwise uses system/native roots
- synchronous option/usage problems raise or return immediately; network/runtime failures are delivered asynchronously as process messages

### Publish

```elixir
{:ok, broadcast} = MOQX.publish(publisher, "anon/demo")
{:ok, track} = MOQX.create_track(broadcast, "video")

:ok = MOQX.write_frame(track, "frame-1")
:ok = MOQX.write_frame(track, "frame-2")
:ok = MOQX.finish_track(track)
```

### Subscribe

Subscriptions are asynchronous and use `FilterType::LatestObject` with
`forward=true`, which means the relay delivers the most recent object and
then forwards new objects as they arrive. This is the standard pattern for
live media consumption from moqtail-style relays.

`subscribe/3` returns `:ok` immediately, then messages arrive in the caller
process.

`subscribe/4` accepts subscription options. Currently supported:

- `delivery_timeout_ms` -- MOQT DELIVERY TIMEOUT parameter (`0x02`) in milliseconds.

The supported subscription message contract is:

- `{:moqx_subscribed, namespace, track_name}` when the subscription becomes active
- `{:moqx_frame, group_id, payload}` for each object
- `:moqx_track_ended` when the track finishes cleanly
- `{:moqx_error, reason}` for asynchronous subscription/runtime failures

```elixir
:ok =
  MOQX.subscribe(
    subscriber,
    "moqtail",
    "catalog",
    delivery_timeout_ms: 1_500
  )

receive do
  {:moqx_subscribed, "moqtail", "catalog"} -> :ok
end

receive do
  {:moqx_frame, group_id, payload} ->
    IO.inspect({group_id, byte_size(payload)}, label: "catalog object")
end
```

### Catalog-driven subscription

The typical flow for consuming live media from a moqtail relay:

```elixir
# Connect
:ok = MOQX.connect_subscriber("https://ord.abr.moqtail.dev")

subscriber =
  receive do
    {:moqx_connected, session} -> session
  end

# Subscribe to the catalog track to discover available media
:ok = MOQX.subscribe(subscriber, "moqtail", "catalog")

receive do
  {:moqx_subscribed, _, _} -> :ok
end

catalog =
  receive do
    {:moqx_frame, _group, payload} ->
      {:ok, cat} = MOQX.Catalog.decode(payload)
      cat
  end

# Pick a video track and subscribe
video = MOQX.Catalog.video_tracks(catalog) |> List.first()

:ok = MOQX.subscribe(subscriber, "moqtail", video.name)

receive do
  {:moqx_subscribed, _, _} -> :ok
end

# Receive live video frames
receive do
  {:moqx_frame, group_id, payload} ->
    IO.puts("video frame: group=#{group_id} size=#{byte_size(payload)}")
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

- `priority` -- integer `0..255` (default `0`)
- `group_order` -- `:original`, `:ascending`, or `:descending` (default `:original`)
- `start` -- `{group_id, object_id}` (default `{0, 0}`)
- `end` -- `{group_id, object_id}` (default: open-ended)

`fetch_catalog/2` is a convenience wrapper that fetches the first catalog
object with sensible defaults (namespace `"moqtail"`, track `"catalog"`,
range `{0,0}..{0,1}`).

`await_catalog/2` collects the fetch messages and decodes the payload into
an `MOQX.Catalog` struct in one call:

```elixir
{:ok, ref} = MOQX.fetch_catalog(subscriber)
{:ok, catalog} = MOQX.await_catalog(ref)

catalog |> MOQX.Catalog.video_tracks() |> Enum.map(& &1.name)
#=> ["259", "260"]
```

### Catalog parsing and track discovery

`MOQX.Catalog` decodes raw CMSF catalog bytes (UTF-8 JSON) into an Elixir
struct with track discovery helpers:

```elixir
{:ok, catalog} = MOQX.Catalog.decode(payload)

MOQX.Catalog.tracks(catalog)           # all tracks
MOQX.Catalog.video_tracks(catalog)     # video tracks only
MOQX.Catalog.audio_tracks(catalog)     # audio tracks only
MOQX.Catalog.get_track(catalog, "259") # by exact name

# Track fields are accessed directly on the struct
track = hd(MOQX.Catalog.video_tracks(catalog))
track.name      #=> "259"
track.codec     #=> "avc1.42C01F"
track.packaging #=> "cmaf"
track.role      #=> "video"
```

Each track also carries a `raw` map with all original JSON fields for
forward compatibility with catalog properties not yet modeled as struct keys.

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

### Run tests

```bash
mix deps.get
mix test
```

For an explicit split between fast checks and integration coverage:

```bash
mix ci
mix test.integration
```

- `mix ci` runs formatting, Credo, and non-integration tests
- `mix test.integration` runs the integration suite

### Local relay TLS

Secure verification is the default in `moqx`.

For local development against a relay with self-signed certificates, either
configure a trusted local certificate chain or opt into `tls: [verify: :insecure]`
explicitly.

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

Then configure the relay to use file-based TLS, for example:

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
