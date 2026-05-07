# Transport layer foundation and research harness

Status: needs-triage

## Problem Statement

`moqx` needs a trustworthy transport layer before higher-level MOQT draft implementations can be built on top of it. The current codebase has a narrow `MOQX.Transport` behaviour and a `quicer` adapter, but the transport contract, normalized event consumption model, support transport, and shared contract tests still need to be established.

New protocol research shows the transport foundation must support more than one MOQT-family profile:

- MOQT draft-14 native QUIC uses ALPN `moq-00`, requires QUIC DATAGRAM support, uses a first client-initiated bidirectional control stream, and sends object data over unidirectional streams and/or datagrams.
- MOQ Lite bare QUIC uses ALPN tokens such as `moq-lite-xx`, has no CLIENT_SETUP/SERVER_SETUP equivalent, uses many bidirectional transaction streams, uses unidirectional group streams, and does not use datagrams.

Without a protocol-neutral QUIC foundation, higher layers could accidentally bake draft-14-only assumptions into the transport layer, depend on raw `quicer` messages, inherit Erlang charlist string semantics, or require live QUIC sockets for ordinary protocol tests.

Performance and limit analysis is also needed, but it should be explicit research under a benchmark harness rather than normal integration testing.

## Solution

Establish a protocol-neutral QUIC transport foundation around `MOQX.Transport`:

- protocol code consumes normalized transport events, not raw `quicer` messages;
- Elixir-facing APIs hide `quicer` charlist/string details;
- ALPN and transport capabilities are configurable per protocol/session profile;
- streams expose direction and initiator metadata without enforcing draft-specific stream rules;
- datagrams are capability-based, because MOQT draft-14 needs them while MOQ Lite does not;
- stream FIN, RESET_STREAM, and STOP_SENDING semantics are first-class;
- a deterministic in-memory support transport provides QUIC-like semantics for future protocol tests;
- shared contract tests verify the support transport and `quicer` adapter against the same behavior;
- transport performance and limits research lives under a separate benchmark harness.

The architectural baseline is recorded in:

- `docs/adr/0001-transport-boundary-support-transport-and-benchmark-harness.md`
- `docs/adr/0002-native-quic-first-webtransport-out-of-scope.md`
- `docs/adr/0003-validated-endpoints-above-raw-transport.md`

## User Stories

1. As a MOQT protocol implementer, I want to depend on a stable transport abstraction, so that protocol code is not coupled to `quicer` internals.
2. As a MOQT protocol implementer, I want to receive normalized transport events, so that protocol code can handle streams, datagrams, and close events consistently.
3. As an Elixir caller, I want to pass hostnames as Elixir strings, so that I do not need to know that Erlang `string()` means charlist.
4. As a session implementer, I want configurable ALPN, so that MOQT draft-14 and MOQ Lite can negotiate different native QUIC protocol identifiers.
5. As a session implementer, I want transport capabilities exposed, so that a protocol can require or ignore datagrams, stream priority, or stats as appropriate.
6. As a draft-14 implementer, I want stream direction and initiator metadata, so that I can enforce the first client-initiated bidirectional control stream and reject invalid extra bidirectional streams at the protocol layer.
7. As a MOQ Lite implementer, I want many concurrent bidirectional transaction streams, so that announce, subscribe, fetch, probe, and goaway transactions can be modeled without transport changes.
8. As a data-plane implementer, I want unidirectional stream support, so that draft-14 data streams and MOQ Lite group streams can be represented cleanly.
9. As a data-plane implementer, I want per-stream ordering but no cross-stream ordering guarantee, so that protocol schedulers can correctly handle out-of-order group/subgroup arrival.
10. As a draft-14 implementer, I want datagram capability and max-size information, so that object datagrams can be used only when safe.
11. As a MOQ Lite implementer, I want datagrams to be optional, so that MOQ Lite can run without datagram-specific assumptions.
12. As a protocol implementer, I want explicit FIN, RESET_STREAM, and STOP_SENDING APIs/events, so that graceful completion, cancellation, expiry, and peer aborts are distinguishable.
13. As a protocol scheduler implementer, I want optional priority and flow-control signals, so that control streams and high-priority media can be scheduled ahead of lower-priority data.
14. As a test author, I want an in-memory support transport, so that protocol tests can run deterministically without a live QUIC socket.
15. As a test author, I want support transport semantics to resemble QUIC streams and datagrams, so that tests exercise meaningful protocol behavior.
16. As a maintainer, I want the support transport and `quicer` adapter to share contract tests, so that both implementations stay aligned.
17. As a maintainer, I want active, passive, and ownership handoff behavior covered by tests, so that process ownership boundaries are explicit.
18. As a protocol implementer, I want deterministic failure injection in the support transport, so that timeout, close, reset, and datagram-loss paths can be tested without flakiness.
19. As a performance researcher, I want a dedicated transport benchmark harness, so that performance work does not slow or destabilize the normal test suite.
20. As a performance researcher, I want raw `iperf3` TCP/UDP baselines, so that QUIC measurements can be compared against host/network limits.
21. As a performance researcher, I want a `MOQX.Transport.Quicer` client/server self-pair benchmark, so that wrapper and BEAM overhead can be measured directly.
22. As a performance researcher, I want reference QUIC client/server comparisons, so that client-side and listener-side behavior can be evaluated independently.
23. As a maintainer, I want benchmark scripts to be standalone Elixir scripts, so that research dependencies do not leak into the library dependency graph.
24. As a future implementer of MOQT draft-14 or MOQ Lite, I want transport semantics to be documented and tested, so that protocol-specific work starts from solid ground.

## Implementation Decisions

- `MOQX.Transport` remains the abstraction used by upper protocol layers.
- Protocol modules must not match raw `quicer` messages directly.
- The near-term event consumption model is helper-based: a transport helper receives backend messages and returns normalized transport events.
- A dedicated router/owner process is not introduced yet, but remains possible later if mailbox isolation becomes necessary.
- The `quicer` adapter owns backend-specific conversions, including Elixir binary strings to Erlang charlists where `quicer` expects Erlang strings.
- ALPN is not hard-coded in the transport layer; protocol/session profiles choose values such as `moq-00` or `moq-lite-xx`.
- Transport capabilities are explicit and queryable where practical, including datagram availability, max datagram payload if available, stream directions, stream priority support, and optional transport stats.
- Stream rules are protocol-specific. The transport layer supports generic bidirectional and unidirectional streams and exposes direction/initiator metadata.
- Datagrams are supported by the transport abstraction but are optional/capability-based.
- Stream finish, reset, and stop-sending behavior should be exposed as distinct operations and events.
- Transport handles remain opaque.
- Binary stream and datagram payloads remain binaries.
- A deterministic support transport will implement the transport behaviour for tests.
- Shared contract tests will verify handshake, stream, datagram, active/passive, close/reset, capabilities, and ownership semantics across transport implementations.
- Performance research uses standalone Elixir scripts with `Mix.install([])` under a benchmark harness.
- The benchmark harness is not part of normal unit tests and is not represented as `mix test.integration`.

## Testing Decisions

Good tests should verify externally observable transport behavior rather than implementation details. Tests should assert what a caller can do and what events/data it receives, not how a backend internally stores listeners, connections, streams, queues, or capabilities.

Modules and surfaces to test:

- `MOQX.Transport` helper/event API
- `MOQX.Transport.Quicer`
- `MOQX.Transport.Support`
- shared transport contract tests that can be run against both implementations

Initial test coverage should include:

- successful client/server handshake with configurable ALPN
- capability discovery for datagrams and stream support
- local stream open and remote stream accept for bidirectional and unidirectional streams
- stream direction and initiator metadata
- many concurrent bidirectional streams for MOQ Lite-style transactions
- stream send/receive over passive receive
- normalized active stream data delivery
- datagram send/receive when available
- datagram unavailable behavior when a protocol/profile does not enable datagrams
- graceful stream FIN
- stream reset with application error code
- STOP_SENDING / receive-side abort behavior where supported
- connection close with application error code/reason
- `controlling_process/2` ownership handoff
- string/charlist input normalization at the `quicer` boundary
- optional priority/flow-control/stat capability behavior

## Out of Scope

- Full MOQT draft-14 session establishment
- Full MOQ Lite implementation
- WebTransport-over-HTTP/3 support
- Final benchmark thresholds or pass/fail criteria
- Selecting a permanent reference QUIC implementation
- Adding a `mix test.integration` task
- Replacing the helper-based event API with a dedicated router process
- Implementing protocol-specific schedulers above the transport layer

## Further Notes

The support transport must not model only MOQT draft-14's single-control-stream world. It should model generic QUIC-like streams so draft-14 and MOQ Lite protocol rules can be enforced above it.

Real QUIC verification belongs in an explicit Docker Compose driven integration harness, not default tests. Integration tests should be tagged `:integration`, excluded by default, and run after the caller starts `docker compose -f docker-compose.integration.yml up -d --wait`.

The integration harness should cover both directions: `MOQX.Transport.Quicer` client to a reference QUIC server, and a reference QUIC client to a `MOQX.Transport.Quicer` listener. Static endpoint and certificate paths belong in `config/test.exs`; tests must not mutate `Application` env.

The benchmark harness should eventually compare raw network/host baselines, self-pair `MOQX.Transport.Quicer` performance, our client against a reference QUIC server, and a reference QUIC client against our listener.

`iperf3` is a baseline tool for host/network capacity, not a QUIC benchmark. QUIC performance measurements should be interpreted relative to that baseline.

## Comments
