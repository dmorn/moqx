# moqx

> Elixir bindings for [Media over QUIC (MOQ)](https://moq.dev) via Rustler NIFs on top of [`moqtail-rs`](https://github.com/moqtail/moqtail).

**Status:** early client library with a deliberately narrow, documented support contract.

## Spec references

`moqx` is aligned to the **draft-14** MOQ/WebTransport stack exposed by `moqtail-rs`. It does not automatically track newer IETF drafts; version bumps are explicit.

- [RFC 9000 — QUIC](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 — TLS for QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9114 — HTTP/3](https://www.rfc-editor.org/rfc/rfc9114)
- [RFC 9221 — QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221)
- [RFC 9297 — HTTP Datagrams and Capsule](https://www.rfc-editor.org/rfc/rfc9297)
- [draft-ietf-webtrans-http3-14](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-14.txt)
- [draft-ietf-moq-transport-14](https://www.ietf.org/archive/id/draft-ietf-moq-transport-14.txt)

## Installation

```elixir
# mix.exs
{:moqx, "~> 0.7.1"}
```

- source: <https://github.com/dmorn/moqx>
- changelog: <https://github.com/dmorn/moqx/blob/main/CHANGELOG.md>
- license: MIT

## Supported client contract

- explicit split roles only (publisher sessions publish, subscriber sessions subscribe)
- WebTransport / MOQT draft-14
- broadcasts, tracks, subgroup-stream and object-datagram delivery
- live subscription via `SUBSCRIBE` with `FilterType::LatestObject`
- raw fetch for retrieving track objects by range (subscriber only; relay serves from cache only)
- catalog publication/retrieval helpers via `MOQX.Helpers`
- CMSF catalog parsing via `MOQX.Catalog`
- relay authentication via `?jwt=...` URL query parameter
- path-rooted relay authorization (connect URL path must match token `root`)
- TLS verification on by default; `tls: [verify: :insecure]` and `tls: [cacertfile: "..."]` available

Not planned: merged publisher/subscriber sessions, relay/server listener APIs, automatic catalog-driven subscription orchestration.

## Public API

- `MOQX` — low-level async message-passing core
- `MOQX.Helpers` — opt-in convenience wrappers built on top of `MOQX`

All network operations are asynchronous and correlated by a ref or handle returned immediately. Errors arrive as typed process messages (`%MOQX.RequestError{}`, `%MOQX.TransportError{}`).

## Usage

### Connect

```elixir
{:ok, ref} = MOQX.connect_publisher("https://relay.example.com?jwt=<token>",
  tls: [cacertfile: "/path/to/rootCA.pem"])

publisher =
  receive do
    {:moqx_connect_ok, %MOQX.ConnectOk{ref: ^ref, session: s}} -> s
    {:moqx_request_error, %MOQX.RequestError{ref: ^ref} = e} -> raise inspect(e)
    {:moqx_transport_error, %MOQX.TransportError{ref: ^ref} = e} -> raise inspect(e)
  end
```

`connect_subscriber/2` and `connect/2` (with `role: :publisher | :subscriber`) follow the same pattern.

### Publish

```elixir
{:ok, publish_ref} = MOQX.publish(publisher, "my-namespace")

broadcast =
  receive do
    {:moqx_publish_ok, %MOQX.PublishOk{ref: ^publish_ref, broadcast: b}} -> b
    {:moqx_request_error, %MOQX.RequestError{ref: ^publish_ref} = e} -> raise inspect(e)
  end

catalog_json = ~s({"version":1,"supportsDeltaUpdates":false,"tracks":[{"name":"video","role":"video"}]})
{:ok, catalog_track} = MOQX.Helpers.publish_catalog(broadcast, catalog_json)

{:ok, track} = MOQX.create_track(broadcast, "video")
:ok = MOQX.write_frame(track, "frame-1")
:ok = MOQX.finish_track(track)
```

For datagram delivery use `write_datagram/3` with explicit `group_id`, `object_id`, etc. Writes are lifecycle-gated and return typed errors before activation or after `finish_track/1`.

### Subscribe

```elixir
{:ok, handle} = MOQX.subscribe(subscriber, "my-namespace", "video", delivery_timeout_ms: 1_500)

receive do: ({:moqx_subscribe_ok, %MOQX.SubscribeOk{handle: ^handle}} -> :ok)

receive do
  {:moqx_object, %MOQX.ObjectReceived{handle: ^handle, object: obj}} ->
    IO.inspect(obj.payload)
  {:moqx_publish_done, %MOQX.PublishDone{handle: ^handle}} ->
    :done
end

:ok = MOQX.unsubscribe(handle)
```

Subscribe message contract: `:moqx_subscribe_ok`, `:moqx_track_init`, `:moqx_object`, `:moqx_end_of_group`, `:moqx_publish_done`, `:moqx_request_error`, `:moqx_transport_error`.

`%MOQX.Object{transport: :subgroup | :datagram}` indicates the delivery path.
Incoming draft-14 status datagrams are mapped into the same mailbox contract:
`:does_not_exist` arrives as an object status, while `:end_of_group` and
`:end_of_track` collapse to lifecycle/control messages.

### Fetch

```elixir
{:ok, ref} = MOQX.Helpers.fetch_catalog(subscriber)
{:ok, catalog} = MOQX.Helpers.await_catalog(ref)

video = catalog |> MOQX.Catalog.video_tracks() |> List.first()
```

`fetch/4` options: `priority`, `group_order` (`:original | :ascending | :descending`), `start`/`end` as `{group_id, object_id}`. Message contract: `:moqx_fetch_ok`, `:moqx_fetch_object`, `:moqx_fetch_done`, `:moqx_request_error`, `:moqx_transport_error`.

Note: the moqtail relay serves standalone fetches from its local cache only. Cache misses surface as `%MOQX.RequestError{op: :fetch}`.

### Catalog

```elixir
{:ok, catalog} = MOQX.Catalog.decode(payload)

MOQX.Catalog.tracks(catalog)
MOQX.Catalog.video_tracks(catalog)
MOQX.Catalog.audio_tracks(catalog)
MOQX.Catalog.get_track(catalog, "259")
```

Each track exposes a `raw` map for forward compatibility with unmodeled catalog fields.

## Relay authentication

Pass JWTs as `?jwt=...` in the connect URL. The URL path must match the token `root` claim.

Claims: `root`, `put` (publish), `get` (subscribe), `cluster`, `iat`, `exp`.

```text
https://localhost:4443/room/123?jwt=eyJhbGciOiJIUzI1NiIs...
```

## Mix tasks

```bash
# Live relay inspection and stats
mix moqx.inspect
mix moqx.inspect --track 259 --list-tracks-only
mix moqx help moqx.inspect   # full options

# Publisher+subscriber roundtrip smoke test
mix moqx.roundtrip
mix moqx.roundtrip https://relay.example.com --timeout 20000
```

## Local development

**Prerequisites:** Rust toolchain (`rustup`), Elixir/Erlang.

```bash
mix deps.get
mix test          # unit tests
mix ci            # format + credo + unit tests
```

Integration tests require a local relay:

```bash
scripts/generate_integration_certs.sh .tmp/integration-certs
export MOQX_RELAY_CACERTFILE=.tmp/integration-certs/ca.pem
export MOQX_EXTERNAL_RELAY_URL=https://127.0.0.1:4433
docker compose -f docker-compose.integration.yml up -d relay
mix test.integration
```

Keep the relay running across test runs for faster iteration. If you regenerate certs or hit `invalid peer certificate: BadSignature`, recreate the container:

```bash
docker compose -f docker-compose.integration.yml down --remove-orphans
docker compose -f docker-compose.integration.yml up -d relay
```

Override the relay image with `MOQX_RELAY_IMAGE=ghcr.io/moqtail/relay:<tag>`.

## License

MIT
