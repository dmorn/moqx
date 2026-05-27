# Rerun mixed pressure after event pump

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Rerun the mixed MOQT-shaped workload on a controlled ARM path after the
MOQX-client event-pump fix and verify that the old mailbox artifact is gone in
real-path conditions.

The previous same-region mixed smoke completed correctly, but the MOQX-client
record ended with `message_queue_len=32234`. Loopback calibration after the
event-pump fix shows pending completions drain cleanly; this issue proves or
falsifies that improvement on disposable remote nodes.

## Acceptance criteria

- [ ] A disposable same-region ARM path is provisioned, baselined with iperf3,
      and destroyed after capture.
- [ ] Mixed MOQT-shaped records are captured for
      reference-client-to-reference-server, MOQX-client-to-reference-server,
      and reference-client-to-MOQX-listener using the established mixed smoke
      shape.
- [ ] MOQX-client mixed diagnostics record object/control send completions,
      pending completions, event-drain counts, final mailbox depth, and peak
      observed mailbox depth.
- [ ] #26 records whether the prior `message_queue_len=32234` artifact is gone
      remotely, still present, or replaced by a new pressure symptom.
- [ ] Result artifacts, run id, path metadata, and teardown status are recorded
      in #26.

## Blocked by

None - can start immediately.

## Notes

This is a validation slice. Do not optimize mixed workload behavior here unless
the run exposes a small correctness bug needed to produce valid records.

