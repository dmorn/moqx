# Improve MOQX-client DATAGRAM paced-send throughput

Status: in-progress
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Diagnose and improve the MOQX-client DATAGRAM pressure ceiling exposed by the
remote cadence bracket after the telemetry collector migration.

Run `20260528T115506Z-issue-26-dgram-cadence` showed that the reference
quicprobe client sustained target offered rate through 30k pps on the same
Hetzner ARM private path, while MOQX-client was contract-valid through 18k pps
and then failed the offered-rate contract at 20k pps and above. The invalid
MOQX records still had high peer delivery, zero DATAGRAM send errors, final
mailbox depth 0, and bounded mailbox peaks, so the next suspect is the
MOQX-client paced sender/event-pump shape rather than receiver loss or
unbounded mailbox backlog.

## Acceptance criteria

- [ ] Reproduce or isolate the paced-send ceiling with the smallest useful
      local or remote harness while keeping local evidence clearly labeled as
      calibration only.
- [ ] Identify whether the limiting cost is benchmark pacing/timer logic,
      `MOQX.Transport.send_datagram/3` admission cost, receive-event draining,
      telemetry collection, binary allocation, scheduler pressure, or quicer
      callback/event traffic.
- [ ] Preserve the async DATAGRAM admission model; do not make
      `send_datagram/3` wait for peer delivery or backend completion.
- [ ] Add only the low-overhead diagnostics needed to classify the ceiling, and
      keep the `transport-bench-v1` summary contract stable.
- [ ] If an implementation change is made, rerun the real-path ARM DATAGRAM
      bracket with an iperf3 baseline and compare against the reference
      quicprobe control.
- [ ] Record the result in #26, including whether MOQX-client can sustain the
      20k pps offered-rate contract and what remains to close versus the
      reference client.
- [ ] Destroy disposable infrastructure and verify no provider resources remain
      after any remote run.

## Blocked by

None. #34 and #39 provide the diagnostics and telemetry collector foundation.

## Notes

The current target is offered-rate capacity, not delivery semantics. A run that
receives almost every DATAGRAM but stretches a 3-second send phase into 5
seconds is still a failed pressure measurement because it did not put the
requested load on the link.

## Progress

- 2026-05-28: Started the first local #40 slice. Added MOQX-client paced
  DATAGRAM send-schedule diagnostics without changing the root transport API:
  target send duration, exact scheduled send span, send pacing lag summary,
  late-send count, DATAGRAM send-call total/percentiles, send-loop overrun, and
  unmeasured send-loop overhead now flow into the existing
  `transport-bench-v1` metrics/diagnostics fields.
- 2026-05-28: Fixed a scheduler accounting bug while adding the diagnostics.
  Paced DATAGRAM sends now compute each send deadline from the absolute start
  time and sequence number instead of accumulating a truncated integer interval.
  This matters for rates such as 30k pps where `1_000_000 / rate` is
  fractional; the previous cumulative truncation scheduled the 1-second span at
  about 990 ms for 30k pps instead of the intended ~999.967 ms.
- 2026-05-28: Local loopback calibration against `tools/quicprobe`
  (`/tmp/moqx-issue-40-local-dgram.jsonl`) at 3k pps, 1192-byte DATAGRAMs, and
  1 second was strict-valid with no break symptom: 3000/3000 delivered,
  offered-rate ratio 0.9993, scheduled send span 999.666 ms, active send
  duration about 1000.658 ms, send DATAGRAM call total about 11.209 ms,
  send-loop overrun about 0.992 ms, and unmeasured send-loop overhead 0. This
  remains loopback calibration only. The next meaningful #40 check is a remote
  rerun around 18k/20k/25k/30k pps to see whether exact scheduling and the new
  diagnostics explain or move the real-path ceiling.
