# Define real-path transport benchmark harness contract

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Create the dedicated transport research harness contract for measuring QUIC path limits and protocol pressure points outside the normal test suite.

The purpose is to learn how hard a real QUIC link can be pushed before it degrades or fails, and how much of a real network path `moqx` can fill under MOQT-shaped traffic. Local loopback is useful only as calibration that the harness works and to estimate local BEAM/quicer overhead; it must not be treated as evidence about real network behavior.

This issue should create the benchmark directory and README contract before implementing the individual benchmark tools. The contract must define what later benchmark tools measure, how they describe the path under test, and how results can be compared across runs.

## Acceptance criteria

- [x] A `bench/transport/` directory exists for transport research.
- [x] `bench/transport/README.md` states that benchmark work is not part of normal tests or integration tests.
- [x] The README defines the core question: path saturation, degradation, and failure behavior for QUIC streams/datagrams under real network conditions.
- [x] The README distinguishes evidence tiers: local loopback calibration, same-region server pair, cross-region server pair, asymmetric edge/home-to-server path, and public relay interop probes.
- [x] The README states that public relays are for interop/smoke probing only, not controlled benchmark baselines.
- [x] The README defines the required run metadata schema: run id, timestamp, git SHA, host identifiers, regions/providers, instance/network class, OS/kernel, CPU/memory, quicer/msquic versions where available, protocol profile, ALPN, congestion-control settings, pacing/settings, certificate mode, and command parameters.
- [x] The README defines the result schema and units for handshake latency, first-byte latency, offered load, goodput, packet/datagram send rate, delivered datagram rate, loss/drop/late counts, stream count, payload size, p50/p95/p99 latency, CPU, memory, mailbox depth, send backpressure/stall time, and close/error reason.
- [x] The README defines "breaks apart" symptoms: connection close/protocol error, send failure, stream stall, datagram delivery collapse, latency explosion, throughput plateau despite higher offered load, mailbox growth without recovery, CPU/memory saturation, and control traffic delayed behind media/object traffic.
- [x] The README explains the benchmark matrix: `iperf3` TCP/UDP path baseline, MOQX quicer self-pair calibration, MOQX client to remote reference server, remote reference client to MOQX listener, reference-to-reference measurement, datagram pressure, stream pressure, and mixed MOQT-shaped control-plus-object load.
- [x] The README explains how tools select protocol-like transport profiles, including draft-14-like ALPN/datagram settings and MOQ Lite-like no-datagram/many-stream settings.
- [x] The README defines ramp methodology: fixed-duration warmup, stepped offered load, steady-state sample window, cooldown, and stop conditions.
- [x] The README requires benchmark tools to produce machine-readable JSON or JSONL with the shared metadata/result schema.
- [x] Tool conventions keep benchmark code in the standalone `bench/transport`
      Mix project, with root `moqx` consumed as a path dependency.
- [x] No benchmark-only dependencies are added to the library dependency graph.

## Blocked by

None - can start immediately

## Design decisions

- Real server paths are the primary evidence for performance and limit claims.
- Loopback and same-host self-pair runs are calibration, not proof that a network path can be filled.
- `iperf3` establishes the host/path ceiling; it is not a QUIC or MOQT benchmark.
- Benchmark tools should support caller-provided endpoints so the same harness can run on same-region, cross-region, and edge-to-server paths.
- The first harness contract should specify measurement and output shape before adding pressure tools.
- MOQT-shaped pressure should be represented as transport-level patterns for now: control trickle plus object streams/datagrams, not full MOQT session semantics.
- Results should be comparable across runs, but #08 does not set pass/fail thresholds.

## Resolution

Implemented by `bench/transport/README.md`.

The contract defines evidence tiers, path metadata, benchmark families, protocol-like profiles, ramp methodology, stop conditions, "breaks apart" symptoms, JSON/JSONL output records, required metadata/result fields, units, tool conventions, result storage, and the intended follow-up issue order.

Validation:

- `git diff --check`

## Comments

- 2026-05-19: Contract amended by issue 22 to allow explicit, short-lived,
  caller-operated benchmark infrastructure under `bench/transport/infra/`.
  Benchmark tools still must accept endpoints and must not start cloud
  infrastructure implicitly.
- 2026-05-19: Script convention clarified after the first iperf3 script:
  `Mix.install/1` is optional and should be used only for explicit script-local
  dependencies. Plain stdlib-only `.exs` scripts are valid benchmark scripts.
- 2026-05-20: Superseded the standalone `.exs` convention with a standalone
  `bench/transport` Mix project. Benchmark commands now live under the
  `mix moqx.transport.*` namespace, and contract/report tests live with the
  benchmark project.
- 2026-05-20: Added a runtime CLI surface, `moqx-transport-bench`, plus release
  packaging basics. Local Mix tasks are now wrappers over the runtime command
  modules; remote nodes should run the release wrapper instead of Mix tasks.
- 2026-05-20: Kept the old `bench/transport/scripts/*.exs` entrypoints as
  compatibility delegates into the nested Mix project.
- 2026-05-20: Added follow-up issue 23 for Docker-built release artifacts and
  explicit SSH deploy/smoke tooling. The benchmark contract still keeps
  provisioning and benchmark execution separate.
