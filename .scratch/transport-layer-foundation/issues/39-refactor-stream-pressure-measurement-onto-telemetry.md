# Refactor stream-pressure measurement onto telemetry collector

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/38-design-telemetry-backed-benchmark-measurement.md`

## What to build

Implement the first low-impact slice of the telemetry-backed measurement design:
move MOQX-client stream-pressure measurement from ad-hoc inline diagnostics to
`:telemetry` events plus a benchmark-owned collector, while preserving workload
behavior and the existing `transport-bench-v1` output contract.

This is not a dashboard, remote collector, run-bundle redesign, or daemon
issue. It is the first refactor that proves the measurement plumbing can change
without changing what the benchmark measures.

## Acceptance criteria

- [ ] Root `moqx` adds only the dependency needed to emit stable telemetry
      events from `MOQX.Transport`.
- [ ] `bench/transport` owns the `telemetry_metrics` dependency and defines
      benchmark metric declarations separately from transport-library code.
- [ ] `MOQX.Transport` emits the minimal stable events required for
      MOQX-client stream pressure, starting with stream send admission and
      normalized event receive timing.
- [ ] The benchmark collector attaches for a single step or run and always
      detaches in `after`.
- [ ] The collector handler does not perform file IO, JSON encoding, payload
      copies, synchronous `Agent` or GenServer calls, or per-event
      `Process.info/2`.
- [ ] MOQX-client stream-pressure records still emit valid
      `transport-bench-v1` `step_summary` records with the same key metrics and
      diagnostics currently used by reports.
- [ ] The old live `Agent`-backed stream diagnostics path is removed or no
      longer used by the MOQX-client stream-pressure hot path.
- [ ] Regression tests prove the collector can reconstruct accepted sends,
      completed sends, event counts, send/receive timing summaries, and bytes
      sent/received from emitted events.
- [ ] Local calibration confirms the refactor does not regress strict JSONL
      validity or obvious loopback throughput versus the post-#37 path.
- [ ] The implementation preserves explicit dependency seams and does not
      introduce `Application` environment as mutable configuration.

## Blocked by

None. #38 records the accepted measurement design.

## Notes

Keep this slice deliberately narrow. It should make the current stream-pressure
measurement path more principled without adding sidecar artifacts, Prometheus,
remote publishing, or daemon control.

If this slice needs a sampler for mailbox or runtime pressure, use a step-owned
sampler process that polls known role pids at a fixed interval. Do not sample
process state inside every telemetry handler.

## Comments

- 2026-05-28: Opened from the #38 design discussion. The goal is to prove the
  telemetry/`telemetry_metrics`/custom-collector split on the MOQX-client
  stream-pressure path first, then migrate DATAGRAM and mixed pressure only
  after the first slice is validated.
