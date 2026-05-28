# Add DATAGRAM drain-cadence diagnostics

Status: done
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Add diagnostics that explain where MOQX-client DATAGRAM pressure degrades
around the 20k-30k pps transition.

The current evidence says the final receiver mailbox is not simply growing
without bound, but it does not yet show whether the loss is caused by
receive-loop cadence, active event drain speed, quicer/MSQUIC admission or
completion behavior, scheduler/NIF pressure, or peer receive behavior.

## Acceptance criteria

- [x] MOQX-client DATAGRAM records expose active send duration, active receive
      duration, total observation duration, and receive-loop stop reason.
- [x] MOQX-client DATAGRAM diagnostics expose datagram event counts, duplicate
      and invalid counts, receive errors, ignored events, and bounded mailbox
      samples across the run.
- [x] Diagnostics include enough cadence information to compare expected
      arrival rate with actual drain progress over time, not only final counts.
- [x] quicer DATAGRAM send/admission errors remain distinct from peer-delivery
      loss and receive-loop loss.
- [x] A loopback calibration or focused test proves the new diagnostics are
      emitted without changing existing JSONL consumers incompatibly.

## Blocked by

#32 - reuse the same diagnostics/reporting shape where practical.

## Notes

Preserve the async DATAGRAM admission model. Do not make `send_datagram/3`
wait for peer delivery or backend completion.

## Comments

- 2026-05-28: Implemented the first local diagnostics slice. MOQX-client
  DATAGRAM diagnostics now expose active send duration, active receive
  duration, observation duration, receive-loop stop reason, and a bounded
  `diagnostics.cadence` trace with accepted/received totals and deltas. The
  cadence trace is optional diagnostics under existing `transport-bench-v1`
  records, not a new required top-level contract.
- 2026-05-28: Loopback calibration passed with
  `/tmp/moqx-cadence-datagram.jsonl`: `datagram_rate=100`,
  `duration_seconds=1`, 100 offered/accepted/received, 100% delivery, no break
  symptom, strict-valid `transport-bench-v1`, active send duration about
  990 ms, active receive duration about 990 ms, observation duration about
  993 ms, `receive_loop_stop_reason=expected_datagrams_received`, and
  11 cadence samples. This remains loopback calibration only, not real network
  evidence.
