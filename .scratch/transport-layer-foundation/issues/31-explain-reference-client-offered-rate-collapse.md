# Explain reference-client offered-rate collapse

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Explain and, if possible, remove the offered-rate collapse seen when the
reference quicprobe client sends high-rate DATAGRAM pressure to the MOQX
listener.

The receiver-side DATAGRAM ramp is now correct and valid through 30k pps, but
the reference client stops sustaining target offered rate above that when the
peer is `moqx-transport-bench moqx-listener`. The same client can sustain
target offered rate against the quicprobe server on the same path, so this is
not just a raw sender pacing limit.

## Evidence

- Run `20260527T080234Z-receiver-dgram-ramp` used same-region ARM `cax11`
  nodes in `nbg1` over the private path `10.88.0.11 -> 10.88.0.12`.
- Raw iperf3 showed about 33.10 Gbps TCP goodput. UDP with 1192-byte datagrams
  delivered 100 Mbps at 100%, 250 Mbps at 99.626%, and 500 Mbps at 99.271%.
- Reference-client-to-reference-server sustained target offered rate through
  50k pps. Delivery fell at the high end, from 99.00% at 30k to 97.71% at
  40k and 90.13% at 50k.
- Reference-client-to-MOQX-listener produced clean offered-rate evidence
  through 30k pps: 100% delivery at 5k/10k, 99.625% at 20k, and 99.489% at
  30k.
- At 35k/40k/50k, quicprobe only offered about 87.5%/79.3%/63.3% of the target
  rate against MOQX. Those records are therefore not clean capacity
  measurements.
- Listener diagnostics still showed bounded receive/echo behavior under the
  attempted high-rate load: 104,830/105,000, 119,713/120,000, and
  149,577/150,000 datagrams received with mailbox peaks 536/800/752.

## Acceptance criteria

- [x] DATAGRAM pressure records expose active send duration separately from
      total observation duration.
- [x] quicprobe JSON exposes enough pacing information to distinguish target
      rate, actual offered rate, and send-loop lag.
- [x] MOQX listener DATAGRAM diagnostics expose echo-send attempts, successful
      echo sends, echo-send errors, and enough timing to see whether server
      echo cadence can backpressure the client.
- [x] Listener mailbox diagnostics include sampled depth over the workload, not
      only final and peak depth.
- [ ] A narrow ARM same-region bracket around 25k/30k/32k/35k/40k pps is run
      with the new diagnostics and reference-to-reference controls.
- [ ] The issue records whether the collapse is caused by sender pacing,
      quic-go peer backpressure, MOQX echo timing, BEAM/quicer scheduling, or a
      remaining measurement artifact.

## Blocked by

None.

## Comments

- 2026-05-27: Created from #26/#12 receiver-side DATAGRAM ramp evidence. The
  next implementation slice should add narrow observability before changing
  listener behavior, so the optimization target is not guessed from delivery
  ratios alone.
- 2026-05-27: Added the first observability slice. `tools/quicprobe` now emits
  active `send_duration_ms`, target/scheduled send timing, pacing late counts,
  and pacing-lag percentiles for paced DATAGRAM runs. Canonical
  `reference-comparison` records carry those values in methodology/metrics.
  `moqx-listener` DATAGRAM diagnostics now include first/last receive and echo
  timings, echo-send duration summaries, and bounded mailbox sample points
  across the workload. Focused quicprobe and benchmark tests pass. The next
  step is the narrow ARM bracket with these fields enabled.
