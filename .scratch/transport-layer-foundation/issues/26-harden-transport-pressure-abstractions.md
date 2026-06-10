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
session logic. This issue should make caller-side pressure, backpressure,
mailbox growth, send-completion cadence, and client limits visible enough to
close the gap deliberately.

## Observations

- Listener/relay benchmarking is future relay scope. The v1 benchmark harness
  targets caller-side processes that connect out to a relay or reference peer
  and publish, subscribe, send, or receive over that outbound QUIC connection.
- `MOQX.Transport` currently normalizes all backend events through the caller
  mailbox. For high-rate datagrams, mailbox growth and drain speed can become
  the benchmark result unless it is measured or separated deliberately.
- Stream sends now expose accepted-send tokens and completion events, but
  datagram sends only expose local admission. Datagram pressure must keep
  offered, locally accepted, and peer-delivered counts distinct.
- `measure` now has explicit stream, DATAGRAM, and mixed workload
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

- [x] Benchmark docs scope listener/relay benchmarking out of v1 and keep the
      active benchmark surface caller-side.
- [x] Datagram benchmark records distinguish offered datagrams, locally
      accepted sends, and peer-delivered datagrams.
- [x] High-rate caller-side datagram runs can record or bound receiver mailbox
      pressure in the MOQX-client topology.
- [x] Mixed MOQX-client pressure drains object-stream send completions instead
      of leaving completion events in the caller mailbox.
- [x] Mixed pressure records sender mailbox depth, peak mailbox depth,
      send-completion counts, pending send-completion counts, and event-drain
      counts.
- [x] Measure datagram support is modeled as an explicit workload
      mode, not hidden inside stream-pressure fields.
- [x] Self-pair and measure datagram workloads support both burst
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
5. #36 is closed: listener/relay benchmarking is dropped from the v1 harness
   and deferred until relay work has an explicit serving model.
6. #37 attacks the first stream-pressure bottleneck identified by #33: the
   MOQX-client caller/event pump and per-payload async completion cadence.
7. #38 designs the next measurement layer so transport and benchmark
   diagnostics can move to structured telemetry and cheap collectors without
   turning the observer into the bottleneck again.
8. #39 implements the first low-impact refactor: MOQX-client stream-pressure
   measurements move onto `:telemetry` events, `telemetry_metrics`
   declarations, and a custom benchmark collector while preserving the
   existing `transport-bench-v1` output.
9. #40 is closed: the apparent DATAGRAM bottleneck was reclassified after the
   quicprobe receive/echo fix, and the corrected x86-control evidence is close
   enough for the current limited draft-14 DATAGRAM support.
10. #45 is the next focused loop: improve MOQX-client mixed stream/control
    pressure against the `quicprobe` reference, using same-run remote evidence,
    explicit stop thresholds, and no DATAGRAM-specific churn.
11. #46 tracks the narrower caller-side stream throughput loop so object stream
    goodput can be improved or bounded independently from mixed control
    scheduling.

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
  measure, and the README now calls out the current listener as a
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
  `measure --topology moqx-client-to-reference-server
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
- 2026-06-08: The current DATAGRAM hardening loop now has a `probed`-driven
  ARM bracket wrapper for quickly comparing `quicprobe` control versus
  MOQX-client DATAGRAM pressure around 30k/32k pps. Two Hetzner ARM attempts on
  this date failed before measurement because ARM placement was unavailable
  across CAX11, CAX21, CAX31, and CAX41 profiles in `hel1`, `nbg1`, and
  `fsn1` combinations. The lab was verified clean after each partial apply.
  The next useful #26/#40 action is to rerun the bracket when an ARM pair can
  be provisioned; x86 can smoke tooling, but it is not a substitute for the
  pending ARM evidence.
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
- 2026-06-10: Added #46 as the dedicated stream-throughput progress tracker.
  #45 remains the mixed object/control health issue, while #46 owns the
  stream/object goodput loop that now matters most for caller-side MOQ Lite 04
  work. The current clean x86-control reference point is
  `issue45-control-first-window64-clean-1`: reference 117.60 Mbps, MOQX
  35.28 Mbps, control p99 improved to 78.60 ms with `STREAM_SEND_WINDOW=64`,
  zero pending completions, and no break symptom. Dirty A/Bs narrowed but did
  not solve the throughput ceiling: event batching reduced receive-event calls
  without moving goodput, window 1000 worsened control without improving
  goodput, and stream-finish completion still reached only 35.33 Mbps against
  a 115.01 Mbps same-run reference.
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
  child issues #32-#36. Measure DATAGRAM pressure already supports
  burst and paced modes. Self-pair remains intentionally burst-only
  calibration for now: local loopback paced DATAGRAMs would mostly measure host
  scheduler/timer behavior, while real-link paced evidence belongs in
  measure after an iperf3 path baseline.
- 2026-05-27: Closed #32. The stream-pressure harness now records the
  MOQX-client send admission/completion gap, echo receive cadence,
  event-drain counters, per-stream completion status, and bounded process
  mailbox samples. `moqx-listener --workload stream_pressure` also emits
  listener-side receive/echo/send-completion diagnostics. The next slice is
  #33: rerun the ARM stream-pressure bracket with these diagnostics enabled and
  classify the first optimization target from real-path evidence.
- 2026-05-27: Closed #33 with real-path evidence from
  `20260527T131746Z-issue-33-streamdiag`, a disposable same-region
  `cax11` ARM pair in `nbg1 -> nbg1` over the private path
  `10.88.0.11 -> 10.88.0.12`. iperf3 established a 6.81 Gbps TCP baseline,
  100 Mbps UDP at 100% delivery, 500 Mbps at 99.79%, and 1 Gbps at 99.25%.
  With the #29 stream shape, reference-client-to-reference-server reached
  about 344.9/703.8/684.2 Mbps at 4/8/16 bidirectional streams, while
  MOQX-client-to-reference-server completed all bytes with no break symptom
  but only reached about 72.2/61.7/53.6 Mbps. Diagnostics showed all MOQX
  sends completed, zero final pending completions, bounded final mailbox depth
  3/2/2, and mailbox peaks 107/225/413. Active send and active echo-receive
  durations matched the full application duration, while the caller drained
  about 10k/8.9k/8.0k transport events/sec. First optimization target:
  MOQX-client caller/event-pump throughput and per-payload async completion
  cadence, not send admission failure, missing completions, reference-server
  limits, or unbounded mailbox backlog. Artifacts are under
  `bench/transport/results/20260527T131746Z-issue-33-streamdiag/`.
  Infrastructure was destroyed and verified clean. Follow-up #37 opened.
- 2026-05-27: #37 local diagnosis found that the first stream-pressure
  bottleneck was benchmark-side instrumentation, not `send_stream/4`,
  `receive_event/2`, quicer callback cadence, or the quicprobe server. In the
  local 8-stream/1200-byte/1000-payload loopback shape, MOQX-client originally
  delivered about 165 Mbps while `send_stream/4` admission took only about
  19.5 ms total for 8000 sends and `receive_event/2` took only about 6.8 ms
  total for 12,533 receives. The missing wall time came from live per-phase
  `Agent.update/2` diagnostics and byte-by-byte payload validation. After
  making `--stream-diagnostics-sampling final` skip live phase-agent updates
  and replacing byte-list validation with binary/iodata comparison, the same
  local MOQX-client run reached about 844 Mbps with strict-valid records; a
  local reference-client-to-reference-server control reached about 747 Mbps,
  while detailed `event` diagnostics still reached about 594 Mbps. Next:
  rerun the #33 ARM same-region bracket in final mode to decide whether the
  real-link bottleneck moved.
- 2026-05-27: Closed #37 with ARM evidence from
  `20260527T154046Z-issue-37-final`, a disposable same-region `cax11` ARM
  pair in `nbg1 -> nbg1` over the private path
  `10.88.0.11 -> 10.88.0.12`. The raw path was comparable to #33: 6.59 Gbps
  TCP, 100 Mbps UDP at 100%, 500 Mbps UDP at 99.71%, and 1 Gbps UDP at
  98.25%. Reference-client-to-reference-server reached about
  472.5/730.2/816.9 Mbps at 4/8/16 bidirectional streams. MOQX-client with
  `--stream-diagnostics-sampling final` reached about
  440.9/505.5/521.8 Mbps, compared with #33's 72.2/61.7/53.6 Mbps. All MOQX
  sends completed with zero pending completions, final mailbox depth 3/3/4,
  and p99 latency improved to about 85/149/291 ms. Conclusion: the first
  stream-pressure bottleneck was benchmark-side observer/validation overhead,
  now fixed. The remaining gap versus reference at 8 and 16 streams is the
  next transport-pressure target. Artifacts are under
  `bench/transport/results/20260527T154046Z-issue-37-final/`. Infrastructure
  was destroyed and verified clean.
- 2026-05-28: Opened #38 to turn the measurement refactor discussion into a
  contract issue before adding more ad-hoc diagnostics. The intent is layered
  `:telemetry` for transport and benchmark events, a cheap in-process
  collector first, stable compact JSONL summaries, richer diagnostics as
  sidecars, and remote collector or daemon work only as later phases.
- 2026-05-28: Added the settled measurement-refactor decision to #38 and
  opened #39 as the first implementation slice. The agreed split is root
  `:telemetry` emitters at `MOQX.Transport`, `telemetry_metrics` declarations
  in `bench/transport`, and a custom low-impact collector that emits the same
  benchmark measurement maps consumed by current `transport-bench-v1` records.
- 2026-05-28: Closed #38 by recording the design in ADR-0005 and linking it
  from the benchmark README. #39 is now unblocked as the first implementation
  slice.
- 2026-05-28: Closed #39. The MOQX-client stream-pressure measurement path now
  uses root `MOQX.Transport` `:telemetry` emitters plus an ETS-backed
  benchmark collector instead of live `Agent` diagnostics in the hot path.
  The collector reconstructs accepted sends, accepted send bytes, stream-data
  received bytes, send/receive timing, event counts, and bounded process
  samples while still emitting the existing `transport-bench-v1`
  step-summary/report diagnostics. Local loopback calibration against
  `tools/quicprobe` (`/tmp/moqx-telemetry-measure.jsonl`) reached
  46.02 Mbps for a tiny 1-stream/20x256-byte smoke with 5120 sent/received
  bytes, 20 accepted sends, 0 send errors, strict-valid JSONL, and no break
  symptom. The next #26 slice can now migrate DATAGRAM/mixed pressure onto the
  same telemetry collector pattern or rerun the ARM stream-pressure bracket
  with the cleaner measurement path.
- 2026-05-28: Completed the full measurement migration without keeping the
  temporary mixed state. `MOQX.TransportBench.TransportTelemetryCollector` now
  backs self-pair calibration, MOQX-client stream, DATAGRAM, mixed pressure,
  and `moqx-listener` stream/DATAGRAM diagnostics. The root transport facade
  emits `recv_stream/3` telemetry in addition to stream send, DATAGRAM send,
  and normalized `receive_event/2`; old no-op live phase scaffolding and
  inline per-event mailbox sampling were removed. Remaining workload loops now
  keep only the semantic state needed to drive the benchmark, validate
  payloads, and decide stop/failure conditions.
- 2026-05-28: Closed #34 locally. MOQX-client DATAGRAM diagnostics now include
  active send/receive/observation durations, receive-loop stop reason, and a
  bounded cadence trace under optional diagnostics. A paced loopback calibration
  at 100 dps for 1 second produced 100 offered/accepted/received, 100%
  delivery, no break symptom, strict-valid JSONL, and 11 cadence samples. The
  next remote #26 DATAGRAM run can use those samples to classify sender
  admission, receiver drain cadence, and peer delivery loss around the known
  20k-30k pps transition.
- 2026-05-28: Closed #35 with real-path mixed MOQT-shaped evidence from
  `20260528T101939Z-issue-35-mixed`. Hetzner ARM placement was unavailable in
  `hel1` for `cax11` and in `nbg1` for `cax11`, `cax31`, and `cax41`; the
  successful disposable path used same-region `cax11` nodes in `fsn1` over
  private path `10.88.0.11 -> 10.88.0.12`. The private baseline reported
  8.74 Gbps TCP. Aggressive 1200-byte UDP baselines were lossy: 1 Gbps offered
  delivered 92.23%, 3 Gbps delivered 76.45%, and 6 Gbps delivered 75.83%.
  The established mixed workload reran across all three topologies with no
  break symptom: reference-client-to-reference-server reached 62.05 Mbps,
  MOQX-client-to-reference-server reached 62.02 Mbps, and
  reference-client-to-MOQX-listener reached 52.23 Mbps. The previous remote
  `message_queue_len=32234` artifact is gone: the MOQX-client mixed record
  ended at `message_queue_len=1`, peaked at 528, sampled process depth 458
  times, drained 32,337 events, recorded 32,000 object send completions and
  100 control send completions, and had zero pending object/control
  completions. Artifacts are under
  `bench/transport/results/20260528T101939Z-issue-35-mixed/`. Infrastructure
  was destroyed and verified clean. Observation for a later diagnostics slice:
  `moqx-listener --diagnostics-output` currently emits stream/DATAGRAM
  listener sidecars but not a mixed-workload diagnostics sidecar.
- 2026-05-28: Ran the remote MOQX-client DATAGRAM cadence bracket as
  `20260528T115506Z-issue-26-dgram-cadence`, a disposable same-region
  `cax11` ARM pair in `fsn1 -> fsn1` over the private path
  `10.88.0.11 -> 10.88.0.12`. The path baseline reported 6.07 Gbps TCP.
  UDP with 1192-byte datagrams delivered 100 Mbps at 100%, 500 Mbps at
  96.95%, and 1 Gbps at 91.49%, so the path is lossy at aggressive UDP rates
  but well above the QUIC goodput produced below. The quicprobe-to-quicprobe
  control sustained the requested offered rate through 30k pps with no break
  symptom, delivering 99.93% at 10k, 98.94% at 20k, 98.28% at 25k, and
  97.60% at 30k. MOQX-client-to-quicprobe-server with the #34 cadence
  diagnostics was contract-valid at 10k, 15k, and 18k pps: 100.00%,
  99.50%, and 99.15% delivery, offered-rate ratios 1.000, 1.010, and
  0.988, and final mailbox depth 0. At 20k, 25k, and 30k pps, the records
  became invalid because the sender did not sustain the offered-rate contract:
  offered-rate ratios were 0.891, 0.673, and 0.595. Those invalid records
  still showed high delivery ratios of 99.49%, 97.97%, and 99.49%, zero
  DATAGRAM send errors, final mailbox depth 0, and bounded mailbox peaks of
  273, 352, and 132. Active send duration stretched from about 3.04 s at
  18k to 3.37 s, 4.46 s, and 5.04 s at 20k/25k/30k. Conclusion: the next
  DATAGRAM target is MOQX-client paced-send/event-pump throughput around the
  18k-20k pps transition, not peer delivery loss, unbounded receiver mailbox
  growth, or DATAGRAM admission errors. Artifacts are under
  `bench/transport/results/20260528T115506Z-issue-26-dgram-cadence/`.
  Infrastructure was destroyed and verified clean. Follow-up #40 opened.
- 2026-05-28: #40 reran the DATAGRAM bracket after the exact send-scheduler
  fix and paced-send diagnostics as
  `20260528T124052Z-issue-40-dgram-paced` on a disposable same-region
  `cax11` ARM pair in `fsn1 -> fsn1` over private path
  `10.88.0.11 -> 10.88.0.12`. iperf3 reported a 6.64 Gbps TCP baseline and
  UDP 1192-byte delivery of 100 Mbps at 100%, 500 Mbps at 99.84%, and
  1 Gbps at 97.53%. The quicprobe-to-quicprobe control sustained target
  offered rate through 30k pps with no break symptom. MOQX-client was
  contract-valid at 18k pps after the scheduler fix, but 18.5k, 19k, 20k,
  25k, and 30k pps all failed the offered-rate contract. At 20k, the sender
  achieved only 0.900 of the target offered rate and the send-loop overrun was
  mostly explained by cumulative DATAGRAM send-call time. At 25k and 30k,
  large unmeasured loop overhead appeared on top of send-call time. Peer
  delivery stayed high, final mailbox depth was 0, mailbox peaks stayed
  bounded, and DATAGRAM send errors stayed at 0. This keeps #40 focused on
  MOQX-client paced sender/event-pump throughput rather than peer loss,
  unbounded receiver mailbox growth, or failed DATAGRAM admission. Artifacts
  are under
  `bench/transport/results/20260528T124052Z-issue-40-dgram-paced/`.
  Infrastructure was destroyed and verified clean.
- 2026-05-29: #40 produced a clearer sender-side boundary after the second
  live tuning loop. The useful slice is now committed as benchmark/quicer
  observability and load-generator hardening, not as a final 32k pps fix:
  dedicated DATAGRAM receiver process by default, summary diagnostics for the
  hot path, suppressed quicer DATAGRAM send-state traffic, quicer connection
  statistics in benchmark diagnostics, configurable quicer settings for
  experiments, and a quicprobe server sidecar that proves whether the reference
  server application received and echoed each DATAGRAM. That evidence made a
  30k near-MTU MOQX-client DATAGRAM run valid, but 32k remained unstable and
  repeated remote runs stopped adding signal. The next #26 direction is
  sender-only: benchmark the cost of one DATAGRAM admission per
  `send_datagram/3`/NIF boundary, then validate whether a BEAM-to-NIF batch
  admission experiment is the right way to recover headroom before restarting
  real-infra tests.
- 2026-06-05: #41 and #43 completed the caller-side sender extraction under
  the canonical `moqxprobe measure` surface. MOQX-client DATAGRAM pressure now
  runs through `MOQXProbe.Traffic.DatagramSender`, and pure stream pressure
  runs through `MOQXProbe.Traffic.StreamSender`; both use bounded Flow
  production, a single final GenStage sink that owns transport send calls, and
  benchmark-owned telemetry harvested by the ETS-backed collector while
  preserving `transport-bench-v1`. The old `reference-comparison` command,
  module, Mix task, workload family, stop reasons, and measurement schema name
  were removed instead of kept as compatibility aliases. The next useful #26
  evidence step is a tight real-path validation bracket of the new sender
  architecture before opening any lower-level NIF batching work.
- 2026-06-05: #36 was closed by dropping the benchmark listener branch from
  the v1 harness. `moqxprobe moqx-listener`, its Mix wrapper, tests, README
  examples, and the `reference-client-to-moqx-listener` measurement topology
  were removed. This keeps the transport benchmark focused on the product's
  first caller-side use cases. Listener/relay performance should return as a
  new relay-scoped issue only when relays become a target.
- 2026-06-09: #40 retried the remote ARM DATAGRAM validation with run id
  `20260609T075017Z-issue40-arm-bracket`, but Hetzner placement was still
  unavailable. The retry covered the available CAX ladder from `cax11` through
  `cax41` across same-region and cross-region EU profiles, and every server
  placement failed with `resource_unavailable` for both roles. Partial shared
  resources were destroyed immediately, `just bench-transport-verify-clean`
  passed, and no bracket artifacts were produced. The performance-hardening
  state is therefore unchanged: the next useful evidence step is still the
  ARM `probed` DATAGRAM bracket for the new caller-side sender architecture,
  not an x86 substitute.
- 2026-06-09: Updated the #40 lab strategy after the repeated ARM placement
  failures. Dedicated `x86-control` nodes are now the primary real-path
  iteration target for caller-side DATAGRAM hardening because they are more
  provisionable and reduce feedback-loop latency. Interpret x86 results as
  their own controlled evidence tier: compare MOQX against `quicprobe` on the
  same path with a fresh iperf3 baseline, not against old ARM absolute
  capacity numbers. ARM remains a confirmation lane for portability and
  architecture sensitivity when Hetzner can place a CAX pair.
- 2026-06-09: The x86-control #40 lab is running as
  `20260609T093717Z-issue40-x86-control`. The first real-path DATAGRAM evidence
  changes the bottleneck classification: the extracted Flow/GenStage sender can
  now offer 30k/32k pps on x86, but peer receive/delivery collapses after local
  DATAGRAM admission while `quicprobe -> quicprobe` remains near 100% delivery
  on the same path. Enabling MsQuic pacing through the new probed
  `QUICER_SETTINGS=pacing_enabled=1` knob did not help; it worsened 30k and
  left 32k around the same loss level. The next useful #26/#40 work is
  sender/path/congestion diagnosis below local admission, not more BEAM
  pacing-loop work or a default change to MsQuic pacing.
- 2026-06-09: A follow-up x86-control bracket with
  `QUICER_SETTINGS=max_operations_per_drain=255` also failed to improve the
  MOQX-client DATAGRAM gap. MOQX delivered only 43.30% at 30k pps while the
  reference control delivered 98.45%; at 32k pps the reference control itself
  collapsed to 11.05%, making that sample low-confidence path/lab evidence.
  Treat this as another negative knob test, not a default-setting candidate.
  The lab remains intentionally up for the current tuning loop.
- 2026-06-09: #40 also falsified the "over-compressed 1 ms sender burst" theory
  with a temporary moqxprobe A/B that was reverted after measurement. On the
  x86-control path at 30k pps, default sink bursts delivered 90.15% for MOQX
  while `quicprobe` delivered 99.99%; adding 33 us spacing inside each MOQX
  burst reduced MOQX offered rate to 28.76k pps and delivery to 57.23%, while
  `quicprobe` still delivered 99.80%. Keep the sender small: do not retain an
  intra-burst spacing knob from this evidence.
- 2026-06-09: #40 then tested MsQuic send buffering after verifying quicer's
  DATAGRAM send context keeps buffers alive until final send state, which is
  safe for `send_buffering_enabled=0`. The clean x86-control 30k pps control
  used `moqxprobe-0.1.0-fe0a5db-linux-x86_64.tar.gz` and delivered 70.57% for
  MOQX while `quicprobe` delivered 99.89%. Disabling send buffering worsened
  MOQX to 54.78% delivery while `quicprobe` stayed at 99.70%. Keep the default
  MsQuic send buffering enabled.
- 2026-06-09: #40 also A/B tested MsQuic BBR by passing
  `QUICER_SETTINGS=congestion_control_algorithm=1`. It left reference healthy
  at 99.98% and MOQX at full offered rate, but MOQX delivery only reached
  72.11% versus the immediate Cubic control's 70.57%. Treat BBR as a non-fix
  for the current DATAGRAM gap.
- 2026-06-09: #40 then ran a clean lower-rate x86-control DATAGRAM bracket
  across 20k, 24k, 26k, 28k, and 30k pps. This changed the next diagnostic
  shape: MOQX can now sustain target offered rate at all tested rates, and it
  crossed the 95% delivery threshold at 20k pps (95.76%) while getting close at
  26k pps (94.45%) and reaching 91.27% at 30k pps. However, the reference
  control was itself unstable at 24k and 28k, so the broad bracket is not clean
  enough for a final threshold claim. Prefer repeated single-rate runs with a
  healthy reference control before doing more implementation churn.
- 2026-06-09: The repeated single-rate follow-up sharpened that conclusion.
  MOQX is repeatably good enough at 20k pps on the current x86-control path
  (95.87% and 95.27% delivery with full offered rate), but still not close at
  30k pps when the reference control is healthy (MOQX 51.14% and 49.18%;
  reference 99.87% and 99.97%). The remaining 30k loss is before quicprobe
  server application receive, confirmed by the sidecar counts. Stop spending
  effort on BEAM pacing-loop shape until lower-level quicer/MsQuic DATAGRAM
  send flags and queue/drop behavior have been inspected.
- 2026-06-09: #40 added controlled quicer DATAGRAM send-flag plumbing and tested
  it on the x86-control path. Single flags did not help enough, but the
  combined `dgram_priority,priority_work` setting moved MOQX 30k delivery from
  roughly 51% to a variable 79.50%/95.19%/84.57% range while maintaining full
  offered rate. This is a useful pressure-abstraction knob and evidence that
  send scheduling below local admission matters, but it is not yet stable
  enough to become the default. Keep the current sender architecture small and
  use the next loop to explain the variance under DATAGRAM-only and mixed
  pressure before claiming #26 closed.
- 2026-06-09: Clean-artifact repeats on `da54a2d` weakened the send-flag
  conclusion. The combined flags produced 87.83% and then 51.38% MOQX delivery,
  while a no-flag clean control produced 62.03%; all three used the same
  artifact, path, 30k pps offered load, and server sidecar. Keep the flag
  plumbing as a diagnostic mechanism, but do not make the flags the default or
  treat them as the #26 fix. The next useful hardening work is variance
  diagnosis below local admission and before quicprobe server receive.
- 2026-06-09: #40 corrected that variance diagnosis with paired pcaps,
  quic-go receive-queue inspection, and a quicprobe server fix that decouples
  DATAGRAM receive draining from echo sending. With clean quicprobe
  `60695bf` and clean moqxprobe `da54a2d` on the x86-control lab, the corrected
  32k pps comparison delivered 99.981% for `quicprobe -> quicprobe` and
  99.932% for `moqxprobe -> quicprobe`; the server-ingress summary showed
  reference at 96,000/96,000 DATAGRAMs and MOQX at 95,958/96,000. Reclassify
  the earlier 30k collapse as a benchmark reference-server echo/receive
  artifact, not a MOQX Transport sender bottleneck. The caller-side DATAGRAM
  send path is now close enough to the reference on this controlled x86 path;
  keep future #26 work focused on remaining observability, mixed workload, or
  listener/relay concerns rather than more DATAGRAM sender churn.
- 2026-06-09: Added `reference_mixed` and `moqx_mixed` to the `probed` remote
  suite runner so mixed MOQT-shaped stream/control pressure can run through the
  same artifact/manifest path as stream and DATAGRAM checks. The current mixed
  workload is stream/control shaped, not QUIC DATAGRAM pressure. A smoke run
  `20260609T093717Z-issue40-x86-control-mixed-suite-smoke-1` verified the
  remote argument plumbing. A pressure-sized x86-control run
  `20260609T093717Z-issue40-x86-control-mixed-pressure-32x1000-1` used 32
  streams, 1000 x 1180-byte object payloads per stream, and 100 x 64-byte
  control messages at 100 messages/sec. Both reference and MOQX records had no
  break symptom. Reference reached 116.99 Mbps with control p99 37.95 ms;
  MOQX reached 73.37 Mbps with control p99 139.43 ms. The previous mailbox
  artifact remains fixed: final `message_queue_len=0`, peak 497, 32,000 object
  send completions, 100 control send completions, and zero pending
  object/control completions. This is an adjacent mixed stream/control
  performance gap, not evidence against the corrected DATAGRAM sender
  conclusion.
- 2026-06-10: Closed #40 and stopped DATAGRAM-specific tuning. The decisive
  evidence is the corrected clean x86-control 32k pps run: valid offered rate,
  reference server ingress 96,000/96,000, MOQX ingress 95,958/96,000, and no
  need for retained sender hacks or default MsQuic/quicer flag changes.
  DATAGRAM is only relevant to the current limited draft-14 path;
  `moq_lite_04` disables QUIC DATAGRAM, so more DATAGRAM-only optimization has
  low leverage. Keep the x86-control lab alive under the standing operator
  instruction, but shift #26 attention to stream/control pressure and protocol
  readiness rather than reopening #40.
- 2026-06-10: Opened #45 as the focused stream/control performance tracker.
  It takes over the role #40 played for DATAGRAM: reproduce the current
  mixed-pressure gap, classify the first bottleneck with evidence, keep
  `transport-bench-v1` stable, reject low-value knobs explicitly, and stop only
  when MOQX is close enough to the same-run `quicprobe` reference for the
  current caller-side mixed workload. The initial target evidence is the
  x86-control mixed run where reference reached 116.99 Mbps with control p99
  37.95 ms and MOQX reached 73.37 Mbps with control p99 139.43 ms, while the
  old mailbox/completion artifact stayed fixed.
- 2026-06-10: #45 reproduced and sharpened the mixed stream/control gap on the
  active x86-control lab (`20260609T093717Z-issue40-x86-control`). The clean
  baseline repetitions used 32 object streams, 1000 x 1180-byte payloads per
  stream, and 100 x 64-byte control messages at 100 messages/sec with
  `TIMEOUT_SECONDS=15` and `TIMEOUT_MARGIN_SECONDS=5`. Reference reached
  55.50/55.48 Mbps with control p99 53.53/55.58 ms. MOQX reached only
  35.11/35.25 Mbps, while all 32,000 object send completions drained, pending
  object completions were zero, and mailbox peaks stayed low at 9/14. The old
  mailbox backlog is therefore not the current bottleneck.
- 2026-06-10: #45 A/Bs also rejected two easy explanations. Switching stream
  diagnostics from `event` to `final` reduced observer work but left MOQX
  around 35.07 Mbps with control p99 1611.12 ms, so the current gap is not
  measurement-agent overhead. Changing `STREAM_SEND_WINDOW` moved control
  latency around but not object goodput: window 64 reached control p99
  78.96 ms but first control byte 6070.63 ms and goodput 35.01 Mbps, while
  window 4 reached first control byte 1458.07 ms, control p99 812.54 ms, and
  goodput 36.57 Mbps.
- 2026-06-10: The first #45 harness fix is control-first scheduling in the
  mixed MOQX-client loop: when a control message is ready, schedule it before
  refilling object-stream windows. Dirty remote validation showed first control
  byte improving from about 4.5-6.1 seconds to about 27 ms. With
  `STREAM_SEND_WINDOW=64`, MOQX control p99 improved to 78.88 ms against a
  same-run reference p99 of 33.05 ms, but object goodput stayed 35.24 Mbps
  versus 117.01 Mbps reference. Keep the change, then rerun from a clean
  committed artifact. The next #26/#45 target is object stream
  throughput/send-completion cadence under mixed pressure, not more DATAGRAM
  tuning and not the old mailbox artifact.
- 2026-06-10: The clean committed #45 rerun used `5382547`
  (`moqxprobe-0.1.0-5382547-linux_x86_64`) on the still-alive x86-control lab.
  Default-window clean validation `issue45-control-first-clean-1` confirmed the
  fix: MOQX first control byte improved to 26.52 ms, matching the same-run
  reference at 25.86 ms, with zero pending object/control completions and
  mailbox peak 21. The remaining issue is still throughput and recurring
  control latency: reference reached 117.22 Mbps with control p99 31.47 ms,
  while MOQX reached 35.23 Mbps with control p99 1564.85 ms. Clean
  `STREAM_SEND_WINDOW=64` validation
  `issue45-control-first-window64-clean-1` improved MOQX control p99 to
  78.60 ms against 35.14 ms reference, again with zero pending completions, but
  object goodput remained 35.28 Mbps versus 117.60 Mbps reference. This keeps
  #45 open: the next target is the mixed unidirectional object-stream
  goodput/send-completion cadence ceiling, and window size should remain an
  experiment knob until two clean repetitions meet the stop threshold.
