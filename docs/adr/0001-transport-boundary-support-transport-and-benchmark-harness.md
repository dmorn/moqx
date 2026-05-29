# ADR-0001: Transport boundary, support transport, and benchmark harness

- Status: Accepted
- Date: 2026-05-06

## Context

`moqx` is a clean-slate Elixir implementation targeting MOQT-family protocols over native QUIC, backed initially by `quicer`.

The current codebase already has a narrow `MOQX.Transport` behaviour and a thin `MOQX.Transport.Quicer` adapter. This boundary is important because MOQT protocol code should be testable without a live QUIC stack and should not depend directly on `quicer` implementation details.

Relevant constraints:

- MOQT draft-14 runs over native QUIC or WebTransport and relies on streams and datagrams.
- Native QUIC MOQT draft-14 uses ALPN `moq-00`.
- MOQT draft-14 requires QUIC DATAGRAM support.
- MOQT draft-14's first stream is a client-initiated bidirectional control stream, and object data uses unidirectional streams and/or datagrams depending on forwarding preference.
- MOQ Lite bare QUIC uses ALPN tokens such as `moq-lite-xx`, has no CLIENT_SETUP/SERVER_SETUP exchange, uses many bidirectional transaction streams, uses unidirectional group streams, and does not use datagrams.
- Stream rules differ by protocol; the transport layer must expose generic QUIC semantics rather than draft-specific policy.
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
- ALPN values accepted by Elixir code should be binaries/`String.t()` where natural;
- the `quicer` adapter is responsible for converting to Erlang charlists when calling `:quicer`;
- binary payloads remain binaries;
- `quicer` handles remain opaque transport terms.

### Protocol-configurable capabilities

ALPN and transport capabilities are selected by higher protocol/session layers, not hard-coded in `MOQX.Transport`.

The transport layer should support protocol-selected ALPN values such as
`moq-00` for MOQT draft-14 and `moq-lite-xx`-style values for MOQ Lite.
Repo-owned transport profile fixtures use canonical atoms such as `:draft_14`
and `:moq_lite_04` to name the draft version they model.

Connections should expose normalized capabilities where practical, including:

- negotiated ALPN;
- datagram availability;
- max datagram payload size, or `:unknown`/`:unsupported`;
- bidirectional and unidirectional stream support;
- stream priority support, or `:unsupported`;
- optional transport stats such as RTT or send-rate/congestion estimate, or `:unsupported`.

### Stream semantics

`MOQX.Transport` models generic QUIC streams. It does not enforce MOQT draft-14's single bidirectional control-stream policy or MOQ Lite's many bidirectional transaction-stream policy.

Normalized stream events should expose enough metadata for higher layers to enforce protocol rules, especially:

- stream direction: bidirectional or unidirectional;
- stream initiator: local/client/server or peer where knowable;
- per-stream ordering of bytes;
- no cross-stream ordering guarantee.

### Stream and connection shutdown semantics

Stream and connection shutdown must preserve distinctions required by MOQT-family protocols.

The transport API should distinguish:

- graceful stream FIN / send-side finish;
- RESET_STREAM with application error code/reason;
- STOP_SENDING / receive-side abort with application error code/reason;
- peer FIN;
- peer reset;
- peer stop-sending;
- connection close with application error code/reason.

A generic `close_stream/2` that discards the reason is insufficient for the protocol layer.

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

- listen/connect/accept/handshake;
- protocol-selected ALPN and capability profiles;
- bidirectional and unidirectional streams;
- stream direction and initiator metadata;
- many concurrent bidirectional streams;
- stream send/receive;
- optional datagrams;
- active/passive delivery;
- graceful stream finish, stream reset, stop-sending, and connection close events;
- `controlling_process/2`;
- deterministic fault injection where useful.

This support transport is for correctness and protocol tests, not performance measurement. It must not model only MOQT draft-14's single-control-stream world; draft-specific stream policies belong above transport.

2026-05-20 amendment: the production `MOQX.Transport` facade must not know or
name `MOQX.Transport.Support`. Backend-specific setup belongs either inside the
backend implementation or in caller-provided backend defaults passed to
`MOQX.Transport.new(backend, opts)`. The facade may merge those defaults into
backend `listen/2` and `connect/4` calls, but test-only support state such as an
in-memory network process is created by test fixtures, not by production
transport code.

### Contract tests

Create shared transport contract tests that can run against both:

- `MOQX.Transport.Support`
- `MOQX.Transport.Quicer`

These tests establish baseline semantics for handshakes, ALPN/capability negotiation, stream lifecycle, stream direction/initiator metadata, stream data, optional datagrams, FIN/reset/stop-sending, connection close, active/passive receive, and ownership handoff.

2026-05-20 amendment: transport DATAGRAM sends schedule unreliable delivery and
return once the backend accepts the send request. Backend send-state completion,
loss, or cancellation is an asynchronous transport event, not something
`send_datagram/3` waits for. This keeps DATAGRAM pressure from being serialized
by per-datagram send-state waits and matches the rest of the native QUIC async
transport operations.

2026-05-21 amendment: stream sends follow the same admission model.
`send_stream/4` returns an accepted send token and does not wait for backend
send completion. Backend send completion or cancellation is surfaced later as a
stream event with the accepted send token. `send_stream/4` accepts `finish:
true` to attach QUIC FIN to the final payload; standalone `finish_sending/2`
remains the FIN-only form and is ordered after previously accepted sends on the
same stream owner path. Neither form is peer-delivery proof.

### Performance and limits research

Transport performance and limit analysis belongs in a separate benchmark/research harness, not in the regular test suite. The harness is for discovering real QUIC path limits and protocol pressure points: how hard a link can be pushed before it degrades or fails, and how much of the path `moqx` can fill under stream, datagram, and mixed MOQT-shaped load.

Use:

```text
bench/infra/
bench/ledger/
bench/quicprobe/
bench/moqxprobe/
bench/probed/
```

Benchmark artifact specs should live in a slim `bench/ledger` Mix project
with no dependency on `moqx`, quicer, HTTP servers, or infrastructure tooling.
Benchmark execution tooling should live in a standalone `bench/moqxprobe`
Mix project with root `moqx` consumed as a path dependency. The canonical
operator surface is the `moqxprobe` runtime CLI; legacy `.exs` paths
may remain as compatibility delegates. Tools should accept caller-provided
endpoints so the same harness can run against same-region server pairs,
cross-region server pairs, and asymmetric edge-to-server paths.

Infrastructure provisioning belongs in `bench/infra/` rather than inside the
CLI project. Reference tools live under `bench/quicprobe/`. A future remote
control-plane daemon belongs in `bench/probed/` so orchestration and API
concerns stay separate from the benchmark CLI.

The harness should eventually compare:

- raw host/network baseline via `iperf3` TCP/UDP on the exact path under test;
- `MOQX.Transport.Quicer` client to `MOQX.Transport.Quicer` server as local/self-pair calibration;
- `MOQX.Transport` client to a remote reference QUIC server;
- remote reference QUIC client to a `MOQX.Transport` listener;
- reference client to reference server across the same path;
- datagram pressure, stream pressure, and mixed control-plus-object traffic patterns.

The benchmark harness should measure raw transport characteristics and
MOQT-shaped pressure patterns, not full MOQT protocol behavior initially.
Scripts may still use protocol transport profiles, such as `:draft_14`
ALPN/datagram settings and `:moq_lite_04` no-datagram/many-bidirectional-stream
settings.

Local loopback and same-host self-pair runs are calibration only. They are useful for proving the harness works and estimating local BEAM/quicer overhead, but they are not evidence about real network saturation. Public relays can be used for interop and smoke probes, but not as controlled benchmark baselines because relay load, namespace behavior, and network path are outside the harness' control.

Each benchmark run should emit machine-readable results with enough metadata to compare runs: run id, timestamp, git SHA, host identifiers, region/provider, instance/network class, OS/kernel, CPU/memory, quicer/msquic versions where available, protocol profile, ALPN, congestion-control/pacing/settings, command parameters, offered load, goodput, latency percentiles, datagram delivery/loss/late counts, stream count, payload size, CPU, memory, mailbox depth, backpressure/stall time, and close/error reason.

2026-05-19 amendment: the harness may include short-lived, caller-operated
cloud infrastructure under `bench/infra/` for controlled server-pair
benchmarks. This does not change the script contract: benchmark scripts accept
endpoints and must not start or destroy infrastructure implicitly. The first
such setup targets Hetzner Cloud with profile-based Terraform variants, minimal
cloud-init, and strict benchmark firewalls.

2026-05-20 amendment: remote benchmark nodes should receive a target-specific
`moqxprobe` release artifact built with Docker for the target
OS/architecture. Deployment tooling may copy and smoke-test that release over
SSH, but must receive explicit targets and must not call Terraform or start
benchmark traffic implicitly.

## Consequences

Positive:

- MOQT-family protocol code remains independent of `quicer` message shapes and Erlang type quirks.
- The same transport foundation can support both MOQT draft-14 and MOQ Lite requirements.
- Future protocol tests can run deterministically without real QUIC sockets.
- The real `quicer` adapter can be verified against the same contract as the support transport.
- Performance research has a clear home and can explore real path behavior without making normal tests slow or flaky.

Tradeoffs:

- The transport boundary must define and maintain a stable event vocabulary.
- The helper-based `receive_event` approach still allows raw backend messages to enter the process mailbox internally.
- A future router/owner process may be needed if mailbox isolation or stricter encapsulation becomes necessary.
- The support transport can validate semantics but cannot predict real QUIC performance.
- Capability discovery introduces an API surface that must gracefully represent unsupported backend features.
- Real-path benchmarks require externally managed hosts or networks; results depend on path conditions and must record enough metadata to be interpretable.

## Non-goals

This ADR does not decide:

- final MOQT draft-14 session/control-message implementation;
- final MOQ Lite session/message implementation;
- final benchmark result thresholds;
- production deployment automation or long-lived benchmark environments;
- public relay performance baselines;
- the reference QUIC implementation to use for benchmarking;
- whether a future dedicated transport-router process should replace the helper-based event API;
- any future integration-test strategy.
