# ADR-0001: Transport boundary, support transport, and benchmark harness

- Status: Accepted
- Date: 2026-05-06

## Context

`moqx` is a clean-slate Elixir implementation targeting MOQT draft-14 over QUIC, backed initially by `quicer`.

The current codebase already has a narrow `MOQX.Transport` behaviour and a thin `MOQX.Transport.Quicer` adapter. This boundary is important because MOQT protocol code should be testable without a live QUIC stack and should not depend directly on `quicer` implementation details.

Relevant constraints:

- MOQT draft-14 runs over native QUIC or WebTransport and relies on streams and datagrams.
- Native QUIC MOQT uses ALPN `moq-00`.
- QUIC DATAGRAM support must be available for MOQT.
- The first stream is a client-initiated bidirectional control stream.
- Object data uses QUIC streams and/or datagrams depending on forwarding preference.
- `quicer` is an Erlang library; Erlang `string()` types are charlists, while Elixir callers expect binaries/`String.t()`.
- Performance and limits need separate research from correctness/integration tests.

## Decision

### Transport boundary

Upper protocol layers MUST depend on `MOQX.Transport`, not directly on `:quicer`.

Protocol modules MUST NOT pattern-match raw `quicer` messages such as:

```elixir
{:quic, data, stream, props}
```

Instead, protocol modules consume normalized `MOQX.Transport.event()` values.

The preferred near-term model is a helper-based approach:

```elixir
MOQX.Transport.receive_event(transport, timeout)
```

or equivalent, where raw backend messages are normalized before protocol code handles them.

This is intentionally lighter than introducing a dedicated transport-router process immediately, but keeps the protocol layer coupled to the transport abstraction rather than to `quicer`.

### Elixir-facing API

The transport API should expose Elixir-friendly types.

In particular:

- hostnames and textual listener addresses accepted by Elixir code should be binaries/`String.t()` where natural;
- the `quicer` adapter is responsible for converting to Erlang charlists when calling `:quicer`;
- binary payloads remain binaries;
- `quicer` handles remain opaque transport terms.

### Support transport

Add a deterministic in-memory transport implementation under test support, likely:

```text
test/support/transport.ex
```

with a module such as:

```elixir
MOQX.Transport.Support
```

It should implement the same `MOQX.Transport` behaviour and simulate enough QUIC-like semantics for protocol tests:

- listen/connect/accept/handshake
- bidirectional and unidirectional streams
- stream send/receive
- datagrams
- active/passive delivery
- stream and connection close/reset events
- `controlling_process/2`
- deterministic fault injection where useful

This support transport is for correctness and protocol tests, not performance measurement.

### Contract tests

Create shared transport contract tests that can run against both:

- `MOQX.Transport.Support`
- `MOQX.Transport.Quicer`

These tests establish baseline semantics for handshakes, stream lifecycle, stream data, datagrams, close events, active/passive receive, and ownership handoff.

### Performance and limits research

Transport performance and limit analysis belongs in a separate benchmark/research harness, not in the regular test suite.

Use:

```text
bench/transport/
```

Benchmark scripts should be independent Elixir scripts using `Mix.install([])` for their own dependencies.

The harness should eventually compare:

- raw host/network baseline via `iperf3` TCP/UDP;
- `MOQX.Transport.Quicer` client to `MOQX.Transport.Quicer` server;
- `MOQX.Transport` client to a reference QUIC server;
- reference QUIC client to a `MOQX.Transport` listener;
- optionally reference client to reference server.

The benchmark harness should measure raw transport characteristics, not MOQT protocol behavior initially.

## Consequences

Positive:

- MOQT protocol code remains independent of `quicer` message shapes and Erlang type quirks.
- Future protocol tests can run deterministically without real QUIC sockets.
- The real `quicer` adapter can be verified against the same contract as the support transport.
- Performance research has a clear home and will not make normal tests slow or flaky.

Tradeoffs:

- The transport boundary must define and maintain a stable event vocabulary.
- The helper-based `receive_event` approach still allows raw backend messages to enter the process mailbox internally.
- A future router/owner process may be needed if mailbox isolation or stricter encapsulation becomes necessary.
- The support transport can validate semantics but cannot predict real QUIC performance.

## Non-goals

This ADR does not decide:

- final MOQT session/control-message implementation;
- final benchmark result thresholds;
- the reference QUIC implementation to use for benchmarking;
- whether a future dedicated transport-router process should replace the helper-based event API;
- any future integration-test strategy.
