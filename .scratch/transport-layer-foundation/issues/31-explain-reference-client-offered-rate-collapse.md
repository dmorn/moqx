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
- [x] A narrow ARM same-region bracket around 25k/30k/32k/35k/40k pps is run
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
- 2026-05-27: Ran the narrow ARM same-region bracket as
  `20260527T094212Z-issue-31-dgram` on `cax11` nodes in `nbg1`, private path
  `10.88.0.11 -> 10.88.0.12`, using build `45a53cf`. Hetzner placement was
  temporarily unavailable at first, so the run preserved partial resources and
  retried until both nodes were available. The client node reported the known
  cloud-init schema error, but manual checks showed Go/Elixir/iperf3 installed,
  private addresses/routes present, ICMP private-path loss 0%, average ping
  RTT about 1.26 ms, and a one-second private TCP probe around 7.1 Gbps.
  Canonical `iperf3-baseline` over the private path showed TCP goodput about
  7.10 Gbps; 1192-byte UDP delivered 100 Mbps at 100%, 250 Mbps at 99.98%,
  and 500 Mbps at 99.96%.
- 2026-05-27: Reference-to-reference controls stayed offered-rate valid for
  the whole bracket. Delivery ratios were 99.929% at 25k pps, 99.803% at 30k,
  99.535% at 32k, 98.302% at 35k, and 98.277% at 40k. Send pacing lag was
  small through 35k (`p99` up to about 2.54 ms) and larger but still
  offered-rate valid at 40k (`p99` about 21.4 ms, offered-rate ratio
  1.000004).
- 2026-05-27: Reference-client-to-MOQX-listener stayed offered-rate valid and
  above delivery threshold through 35k pps in this run: 99.708% at 25k,
  99.011% at 30k, 99.171% at 32k, and 99.716% at 35k. The only invalid
  offered-rate record was 40k pps: the client delivered 99.849% of its
  attempted datagrams, but only offered about 31.40k pps
  (`offered_rate_ratio=0.785`). The new quicprobe pacing fields make this
  visible directly: active send duration stretched to 3821 ms for a 3000 ms
  target, `send_pacing_lag_p50_ms` was about 474 ms, and
  `send_pacing_lag_p99_ms` was about 813 ms.
- 2026-05-27: MOQX listener diagnostics do not support listener receive loss or
  echo-send latency as the 40k offered-rate-collapse cause. At 40k, the
  listener received and echoed 119,932/120,000 datagrams with no echo errors;
  its last receive/echo timestamp was about 3829 ms, matching the stretched
  client send duration rather than the nominal 3000 ms target. Echo-send timing
  stayed tiny: mean about 0.0029 ms and max about 1.81 ms. Listener mailbox
  peak was bounded at 672. Current interpretation: the collapse is on the
  reference client pacing/backpressure side when the peer is MOQX, not a MOQX
  listener mailbox blow-up or slow echo-send loop. A further slice is needed to
  distinguish quic-go datagram-send backpressure from local Go scheduler/send
  loop delay at the 35k-40k transition.
- 2026-05-27: Added that next client-side split for future runs. quic-go
  `SendDatagram` enqueues into a bounded 32-frame DATAGRAM send queue and can
  block once that queue is full, so `tools/quicprobe` now records synchronous
  `SendDatagram` call duration percentiles, slow-call count, and the slow-call
  threshold separately from absolute-schedule pacing lag. Canonical
  `reference-comparison` metrics now carry those values. The next remote run
  can distinguish high lag from quic-go send-queue backpressure versus high lag
  with low send-call time from scheduler/timer/send-loop slippage.
