# Improve MOQX-client DATAGRAM paced-send throughput

Status: ready-for-agent
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
