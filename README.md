# moqx

`moqx` is an Elixir Media over QUIC library with explicit, independent
implementations of standard MOQT draft-18 and MoQ Lite draft-05 over native
QUIC. Protocol selection is explicit; endpoints never imply a protocol and
there is no silent fallback.

The QUIC transport boundary is backed by
[`quicer`](https://github.com/dmorn/quic). Protocol implementations depend on
`MOQX.Transport`, while tests can select the deterministic
`MOQX.Testing.Transport` without changing protocol code.

## Protocol documents

- [RFC 9000 — QUIC](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 — Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9221 — QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221)
- [draft-ietf-moq-transport-18 — Media over QUIC Transport](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-18)
- [draft-lcurley-moq-lite-05 — Media over QUIC Lite](https://datatracker.ietf.org/doc/html/draft-lcurley-moq-lite-05)

The draft-18 interoperability reference is MOQtail pinned at
[`0e265d8`](https://github.com/moqtail/moqtail/commit/0e265d8bf133f86e17472c59f14ca7dc62032900).
The Lite05 interoperability reference is Curley pinned at
[`fd47708`](https://github.com/moq-dev/moq/commit/fd477082c43c3c0738fb62d077d85ea078f10045).

## Installation

```elixir
def deps do
  [{:moqx, "~> 0.10.0"}]
end
```

## Standard MOQT draft-18

Draft-18 is the canonical standard implementation and negotiates native-QUIC
ALPN `moqt-18`:

```elixir
{:ok, client} =
  MOQX.connect("moqt://relay.moqtail.dev:443", protocol: :draft_18)

track = %MOQX.TrackRef{
  namespace: ["moqtail", "testsrc"],
  track: "catalog"
}

{:ok, subscription} =
  MOQX.subscribe(client, track,
    profile: :moqtail_cmsf,
    start: :next_group,
    priority: 127
  )

receive do
  {:moqx, ^client,
   %MOQX.Event.CatalogReceived{
     subscription: ^subscription,
     catalog: %MOQX.Catalog{} = catalog
   }} ->
    catalog
end
```

Publishing has two readiness boundaries: `PublicationReady` accepts the
namespace, then `PublicationSubscriberJoined` accepts each `PUBLISH` track
request before objects may be sent.

```elixir
{:ok, publication} = MOQX.publish(client, ["example", "camera"])

receive do
  {:moqx, ^client, %MOQX.Event.PublicationReady{publication: ^publication}} -> :ok
end

{:ok, video} = MOQX.add_track(client, publication, "video", delivery: :subgroup)

receive do
  {:moqx, ^client, %MOQX.Event.PublicationSubscriberJoined{track: ^video}} ->
    :ok = MOQX.publish_object(client, video, object)
end

:ok = MOQX.finish_publication(client, publication)
```

Draft-18 supports subgroup and datagram delivery, all four subscription filter
forms, request updates, controlled inbound subscriptions, extension
preservation, and delivery draining through `PUBLISH_DONE`. Setup uses paired
unidirectional control streams; each subscription and publication request owns
a bidirectional request stream.

Exact object and subgroup-completion roundtrips were verified against MOQtail
and Cloudflare public draft-18 relays on 2026-09-15. External services can
change independently, so rerun the public integration test for current evidence.

## MoQ Lite draft-05

Lite05 remains an independent protocol implementation selected as
`:moq_lite_05`. It supports timestamped groups, publication and subscription,
track provisioning, broadcast discovery, and the HANG application profile.

```elixir
{:ok, client} = MOQX.connect("moqt://cdn.moq.dev:443", protocol: :moq_lite_05)
{:ok, publication} = MOQX.publish(client, ["anon", "example"])
{:ok, track} = MOQX.add_track(client, publication, "video")
```

See [the pinned HANG/Lite05 interoperability evidence](docs/interop/hang-lite05.md)
for the exact verified scope and playback limitations.

## Application catalog profiles

Wire protocol selection is connection-scoped; catalog profiles are selected per
subscription or published catalog. Raw objects are the default.

| Profile | MOQT draft-18 | MoQ Lite 05 | Catalog track |
| --- | --- | --- | --- |
| `:none` | yes | yes | any, opaque |
| `:cloudflare_cmsf` | yes | yes | `.catalog` |
| `:moqtail_cmsf` | yes | yes | `catalog` |
| `:hang` | rejected | yes | `catalog.json` / `catalog.json.z` |

The matrix describes codec composition, not certification against every relay.
Cloudflare CMSF and MOQtail CMSF remain distinct application formats even
though their retired transport drafts are no longer implemented.

## Events and ordering

Application output uses typed `MOQX.Event.*` structs inside
`{:moqx, client, event}`. Events default to the connecting process; a shared
owner may pass `events_to: router_pid`.

Objects are emitted in normalized transport arrival order. One subgroup
preserves stream-local order and emits a typed `SubgroupEnded` boundary after
its objects. No global coordinate ordering is manufactured across streams.
Applications needing stronger ordering own and bound their reorder policy.

## Development

```bash
mix deps.get
mix format
mix test
mix credo --strict
```

Default tests are fast and hermetic. Real QUIC checks are tagged as integration
tests and excluded by default.

Run public draft-18 publisher/subscriber checks against MOQtail and Cloudflare:

```bash
mix test --only integration test/integration/draft_18_public_relays_test.exs
```

Run the pinned local MOQtail draft-18 relay harness:

```bash
scripts/run_moqtail_draft18_integration.sh
```

Run the pinned Curley Lite05 harness:

```bash
scripts/run_curley_moq_lite_05_integration.sh
```

ExUnit never starts Docker. The runner scripts own Compose startup and cleanup.
The shared integration file also exposes the reference QUIC server:

```bash
docker compose -f docker-compose.integration.yml up -d --wait
mix test --only integration
docker compose -f docker-compose.integration.yml down
```

Loopback TLS certificates are generated under `.tmp/integration-certs/` by
`scripts/gen-loopback-certs.sh`. They are deliberately long-lived and only
authenticate local test names.

## License

MIT
