# Rerun mixed pressure after event pump

Status: closed
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

- [x] A disposable same-region ARM path is provisioned, baselined with iperf3,
      and destroyed after capture.
- [x] Mixed MOQT-shaped records are captured for
      reference-client-to-reference-server, MOQX-client-to-reference-server,
      and reference-client-to-MOQX-listener using the established mixed smoke
      shape.
- [x] MOQX-client mixed diagnostics record object/control send completions,
      pending completions, event-drain counts, final mailbox depth, and peak
      observed mailbox depth.
- [x] #26 records whether the prior `message_queue_len=32234` artifact is gone
      remotely, still present, or replaced by a new pressure symptom.
- [x] Result artifacts, run id, path metadata, and teardown status are recorded
      in #26.

## Blocked by

None - can start immediately.

## Notes

This is a validation slice. Do not optimize mixed workload behavior here unless
the run exposes a small correctness bug needed to produce valid records.

## Result

- 2026-05-28: Closed by run `20260528T101939Z-issue-35-mixed`. Hetzner
  same-region ARM capacity was unavailable in `hel1` for `cax11` and in `nbg1`
  for `cax11`, `cax31`, and `cax41`; the successful disposable path used two
  `cax11` nodes in `fsn1` over private network `10.88.0.11 -> 10.88.0.12`.
  The client reported the known Hetzner/cloud-init `network-config-v1` status
  error, but Go, Elixir, iperf3, private routing, and benchmark release smoke
  checks passed. Manual private ICMP had 0% loss and a one-second TCP sanity
  sample reported about 8.81 Gbps.
- Canonical `iperf3-baseline` on the private path reported 8.74 Gbps TCP
  goodput. UDP at 1200-byte datagrams was lossy at the aggressive offered
  rates: 1 Gbps offered delivered 92.23%, 3 Gbps delivered 76.45%, and 6 Gbps
  delivered 75.83%.
- The established mixed MOQT-shaped workload was rerun with 32 object-like
  streams, 1000 x 1200-byte payloads per object stream, and 100 x 64-byte
  control messages at 20 messages/sec. All three records passed validation
  with no break symptom: reference-client-to-reference-server reached
  62.05 Mbps, MOQX-client-to-reference-server reached 62.02 Mbps, and
  reference-client-to-MOQX-listener reached 52.23 Mbps.
- The old `message_queue_len=32234` artifact is gone remotely. The
  MOQX-client mixed diagnostics recorded final `message_queue_len=1`,
  `message_queue_len_peak=528`, 458 process samples, 32,000 object send
  completions, 100 control send completions, zero pending object/control
  completions, and 32,337 drained events.
- Result artifacts are under
  `bench/transport/results/20260528T101939Z-issue-35-mixed/`. Infrastructure
  was destroyed and `just bench-transport-verify-clean` reported no Terraform
  state entries or labelled Hetzner resources remaining.
