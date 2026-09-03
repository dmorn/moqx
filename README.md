# moqx

`moqx` is an Elixir Media over QUIC library.

It provides a QUIC transport boundary backed by [`quicer`](https://github.com/dmorn/quic) for building MOQT implementations in Elixir. The transport boundary keeps protocol code independent from the concrete QUIC backend and allows tests to use deterministic support transports.

## Protocol documents

`moqx` implements independent Cloudflare draft-14, standard MOQT draft-16, and
MoQ Lite draft-05 protocols over native QUIC. Protocol selection is explicit,
so the implementations coexist without hostname inference or fallback.

Core references:

- [RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 — Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9002 — QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002)
- [RFC 9114 — HTTP/3](https://www.rfc-editor.org/rfc/rfc9114)
- [RFC 9221 — QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221)
- [RFC 9297 — HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297)
- [draft-ietf-webtrans-http3-14 — WebTransport over HTTP/3](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-14.txt)
- [draft-ietf-moq-transport-14 — Media over QUIC Transport](https://www.ietf.org/archive/id/draft-ietf-moq-transport-14.txt)
- [draft-ietf-moq-transport-16 — Media over QUIC Transport](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-16)
- [draft-lcurley-moq-lite-05 — Media over QUIC Lite](https://datatracker.ietf.org/doc/html/draft-lcurley-moq-lite-05)

The draft-16 interoperability reference is Moqtail's `draft-16` branch pinned
at commit
[`c2ff7253479c6a0d7c8282a1cad289d591ebc302`](https://github.com/moqtail/moqtail/commit/c2ff7253479c6a0d7c8282a1cad289d591ebc302).

## Installation

```elixir
# mix.exs
{:moqx, "~> 0.7.1"}
```

## Cloudflare draft-14 subscriber

Protocol selection is explicit; the endpoint never selects an implementation
implicitly. Cloudflare's public Big Buck Bunny catalog can be requested with:

```elixir
{:ok, client} =
  MOQX.connect("moqt://draft-14.cloudflare.mediaoverquic.com:443",
    protocol: :cloudflare_draft_14
  )

catalog_track = %MOQX.TrackRef{namespace: ["bbb"], track: ".catalog"}
{:ok, subscription} = MOQX.subscribe(client, catalog_track)

receive do
  {:moqx, ^client,
   %MOQX.Event.CatalogReceived{catalog: %MOQX.Catalog{} = catalog}} ->
    catalog.tracks
end
```

This path uses native QUIC with ALPN `moq-00`, negotiates MOQT draft-14,
subscribes with `LargestObject`, and decodes the CMSF catalog delivered on a
subgroup stream. It does not use `FETCH`.

Subscriptions accept a protocol-neutral relative start policy:

```elixir
{:ok, subscription} =
  MOQX.subscribe(client, track,
    start: :next_group
  )
```

`:next_object` is the compatibility default and maps to draft-14
`LargestObject`; `:next_group` maps to `NextGroupStart`. A selected protocol
that cannot represent a requested policy returns
`{:error, {:unsupported_subscription_start, policy}}` instead of silently
substituting another boundary.

## MoQ Lite draft-05 subscriber and publisher

Select MoQ Lite explicitly with `protocol: :moq_lite_05`. It uses native QUIC
ALPN `moq-lite-05`, sends a unidirectional Setup Stream with Path and Role, and
implements Announce, Track, Subscribe, and reliable Group Streams through the
same public API as the other implementations:

```elixir
{:ok, client} =
  MOQX.connect("moql://relay.example/live",
    protocol: :moq_lite_05,
    role: :publisher
  )

{:ok, publication} = MOQX.publish(client, ["live"])

{:ok, video} =
  MOQX.add_track(client, publication, "video",
    timescale: 90_000,
    publisher_priority: 127,
    publisher_max_latency: 1_000
  )

:ok =
  MOQX.publish_object(client, video, %MOQX.Object{
    group_id: 42,
    object_id: 0,
    timestamp: 3_780_000,
    end_of_group?: true,
    payload: frame
  })
```

`timescale` is required and positive. Publisher priority is a byte and maximum
latency is a bounded QUIC varint. Received objects preserve FRAME timestamps
independently from group and object identifiers. Automatic, controlled, and
reactive inbound subscription handling use the existing opaque request and
published-subscription handles; a Group Stream is kept open across objects
until `end_of_group?: true`.

The default subscriber request resolves the publisher's latest group.
Draft-05 can also represent absolute group starts and ranges whose object
coordinate is zero. Unsupported relative starts, non-zero object coordinates,
parameters, and delivery modes return typed errors rather than changing their
meaning. WebTransport, Fetch, Probe, datagram delivery, catalogs, and draft-06
are not part of this implementation.

The native-QUIC endpoint scheme is `moql://`; the older `moqt://` spelling
remains accepted for existing callers. MoQ Lite draft-05 requires the QUIC
DATAGRAM transport parameter even when an application only publishes reliable
Group Streams, so MOQX advertises receive support without changing the public
delivery API.

## Standard draft-16 subscriber and publisher

Moqtail's public relay can be reached through the independent `:draft_16`
implementation. Subscription and catalog reception are available against the
public relay:

```elixir
{:ok, client} =
  MOQX.connect("moqt://relay.moqtail.dev:443",
    protocol: :draft_16
  )

catalog_track =
  %MOQX.TrackRef{
    namespace: ["moqtail", "testsrc"],
    track: "catalog"
  }

{:ok, subscription} =
  MOQX.subscribe(client, catalog_track,
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

Draft-16 publication uses two readiness boundaries. `PublicationReady` means
the relay accepted the namespace. Each added track then sends draft-16
`PUBLISH`; objects are accepted only after the corresponding
`PublicationSubscriberJoined` event confirms `PUBLISH_OK`:

```elixir
{:ok, publication} = MOQX.publish(client, ["example", "camera"])

receive do
  {:moqx, ^client,
   %MOQX.Event.PublicationReady{publication: ^publication}} ->
    :ok
end

{:ok, video} =
  MOQX.add_track(client, publication, "video",
    delivery: :datagram
  )

receive do
  {:moqx, ^client,
   %MOQX.Event.PublicationSubscriberJoined{track: ^video}} ->
    MOQX.publish_object(client, video, object)
end

:ok = MOQX.finish_publication(client, publication)
```

`delivery: :subgroup` is the default and opens one subgroup stream per object.
`delivery: :datagram` emits draft-16 unified object datagrams and reports zero
opened streams when the track completes. The delivery choice also applies to
relay-initiated subscribers of that track. Cloudflare draft-14 rejects
`:datagram` explicitly because that implementation supports subgroup
publication only.

`finish_publication/3` first cancels pending controlled requests with
`REQUEST_ERROR(DOES_NOT_EXIST)`, then completes established relay subscriptions
and ready publisher-initiated tracks with `PUBLISH_DONE` and their exact
opened-stream counts. It sends `PUBLISH_NAMESPACE_DONE` only after those
subscription boundaries. Applications receive
`PublicationSubscriptionCancelled` and `PublicationSubscriberLeft` for the
affected requests, and their handles become stale immediately.

Namespace rejection/cancellation and per-track rejection emit
`PublicationFailed`, `PublicationCancelled`, and `PublicationTrackFailed`
respectively; rejected and finished handles are invalidated deterministically.

Incoming draft-16 `SUBSCRIBE` requests use the same
`inbound_subscriptions: :automatic | :controlled` publication policy and the
same opaque request, accept, reject, timeout, joined, and left events as the
draft-14 implementation. Accepted subscribers receive their own track alias
and the track's selected subgroup or datagram delivery; `UNSUBSCRIBE` completes
that subscriber with the exact stream count.

The operator workflow below was verified against `relay.moqtail.dev` and
`player.moqtail.dev` on 2026-07-28: the player discovered the CMSF catalog,
selected the advertised H.264 track, reached `Playing`, decoded 640×360 video,
and advanced its media clock while the publisher completed cleanly. Those
services can change independently, so rerun the smoke for current deployment
evidence.

This path negotiates ALPN `moqt-16`, sends native-QUIC `PATH` and `AUTHORITY`
setup parameters, and decodes draft-16 subgroup streams and object datagrams.
Objects preserve extension headers and end-of-group metadata. Objects on the
`catalog` track are decoded as current Moqtail CMSF values. Other tracks remain
ordinary `ObjectReceived` events.

Draft-16 also accepts the complete protocol-neutral filter model:

```elixir
filter = %MOQX.SubscriptionFilter{
  type: :absolute_range,
  start_location: {12, 4},
  end_group: 20
}

{:ok, subscription} =
  MOQX.subscribe(client, track,
    filter: filter,
    priority: 127,
    group_order: :ascending,
    delivery_timeout: 5_000
  )

:ok =
  MOQX.update_subscription(client, subscription,
    start: :next_group,
    priority: 64
  )
```

The relative `:start` policies remain the portable API shared with Cloudflare.
Absolute start/range filters, request updates, datagrams, and accepted
subscription parameters are currently implemented by `:draft_16`. Update
success and rejection arrive as `SubscriptionUpdated` and
`SubscriptionUpdateFailed`; an update rejection leaves the subscription
active.

Current Moqtail catalogs use top-level `role`, `packaging`, `codec`, dimensions,
bitrate, and timescale fields. Per-track base64 `initData` is validated and
decoded into `track.init_data`. The catalog subscription namespace is retained
when track entries omit one, so the selected address is exact:

```elixir
{:ok, video} = MOQX.Catalog.select_h264(catalog)
media_ref = MOQX.Catalog.track_ref(catalog, video)
{:ok, subscription} = MOQX.subscribe(client, media_ref)

receive do
  {:moqx, ^client,
   %MOQX.Event.ObjectReceived{
     object: %MOQX.Object{subscription: ^subscription} = object
   }} ->
    object.payload
end
```

H.264 selection is deterministic: compatible initialized tracks are ordered by
resolution, bitrate, then track name. Invalid versions, field types, supported
values, and base64 return `%MOQX.Catalog.Error{path: path, reason: reason}`.

For CMAF H.264, `MOQX.CMAF.capture/4` uses Moqtail inline initialization bytes
or subscribes to Cloudflare's separately advertised initialization track. It
then subscribes to the exact media address, orders received objects by their
protocol coordinates, writes a fragmented MP4 atomically, and unsubscribes its
temporary subscriptions:

```elixir
{:ok, report} =
  MOQX.CMAF.capture(client, catalog, "/tmp/cloudflare-bbb.mp4",
    objects: 120,
    timeout: 30_000
  )
```

The runnable external example performs the complete flow:

```bash
mix run scripts/cloudflare_h264_capture.exs /tmp/cloudflare-bbb.mp4 120

ffprobe -v error -show_streams /tmp/cloudflare-bbb.mp4
ffmpeg -y -i /tmp/cloudflare-bbb.mp4 -map 0:v:0 -c:v copy \
  -bsf:v h264_mp4toannexb -an -f h264 /tmp/cloudflare-bbb.h264
ffmpeg -v error -f h264 -i /tmp/cloudflare-bbb.h264 -f null -
```

`MOQX.unsubscribe/2` sends the selected protocol's unsubscribe message;
`MOQX.close/2` closes the connection. Relay rejections are delivered as
`MOQX.Event.SubscriptionFailed`, while `MOQX.Event.SubscriptionDone` is emitted
only after every stream advertised by `PUBLISH_DONE` has been processed or the
subscription's `:delivery_timeout` has elapsed.

Objects are emitted in normalized transport arrival order. Objects within one
subgroup preserve their stream order, but no global coordinate or group order
is manufactured across independent subgroup streams.

Each subgroup stream emits a typed boundary after all preceding object/status
events:

```elixir
receive do
  {:moqx, ^client,
   %MOQX.Event.SubgroupEnded{
     subscription: ^subscription,
     group_id: group_id,
     subgroup_id: subgroup_id,
     outcome: :complete
   }} ->
    {group_id, subgroup_id}
end
```

Cloudflare's catalog convention remains separate: `.catalog`,
`commonTrackFields`, codec values under `selectionParams`, and `initTrack`.
Both shapes normalize into `%MOQX.Catalog{}` without changing their
initialization lifecycle; `catalog.format` is `:cloudflare` or
`:moqtail_cmsf`.

`:complete` means FIN proved the subgroup complete. `:reset` means more objects
may exist and does not end the subscription; `:closed` means completeness is
unknown. `SubscriptionDone` never overtakes an accepted subgroup boundary.
Datagrams have no subgroup boundary. Applications requiring stronger ordering
own and bound their reorder buffer and gap policy; see ADR-0011.

All application-facing output uses typed `MOQX.Event.*` structs inside the
stable `{:moqx, client, event}` envelope. By default events go to the process
that calls `MOQX.connect/2`; shared connection owners can choose a router:

```elixir
{:ok, client} =
  MOQX.connect(endpoint,
    protocol: :cloudflare_draft_14,
    events_to: router_pid
  )
```

Downstream projects can run hermetic protocol tests with the packaged in-memory
transport. It must be selected explicitly and is never chosen by production
facade code:

```elixir
{:ok, network} = MOQX.Testing.Transport.start_network()

MOQX.connect("moqt://localhost:443",
  protocol: :cloudflare_draft_14,
  transport: {MOQX.Testing.Transport, network: network, profile: :draft_14}
)
```

## Cloudflare draft-14 publisher

Publishing uses the same explicitly selected client. Applications declare a
namespace and tracks, then supply protocol-neutral objects; Cloudflare request
IDs, track aliases, and inbound relay subscriptions remain implementation
details:

```elixir
{:ok, publication} = MOQX.publish(client, ["live", "camera-1"])

{:ok, video} =
  MOQX.add_track(client, publication, "video.m4s", retention: :live)

:ok =
  MOQX.publish_object(client, video, %MOQX.Object{
    group_id: 42,
    subgroup_id: 0,
    object_id: 0,
    publisher_priority: 127,
    payload: fragment
  })

:ok = MOQX.finish_publication(client, publication)
```

Retention is application policy: `:live` discards objects when no subscriber
is active, `:latest` retains one object for catalog or initialization tracks,
and `:all` replays bounded static content.

Inbound subscriptions are accepted automatically by default. A publisher can
instead inspect, authorize, and provision each request before deciding it:

```elixir
{:ok, publication} =
  MOQX.publish(client, ["live", "camera-1"],
    inbound_subscriptions: :controlled,
    subscription_decision_timeout: 5_000,
    max_pending_subscriptions: 128
  )

receive do
  {:moqx, ^client,
   %MOQX.Event.PublicationSubscriptionRequested{request: request}} ->
    {:ok, video} =
      MOQX.add_track(client, publication, request.track.track, retention: :live)

    {:ok, published_subscription} =
      MOQX.accept_subscription(client, request, video)
end
```

For a draft-16 namespace-forwarded request whose track does not yet exist,
acceptance can materialize the requested track without sending a conflicting
publisher-initiated `PUBLISH`. The call returns the track and its first
accepted subscription as separate opaque handles:

```elixir
{:ok, video, published_subscription} =
  MOQX.accept_subscription(client, request,
    retention: :live,
    delivery: :subgroup
  )
```

`PublicationSubscriberJoined` and `PublicationSubscriberLeft` carry the same
`PublishedSubscription` handle in their `subscription` field. The legacy
wire-derived `request_id` field remains temporarily available for
compatibility, but application lifecycle state should use the opaque handle.

An application can finish exactly one accepted subscriber without withdrawing
the published track or namespace:

```elixir
:ok =
  MOQX.finish_subscription(client, published_subscription,
    status: :subscription_ended,
    reason: "source unavailable"
  )
```

Both supported implementations translate the status to their native
`PUBLISH_DONE`, include the exact number of opened subgroup streams, emit
`PublicationSubscriberLeft`, and invalidate the handle. Remote `UNSUBSCRIBE`
converges on the same terminal event and handle lifecycle. Duplicate, stale,
and cross-connection handles return deterministic errors.

`MOQX.reject_subscription/3` accepts a protocol-neutral
`MOQX.SubscriptionRejection`. Pending requests are connection-scoped, bounded
by the configured count and timeout, and are invalidated by unsubscribe,
publication termination, or connection closure. Request events preserve
priority, forward state, group order, all four draft-14 filters, repeated
authorization parameters, delivery timeout, and unknown extensions.

Controlled acceptance supports ascending delivery. A request for descending
delivery remains pending and `accept_subscription/4` returns
`{:error, :unsupported_group_order}`; the application should reject it with
`:not_supported`. Publisher-selected order defaults to ascending and can be
confirmed explicitly with `group_order: :ascending` in the acceptance options.

`MOQX.CMAF.publish_file/3` prepares a fragmented MP4 using the selected
protocol's catalog convention. Cloudflare draft-14 uses `.catalog`, a separate
initialization track, and retained media fragments. Standard draft-16 waits for
namespace and track readiness, publishes a Moqtail-compatible `catalog` with
inline `initData`, then publishes retained media on `video`:

```elixir
{:ok, published} =
  MOQX.CMAF.publish_file(client, "/tmp/input.mp4",
    namespace: ["live", "camera-1"],
    catalog_repetitions: 10,
    catalog_interval: 1_000,
    fragment_interval: 1_000
  )
```

The repository includes an opt-in finite publisher for the public Moqtail
draft-16 relay and player. It prints the player URL before publication starts,
repeats only the catalog during the discovery window, and sends each media
fragment once so embedded CMAF decode timestamps remain monotonic:

```bash
ffmpeg -i input.mp4 -an -c:v libx264 -profile:v baseline -level 3.1 \
  -g 30 -keyint_min 30 -sc_threshold 0 \
  -movflags +frag_keyframe+empty_moov+default_base_moof \
  -frag_duration 1000000 -f mp4 /tmp/input-fragmented.mp4

mise exec -- mix run scripts/moqtail_cmaf_publish.exs \
  /tmp/input-fragmented.mp4 \
  --endpoint moqt://relay.moqtail.dev:443 \
  --namespace moqx/unique-camera \
  --catalog-repetitions 10 \
  --catalog-interval 1000 \
  --fragment-interval 1000
```

Open the printed `https://player.moqtail.dev` URL during the catalog discovery
window. The input must be fragmented H.264 CMAF; the codec, dimensions,
bitrate, timescale, and fragment pacing options must describe that file. This
manual workflow is not part of ordinary `mix test`, and local success alone is
not evidence of public relay/player playback.

Managed relay credentials are explicit caller input. The credential value is
wrapped so both its value and the resulting sensitive wire actions have
redacted inspection:

```elixir
{:ok, client} =
  MOQX.connect(endpoint,
    protocol: :cloudflare_draft_14,
    authorization: MOQX.Secret.new(token)
  )
```

MOQX encodes that value using draft-14's standard AUTHORIZATION TOKEN
parameter. Token acquisition, permissions, storage, and rotation remain relay
and application concerns; MOQX does not read process or application
configuration for credentials.

The manual publisher/subscriber roundtrip accepts a token file so the token is
not placed in shell history. Omit it for Cloudflare's public relay:

```bash
mix run scripts/cloudflare_h264_publish.exs /tmp/input.mp4 \
  --endpoint moqt://draft-14.cloudflare.mediaoverquic.com:443 \
  --namespace moqx-test/unique-publisher \
  --output /tmp/roundtrip.mp4 \
  --timeout 120000

# For a managed relay, additionally pass:
# --authorization-file /path/to/temporarily-mounted-token

ffprobe -v error -show_streams /tmp/roundtrip.mp4
ffmpeg -v error -i /tmp/roundtrip.mp4 -map 0:v:0 -f null -
```

## Development

```bash
mix deps.get
mix test
mix ci
```

Default tests are fast and hermetic. Real QUIC checks are tagged as ExUnit
integration tests and are excluded by default.

The public Moqtail draft-16 subscriber smoke is independently selectable:

```bash
mix test --only integration \
  test/integration/moqtail_draft_16_catalog_test.exs
```

The repo-owned draft-16 harness builds Moqtail's relay and test publisher at
the immutable revision
`c2ff7253479c6a0d7c8282a1cad289d591ebc302`, then verifies the ordinary MOQX
public subscriber API over local QUIC with generated TLS:

```bash
scripts/run_moqtail_draft16_integration.sh
```

This pinned harness is independent of the public relay smoke and does not run
during ordinary `mix test`.

The self-contained public Cloudflare subscription-start check publishes a
unique namespace, subscribes with `:next_group`, and records the deployed
relay's boundary behavior. It is independently selectable and depends on the
availability of an external service:

```bash
mix test --only integration \
  test/integration/cloudflare_subscription_start_test.exs
```

The separate `test/integration/cloudflare_catalog_test.exs` smoke depends on
Cloudflare's optional `bbb/.catalog` fixture being published.

The repo-owned Cloudflare draft-14 roundtrip runs both MOQX and a real relay in
Docker. It publishes a catalog and media object through the public API,
subscribes through a second public client, verifies delivery, and exercises
graceful publication completion:

```bash
scripts/run_moq_rs_integration.sh
```

The harness builds Cloudflare's `moq-rs` `draft-ietf-moq-transport-14` branch at
the immutable revision `69302d3dc2422e93b8a1d62f853a6759aa9e5468`. Do not
replace that pin with `main`: upstream `main` has moved to a later MOQT draft
and no longer negotiates the draft-14 `moq-00` ALPN. The MOQX test runner joins
the Compose network directly so the QUIC path is identical on Docker Desktop
and Linux CI rather than depending on host UDP forwarding.

That pinned relay decodes `NextGroupStart` but does not apply the filter when
attaching its retained subgroup reader: it can replay the current retained
group before delivering a later group. The integration test records this relay
limitation explicitly. Fixed wire and reducer tests establish that MOQX sends
draft-14 filter value `0x1`; applications must not treat this relay version as
proof that the peer enforced the requested boundary.

ExUnit never starts Docker. The script owns Compose startup and cleanup, and
the same script is the `Cloudflare draft-14 relay roundtrip` CI job. Future
relay variants should add separately pinned Compose services,
tagged public-API tests, and runner scripts following this boundary; they must
not add an implicit protocol fallback or overload this Cloudflare test.

The MoQ Lite draft-05 interoperability harness builds Curley's official relay
and `moq` CLI from the same immutable source revision
`fd477082c43c3c0738fb62d077d85ea078f10045` (the `moq-relay-v0.14.15` and
`moq-cli-v0.10.0` release commit). It uses generated loopback TLS certificates
and real native QUIC inside the Compose network:

```bash
scripts/run_curley_moq_lite_05_integration.sh
```

The integration matrix verifies an exact timestamped payload through MOQX in
both roles, then runs the official Curley CLI as an independent H.264 publisher
and subscriber in the opposite directions. It also verifies relay fan-out and
final-subscriber lifecycle: A can leave while B continues receiving; B's final
explicit departure produces the upstream leave within 5 seconds; an abrupt
final disconnect also leaves; and a later C receives a fresh group without a
publisher restart. The configured publisher maximum latency remains the issue's
45-second upper bound. The complete local matrix currently finishes in under a
second after image startup.

The public `cdn.moq.dev` check is intentionally opt-in. It publishes a unique,
anonymous broadcast below `/anon`, waits for clustered route propagation, and
subscribes through a separate MOQX connection:

```bash
scripts/run_curley_moq_lite_05_public.sh
```

On 2026-09-03 the container resolved `cdn.moq.dev` to IPv4
`172.232.208.199`; the DNS resolver returned no IPv6 address. MOQX passes the
hostname unchanged to Quicer/MsQuic, so address selection and any transport
fallback remain below the protocol abstraction rather than being implemented
as a second MOQX connection policy. The test prints current IPv4 and IPv6
resolution on every run. Public availability and DNS can change independently,
which is why this check is not part of the hermetic CI job.

To run the caller-managed QUIC integration harness:

```bash
docker compose -f docker-compose.integration.yml up -d --wait
mix test --only integration
```

ExUnit does not start Docker. Stop the harness when finished:

```bash
docker compose -f docker-compose.integration.yml down
```

The harness provisions self-signed certificates under
`.tmp/integration-certs/` (via `scripts/gen-loopback-certs.sh`) and runs the
repo-owned reference QUIC server from `bench/quicprobe` on UDP port 4433. The
generated CA/server certificate is valid for ~100 years — it only authenticates
a `localhost` QUIC handshake, so it is intentionally long-lived to avoid expiry
friction. To (re)generate the loopback certificates outside the harness:

```bash
scripts/gen-loopback-certs.sh .tmp/integration-certs
```

The script is idempotent: it reuses an existing certificate unless it is missing
or nearly expired.

For manual debugging, run the reference CLI directly:

```bash
go run ./bench/quicprobe server --addr :4433 \
  --cert .tmp/integration-certs/server.pem \
  --key .tmp/integration-certs/server-key.pem \
  --alpn moqx-test

go run ./bench/quicprobe client --addr 127.0.0.1:4433 \
  --ca .tmp/integration-certs/ca.pem \
  --alpn moqx-test \
  --bidi-echo hello
```

For reference stream-pressure experiments, the client can emit structured
`quicprobe-v1` JSON:

```bash
go run ./bench/quicprobe client --addr 127.0.0.1:4433 \
  --ca .tmp/integration-certs/ca.pem \
  --alpn moqx-test \
  --json \
  --stream-direction bidirectional \
  --stream-count 2 \
  --payload-size 1200 \
  --payload-count 100
```

## License

MIT
