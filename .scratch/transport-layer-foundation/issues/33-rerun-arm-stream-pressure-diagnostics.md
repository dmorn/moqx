# Rerun ARM stream-pressure diagnostics

Status: closed
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

- [x] A disposable same-region ARM path is provisioned, baselined with iperf3,
      and destroyed after capture.
- [x] Reference-client-to-reference-server and MOQX-client-to-reference-server
      stream-pressure records are captured for at least 4, 8, and 16
      bidirectional streams using the same payload shape as the #29 rerun.
- [x] New diagnostics from #32 are present in the MOQX records and sufficient
      to classify the first bottleneck hypothesis.
- [x] Result artifacts, run id, path metadata, and teardown status are recorded
      in #26.
- [x] If the evidence identifies a targeted code fix, a follow-up issue is
      opened with a narrow hypothesis and acceptance criteria.

## Blocked by

#32 - stream-pressure diagnostics must exist before this rerun is useful.

## Notes

Do not treat loopback results as capacity evidence. Use loopback only to verify
the diagnostic fields before spending remote nodes.

## Comments

- 2026-05-27: Ran `20260527T131746Z-issue-33-streamdiag` on disposable
  Hetzner `cax11` ARM nodes in `nbg1 -> nbg1` over the private path
  `10.88.0.11 -> 10.88.0.12`. Private readiness passed with 0% ping loss and
  about 2.01 ms average RTT. The structured iperf3 baseline reported
  6.81 Gbps TCP, 100 Mbps UDP at 100% delivery, 500 Mbps UDP at 99.79%
  delivery, and 1 Gbps UDP at 99.25% delivery.
- 2026-05-27: Captured the #29 payload shape: bidirectional stream pressure at
  4/8/16 streams, 1200-byte payloads, and 1000 payloads per stream. The
  reference-client-to-reference-server control reached about 344.9/703.8/
  684.2 Mbps with p99 latency about 110.3/108.6/223.3 ms. The
  MOQX-client-to-reference-server topology completed all bytes with no break
  symptom, but reached only about 72.2/61.7/53.6 Mbps with p99 latency about
  530 ms/1.24 s/2.86 s.
- 2026-05-27: #32 diagnostics classify the first bottleneck hypothesis. MOQX
  accepted and completed all sends with zero cancellations and zero final
  pending completions: 4000/8000/16000 send completions at 4/8/16 streams.
  Final mailbox depth was bounded at 3/2/2, with observed peaks 107/225/413.
  Active send duration and active echo-receive duration were essentially the
  whole application duration: about 527 ms, 1.23 s, and 2.85 s. The owner
  process drained 5305/11060/23050 transport events, about 10k/8.9k/8.0k
  events/sec. This points away from missing send completion, unbounded mailbox
  backlog, or reference-server limits, and toward the MOQX-client caller/event
  pump plus per-payload async completion cadence as the immediate performance
  target.
- 2026-05-27: Artifacts are under
  `bench/transport/results/20260527T131746Z-issue-33-streamdiag/`, especially
  `iperf3-private.jsonl`, `reference-comparison-stream-private.jsonl`,
  `path_metadata_private.json`, and the rendered report files. Terraform
  destroy completed and `just bench-transport-verify-clean` confirmed no state
  entries or labelled Hetzner resources remain. Follow-up #37 opened for the
  event-pump/send-cadence optimization hypothesis.
