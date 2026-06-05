# Add stream-pressure diagnostics

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Add enough stream-pressure diagnostics to explain why the MOQX client is far
slower than the reference client under bidirectional echo pressure before
changing transport behavior.

The benchmark should make send admission, send completion, echo receive,
mailbox pressure, and active event-drain cadence visible for
`moqx-client-to-reference-server` stream-pressure runs. Listener-side
stream-pressure diagnostics should also expose the corresponding receive/echo
cadence where practical, because the current listener is known to be a
correctness peer first.

## Acceptance criteria

- [x] MOQX-client stream-pressure records expose accepted send count,
      completed send count, cancelled/error send count, pending send count, and
      per-stream completion status.
- [x] MOQX-client stream-pressure records expose active send duration, active
      echo receive duration, timeout phase if any, and event-drain counters for
      stream data, FIN, send-completion, close, and ignored events.
- [x] MOQX-client stream-pressure records expose final mailbox depth, peak
      observed mailbox depth, and bounded mailbox samples across the workload.
- [x] Listener-side stream-pressure runs expose receive, echo-send, and
      send-completion counts or explicitly document why a signal is
      unavailable for that topology.
- [x] Human reports surface the new diagnostics without changing the
      machine-readable `transport-bench-v1` contract shape incompatibly.
- [x] Focused tests or loopback calibration prove the diagnostics are emitted
      for bidirectional stream pressure and remain absent or `null` where not
      applicable.

## Blocked by

None - can start immediately.

## Notes

Keep this as observability, not optimization. The goal is to make the next
remote stream-pressure run explain where time and queued work accumulate.

## Comments

- 2026-05-27: Implemented additive stream-pressure diagnostics for
  `measure --topology moqx-client-to-reference-server` without
  changing the `transport-bench-v1` record envelope. Bidirectional
  stream-pressure records now include accepted/completed/cancelled/pending send
  counts, per-stream completion status, active send and echo-receive durations,
  timeout phase, event-drain counters, and final/peak/bounded mailbox samples.
- 2026-05-27: Added listener-side stream-pressure diagnostics for
  `moqx-transport-bench moqx-listener --workload stream_pressure
  --diagnostics-output ...`. The listener emits a
  `moqx-listener-diagnostics-v1` `stream_listener_run` record with receive
  counts, echo-send admission/completion counts, pending completions, per-stream
  status, stop reason, and process mailbox samples.
- 2026-05-27: Added report support for a compact diagnostics row and documented
  the new optional diagnostics payloads in `bench/transport/README.md`.
  Focused tests cover MOQX-client diagnostics, listener diagnostics, and report
  rendering. A loopback calibration against local `quicprobe` recorded
  `sent=4096`, `recv=4096`, `send_done=16`, `pending=0`, `events=29`, and
  mailbox `6/34`; this is local calibration only, not real network evidence.
