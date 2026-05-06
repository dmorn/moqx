# Transport layer foundation and research harness

Status: needs-triage

## Problem Statement

`moqx` needs a trustworthy transport layer before higher-level MOQT draft implementations can be built on top of it. The current codebase has a narrow `MOQX.Transport` behaviour and a `quicer` adapter, but the transport contract, normalized event consumption model, support transport, and shared contract tests still need to be established.

Without this foundation, MOQT protocol code could accidentally depend on raw `quicer` messages, Erlang charlist string semantics, or live QUIC sockets in ordinary tests. That would make protocol implementations harder to test, harder to reason about, and harder to benchmark against reference QUIC implementations later.

Performance and limit analysis is also needed, but it should be treated as explicit research under a benchmark harness rather than as normal integration testing.

## Solution

Establish a transport foundation around `MOQX.Transport`:

- protocol code consumes normalized transport events, not raw `quicer` messages;
- Elixir-facing APIs hide `quicer` charlist/string details;
- a deterministic in-memory support transport provides QUIC-like semantics for future protocol tests;
- shared contract tests verify the support transport and `quicer` adapter against the same behavior;
- transport performance and limits research lives under a separate benchmark harness.

The architectural decisions are recorded in `docs/adr/0001-transport-boundary-support-transport-and-benchmark-harness.md`.

## User Stories

1. As a MOQT protocol implementer, I want to depend on a stable transport abstraction, so that protocol code is not coupled to `quicer` internals.
2. As a MOQT protocol implementer, I want to receive normalized transport events, so that protocol code can handle streams, datagrams, and close events consistently.
3. As an Elixir caller, I want to pass hostnames as Elixir strings, so that I do not need to know that Erlang `string()` means charlist.
4. As a test author, I want an in-memory support transport, so that protocol tests can run deterministically without a live QUIC socket.
5. As a test author, I want support transport semantics to resemble QUIC streams and datagrams, so that tests exercise meaningful protocol behavior.
6. As a maintainer, I want the support transport and `quicer` adapter to share contract tests, so that both implementations stay aligned.
7. As a maintainer, I want active, passive, and ownership handoff behavior covered by tests, so that process ownership boundaries are explicit.
8. As a maintainer, I want stream close and connection close behavior normalized, so that MOQT errors can later map cleanly onto transport shutdown behavior.
9. As a protocol implementer, I want deterministic failure injection in the support transport, so that timeout, close, and datagram-loss paths can be tested without flakiness.
10. As a performance researcher, I want a dedicated transport benchmark harness, so that performance work does not slow or destabilize the normal test suite.
11. As a performance researcher, I want raw `iperf3` TCP/UDP baselines, so that QUIC measurements can be compared against host/network limits.
12. As a performance researcher, I want a `MOQX.Transport.Quicer` client/server self-pair benchmark, so that wrapper and BEAM overhead can be measured directly.
13. As a performance researcher, I want reference QUIC client/server comparisons, so that client-side and listener-side behavior can be evaluated independently.
14. As a maintainer, I want benchmark scripts to be standalone Elixir scripts, so that research dependencies do not leak into the library dependency graph.
15. As a future implementer of MOQT draft-14 or MOQ Lite, I want transport semantics to be documented and tested, so that protocol-specific work starts from solid ground.

## Implementation Decisions

- `MOQX.Transport` remains the abstraction used by upper protocol layers.
- Protocol modules must not match raw `quicer` messages directly.
- The near-term event consumption model is helper-based: a transport helper receives backend messages and returns normalized transport events.
- A dedicated router/owner process is not introduced yet, but remains possible later if mailbox isolation becomes necessary.
- The `quicer` adapter owns backend-specific conversions, including Elixir binary strings to Erlang charlists where `quicer` expects Erlang strings.
- Transport handles remain opaque.
- Binary stream and datagram payloads remain binaries.
- A deterministic support transport will implement the transport behaviour for tests.
- Shared contract tests will verify handshake, stream, datagram, active/passive, close, and ownership semantics across transport implementations.
- Performance research uses standalone Elixir scripts with `Mix.install([])` under a benchmark harness.
- The benchmark harness is not part of normal unit tests and is not represented as `mix test.integration`.

## Testing Decisions

Good tests should verify externally observable transport behavior rather than implementation details. Tests should assert what a caller can do and what events/data it receives, not how a backend internally stores listeners, connections, streams, or queues.

Modules and surfaces to test:

- `MOQX.Transport` helper/event API
- `MOQX.Transport.Quicer`
- `MOQX.Transport.Support`
- shared transport contract tests that can be run against both implementations

Initial test coverage should include:

- successful client/server handshake
- local stream open and remote stream accept
- stream send/receive over passive receive
- normalized active stream data delivery
- datagram send/receive
- stream close and connection close events
- `controlling_process/2` ownership handoff
- string/charlist input normalization at the `quicer` boundary

## Out of Scope

- Full MOQT draft-14 session establishment
- Full MOQ Lite implementation
- WebTransport-over-HTTP/3 support
- Final benchmark thresholds or pass/fail criteria
- Selecting a permanent reference QUIC implementation
- Adding a `mix test.integration` task
- Replacing the helper-based event API with a dedicated router process

## Further Notes

The benchmark harness should eventually compare raw network/host baselines, self-pair `MOQX.Transport.Quicer` performance, our client against a reference QUIC server, and a reference QUIC client against our listener.

`iperf3` is a baseline tool for host/network capacity, not a QUIC benchmark. QUIC performance measurements should be interpreted relative to that baseline.

## Comments
