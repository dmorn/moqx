# Add MOQX quicer self-pair calibration benchmark

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a benchmark tool that runs a `MOQX.Transport.Quicer` client against a `MOQX.Transport.Quicer` listener using a tiny measurement protocol over QUIC streams and datagrams.

This establishes calibration data for the Elixir transport wrapper, `quicer`, and the BEAM without introducing MOQT protocol semantics. It is useful for understanding local overhead and harness behavior, but it must not be presented as evidence about real network path saturation.

## Acceptance criteria

- [x] A standalone Elixir benchmark tool can start a local listener and client using `MOQX.Transport.Quicer`.
- [x] The tool can run with protocol-like ALPN/capability profiles, at minimum draft-14-like and MOQ Lite-like modes.
- [x] The tool measures handshake latency and first-byte latency.
- [x] The tool measures stream throughput for configurable payload size and duration/count.
- [x] The tool measures datagram send/receive rate where datagrams are available.
- [x] Output follows the shared benchmark metadata/result schema defined by issue 08.
- [x] Documentation labels self-pair and loopback results as calibration only.
- [x] The tool does not require adding benchmark dependencies to the library dependency graph.

## Blocked by

None - issue 08 is closed.

## Design decisions

- Self-pair is still valuable because it estimates local BEAM/quicer overhead and validates benchmark machinery.
- Self-pair does not answer how much of a real network path `moqx` can fill.
- The benchmark should use the same output schema as real-path tools so local overhead can be compared with server-pair results.
- Prior blockers for stream lifecycle, datagrams, capability surface, and issue 08 are closed.

## Progress

Implemented by the nested benchmark Mix task
`bench/transport/lib/mix/tasks/moqx/transport/self_pair.ex`.

The task runs a `MOQX.Transport.Quicer` listener/client pair in one Mix-loaded
process, emits JSONL `step_summary` records with
`evidence_tier = "loopback_calibration"`, and uses explicit CLI options instead
of `Application` env as a benchmark seam.

Implemented steps:

- `handshake_first_byte`
- `stream_pressure`
- `datagram_pressure` for profiles where QUIC DATAGRAM is available

Supported profiles:

- `draft_14`: ALPN `moq-00`, datagrams enabled, unidirectional stream pressure by default
- `moq_lite_04`: ALPN `moq-lite-04`, datagrams disabled, bidirectional stream pressure by default

Documentation was added to `bench/transport/README.md`.

Local validation:

- `cd bench/transport`
- `mix moqx.transport.self_pair --profile draft_14 --payload-count 2 --datagram-count 2 --stream-count 1 --output /private/tmp/moqx-quicer-self-pair-smoke.jsonl`
  - Result: 3 JSONL `step_summary` records: handshake/first-byte, stream pressure, datagram pressure.
- `mix moqx.transport.self_pair --profile moq_lite_04 --payload-count 2 --stream-count 1 --output /private/tmp/moqx-quicer-self-pair-moq-lite-smoke.jsonl`
  - Result: 2 JSONL `step_summary` records: handshake/first-byte and stream pressure; datagram step skipped by profile capability.

## Comments

- 2026-05-20: Closed with a Mix-runnable quicer self-pair calibration task.
  The output is intentionally loopback-only calibration evidence; real network
  capacity claims still require controlled server-pair runs after an `iperf3`
  path baseline.
- 2026-05-20: Moved self-pair into the standalone `bench/transport` Mix
  project. The task entrypoint is now `mix moqx.transport.self_pair` from
  `bench/transport/`; JSONL output remains `transport-bench-v1`.
- 2026-05-20: Added the runtime CLI entrypoint
  `moqx-transport-bench self-pair`. The Mix task remains as a local
  development wrapper over the same command path.
