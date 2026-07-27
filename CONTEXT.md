# MOQX Context

Transport performance work is parked. Current protocol work extends the
subscriber surface across Cloudflare draft-14 and standard MOQT draft-16 over
native QUIC.

## Decisions

- Initial scope is native QUIC via `quicer`; WebTransport/HTTP/3 is out until a
  browser-facing requirement appears.
- Protocol code depends on `MOQX.Transport`, not raw `:quicer` messages.
- `MOQX.Transport` exposes generic QUIC streams, DATAGRAMs, capabilities, and
  shutdown semantics. Draft-specific stream policy lives above it.
- `MOQX.Testing.Transport` is the packaged deterministic test seam. Production facade code
  must not name or construct support-transport state.
- Send APIs return backend-admission credit. Peer delivery is proven later by
  normalized events or receiver evidence.
- The stable public connection API accepts a URI-shaped endpoint plus an
  explicit protocol implementation or built-in identifier. Protocol selection
  is never inferred from the hostname or negotiated as silent fallback.
- Concrete protocol implementations select ALPN, required transport
  capabilities, wire packages, lifecycle, and relay-specific behavior.
- Standard draft-16 subscriber support includes all four subscription filters,
  request updates, subgroup and datagram delivery, accepted parameter and
  extension preservation, and `PUBLISH_DONE` delivery draining. Independent
  subgroup streams are emitted in transport arrival order until #29 defines a
  stronger public ordering contract.
- The protocol-neutral connection driver owns the transport context, feeds
  normalized events to the selected implementation, and applies returned
  transport actions.
- Benchmarks live under `bench/`. Fake and loopback runs are calibration; real
  claims need explicit targets and path evidence.

## Glossary

**Finish Sending**: graceful local send-side stream completion; maps to QUIC
FIN. Avoid "close stream" for this.

**Abort Sending**: abortive local send-side termination with an application
error code; maps to RESET_STREAM.

**Abort Receiving**: abortive local receive-side termination with an
application error code; maps to STOP_SENDING.

**Connection Close**: connection-level shutdown carrying a transport-visible
application error code where the backend supports it.

**Application Error Code**: unsigned integer selected by the protocol layer and
carried by QUIC stream or connection shutdown.

**Transport Profile**: named fixture for protocol-selected ALPN, transport
capabilities, and stream expectations. Current profiles: `:draft_14`,
`:draft_16`, and the protocol-neutral `:streams_only` test fixture.

**Protocol Variant**: concrete MOQT-family protocol version with its own
message model and session rules, e.g. MOQT draft-14 or MOQT draft-16.

**Versioned Wire Package**: reusable message structs, numeric registries, and
framing codecs for one published wire specification, such as IETF MOQT
draft-14 or draft-16. It does not own provider lifecycle or relay policy.

**Protocol Implementation**: executable composition selected explicitly by a
caller, such as Cloudflare draft-14 or standard draft-16. It owns lifecycle,
supported operations, authentication, conventions, events, errors, and
conversion between public intent and wire messages.

**Connection Driver**: protocol-neutral runtime owner of one transport context,
connection, and selected protocol state. It applies protocol-requested
transport actions and publishes protocol-produced public events.

**Relay Integration Harness**: caller-managed Docker Compose deployment of one
pinned relay implementation plus a containerized MOQX public-API test runner.
It is functional interop evidence, not transport benchmark evidence. Each relay
variant owns a separate service, test tag, and runner while sharing certificate
provisioning and the Compose lifecycle boundary.

**Protocol Session**: implementation-owned state machine for one protocol
relationship over one transport connection. It owns stream state, role rules,
protocol events, and transport actions.

**Public Operation**: protocol-neutral application intent submitted through the
stable API, e.g. subscribe, unsubscribe, or close. The selected implementation
converts it into its private state transitions and wire messages.

**Protocol Event**: typed output emitted by a Protocol Session. Stream-derived
events stay tagged with stream identity.

**Transport Action**: side effect requested by a Protocol Session and applied
by a runner through `MOQX.Transport`: open stream, send bytes, finish a send
side, abort a stream side, or close a connection.

**Codec**: protocol-neutral binary helpers and encoder/decoder contracts under
`MOQX.Codec`.

**Payload Codec**: encoding or decoding for one typed protocol payload after
stream framing removed length/type context.

**Stream Codec**: protocol-specific framing and buffering before complete
payloads are dispatched.

**Stream Side**: one directional half of a stream: local sending or local
receiving.

## Relationships

- `send_stream(..., finish: true)` sends the final payload and FIN in one
  ordered request.
- Standalone Finish Sending is FIN-only and ordered after accepted sends on the
  same stream owner path.
- Connection Close may implicitly close all streams on the connection.
- Application Error Code is interpreted by protocol modules, not raw transport.
- A Transport Profile may describe protocol expectations, but the raw transport
  boundary stays generic.
- A Protocol Implementation returns its transport requirements; Transport does
  not resolve protocol identifiers or enforce provider stream rules.
- Multiple Protocol Implementations may compose one Versioned Wire Package
  without sharing lifecycle state.
- Relay Integration Harnesses select the protocol and relay explicitly. They do
  not infer a protocol from the service hostname or start Docker from ExUnit.
- A Protocol Implementation consumes transport input through
  `handle_transport/2` and public intent through `handle_operation/2`.
- A Protocol Session returns Transport Actions as data. Runners apply them.
- Stream Codecs are per transport stream. Bytes from different streams are
  never muxed together before decoding.
