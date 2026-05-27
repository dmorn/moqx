# Harden transport pressure abstractions

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Turn the transport pressure harness into a useful performance-hardening loop
before moving on to higher-level MOQT protocol work.

The transport is semantically ready for protocol implementation, but the
current real-path evidence shows that MOQX is still far enough from the
reference peer that protocol work would risk hiding transport bottlenecks under
session logic. This issue should make pressure, backpressure, mailbox growth,
send-completion cadence, and listener/client limits visible enough to close the
gap deliberately.

## Observations

- `moqx-transport-bench moqx-listener` is a correctness peer, not yet a
  serious performance peer. It accepts all expected streams, then serves them
  sequentially by stream id, which can create benchmark artifacts under heavier
  bidirectional stream pressure.
- `MOQX.Transport` currently normalizes all backend events through the caller
  mailbox. For high-rate datagrams, mailbox growth and drain speed can become
  the benchmark result unless it is measured or separated deliberately.
- Stream sends now expose accepted-send tokens and completion events, but
  datagram sends only expose local admission. Datagram pressure must keep
  offered, locally accepted, and peer-delivered counts distinct.
- `reference-comparison` now has explicit stream, DATAGRAM, and mixed workload
  modes. The next risk is not workload shape; it is whether those workloads
  expose enough runtime pressure signals to guide optimization.
- The self-pair datagram pressure step is burst-only: it sends all datagrams as
  fast as possible, then drains received events. Real-link datagram pressure
  needs both burst and rate-stepped modes.
- Mixed MOQT-shaped pressure exposed a concrete MOQX-client artifact:
  run `20260526T135920Z-mixed-smoke` completed correctly but recorded
  `message_queue_len=32234`. That is almost certainly mostly undrained async
  object-stream send-completion traffic, because the mixed workload scheduled
  32,000 object payload sends and then used a passive control-stream loop.
  Mixed pressure must drain or explicitly bound those events before its
  goodput/control-latency numbers can be used for optimization claims.

## Acceptance criteria

- [x] Benchmark docs distinguish correctness peers from performance peers and
      call out known listener serialization limits.
- [x] Datagram benchmark records distinguish offered datagrams, locally
      accepted sends, and peer-delivered datagrams.
- [x] High-rate datagram runs can record or bound receiver mailbox pressure in
      all MOQX receiver topologies.
- [x] `moqx-listener` DATAGRAM runs record receiver mailbox pressure and bound
      lossy-step idle waits.
- [x] Mixed MOQX-client pressure drains object-stream send completions instead
      of leaving completion events in the caller mailbox.
- [x] Mixed pressure records sender mailbox depth, peak mailbox depth,
      send-completion counts, pending send-completion counts, and event-drain
      counts.
- [x] Reference-comparison datagram support is modeled as an explicit workload
      mode, not hidden inside stream-pressure fields.
- [x] Self-pair and reference-comparison datagram workloads support both burst
      and rate-stepped modes, or document why one mode is intentionally absent.
- [ ] Any transport API refactor preserves explicit dependency seams and does
      not introduce `Application` environment as mutable configuration.

## Blocked by

None. Start with #32.

## Roadmap

Use this issue as the performance-hardening umbrella. Implement the focused
child issues in evidence order:

1. #32 adds stream-pressure diagnostics to explain the MOQX-client
   bidirectional gap without guessing.
2. #33 reruns the ARM stream-pressure bracket with those diagnostics and
   classifies the first optimization target.
3. #34 adds DATAGRAM receive/drain cadence diagnostics around the 20k-30k pps
   MOQX-client transition.
4. #35 reruns mixed MOQT-shaped pressure on real ARM nodes after the event-pump
   fix to confirm the mailbox artifact is gone off loopback.
5. #36 is a human design decision: keep `moqx-listener` as a correctness peer
   or build a dedicated performance-serving model.

The first implementation slice is #32. Do not start broad transport API
refactors from this umbrella issue; any API change should be motivated by
evidence from the focused child issues and must preserve explicit dependency
seams without `Application` env.

## Comments

- 2026-05-21: Created from observations after landing
  `reference-client-to-moqx-listener` in #12. The immediate next #12 slice can
  proceed with datagram pressure, but should keep these measurement boundaries
  explicit.
- 2026-05-21: The #12 datagram-pressure slice addressed the explicit
  workload-mode and offered/accepted/delivered-count boundaries for
  reference-comparison, and the README now calls out the current listener as a
  correctness peer. Remaining work is about high-rate observability,
  rate-stepped datagram pressure, and any transport API refactor suggested by
  real benchmark evidence.
- 2026-05-22: The ARM near-MTU run `20260522T133552Z-mtu-dgram` showed that
  strict delivery-threshold failures can make `methodology.step_seconds`,
  `goodput_bps`, and `delivered_datagrams_per_second` harder to interpret:
  failed paced steps offered traffic for 10 seconds, then included the longer
  timeout/drain window in the recorded step duration. Delivery ratio, drop
  count, offered rate ratio, and latency percentiles remain the primary
  capacity signals for those records. A follow-up should decide whether paced
  records need separate active-send duration and total-observation duration
  fields.
- 2026-05-22: The ARM stream-pressure run `20260522T141346Z-strm` added
  listener-side pressure evidence: reference-client-to-MOQX-listener stayed
  contract-valid, but bidirectional goodput plateaued around 185 Mbps from 16
  to 64 streams while p99 latency grew from about 787 ms to 3.27 s. The same
  path's reference-to-reference baseline reached 769 Mbps at 16 bidirectional
  streams, 843 Mbps at 64 bidirectional streams, and 1.36 Gbps with 64
  unidirectional streams. This reinforces that the current `moqx-listener`
  command is a correctness peer first and needs explicit observability or a
  different serving model before it can support listener-side capacity claims.
- 2026-05-26: The #29 remote rerun
  `20260526T075945Z-issue-29-bidi` showed the same kind of boundary on the
  MOQX-client side after the correctness bug was fixed. On a same-region
  `cax21` ARM private path with a 6.85 Gbps TCP iperf3 baseline, the
  reference-client-to-reference-server control reached about 541/844/932 Mbps
  at 4/8/16 bidirectional streams with p99 latency about 70/91/164 ms. The
  MOQX-client-to-reference-server topology delivered all bytes with no break
  symptom, but only about 78.6/69.7/60.8 Mbps and p99 latency about
  487 ms/1.10 s/2.52 s. The benchmark now separates correctness from
  performance, but these numbers need observability before optimization:
  scheduler pressure, mailbox depth over time, send-completion cadence, active
  event drain rate, and per-stream window occupancy are the likely first
  signals to add.
- 2026-05-26: The same run exposed two DATAGRAM pressure hardening needs. First,
  `moqx-listener` waits for the exact expected datagram count; once a lossy
  step misses even one datagram, the listener can keep the UDP port occupied
  until timeout and contaminate the next step. Future ramps should either use
  isolated ports/processes per step, a delivery-threshold-aware listener exit,
  or an explicit peer-control handshake. Second, high-rate DATAGRAM records
  still do not explain where drops occur: sender admission, active event drain,
  receiver mailbox, echo-send failure, or peer receive. Add per-step
  observability before using these records for optimization claims.
- 2026-05-26: The run also found a concrete max-payload bug split to #30:
  MOQX/quicer DATAGRAM sends accept 1192-byte payloads but return
  `{:dgram_send_error, :invalid_parameter}` at 1193 bytes and above. The
  benchmark currently reports this through a `MatchError` and loses the
  configured payload size in failure records. That is a correctness/reporting
  bug, separate from throughput optimization.
- 2026-05-26: Re-scoped as the next transport focus before protocol work. The
  first implementation slice should address the mixed-workload mailbox artifact
  by replacing the MOQX-client mixed path with a mailbox-driven event pump:
  bounded object send windows, active control-stream reads, send-completion
  draining, and diagnostics that make pending completions and mailbox depth
  visible.
- 2026-05-26: Implemented the mixed MOQX-client event pump slice. A loopback
  quicprobe smoke run (`mixed-event-pump-loopback`) completed with no break
  symptom, object send completions `80/80`, control send completions `5/5`,
  pending completions `0`, final sender `message_queue_len=0`, and peak
  observed sender `message_queue_len=74`. The result is loopback calibration
  evidence only, but it confirms the previous `message_queue_len=32234`
  artifact is no longer caused by undrained async send-completion traffic in
  the mixed harness path.
- 2026-05-26: Added listener-side DATAGRAM diagnostics for
  `moqx-transport-bench moqx-listener --workload datagram_pressure`.
  The listener can now append `moqx-listener-diagnostics-v1` JSONL with
  expected/received/unique/missing datagram counts, echo counts, duplicate and
  invalid counts, stop reason, idle/observation bounds, and receiver
  `message_queue_len`/peak/sample counts. DATAGRAM receive loops also stop
  after a bounded post-first-datagram idle period instead of waiting for the
  exact expected count forever in lossy steps. A loopback quicprobe smoke with
  10 datagrams delivered all echoes and produced listener diagnostics with
  `stop_reason=expected_datagrams_received`, `message_queue_len=22`, and
  `message_queue_len_peak=22`; this is loopback calibration only, but confirms
  receiver mailbox pressure is now visible for the next ARM ramp.
- 2026-05-26: Added MOQX-client DATAGRAM receive diagnostics to
  `reference-comparison --topology moqx-client-to-reference-server
  --workload datagram_pressure`. Canonical records now include
  `moqx-client-datagram-diagnostics-v1` with accepted/received/missing counts,
  receive-loop event counters, duplicate/invalid counts, receive errors, and
  receiver `message_queue_len`/peak/sample counts. A loopback quicprobe smoke
  (`moqx-client-datagram-diagnostics-loopback`) delivered 10/10 echoes with no
  break symptom, final `receiver_mailbox_depth=0`, peak
  `message_queue_len_peak=10`, and `ignored_events=24`. This closes the
  receiver-mailbox observability criterion for both MOQX receiver topologies;
  the next step is to rerun the ARM private-path DATAGRAM ramp with these
  diagnostics enabled.
- 2026-05-26: Ran the ARM same-region private-path DATAGRAM diagnostics ramp
  as `20260526T154951Z-datagram-diagnostics` on `cax11` nodes in `nbg1`.
  Raw iperf3 UDP delivered 100/250 Mbps with no loss and 500 Mbps with
  99.68% delivery, so the path can carry more than the 1192-byte QUIC steps
  below. At 1192-byte paced DATAGRAM pressure, quicprobe-to-quicprobe delivered
  100% at 5k and 10k pps, 99.36% at 20k pps, and 99.26% at 30k pps. The
  MOQX-client-to-quicprobe-server topology matched reference behavior through
  20k pps: 100% at 5k and 10k, 99.52% at 20k, final
  `receiver_mailbox_depth=0`, and observed mailbox peaks of 25/30/311. At
  30k pps, MOQX dropped to 79.29% delivery with 18,639 missing datagrams,
  p99 latency about 38.7 ms, final `receiver_mailbox_depth=0`, and observed
  mailbox peak 526. This gives a concrete next optimization target: the
  collapse is not explained by an unbounded final mailbox backlog, so inspect
  receive/drain cadence, quicer DATAGRAM admission/completion signals, and
  scheduler/NIF pressure around the 20k-30k pps transition.
- 2026-05-26: The same ARM run could not produce valid
  reference-client-to-MOQX-listener DATAGRAM capacity numbers. quicprobe clients
  timed out while dialing the MOQX listener at every rate, and the listener
  only logged `:timeout`; a follow-up smoke with `--host 0.0.0.0` showed
  `beam.smp` UDP sockets open on the port via `ss -lunp`, but quic-go still
  timed out before the listener accepted a connection. Treat this as an
  interop/reachability blocker for receiver-side remote capacity claims, not as
  DATAGRAM throughput evidence.
- 2026-05-27: Added pre-workload listener diagnostics for
  `moqx-transport-bench moqx-listener`. When the listener fails while waiting
  in accept or handshake, `--diagnostics-output` now appends a
  `moqx-listener-diagnostics-v1` `listener_accept_run` record with the
  configured/bound listener address, phase, timeout, error reason, served
  connection count, and process mailbox snapshot.
- 2026-05-27: Remote ARM same-region tcpdump smoke
  `20260527T073033Z-listener-tcpdump` narrowed the
  reference-client-to-MOQX-listener blocker. On `cax11` nodes in `nbg1`,
  quicprobe-to-quicprobe control traffic succeeded and tcpdump showed
  bidirectional UDP on the private interface. Reference-client-to-MOQX-listener
  burst mode also succeeded: 10/10 DATAGRAM echoes, listener
  `stop_reason=expected_datagrams_received`, and tcpdump showing server
  replies. Paced `1192` byte DATAGRAMs at `5k` pps for `3s` succeeded with a
  generous listener accept window (`--timeout-seconds 30`) and with immediate
  launch at `10s`/`12s`, delivering `15000/15000` echoes with listener mailbox
  peaks `36`-`46`. The reproduced `8s` failure emitted
  `listener_accept_run phase=accept error_reason=timeout connections_served=0`;
  tcpdump showed client Initial packets reaching `10.88.0.12:55560` but no
  server UDP response. The prior failure was therefore an orchestration timeout
  artifact: the listener accept timeout was consumed by setup/capture/client
  dispatch delay, not evidence that quicprobe cannot reach or interoperate with
  the MOQX listener. Future remote receiver-side ramps should decouple
  listener readiness/accept lifetime from per-step measurement timeouts, or use
  a generous listener accept window when external capture/setup is involved.
  Artifacts are under
  `bench/transport/results/20260527T073033Z-listener-tcpdump/`.
- 2026-05-27: Implemented the harness split implied by the tcpdump smoke.
  `moqx-transport-bench moqx-listener` now accepts
  `--accept-timeout-seconds` for the listener readiness/connection accept
  window, while `--timeout-seconds` remains the workload/read timeout after
  accept. Existing commands remain compatible because the accept timeout
  defaults to `--timeout-seconds`. Regression coverage verifies that an
  overridden accept timeout is passed only to `Transport.accept/4` and does not
  inflate DATAGRAM observation/read bounds.
- 2026-05-27: Reran the ARM same-region receiver-side DATAGRAM ramp as
  `20260527T080234Z-receiver-dgram-ramp` after the accept-timeout split. The
  path was `cax11` private `10.88.0.11 -> 10.88.0.12` in `nbg1`. Raw iperf3
  showed TCP goodput around 33.10 Gbps; UDP with 1192-byte datagrams delivered
  100 Mbps at 100%, 250 Mbps at 99.626%, and 500 Mbps at 99.271%. The
  quicprobe-to-quicprobe control sustained target offered rate through
  50k pps, with delivery 100% at 5k/10k, 99.40% at 20k, 99.00% at 30k,
  99.26% at 35k, 97.71% at 40k, and 90.13% at 50k
  (`datagram_delivery_loss`). Reference-client-to-MOQX-listener produced clean
  offered-rate evidence through 30k pps: 100% delivery at 5k/10k, 99.625% at
  20k, and 99.489% at 30k, with listener mailbox peaks of 42/75/221/473. At
  35k, 40k, and 50k, quicprobe only offered about 0.875/0.793/0.633 of the
  target rate against the MOQX listener, so those records are not clean
  capacity measurements. Listener diagnostics still showed bounded receive and
  echo behavior under that attempted load: 104,830/105,000,
  119,713/120,000, and 149,577/150,000 datagrams received with mailbox peaks
  536/800/752. Conclusion: the remote receiver-side timeout blocker is closed,
  and the MOQX listener is competitive through 30k pps on this path. The next
  question is why the reference client cannot sustain more than about
  31k pps against MOQX while it can sustain target offered rates against the
  quicprobe server; that points toward server pacing/backpressure or echo
  timing affecting the client generator, rather than simple listener receive
  loss.
- 2026-05-27: #12 is closed as the reference QUIC benchmark script/tooling
  contract. The remaining work from #12 is deliberately part of this issue:
  richer CPU/scheduler/backpressure observability, stream-pressure
  optimization, DATAGRAM receive/drain cadence, mixed workload real-path reruns
  after the event-pump fix, and deciding whether `moqx-listener` should become
  a performance peer or remain a correctness peer. #31 also closed the
  reference-client offered-rate ambiguity: invalid high-rate
  reference-client-to-MOQX-listener DATAGRAM records above the clean range are
  caused by quic-go `SendDatagram` call cost in the reference client consuming
  the pacing budget, not by MOQX listener receive loss or mailbox growth.
- 2026-05-27: Refined #26 into a focused roadmap and split the next work into
  child issues #32-#36. Reference-comparison DATAGRAM pressure already supports
  burst and paced modes. Self-pair remains intentionally burst-only
  calibration for now: local loopback paced DATAGRAMs would mostly measure host
  scheduler/timer behavior, while real-link paced evidence belongs in
  reference-comparison after an iperf3 path baseline.
