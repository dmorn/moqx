# Add DATAGRAM drain-cadence diagnostics

Status: ready-for-agent
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

- [ ] MOQX-client DATAGRAM records expose active send duration, active receive
      duration, total observation duration, and receive-loop stop reason.
- [ ] MOQX-client DATAGRAM diagnostics expose datagram event counts, duplicate
      and invalid counts, receive errors, ignored events, and bounded mailbox
      samples across the run.
- [ ] Diagnostics include enough cadence information to compare expected
      arrival rate with actual drain progress over time, not only final counts.
- [ ] quicer DATAGRAM send/admission errors remain distinct from peer-delivery
      loss and receive-loop loss.
- [ ] A loopback calibration or focused test proves the new diagnostics are
      emitted without changing existing JSONL consumers incompatibly.

## Blocked by

#32 - reuse the same diagnostics/reporting shape where practical.

## Notes

Preserve the async DATAGRAM admission model. Do not make `send_datagram/3`
wait for peer delivery or backend completion.

