# Harden iperf3 baseline timeout and failure handling

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Make `moqx-transport-bench iperf3-baseline` resilient when the caller provides
an unreachable endpoint or a path that silently drops TCP/UDP traffic.

The command currently shells out to `iperf3` without a caller-visible timeout.
During the Hetzner smoke run `20260520T134420Z-smoke`, a private-path attempt
to `10.88.0.12:55201` hung until manually interrupted because the server's
private interface was down.

## Acceptance criteria

- [x] Each `iperf3` step has a configurable timeout greater than its requested
      duration.
- [x] A timed-out `iperf3` process is terminated and does not leave child
      processes running.
- [x] Timeout/failure is emitted as a valid `transport-bench-v1` JSONL record
      with clear `limits` and `errors` fields.
- [x] The report command renders timed-out steps clearly.
- [x] Tests cover a fake or controlled `iperf3` command that exceeds the
      timeout.
- [x] Documentation explains how timeout values relate to TCP/UDP step
      duration.

## Blocked by

None.

## Context

This is not a throughput feature. It is operator safety for bad-path smoke
tests and future reference-comparison experiments.

The first implementation should stay local to the benchmark subproject. Do not
add retry orchestration, Terraform coupling, or global configuration.

## Resolution

Implemented in the benchmark subproject:

- `moqx-transport-bench iperf3-baseline` now runs each `iperf3` step through a
  supervised port with a timeout instead of blocking indefinitely in
  `System.cmd/3`.
- `--timeout-margin-seconds` controls the timeout as
  `step_duration + margin`; the default margin is 5 seconds.
- Timed-out records remain valid `transport-bench-v1` JSONL and set:
  `methodology.timeout_seconds`, `limits.first_break_symptom=step_timeout`,
  `limits.stopped_by=iperf3_step_timeout`,
  `errors.close_reason=timeout`, and `errors.error_code=124`.
- Tests cover a fake slow `iperf3` command, validate the emitted timeout record,
  and verify the command process is gone after timeout handling.
- The report command already renders limit/error rows; test coverage now pins
  timed-out step rendering.

## Comments

- 2026-05-20: Created from Hetzner smoke `20260520T134420Z-smoke`. The public
  IPv4 baseline completed, but the failed private-path attempt showed that an
  unreachable path can hold the runtime CLI until the operator interrupts it.
- 2026-05-21: Prior to this timeout work, smoke `20260521T070013Z-smoke`
  confirmed the public IPv4 path and `just` operator flow are working. Commit
  `f605b99` fixed adjacent `iperf3-baseline` contract problems (`--path-json`
  inline JSON and release git SHA), but bad-path timeout handling remains the
  next operator-safety gap before private-network probing or reference QUIC
  comparison runs.
- 2026-05-21: Closed after adding per-step timeout handling, timeout JSONL
  semantics, report coverage, and README documentation. The change is local to
  the benchmark subproject and does not add Terraform coupling or retry
  orchestration.
- 2026-05-21: Validation run before handoff: root `mix test`, benchmark
  `mix test`, root `mix credo --strict`, benchmark `mix credo --strict`,
  `mix format`, `just --fmt --check`, `git diff --check`, and a real local
  `mix moqx.transport.iperf3_baseline` loopback run with
  `--timeout-margin-seconds 1` all passed.
