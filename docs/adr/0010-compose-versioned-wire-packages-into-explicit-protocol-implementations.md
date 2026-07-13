# ADR-0010: Compose versioned wire packages into explicit protocol implementations

- Status: Accepted
- Date: 2026-07-13
- Supersedes: ADR-0006 and ADR-0007

## Context

`moqx` needs to support multiple deployed MOQT-family protocols over the
existing `MOQX.Transport` abstraction. Initial targets include:

- Cloudflare's deployed subset and lifecycle for MOQT draft-14;
- Moqtail's deployed MOQT draft-14 behavior;
- MOQ Lite draft-04.

There are two different axes of variation:

1. A versioned wire specification defines message layouts, framing, stream
   types, datagrams, setup parameters, and error codes.
2. A deployed protocol implementation selects a wire specification and adds
   its supported subset, lifecycle, authentication, catalog conventions,
   extensions, and relay behavior.

Cloudflare draft-14 and Moqtail draft-14 can reuse standard draft-14 message
structs and codecs without sharing one state machine. MOQ Lite draft-04 has a
different wire and stream model altogether.

Only `MOQX.Transport` is treated as an existing architectural foundation for
this decision. Earlier protocol facades, module placement, state machines, and
public API decisions are migration input rather than constraints.

## Decision

Build the protocol layer using composition with four boundaries:

1. a stable public API expressed as application intent;
2. a protocol-neutral connection driver;
3. independent concrete protocol implementations;
4. reusable, versioned wire packages where specifications are genuinely
   shared.

### Public API

Callers provide both an endpoint and an explicit protocol implementation:

```elixir
MOQX.connect(endpoint, protocol: :cloudflare_draft_14)
```

Built-in identifiers resolve to implementation modules. A caller may also
provide a custom module implementing `MOQX.Protocol`.

Protocol selection must not be inferred from a hostname, URI path, negotiated
ALPN, or server failure. There is no silent fallback between implementations.
Endpoint presets may be offered later as conveniences only if the resolved
protocol remains explicit and inspectable.

The ordinary public API uses protocol-neutral application values such as
`MOQX.TrackRef` and `MOQX.Operation.Subscribe`. It does not expose wire message
structs as the normal subscription API. Protocol-specific operations may be
available through a deliberate advanced escape hatch without widening every
implementation's common surface.

### Protocol implementation contract

`MOQX.Protocol` is the mechanical contract between a concrete implementation
and the connection driver. An implementation provides:

- a stable identifier;
- transport requirements for an endpoint;
- initial private protocol state;
- handling of public operations;
- handling of normalized `MOQX.Transport` events;
- inspectable application-level capabilities.

Protocol handlers return `MOQX.Protocol.Transition` values containing updated
private state, public events, and requested transport actions. Protocol code
does not call `MOQX.Transport`, `quicer`, or process APIs directly.

The shared callback shape does not imply a shared lifecycle or shared Session
struct. It standardizes only how the driver exchanges data with an
implementation.

### Connection driver

`MOQX.Runtime.ConnectionDriver` owns:

- the `MOQX.Transport.Context` and connection;
- explicit protocol resolution;
- transport connection and capability validation;
- feeding normalized transport events and public operations to the selected
  protocol implementation;
- applying returned transport actions;
- publishing returned public events;
- runtime process ownership, timeouts, and shutdown coordination.

The driver does not decode protocol bytes, know message identifiers, classify
protocol streams, allocate protocol request IDs, or make provider-specific
decisions.

### Concrete implementations

Each deployed implementation owns:

- setup and shutdown lifecycle;
- supported operations and capability reporting;
- conversion between public operations and wire messages;
- stream and datagram classification;
- per-stream incremental decoder state;
- subscription, publication, request, and namespace state;
- protocol events and errors;
- authentication and relay-specific conventions;
- interpretation of peer FIN, reset, stop-sending, and connection close.

Initial implementation namespaces are:

- `MOQX.Protocol.CloudflareDraft14`;
- `MOQX.Protocol.MoqtailDraft14`;
- `MOQX.Protocol.MOQLite04`.

They are independent implementations. Provider differences must not accumulate
as conditionals in one global draft-14 state machine.

### Versioned wire packages

`MOQX.Protocol.MOQTDraft14` is the reusable standard draft-14 wire package. It
may contain:

- semantic standard message structs;
- payload encoders and decoders;
- control-stream framing;
- object-stream framing;
- object datagram encoding and decoding;
- standard numeric registries and error-code mappings.

Cloudflare and Moqtail implementations compose this package where their wire
behavior matches the draft. Provider extensions stay in the provider
implementation unless they are standardized and reusable.

MOQ Lite draft-04 owns its own messages and codecs under
`MOQX.Protocol.MOQLite04` because it does not use the draft-14 operating model.

`MOQX.Codec` remains restricted to binary primitives or contracts that are
independent of all MOQT-family versions and deployments.

### Transport requirements

Each implementation returns an `MOQX.Protocol.TransportSpec` describing its
ALPN, connection options, and required transport capabilities. The connection
driver translates that value into `MOQX.Transport` calls.

`MOQX.Transport` remains unaware of protocol identifiers and does not enforce
protocol stream rules.

### State and process model

Protocol state is explicit implementation-owned data. Input handling is
modeled as deterministic transitions so codecs and lifecycle rules can be
tested without real processes or QUIC.

Runtime process topology is owned above the protocol implementation. The
initial connection driver may serialize connection-level transitions. Later
stream workers or delivery processes may be introduced for throughput, but
they must preserve stream identity and feed normalized events through the same
implementation boundary.

Bytes from independent QUIC streams are never combined before protocol
decoding.

### Configuration

Endpoint, protocol implementation, transport backend, credentials, and
implementation options are explicit inputs. Mutable `Application` environment
is not used as protocol selection, a lifecycle seam, or test configuration.

## Initial scaffold

The architectural scaffold introduces:

- `MOQX.Protocol`;
- `MOQX.Protocol.TransportSpec`;
- `MOQX.Protocol.Capabilities`;
- `MOQX.Protocol.Transition`;
- `MOQX.Protocol.Resolver`;
- `MOQX.TrackRef` and protocol-neutral operation structs;
- implementation and wire-package namespace anchors;
- `MOQX.Runtime.ConnectionDriver` as the documented ownership boundary.

The namespace anchors are not runnable protocol implementations. The first
vertical slice will make `MOQX.Protocol.CloudflareDraft14` executable through
the public subscriber path.

## Consequences

Positive:

- Applications get one explicit connection API without coupling to provider
  wire structs.
- Cloudflare and Moqtail can reuse draft-14 encoding without sharing lifecycle
  state or provider conditionals.
- MOQ Lite can keep its different stream model.
- Protocol implementations can be tested as deterministic state transitions.
- Custom implementations can integrate through the same runtime contract.
- Transport backends remain reusable and protocol-neutral.

Tradeoffs:

- A connection driver and operation/event translation layer are required.
- Some concepts will exist twice intentionally: public application intent and
  provider/version-specific wire messages.
- Shared wire packages need disciplined boundaries to avoid provider policy
  leaking into nominally standard modules.
- Existing `MOQX.MOQLite04` code must be migrated rather than treated as the
  permanent public architecture.

## Rejected alternatives

### Duplicate the entire draft-14 stack per provider

This would isolate implementations but duplicate standard structs, codecs, and
framing, making draft corrections and interoperability fixes diverge.

### One draft-14 Session with provider flags

This would centralize codecs but mix supported subsets, authentication,
catalog behavior, extensions, and lifecycle branches into one state machine.

### Infer protocol from the endpoint

This makes behavior depend on hostname knowledge, prevents custom deployments,
and turns configuration errors into surprising negotiation or fallback paths.

### Expose only protocol-specific public clients

This makes applications select both a module-specific API and an endpoint and
prevents a stable library-level connection and subscription surface.

### Normalize all wire messages into one universal message model

Wire messages have version-specific fields and lifecycle meaning. Only
application operations and events should be normalized; wire models remain
version/provider-owned.

## References

- `CONTEXT.md`
- `docs/adr/0006-protocol-variants-own-session-state-codec-stays-generic.md`
- `docs/adr/0007-protocol-sessions-are-pure-reducers.md`
- `MOQX.Transport`
