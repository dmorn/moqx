# Transport layer foundation and research harness

Status: needs-triage

## Problem Statement

`moqx` needs a trustworthy transport layer before higher-level MOQT draft implementations can be built on top of it. The current codebase has a narrow `MOQX.Transport` behaviour and a `quicer` adapter, but the transport contract, normalized event consumption model, support transport, and shared contract tests still need to be established.

New protocol research shows the transport foundation must support more than one MOQT-family profile:

- MOQT draft-14 native QUIC uses ALPN `moq-00`, requires QUIC DATAGRAM support, uses a first client-initiated bidirectional control stream, and sends object data over unidirectional streams and/or datagrams.
- MOQ Lite bare QUIC uses ALPN tokens such as `moq-lite-xx`, has no CLIENT_SETUP/SERVER_SETUP equivalent, uses many bidirectional transaction streams, uses unidirectional group streams, and does not use datagrams.

Without a protocol-neutral QUIC foundation, higher layers could accidentally bake draft-14-only assumptions into the transport layer, depend on raw `quicer` messages, inherit Erlang charlist string semantics, or require live QUIC sockets for ordinary protocol tests.

Performance and limit analysis is also needed, but it should be explicit real-path research under a benchmark harness rather than normal integration testing or loopback-only microbenchmarks.

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
- transport performance and limits research lives under a separate benchmark
  harness focused on explicit targets, with local/fake runs used only for
  calibration;
- controlled server paths are provided as target endpoints rather than created
  implicitly by benchmark scripts.

The architectural baseline is recorded in:

- `docs/adr/0001-transport-boundary-support-transport-and-benchmark-harness.md`
- `docs/adr/0002-native-quic-first-webtransport-out-of-scope.md`
- `docs/adr/0003-validated-endpoints-above-raw-transport.md`
- `docs/adr/0008-functional-conn-stream-ownership.md`

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
19. As a performance researcher, I want a dedicated real-path transport benchmark harness, so that performance work can explore path saturation, degradation, and failure behavior without slowing or destabilizing the normal test suite.
20. As a performance researcher, I want raw `iperf3` TCP/UDP baselines for the exact server path under test, so that QUIC measurements can be compared against host/network limits.
21. As a performance researcher, I want a `MOQX.Transport.Quicer` client/server self-pair calibration benchmark, so that wrapper and BEAM overhead can be measured without mistaking loopback behavior for network behavior.
22. As a performance researcher, I want reference QUIC client/server comparisons across real server paths, so that client-side and listener-side behavior can be evaluated independently under actual RTT, loss, buffering, and congestion-control conditions.
23. As a maintainer, I want benchmark tooling isolated in dedicated bench subprojects, so that research dependencies and release packaging do not leak into the library dependency graph.
24. As an operator, I want simple target endpoints for `iperf3` and
    `quicprobe`, so that caller-side performance work can iterate without
    rebuilding and redeploying a large benchmark stack.
25. As a future implementer of MOQT draft-14 or MOQ Lite, I want transport semantics to be documented and tested, so that protocol-specific work starts from solid ground.
26. As a high-throughput caller implementer, I want connection-scoped and
    stream-scoped transport state to be separable, so that object stream
    senders can own their own backend-credit loop without a global stream pump.
27. As a transport API user, I want one clear connection vocabulary, so that I
    do not have to distinguish ambiguous `Conn` and `Connection` modules.

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
- The clean connection vocabulary is `MOQX.Transport.Conn`; the transport API
  must not expose both `Conn` and `Connection` modules.
- Stream-scoped state belongs under the connection hierarchy as
  `MOQX.Transport.Conn.Stream`. A single stream structure represents
  bidirectional and unidirectional streams through stream metadata and side
  availability.
- `MOQX.Transport` remains functional and process-free. OTP/GenStage sender
  processes are built above transport by owning `Conn` and `Conn.Stream` state
  values explicitly.
- Stream send completion is backend/buffer credit for an accepted send token,
  not peer-delivery proof. Completion correlation should be stream-local so
  one sender process per stream is possible.
- A deterministic support transport will implement the transport behaviour for tests.
- Shared contract tests will verify handshake, stream, datagram, active/passive, close/reset, capabilities, and ownership semantics across transport implementations.
- Performance research uses a standalone `bench/moqxprobe` Mix project with
  Benchee scripts, caller-side client implementations, and explicit target
  flags for fake, local `quicprobe`, and remote `quicprobe` paths.
- Delivery-aware benchmark scripts keep timing and receiver evidence separate:
  timed Benchee functions return run receipts, and unmeasured post-run hooks
  collect target evidence through adapters.
- The benchmark harness is not part of normal unit tests and is not represented as `mix test.integration`.
- Local loopback, fake-target, and same-host runs are calibration only; real
  server paths provide the evidence for network saturation and degradation
  claims.
- Benchmark scripts must accept endpoints and must not start, destroy, or infer
  infrastructure state implicitly.
- `iperf3` is a target preflight and sidecar metadata source, not a QUIC
  benchmark job.
- `bench/quicprobe` remains the repo-owned reference QUIC peer. It can be run
  locally or kept as a persistent service on a simple VM. Its evidence HTTP API
  exposes receiver-side run records and an exclusive experiment lease.
- Parallel benchmark suites must not share one `quicprobe` target. `moqxprobe`
  must acquire the target lease before a `quicprobe` suite and match receiver
  evidence by lease token as well as run sequence.
- `quicprobe` DATAGRAM server behavior is explicit: drain mode is used for
  publish-only MOQX DATAGRAM object benchmarks, while echo mode is reserved for
  round-trip/reference-client checks.
- The historical Terraform, `probed`, release-deploy, shared ledger, and
  `transport-bench-v1` JSONL paths are legacy and should not receive new active
  benchmark work.
- The `Conn`/`Conn.Stream` ownership refactor is expected to affect stream and
  mixed benchmark results. Existing #45/#46 evidence remains valid for the old
  single-pump/global-context transport shape, but fresh stream and mixed
  baselines are required after the refactor before closing performance issues.
- As of 2026-06-12, the refactor is implemented locally with
  `Conn.Stream.Sender` as the explicit stream-local send-completion credit
  owner. The current benchmark harness still labels its stream topology as
  `context_owner`; remote performance closure requires fresh runs from a
  current artifact and, if needed, a follow-up per-stream sender topology.

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
- Full MOQ Lite implementation, now tracked separately in
  `.scratch/moq-lite-04-protocol/PRD.md`
- WebTransport-over-HTTP/3 support
- Final benchmark thresholds or pass/fail criteria
- Selecting a permanent reference QUIC implementation
- Production deployment automation or a repository-owned remote control plane
- Disposable cloud lab provisioning
- Treating public relays as controlled benchmark baselines
- Adding a `mix test.integration` task
- Replacing the helper-based event API with a dedicated router process
- Implementing protocol-specific schedulers above the transport layer

## Further Notes

The support transport must not model only MOQT draft-14's single-control-stream world. It should model generic QUIC-like streams so draft-14 and MOQ Lite protocol rules can be enforced above it.

Real QUIC verification belongs in an explicit Docker Compose driven integration harness, not default tests. Integration tests should be tagged `:integration`, excluded by default, and run after the caller starts `docker compose -f docker-compose.integration.yml up -d --wait`.

The integration harness should cover both directions: `MOQX.Transport.Quicer` client to a reference QUIC server, and a reference QUIC client to a `MOQX.Transport.Quicer` listener. Static endpoint and certificate paths belong in `config/test.exs`; tests must not mutate `Application` env.

The benchmark harness should compare raw network/host baselines, fake-transport
process-model calibration, our caller-side clients against a reference QUIC
server, and reference client/server behavior when useful across the same target
path.

`iperf3` is a baseline tool for host/network capacity, not a QUIC benchmark. QUIC performance measurements should be interpreted relative to that baseline.

The primary benchmark question is how far a real QUIC link can be pushed before it degrades or fails, and how much of a real network path `moqx` can fill under stream, datagram, and mixed MOQT-shaped load. "Breaks apart" means observable symptoms such as connection close, protocol error, stream stall, datagram delivery collapse, latency explosion, throughput plateau despite higher offered load, mailbox growth without recovery, CPU or memory saturation, or control traffic delayed behind media/object traffic.

## Comments
