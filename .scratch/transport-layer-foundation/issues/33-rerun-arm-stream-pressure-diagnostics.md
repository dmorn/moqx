# Rerun ARM stream-pressure diagnostics

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Run the same-region ARM stream-pressure bracket with the diagnostics from #32
and record the first concrete optimization target for the MOQX-client
bidirectional gap.

This is an evidence slice, not an optimization slice. It should compare
reference-client-to-reference-server and MOQX-client-to-reference-server on the
same controlled path after an iperf3 baseline, then update #26 with a clear
classification: send admission, send completion cadence, echo receive/event
drain, mailbox growth, scheduler pressure, peer behavior, or remaining
measurement artifact.

## Acceptance criteria

- [ ] A disposable same-region ARM path is provisioned, baselined with iperf3,
      and destroyed after capture.
- [ ] Reference-client-to-reference-server and MOQX-client-to-reference-server
      stream-pressure records are captured for at least 4, 8, and 16
      bidirectional streams using the same payload shape as the #29 rerun.
- [ ] New diagnostics from #32 are present in the MOQX records and sufficient
      to classify the first bottleneck hypothesis.
- [ ] Result artifacts, run id, path metadata, and teardown status are recorded
      in #26.
- [ ] If the evidence identifies a targeted code fix, a follow-up issue is
      opened with a narrow hypothesis and acceptance criteria.

## Blocked by

#32 - stream-pressure diagnostics must exist before this rerun is useful.

## Notes

Do not treat loopback results as capacity evidence. Use loopback only to verify
the diagnostic fields before spending remote nodes.

