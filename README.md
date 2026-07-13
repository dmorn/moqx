# moqx

`moqx` is an Elixir Media over QUIC library.

It provides a QUIC transport boundary backed by [`quicer`](https://github.com/dmorn/quic) for building MOQT implementations in Elixir. The transport boundary keeps protocol code independent from the concrete QUIC backend and allows tests to use deterministic support transports.

## Protocol documents

`moqx` currently targets MOQT draft-14 and is expected to grow support for MOQ Lite.

Core references:

- [RFC 9000 — QUIC: A UDP-Based Multiplexed and Secure Transport](https://www.rfc-editor.org/rfc/rfc9000)
- [RFC 9001 — Using TLS to Secure QUIC](https://www.rfc-editor.org/rfc/rfc9001)
- [RFC 9002 — QUIC Loss Detection and Congestion Control](https://www.rfc-editor.org/rfc/rfc9002)
- [RFC 9114 — HTTP/3](https://www.rfc-editor.org/rfc/rfc9114)
- [RFC 9221 — QUIC DATAGRAM](https://www.rfc-editor.org/rfc/rfc9221)
- [RFC 9297 — HTTP Datagrams and the Capsule Protocol](https://www.rfc-editor.org/rfc/rfc9297)
- [draft-ietf-webtrans-http3-14 — WebTransport over HTTP/3](https://www.ietf.org/archive/id/draft-ietf-webtrans-http3-14.txt)
- [draft-ietf-moq-transport-14 — Media over QUIC Transport](https://www.ietf.org/archive/id/draft-ietf-moq-transport-14.txt)
- [draft-lcurley-moq-lite — MOQ Lite](https://datatracker.ietf.org/doc/draft-lcurley-moq-lite/)

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

Catalog tracks can be subscribed directly. Delivered objects retain their
subscription, group, subgroup, object, and priority coordinates:

```elixir
{:ok, video} = MOQX.Catalog.select_h264(catalog)
{:ok, subscription} = MOQX.subscribe(client, MOQX.Catalog.Track.track_ref(video))

receive do
  {:moqx, ^client,
   %MOQX.Event.ObjectReceived{
     object: %MOQX.Object{subscription: ^subscription} = object
   }} ->
    object.payload
end
```

For CMAF H.264, `MOQX.CMAF.capture/4` subscribes to the advertised
initialization and media tracks, orders received objects by their protocol
coordinates, writes a fragmented MP4 atomically, and unsubscribes its temporary
subscriptions:

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

`MOQX.CMAF.publish_file/3` prepares a fragmented MP4 as a CMSF `.catalog`, an
initialization track, and retained media fragments:

```elixir
{:ok, published} =
  MOQX.CMAF.publish_file(client, "/tmp/input.mp4",
    namespace: ["live", "camera-1"]
  )
```

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

The public Cloudflare interop check is independently selectable and depends on
the availability of an external service:

```bash
mix test --only integration test/integration/cloudflare_catalog_test.exs
```

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
