# ADR-0010: Compose versioned wire packages into explicit protocol implementations

- Status: Accepted
- Date: 2026-07-13
- Supersedes: ADR-0006 and ADR-0007

## Scope update: 2026-07-14

The multi-protocol boundaries remain accepted, but the active product scope is
Cloudflare draft-14. The legacy parallel `MOQX.MOQLite04` implementation and
empty future-protocol namespace placeholders were removed rather than carried
as unsupported public surfaces. MOQ Lite and Moqtail work are deferred; any
future implementation starts directly behind `MOQX.Protocol` and
`MOQX.Runtime.ConnectionDriver`, without a compatibility facade.

The protocol-neutral transport coverage previously using a MOQ Lite profile is
retained as the `:streams_only` test fixture. This narrows the supported
protocol set without weakening the transport abstraction or changing the
explicit protocol-selection decision.

## Scope update: 2026-07-27

The second active implementation is standard MOQT draft-16, selected as
`:draft_16` and implemented by `MOQX.Protocol.Draft16`. It coexists with
Cloudflare draft-14 rather than replacing it. Its subscriber path covers native
QUIC ALPN `moqt-16`, strict draft-16 setup and request credit, all four
protocol-neutral subscription filters, request updates, subscription
acceptance/error/completion, subgroup streams, object datagrams, extension
preservation, and stream draining through the existing typed public API.

The normative wire reference is
`draft-ietf-moq-transport-16`. Interoperability behavior is checked against
Moqtail's `draft-16` branch pinned at
`c2ff7253479c6a0d7c8282a1cad289d591ebc302` and its public
`relay.moqtail.dev` endpoint. ADR-0011 defines cross-stream delivery as
immediate arrival order with explicit subgroup boundaries and no global reorder
buffer. ADR-0012 defines typed current-Moqtail CMSF decoding, deterministic
media selection, inline initialization, and coexistence with Cloudflare's
separate-init-track catalog. Draft-16 publication remains separate incremental
work.

The pin is also executable through
`scripts/run_moqtail_draft16_integration.sh`: Docker builds the Moqtail relay
and namespace publisher at that revision, then runs the stable MOQX subscriber
API against the local native-QUIC endpoint with generated TLS.

## Context

`moqx` needs to support multiple deployed MOQT-family protocols over the
existing `MOQX.Transport` abstraction. Initial targets include:

- Cloudflare's deployed subset and lifecycle for MOQT draft-14;
- standard MOQT draft-16, including Moqtail relay interoperability;
- MOQ Lite draft-04.

There are two different axes of variation:

1. A versioned wire specification defines message layouts, framing, stream
   types, datagrams, setup parameters, and error codes.
2. A deployed protocol implementation selects a wire specification and adds
   its supported subset, lifecycle, authentication, catalog conventions,
   extensions, and relay behavior.

Cloudflare draft-14 and standard draft-16 use independent versioned wire
packages and state machines behind one public API. MOQ Lite draft-04 has a
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
- publishing typed `MOQX.Event.*` values in a stable client envelope to the
  caller-selected event recipient;
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

Implementation namespaces follow this shape:

- `MOQX.Protocol.CloudflareDraft14`;
- `MOQX.Protocol.Draft16`;
- a future MOQ Lite implementation under `MOQX.Protocol.MOQLite04`.

Cloudflare draft-14 has subscriber and publisher support. Standard draft-16
has a complete subscriber lifecycle. Both implementations follow ADR-0011's
protocol-neutral arrival-order and subgroup-boundary contract. Concrete
implementations are independent; version and deployment differences must not
accumulate as conditionals in one global state machine.

### Versioned wire packages

`MOQX.Protocol.MOQTDraft14` is the reusable standard draft-14 wire package. It
may contain:

- semantic standard message structs;
- payload encoders and decoders;
- control-stream framing;
- object-stream framing;
- object datagram encoding and decoding;
- standard numeric registries and error-code mappings.

`MOQX.Protocol.MOQTDraft16` independently owns standard draft-16 wire behavior.
Provider extensions stay in a concrete implementation unless they are
standardized and reusable.

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

## Initial implementation

The architectural scaffold introduced:

- `MOQX.Protocol`;
- `MOQX.Protocol.TransportSpec`;
- `MOQX.Protocol.Capabilities`;
- `MOQX.Protocol.Transition`;
- `MOQX.Protocol.Resolver`;
- `MOQX.TrackRef` and protocol-neutral operation structs;
- implementation and wire-package namespace anchors;
- `MOQX.Runtime.ConnectionDriver` as the documented ownership boundary.

The first runnable vertical slice makes
`MOQX.Protocol.CloudflareDraft14` executable through the public subscriber
path. The driver owns a dedicated process and normalizes already-received
backend messages through `MOQX.Transport.normalize_event/2`. Logical stream
keys in transport actions let implementations request IO without owning raw
transport handles.

The subscriber slice completes draft-14 setup, sends live catalog and media
subscriptions, incrementally decodes the observed `SubgroupIdExt` object
streams, and publishes decoded `%MOQX.Catalog{}` and typed `%MOQX.Object{}`
events. It also handles subscribe errors, unsubscribe, connection close, and
catalog-driven CMAF capture.

The completed subscriber lifecycle decodes `PUBLISH_DONE` without treating it
as immediate end-of-stream. The protocol reducer associates subgroup streams
with subscriptions and requests a driver-owned delivery timer. A typed
`MOQX.Event.SubscriptionDone` is emitted after the advertised stream count has
been processed, or with explicit timeout metadata when the delivery timer
expires. Timer scheduling remains a runtime action, not a process side effect
inside protocol code.

Public events use typed structs inside `{:moqx, client, event}`. Connections
default event ownership to the connecting process and accept an explicit
`events_to: pid` router for shared sessions. `MOQX.Testing.Transport` packages
the deterministic transport for downstream integration tests; it remains an
explicit caller-selected test dependency and is never constructed by the
production facade.

The Cloudflare publisher slice extends that same implementation with
protocol-neutral publication and track handles. Applications register content;
the concrete implementation advertises PUBLISH_NAMESPACE, handles inbound
SUBSCRIBE and UNSUBSCRIBE, assigns aliases, emits SUBSCRIBE_OK or ERROR, sends
subgroup streams, reports PUBLISH_DONE, and withdraws the namespace with
PUBLISH_NAMESPACE_DONE. Publisher-initiated PUBLISH/PUBLISH_OK remains a
separate future capability rather than a prerequisite for this demonstrated
announce-and-serve lifecycle.

Publications may opt into controlled inbound subscriptions. The Cloudflare
implementation retains pending request identity, decoded delivery semantics,
decision state, and wire response ownership; the connection driver only
executes the implementation's keyed timer actions. Applications receive typed
protocol-neutral request events and decide them through public accept/reject
operations. Automatic acceptance remains the default publication policy.

Authorization preserves the same ownership boundary. The shared draft-14 wire
package encodes the standard AUTHORIZATION TOKEN structure. The Cloudflare
implementation attaches an explicitly supplied credential to setup and
namespace publication. Secret lookup, issuance, permission, and rotation stay
outside the library. Secret values and sensitive encoded actions have redacted
inspection and are unwrapped only at the driver's transport-send boundary.

Other protocol implementations remain incremental work behind the same
boundaries.

## Consequences

Positive:

- Applications get one explicit connection API without coupling to provider
  wire structs.
- Cloudflare draft-14 and standard draft-16 coexist without sharing lifecycle
  state or version conditionals.
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
- A future MOQ Lite implementation must enter through the shared protocol and
  runtime boundaries rather than recreating a parallel public facade.

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
- `docs/adr/0012-normalize-catalog-values-without-merging-deployment-conventions.md`
- `MOQX.Transport`
