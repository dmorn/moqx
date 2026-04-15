# moqx

> Elixir bindings for [Media over QUIC (MOQ)](https://moq.dev) via Rustler NIFs on top of [`moqtail-rs`](https://github.com/moqtail/moqtail).

**Status:** early client library with a deliberately narrow, documented support contract.

## Spec references

`moqx` is currently aligned to the **draft-14** MOQ/WebTransport stack exposed by
`moqtail-rs` / `moqtail`. This project does **not** currently track whatever the
latest MOQT Internet-Draft happens to be.

The intended protocol baseline today is:

- [RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 — Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9002 — QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002)
- [RFC 9114 — HTTP/3](https://www.rfc-editor.org/rfc/rfc9114)
- [RFC 9221 — QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221)
- [RFC 9297 — HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297)
- [draft-ietf-webtrans-http3-14 — WebTransport over HTTP/3](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-14.txt)
- [draft-ietf-moq-transport-14 — Media over QUIC Transport](https://www.ietf.org/archive/id/draft-ietf-moq-transport-14.txt)

If the MOQT draft evolves beyond draft-14, `moqx` will only adopt newer wire
behavior once the project explicitly chooses to move and documents that change
(e.g. a future draft-17 support effort).

## Installation

```elixir
# mix.exs
{:moqx, "~> 0.5.0"}
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
- WebTransport / MOQT draft-14
- broadcasts, tracks, and frame delivery
- live subscription via SUBSCRIBE with `FilterType::LatestObject`
- raw fetch for retrieving track objects by range (subscriber sessions only)
  - on the current moqtail relay, standalone fetch succeeds only for objects the relay already has in cache; upstream relay-to-publisher standalone fetch is not implemented yet
- optional helper-layer catalog publication via `MOQX.Helpers.publish_catalog/2`
  and `MOQX.Helpers.update_catalog/2`
- optional helper-layer catalog retrieval via `MOQX.Helpers.fetch_catalog/2`
  and `MOQX.Helpers.await_catalog/2`
- CMSF catalog parsing and track discovery via `MOQX.Catalog`
- relay authentication through the connect URL query, using `?jwt=...`
- path-rooted relay authorization, where the connect URL path must match the token `root`
- minimal client TLS controls:
  - verification is on by default
  - `tls: [verify: :insecure]` is an explicit local-development escape hatch
  - `tls: [cacertfile: "/path/to/rootCA.pem"]` trusts a custom root CA

Not planned:

- merged publisher/subscriber sessions

Out of scope for the current client contract:

- relay/server listener APIs
- embedding or managing a relay from Elixir
- automatic subscription orchestration from a parsed catalog

## Public API

`moqx` exposes:

- `MOQX` — low-level core message-passing API
- `MOQX.Helpers` — opt-in convenience helpers built on top of `MOQX`

This split is intentional:

- `MOQX` stays explicit, asynchronous, and low-level
- `MOQX.Helpers` provides small convenience flows built purely on public `MOQX`
- a future managed/stateful ergonomics layer may be added separately, but it is
  not part of the `MOQX` core contract

If you want blocking waits, retries, buffering policy, or mailbox demultiplexing,
build them on top of the public message contracts instead of expecting hidden
state inside `MOQX` itself.

## 0.5.0 migration notes

`0.5.0` finalizes the low-level async core contract. If you are upgrading from
older `0.2.x`–`0.4.x` APIs, the main changes are:

- connect is explicitly correlated:
  - `connect/2`, `connect_publisher/2`, `connect_subscriber/2` now return
    `{:ok, connect_ref}`
  - success/failure arrives later via typed async messages
- publish readiness is explicit:
  - `publish/2` returns `{:ok, publish_ref}`
  - the broadcast handle arrives only in `{:moqx_publish_ok, ...}`
- publisher writes are lifecycle-gated:
  - writes before downstream activation now return typed sync request errors
    instead of silently dropping
- subscribe/fetch lifecycle messages are typed structs now:
  - old tuple-era contracts like `:moqx_subscribed`, `:moqx_track_ended`,
    `:moqx_fetch_started`, `:moqx_fetch_error`, and generic async tuple errors
    have been replaced by typed families such as `:moqx_subscribe_ok`,
    `:moqx_publish_done`, `:moqx_fetch_ok`, `:moqx_request_error`, and
    `:moqx_transport_error`
- catalog helpers moved out of `MOQX` core into `MOQX.Helpers`
- `unsubscribe/1` now culminates in `{:moqx_publish_done, ...}` rather than the
  older `:moqx_track_ended` tuple contract
- subscribe timeout option is `delivery_timeout_ms`:
  - draft-14 `SUBSCRIBE` uses MOQT `DELIVERY_TIMEOUT` (`0x02`)
  - the later-draft `RENDEZVOUS_TIMEOUT` parameter is not part of the draft-14 stack used by `moqtail`
- primary mix task names are now:
  - `mix moqx.inspect`
  - `mix moqx.roundtrip`

The examples below reflect the stabilized `0.5.0` contract.

### Connect

Connections are asynchronous and explicitly correlated.
`connect_publisher/2`, `connect_subscriber/2`, and `connect/2` return
`{:ok, connect_ref}` immediately.

Later, the caller receives one of:

- `{:moqx_connect_ok, %MOQX.ConnectOk{ref: connect_ref, session: session, role: role, version: version}}`
- `{:moqx_request_error, %MOQX.RequestError{op: :connect, ref: connect_ref, ...}}`
- `{:moqx_transport_error, %MOQX.TransportError{op: :connect, ref: connect_ref, ...}}`

There is no supported `:both` session mode.

```elixir
{:ok, connect_ref} = MOQX.connect_publisher("https://relay.example.com")

publisher =
  receive do
    {:moqx_connect_ok, %MOQX.ConnectOk{ref: ^connect_ref, session: session}} -> session
    {:moqx_request_error, %MOQX.RequestError{ref: ^connect_ref} = err} ->
      raise "connect rejected: #{inspect(err)}"

    {:moqx_transport_error, %MOQX.TransportError{ref: ^connect_ref} = err} ->
      raise "connect transport failure: #{inspect(err)}"
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
{:ok, publish_ref} = MOQX.publish(publisher, "alice")

broadcast =
  receive do
    {:moqx_publish_ok, %MOQX.PublishOk{ref: ^publish_ref, broadcast: broadcast}} -> broadcast
  end

{:ok, _sub_ref} = MOQX.subscribe(subscriber, "alice", "video")
```

If you need dynamic role selection:

```elixir
{:ok, _ref} = MOQX.connect(url, role: :publisher)

{:ok, _ref} =
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

Publish namespace registration is asynchronous and explicit.
`publish/2` returns `{:ok, publish_ref}` immediately, and the broadcast is
usable only after `:moqx_publish_ok`:

```elixir
{:ok, publish_ref} = MOQX.publish(publisher, "anon/demo")

broadcast =
  receive do
    {:moqx_publish_ok,
     %MOQX.PublishOk{ref: ^publish_ref, broadcast: broadcast, namespace: "anon/demo"}} ->
      broadcast

    {:moqx_request_error, %MOQX.RequestError{op: :publish, ref: ^publish_ref} = err} ->
      raise "publish rejected: #{inspect(err)}"

    {:moqx_transport_error, %MOQX.TransportError{op: :publish, ref: ^publish_ref} = err} ->
      raise "publish transport failure: #{inspect(err)}"
  end

catalog_json = ~s({"version":1,"supportsDeltaUpdates":false,"tracks":[{"name":"video","role":"video"}]})
{:ok, catalog_track} = MOQX.Helpers.publish_catalog(broadcast, catalog_json)
:ok = MOQX.Helpers.update_catalog(catalog_track, catalog_json)

{:ok, track} = MOQX.create_track(broadcast, "video")
:ok = MOQX.write_frame(track, "frame-1")
:ok = MOQX.write_frame(track, "frame-2")
:ok = MOQX.finish_track(track)

# lifecycle gating on the same handle:
{:error, %MOQX.RequestError{code: :track_closed}} = MOQX.write_frame(track, "frame-3")
```

Write calls are explicitly lifecycle-gated (no silent drops):

- `{:error, %MOQX.RequestError{code: :track_not_active}}` before downstream
  subscribe activation
- `{:error, %MOQX.RequestError{code: :track_closed}}` after `finish_track/1`

### Publisher-side catalog publication

In moqtail-style relays, the publisher is responsible for publishing the
`"catalog"` track. The relay then forwards that catalog track downstream to
subscribers.

Use `MOQX.Helpers.publish_catalog/2` for initial publication, then
`MOQX.Helpers.update_catalog/2` for subsequent catalog objects:

```elixir
{:ok, publish_ref} = MOQX.publish(publisher, "my-namespace")

broadcast =
  receive do
    {:moqx_publish_ok, %MOQX.PublishOk{ref: ^publish_ref, broadcast: broadcast}} -> broadcast
  end

catalog_json =
  ~s({"version":1,"supportsDeltaUpdates":false,"tracks":[{"name":"video","role":"video"}]})

{:ok, catalog_track} = MOQX.Helpers.publish_catalog(broadcast, catalog_json)
:ok = MOQX.Helpers.update_catalog(catalog_track, catalog_json)
```

### Subscribe

Subscriptions are asynchronous and correlated by subscription handle.
`subscribe/3,4` returns `{:ok, handle}` immediately.

`subscribe/4` options:

- `delivery_timeout_ms` -- draft-14 MOQT `DELIVERY_TIMEOUT` in milliseconds
  (encoded as parameter `0x02` on `SUBSCRIBE`).

`moqx` currently targets the draft-14 stack exposed by `moqtail`. Later MOQT
 drafts introduce a separate `RENDEZVOUS_TIMEOUT` parameter, but that is not a
 draft-14 wire parameter and is not exposed separately here.

The subscription message contract is:

- `{:moqx_subscribe_ok, %MOQX.SubscribeOk{handle, namespace, track_name}}`
- `{:moqx_track_init, %MOQX.TrackInit{handle, init_data, track_meta}}`
- `{:moqx_object, %MOQX.ObjectReceived{handle, object: %MOQX.Object{...}}}`
- `{:moqx_end_of_group, %MOQX.EndOfGroup{handle, group_id, subgroup_id}}`
- `{:moqx_publish_done, %MOQX.PublishDone{handle, status, ...}}`
- `{:moqx_request_error, %MOQX.RequestError{op: :subscribe, handle, ...}}`
- `{:moqx_transport_error, %MOQX.TransportError{op: :subscribe, handle, ...}}`

```elixir
{:ok, handle} = MOQX.subscribe(subscriber, "moqtail", "catalog", delivery_timeout_ms: 1_500)

receive do
  {:moqx_subscribe_ok, %MOQX.SubscribeOk{handle: ^handle}} -> :ok
end

receive do
  {:moqx_object, %MOQX.ObjectReceived{handle: ^handle, object: obj}} ->
    IO.inspect({obj.group_id, byte_size(obj.payload)}, label: "catalog object")
end

:ok = MOQX.unsubscribe(handle)
```

`unsubscribe/1` is idempotent and fire-and-forget: it sends MOQ
`Unsubscribe` to the relay and removes local subscription state. If the
handle is garbage-collected before `unsubscribe/1` is called, the same
cleanup runs automatically — so short-lived subscribing processes do not
need to unsubscribe explicitly.

### Catalog-driven subscription

The typical flow for consuming live media from a moqtail relay:

```elixir
{:ok, connect_ref} = MOQX.connect_subscriber("https://ord.abr.moqtail.dev")

subscriber =
  receive do
    {:moqx_connect_ok, %MOQX.ConnectOk{ref: ^connect_ref, session: session}} -> session
  end

{:ok, catalog_ref} = MOQX.subscribe(subscriber, "moqtail", "catalog")

receive do
  {:moqx_subscribe_ok, %MOQX.SubscribeOk{handle: ^catalog_ref}} -> :ok
end

catalog =
  receive do
    {:moqx_object, %MOQX.ObjectReceived{handle: ^catalog_ref, object: %{payload: payload}}} ->
      {:ok, cat} = MOQX.Catalog.decode(payload)
      cat
  end

video = MOQX.Catalog.video_tracks(catalog) |> List.first()
{:ok, video_ref} = MOQX.subscribe_track(subscriber, "moqtail", video)

receive do
  {:moqx_subscribe_ok, %MOQX.SubscribeOk{handle: ^video_ref}} -> :ok
end
```

### Mix task: relay inspection and live stats

For quick manual debugging, use the built-in inspection task:

```bash
mix moqx.inspect
# defaults to https://ord.abr.moqtail.dev and namespace moqtail
mix moqx.inspect --track 259
mix moqx.inspect --list-tracks-only
mix moqx.inspect --list-relay-presets
mix moqx.inspect --choose-relay --list-tracks-only
mix moqx.inspect --preset cloudflare-draft14-bbb --list-tracks-only

# Cloudflare moq-rs style catalogs use .catalog
mix moqx.inspect https://draft-14.cloudflare.mediaoverquic.com --namespace bbb --catalog-track .catalog --list-tracks-only
mix moqx.inspect https://draft-14.cloudflare.mediaoverquic.com --namespace bbb --no-fetch --list-tracks-only
```

The task will:

1. connect as a subscriber,
2. load catalog via fetch (with live-subscribe fallback when fetch has no objects or the relay has not cached the track yet),
3. optionally apply a known relay preset (`--preset`) or choose one interactively (`--choose-relay`),
4. try `"catalog"` and then `".catalog"` unless `--catalog-track` is set,
5. optionally skip fetch entirely with `--no-fetch` and go straight to live subscribe,
6. prompt you to choose a track (or use `--track <name>`),
7. subscribe and print live stats each interval:
   - PRFT latency (or `n/a` if unavailable),
   - bandwidth (`B/s` and `kbps`),
   - groups/sec,
   - objects/sec.

Use `mix help moqx.inspect` for full options.

Tips:
- `--list-tracks-only` is handy for scripting/discovery without subscribing.
- `--list-relay-presets` prints known relay presets and example commands.
- `--choose-relay` lets you pick a known relay interactively and prints the exact reproduce command.
- `--no-fetch` is useful for relays that do not implement fetch yet.
- `--show-raw` prints full per-track raw catalog maps.
- pass `--timeout <ms>` to auto-stop after a bounded runtime.
- the default relay (`https://ord.abr.moqtail.dev`) has an online demo player at
  `https://abr.moqtail.dev/demo`, which is useful for quickly double-checking
  relay availability outside of `moqx`.
- legacy aliases `mix moqx.moqtail.demo` and `mix moqx.e2e.pubsub` still work,
  but now print deprecation notices.

### Mix task: relay roundtrip smoke test

For a quick publisher+subscriber roundtrip against a relay, use:

```bash
mix moqx.roundtrip
# defaults to https://ord.abr.moqtail.dev

# Cloudflare draft-14 relay endpoints
mix moqx.roundtrip https://interop-relay.cloudflare.mediaoverquic.com:443 --timeout 20000
mix moqx.roundtrip https://draft-14.cloudflare.mediaoverquic.com --timeout 20000
```

The task connects as both publisher and subscriber, publishes a test track,
subscribes to it, waits for publisher track activation, and verifies the
subscriber receives the expected payload.

### Fetch

Fetch retrieves raw track objects by range from a subscriber session.
`fetch/4` returns `{:ok, ref}` immediately, then delivers messages to the
caller's mailbox correlated by `ref`.

Important moqtail relay note: the current relay only serves standalone fetches
from its local track cache. In practice that means fetch works end-to-end for
objects the relay has already seen (for example after live delivery to a
subscriber), but it does not yet forward standalone fetch upstream to a
publisher on cache miss. On such a cache miss, `moqx` surfaces the relay reply
as a typed `{:moqx_request_error, %MOQX.RequestError{op: :fetch, ...}}` rather
than hanging silently.

The fetch message contract is:

- `{:moqx_fetch_ok, %MOQX.FetchOk{ref, namespace, track_name}}`
- `{:moqx_fetch_object, %MOQX.FetchObject{ref, group_id, object_id, payload}}`
- `{:moqx_fetch_done, %MOQX.FetchDone{ref}}`
- `{:moqx_request_error, %MOQX.RequestError{op: :fetch, ref, ...}}`
- `{:moqx_transport_error, %MOQX.TransportError{op: :fetch, ref, ...}}`

Options:

- `priority` -- integer `0..255` (default `0`)
- `group_order` -- `:original`, `:ascending`, or `:descending` (default `:original`)
- `start` -- `{group_id, object_id}` (default `{0, 0}`)
- `end` -- `{group_id, object_id}` (default: open-ended)

`MOQX.Helpers.fetch_catalog/2` is a convenience wrapper that fetches the first
catalog object with sensible defaults (namespace `"moqtail"`, track
`"catalog"`, range `{0,0}..{0,1}`). Override the catalog track explicitly when
needed, for example `track: ".catalog"` for Cloudflare `moq-rs` style relays.

`MOQX.Helpers.await_catalog/2` collects the fetch messages and decodes the
payload into an `MOQX.Catalog` struct in one call:

```elixir
{:ok, ref} = MOQX.Helpers.fetch_catalog(subscriber)
{:ok, catalog} = MOQX.Helpers.await_catalog(ref)

{:ok, cf_ref} = MOQX.Helpers.fetch_catalog(subscriber, namespace: "bbb", track: ".catalog")
{:ok, cloudflare_catalog} = MOQX.Helpers.await_catalog(cf_ref)

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
```

- `mix ci` runs formatting, Credo, and non-integration tests

Integration tests are run separately with `mix test.integration`, against a
relay you start yourself. For local development, the intended workflow is:

```bash
scripts/generate_integration_certs.sh .tmp/integration-certs
export MOQX_RELAY_CACERTFILE=.tmp/integration-certs/ca.pem
export MOQX_EXTERNAL_RELAY_URL=https://127.0.0.1:4433
docker compose -f docker-compose.integration.yml up -d relay
mix test.integration
```

This keeps the relay running across repeated test runs, which is faster and
simpler during local integration-test loops.

You can override relay version independently from the locally compiled moqtail
library by setting `MOQX_RELAY_IMAGE`, for example:

```bash
MOQX_RELAY_IMAGE=ghcr.io/moqtail/relay:sha-190e502 \
  docker compose -f docker-compose.integration.yml up -d relay
```

Set a digest-pinned reference for strict reproducibility:

```bash
MOQX_RELAY_IMAGE='ghcr.io/moqtail/relay:sha-190e502@sha256:36c929b71140a83158da383721f1d59f199a9f643ab5d033910258f5aa2903ee' \
  docker compose -f docker-compose.integration.yml up -d relay
```

`mix test.integration` expects a relay URL and trusted CA path via environment.
By default the tests use `https://127.0.0.1:4433`; set
`MOQX_EXTERNAL_RELAY_URL` and `MOQX_RELAY_CACERTFILE` if you are using a
non-default setup.

When finished locally, tear the relay down with:

```bash
docker compose -f docker-compose.integration.yml down --remove-orphans
```

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
