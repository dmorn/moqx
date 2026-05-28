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

- [x] Reproduce or isolate the paced-send ceiling with the smallest useful
      local or remote harness while keeping local evidence clearly labeled as
      calibration only.
- [ ] Identify whether the limiting cost is benchmark pacing/timer logic,
      `MOQX.Transport.send_datagram/3` admission cost, receive-event draining,
      telemetry collection, binary allocation, scheduler pressure, or quicer
      callback/event traffic.
- [x] Preserve the async DATAGRAM admission model; do not make
      `send_datagram/3` wait for peer delivery or backend completion.
- [x] Add only the low-overhead diagnostics needed to classify the ceiling, and
      keep the `transport-bench-v1` summary contract stable.
- [x] If an implementation change is made, rerun the real-path ARM DATAGRAM
      bracket with an iperf3 baseline and compare against the reference
      quicprobe control.
- [x] Record the result in #26, including whether MOQX-client can sustain the
      20k pps offered-rate contract and what remains to close versus the
      reference client.
- [x] Destroy disposable infrastructure and verify no provider resources remain
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
- 2026-05-28: Reran the real-path ARM DATAGRAM bracket as
  `20260528T124052Z-issue-40-dgram-paced` after committing the exact scheduler
  fix and diagnostics at `ecc557b`. The disposable path was a same-region
  Hetzner `cax11` ARM pair in `fsn1 -> fsn1` over the private network
  `10.88.0.11 -> 10.88.0.12`. iperf3 established a 6.64 Gbps TCP baseline;
  UDP with 1192-byte datagrams delivered 100 Mbps at 100%, 500 Mbps at
  99.84%, and 1 Gbps at 97.53%. The quicprobe-to-quicprobe control sustained
  target offered rate through 30k pps with no break symptom: 18k/20k/25k/30k
  sent at essentially target rate with delivery of 99.85%, 98.82%, 99.73%,
  and 97.55%. MOQX-client-to-quicprobe-server became contract-valid at 18k
  pps after the scheduler fix: offered-rate ratio 0.967, send rate 17.41k pps,
  delivery 99.87%, send-loop overrun about 102.54 ms, DATAGRAM send-call total
  about 310.82 ms, and no unmeasured send-loop overhead.
- 2026-05-28: The same run tightened the MOQX-client ceiling instead of
  clearing 20k pps. Additional 18.5k and 19k samples missed the offered-rate
  contract in this run with ratios 0.937 and 0.848. At 20k, the offered-rate
  ratio was 0.900, send-loop overrun about 334.70 ms, and DATAGRAM send-call
  total about 349.92 ms, with no unmeasured overhead. At 25k and 30k, ratios
  fell to 0.690 and 0.540; send-call totals were about 466.69 ms and
  616.54 ms, while unmeasured send-loop overhead grew to about 878.60 ms and
  1940.22 ms. Delivery remained high, final mailbox depth was 0, observed
  mailbox peaks stayed bounded, and DATAGRAM send errors stayed at 0. Current
  conclusion: exact scheduling fixed the local accounting bug and rescued 18k,
  but the real bottleneck remains the MOQX-client paced sender/event pump. At
  20k it is mostly explained by cumulative per-send call/instrumentation cost;
  beyond 20k, scheduler/event-loop pressure or another per-iteration cost also
  dominates. Infrastructure was destroyed and `just bench-transport-verify-clean`
  reported no Terraform state entries or labelled Hetzner resources.
