# Add stream-pressure diagnostics

Status: ready-for-agent
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

- [ ] MOQX-client stream-pressure records expose accepted send count,
      completed send count, cancelled/error send count, pending send count, and
      per-stream completion status.
- [ ] MOQX-client stream-pressure records expose active send duration, active
      echo receive duration, timeout phase if any, and event-drain counters for
      stream data, FIN, send-completion, close, and ignored events.
- [ ] MOQX-client stream-pressure records expose final mailbox depth, peak
      observed mailbox depth, and bounded mailbox samples across the workload.
- [ ] Listener-side stream-pressure runs expose receive, echo-send, and
      send-completion counts or explicitly document why a signal is
      unavailable for that topology.
- [ ] Human reports surface the new diagnostics without changing the
      machine-readable `transport-bench-v1` contract shape incompatibly.
- [ ] Focused tests or loopback calibration prove the diagnostics are emitted
      for bidirectional stream pressure and remain absent or `null` where not
      applicable.

## Blocked by

None - can start immediately.

## Notes

Keep this as observability, not optimization. The goal is to make the next
remote stream-pressure run explain where time and queued work accumulate.

