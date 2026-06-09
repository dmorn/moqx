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
- [x] If an implementation change is made, rerun a controlled real-path
      DATAGRAM bracket with an iperf3 baseline and compare against the
      reference quicprobe control. Use the dedicated x86-control profile as the
      primary iteration lab while Hetzner ARM placement is unavailable; treat
      ARM as an opportunistic confirmation lane, not as a blocker.
- [x] Record the result in #26, including whether MOQX-client can sustain the
      20k pps offered-rate contract and what remains to close versus the
      reference client.
- [ ] Keep the active x86-control lab alive during the agreed tuning loop; when
      the loop ends or the operator asks, destroy disposable infrastructure and
      verify no provider resources remain.

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
- 2026-05-28: Added a low-overhead phase split for the paced DATAGRAM sender
  hot path. Canonical records now keep the existing `transport-bench-v1`
  contract but add metrics/diagnostics for payload encode timing, outer
  `Transport.send_datagram/3` wall-clock timing, wrapper/telemetry overhead,
  and residual loop overhead after accounting for payload encode plus the
  outer send call. This lets the next remote run distinguish benchmark payload
  allocation, public transport-call overhead, telemetry/collector overhead,
  receive-drain/event-pump cost, and backend admission cost before changing the
  transport API or quicer backend.
- 2026-05-28: Loopback calibration
  (`/tmp/moqx-issue-40-phase-split.jsonl`) against `tools/quicprobe` at
  3k pps, 1192-byte DATAGRAMs, and 1 second was strict-valid with no break
  symptom: offered-rate ratio 0.9998, 3000/3000 delivered, send-loop overrun
  about 0.53 ms, internal DATAGRAM send-call total about 6.83 ms, payload
  encode total about 27.84 ms, outer send-call total about 12.63 ms, and
  wrapper/telemetry overhead about 5.80 ms. This is loopback calibration only,
  but it proves the new split is populated and shows that benchmark payload
  allocation can be a meaningful part of the per-DATAGRAM cost.
- 2026-05-29: Stopped the remote tuning loop after the 32k pps phase started
  producing low-leverage repetitions. The live lab was torn down by the
  operator before the next experiment. Current evidence says the original
  18k-20k offered-rate ceiling was moved substantially by reducing benchmark
  observer overhead, using a dedicated DATAGRAM receiver process, suppressing
  quicer DATAGRAM send-state messages, and disabling MsQuic pacing for the
  paced load-generator path. A 30k pps near-MTU MOQX-client run became
  contract-valid, but 32k pps remained unstable.
- 2026-05-29: Added `tools/quicprobe server --stats-output` during the live
  lab to distinguish echo-return loss from loss before the reference server
  application. The sidecar showed the server echoed every DATAGRAM it received,
  while failing 32k MOQX-client samples often reached the server application
  with fewer than the intended 96,000 DATAGRAMs. This shifts the remaining
  suspect away from receiver mailbox growth and toward sender burst shape,
  BEAM/NIF admission overhead, MsQuic/path admission, or lab variance near the
  path limit.
- 2026-05-29: Narrowed the next experiment before any more infrastructure.
  Local quicer inspection found that the current public API only exposes one
  DATAGRAM send request per NIF call: `async_send_dgram/2|3` routes to
  `quicer_nif:send_dgram/3`, whose C implementation allocates one send
  context and calls `MsQuic->DatagramSend` once with `BufferCount = 1`.
  MsQuic's `BufferCount` is scatter/gather for one logical DATAGRAM payload,
  not a batch of DATAGRAM frames. The next hypothesis is therefore a
  benchmark-only sender experiment around BEAM-to-NIF batching: accept a burst
  from the paced sink in one NIF call, loop inside the NIF, and measure whether
  reducing scheduler/NIF boundary crossings gives enough headroom before
  touching listener-side performance.
- 2026-05-29: Added the local `sender-admission` microbenchmark under
  `bench/transport`. It opens a loopback quicer pair, waits for the client
  DATAGRAM-ready event, hands the server connection to a sink process, reuses a
  fixed payload, and compares public `MOQX.Transport.send_datagram/3` against
  direct quicer admission in raw-burst and absolute-timer paced modes. This
  remains loopback calibration only and emits `sender-admission-v1` rather than
  `transport-bench-v1`.
- 2026-05-29: The first local 1192-byte run produced intermittent
  `{:dgram_send_error, :invalid_parameter}` failures. After recording
  negotiated DATAGRAM metadata, the harness showed this local pair advertised a
  1187-byte maximum, so the 1192-byte result was payload-limit evidence rather
  than sender-throughput evidence. The stable local sample used 1180-byte
  payloads.
- 2026-05-29: Local 1180-byte sender-admission evidence does not support
  "one NIF call per DATAGRAM is already impossible" at the 32k pps target on
  this Apple ARM loopback host. In paced mode, both MOQX and direct quicer
  admitted 96,000/96,000 DATAGRAMs across three 3-second repetitions with zero
  send errors. MOQX averaged about 31,999 dgram/s, direct quicer about 32,003
  dgram/s, burst p99 was about 0.085 ms for MOQX and 0.051 ms for direct
  quicer, and no burst exceeded the 1 ms budget. In raw-burst mode, MOQX
  averaged about 1.04M dgram/s with ~32.6x target headroom, while direct quicer
  averaged about 1.43M dgram/s with ~44.7x headroom. Batching may still be a
  useful future optimization, but this local evidence shifts the next question
  back to the remote paced load-generator shape, path/MSQUIC admission near the
  real limit, and listener/event-loop behavior rather than proving an immediate
  BEAM-to-NIF boundary ceiling.
- 2026-05-29: Follow-up interpretation of the local sender-admission delta:
  `MOQX.Transport.send_datagram/3` is measurably slower than direct
  `MOQX.Transport.Quicer.send_datagram/2` because the public facade adds the
  context/connection backend check, dynamic backend dispatch, public result
  wrapping, timing, metadata construction, and `:telemetry.execute/3` around
  the same quicer DATAGRAM admission call. A fake-backend microbenchmark put
  the facade-only delta at about 0.39 us/send on this host, matching the
  observed public-vs-direct sender-admission gap of about 0.42 us/send. At
  32k pps this is roughly 13 ms of CPU time per second, so it is worth keeping
  in mind but is not a current optimization target. Preserve the public facade
  and telemetry path; revisit only if future real-path evidence shows this
  overhead has become the limiting factor.
- 2026-06-05: Completed the benchmark-client redesign that #40 pointed toward.
  Follow-up #41 moved MOQX-client DATAGRAM pressure onto
  `MOQXProbe.Traffic.DatagramSender`: bounded Flow payload production, a
  single GenStage sink that owns `MOQX.Transport.send_datagram/3`, absolute
  monotonic pacing, capped catch-up, hot-path telemetry, and stable
  `transport-bench-v1` adaptation. Local loopback calibration at 32k pps with
  1180-byte DATAGRAMs was contract-valid (`offered_rate_ratio=0.9858`,
  `datagram_delivery_ratio=0.97559375`) but remains calibration only.
  Follow-up #43 applied the same sender architecture to pure stream pressure
  through `MOQXProbe.Traffic.StreamSender`. The canonical command surface is
  now `moqxprobe measure`; no `reference-comparison` compatibility path
  remains. The next #40 step is not more local sender-admission work, but a
  small ARM real-path bracket comparing quicprobe control versus the new
  MOQX-client DATAGRAM sender around 30k/32k pps.
- 2026-06-08: Attempted to start the next ARM real-path bracket with run id
  `20260608T151903Z-issue40-arm-dgram`, after closing #42 and pushing a clean
  `main` so the remote build would have stable artifact identity. Hetzner ARM
  placement was unavailable for every attempted profile: `arm-hel1-tiny`
  (`cax11`, `hel1 -> hel1`), `arm-nbg1-tiny` (`cax11`, `nbg1 -> nbg1`),
  `arm-default` (`cax31`, `fsn1 -> hel1`), and `arm-nbg1-hel1-stress`
  (`cax41`, `nbg1 -> hel1`) all failed during server placement with
  `resource_unavailable` for both client and server. Each partial network,
  firewall, and SSH-key state was destroyed immediately after the failed
  apply. `just bench-transport-verify-clean` reported no Terraform state
  entries or labelled Hetzner resources remaining. No performance evidence was
  produced, and no x86 substitute was run because it would not satisfy the
  pending ARM #40 validation.
- 2026-06-08: Retried the ARM real-path bracket with the new `probed`
  DATAGRAM bracket wrapper using run id
  `20260608T160101Z-issue40-arm-bracket`. Hetzner ARM placement was still
  unavailable. The attempted profiles were `arm-hel1-tiny` (`cax11`,
  `hel1 -> hel1`), `arm-nbg1-tiny` (`cax11`, `nbg1 -> nbg1`),
  `arm-default` (`cax31`, `fsn1 -> hel1`), `arm-nbg1-hel1-stress`
  (`cax41`, `nbg1 -> hel1`), and `arm-smoke` (`cax21`, `fsn1 -> nbg1`).
  Every apply failed during server placement with `resource_unavailable` for
  both client and server roles. Each partial network/firewall/SSH-key apply was
  destroyed immediately, and `just bench-transport-verify-clean` reported no
  Terraform state entries or labelled Hetzner resources remaining. No bracket
  artifacts or performance measurements were produced. This keeps the next
  #40 action unchanged: run the `probed` DATAGRAM bracket on ARM once Hetzner
  can place a pair, not on x86 as a substitute.
- 2026-06-09: Retried the ARM real-path bracket with run id
  `20260609T075017Z-issue40-arm-bracket`. Hetzner ARM placement is still
  unavailable across the useful ARM ladder: `arm-hel1-tiny` (`cax11`,
  `hel1 -> hel1`), `arm-nbg1-tiny` (`cax11`, `nbg1 -> nbg1`),
  `arm-nbg1-hel1-tiny` (`cax11`, `nbg1 -> hel1`), `arm-smoke` (`cax21`,
  `fsn1 -> nbg1`), `arm-default` (`cax31`, `fsn1 -> hel1`), and
  `arm-nbg1-hel1-stress` (`cax41`, `nbg1 -> hel1`). Every apply that reached
  server creation failed during placement with `resource_unavailable` for both
  client and server roles. A Terraform plan-version mismatch occurred during
  the first `arm-nbg1-hel1-stress` apply attempt; regenerating the plan with
  the active Terraform `1.15.5` resolved that tooling issue before the final
  placement attempt, and it did not create server resources. Each partial
  network/firewall/SSH-key apply was destroyed immediately, the current run
  marker was cleared, and `just bench-transport-verify-clean` reported no
  Terraform state entries or labelled Hetzner resources remaining. No bracket
  artifacts or performance measurements were produced. The next #40 action is
  unchanged: rerun the `probed` DATAGRAM bracket on ARM when Hetzner can place
  a pair.
- 2026-06-09: Revised the #40 evidence contract after repeated Hetzner CAX
  placement misses. The active performance-hardening lab is now the dedicated
  `x86-control` profile: run iperf3, `quicprobe -> quicprobe`, and
  `moqxprobe -> quicprobe` on the same x86 path and compare MOQX against that
  reference baseline. Do not mix the new x86 absolute capacity numbers with
  older ARM CAX numbers. ARM remains valuable as a later portability and
  confirmation check when capacity is available, but it no longer blocks the
  DATAGRAM sender tuning loop.
- 2026-06-09: Brought up the dedicated x86-control lab
  `20260609T093717Z-issue40-x86-control` (`ccx23`, `fsn1 -> hel1`, private
  path `10.88.0.11 -> 10.88.0.12`) and kept it running for iteration. Private
  network/toolchain checks passed. `probed`, `quicprobe`, and `moqxprobe` were
  deployed and the baseline suite passed. The first x86 DATAGRAM bracket
  `20260609T093717Z-issue40-x86-control-dgram-bracket-094959` used 1180-byte
  DATAGRAMs for 3 seconds at 30k and 32k pps with MOQX's current
  `pacing_enabled=0` default. `quicprobe -> quicprobe` sustained target
  offered rate with 99.94% delivery at 30k and 99.46% at 32k. MOQX-client also
  sustained target offered rate, so the old offered-rate failure is gone, but
  delivery collapsed after local admission: 85.89% at 30k and 48.59% at 32k,
  both with `datagram_delivery_loss`. The quicprobe server sidecar received
  roughly the same counts reported by MOQX as delivered, so this is not a
  client echo-drain or mailbox-backlog artifact; the missing DATAGRAMs are lost
  before the reference server application receives them.
- 2026-06-09: Added a benchmark-control knob for this diagnosis:
  `QUICER_SETTINGS` is forwarded by the probed suite/bracket and appended as
  `--quicer-setting` only to MOQX-client measurements. The fake bracket
  regression covers forwarding. Reran the same x86 bracket as
  `20260609T093717Z-issue40-x86-control-dgram-bracket-100620` with
  `QUICER_SETTINGS=pacing_enabled=1`. This isolated MsQuic pacing as a
  non-fix: reference stayed healthy at 99.86%/99.97% delivery for 30k/32k,
  while MOQX still sustained offered rate but delivered only 53.32% at 30k and
  49.32% at 32k. Keep the knob for controlled experiments, but do not change
  the default away from `pacing_enabled=0` based on this evidence.
- 2026-06-09: Tested another quicer/MsQuic scheduling hypothesis on the same
  running x86 lab with
  `QUICER_SETTINGS=max_operations_per_drain=255`, bracket
  `20260609T093717Z-issue40-x86-control-dgram-bracket-101312`. This is not a
  fix. At 30k pps, reference delivered 98.45% but MOQX delivered only 43.30%.
  At 32k pps, the reference control itself collapsed to 11.05% delivery while
  MOQX delivered 12.89%, so that sample is low-confidence path/lab evidence
  rather than a clean MOQX-specific signal. The quicprobe server sidecar again
  received and echoed roughly the delivered counts, which keeps the remaining
  suspect below local send admission and before server-application receive.
  Keep the setting available for experiments, but do not raise
  `max_operations_per_drain` by default from this run.
- 2026-06-09: Tested the next sender-shape hypothesis by temporarily adding an
  optional quicprobe-like intra-burst spacing knob to the MOQX DATAGRAM sink,
  deploying dirty artifact
  `moqxprobe-0.1.0-0caab6d-dirty-9da5c5e9ae49-linux-x86_64.tar.gz`, and
  running a tight 30k pps A/B on the still-running x86 lab. Default spacing
  (`DATAGRAM_BURST_SPACING_US=0`) in suite
  `20260609T093717Z-issue40-x86-control-probed-suite-103202` kept the reference
  healthy at 99.99% delivery and MOQX at full offered rate with 90.15%
  delivery. The spaced variant (`DATAGRAM_BURST_SPACING_US=33`) in suite
  `20260609T093717Z-issue40-x86-control-probed-suite-103348` made MOQX worse:
  offered rate fell to 28.76k pps and delivery fell to 57.23%, while reference
  stayed healthy at 99.80%. The quicprobe server sidecar again matched the
  delivered counts. This falsifies "millisecond burst compression is the main
  loss source" for this setup. The temporary implementation was reverted and
  no burst-spacing knob was kept.
- 2026-06-09: Inspected quicer/MsQuic DATAGRAM buffer ownership before testing
  MsQuic send buffering. `send_dgram/3` copies the BEAM iodata into a per-send
  NIF environment, passes that buffer as `ClientSendContext` to
  `MsQuic->DatagramSend`, and destroys the send context only on final
  `DATAGRAM_SEND_STATE_CHANGED` states (`LOST_DISCARDED`, `ACKNOWLEDGED`,
  `ACKNOWLEDGED_SPURIOUS`, or `CANCELED`). MsQuic documents `SENT` as the
  earliest point where the app may free DATAGRAM buffers, so quicer's lifetime
  is conservative enough to safely A/B `send_buffering_enabled=0`.
- 2026-06-09: Redeployed clean artifact
  `moqxprobe-0.1.0-fe0a5db-linux-x86_64.tar.gz` to remove the previous
  temporary dirty spacing build, then ran a 30k pps send-buffering A/B on the
  x86-control lab. Clean default suite
  `20260609T093717Z-issue40-x86-control-probed-suite-103907` kept reference at
  99.89% delivery and MOQX at full offered rate with 70.57% delivery.
  `QUICER_SETTINGS=send_buffering_enabled=0` suite
  `20260609T093717Z-issue40-x86-control-probed-suite-104035` kept reference at
  99.70% but made MOQX worse: full offered rate, 54.78% delivery, and
  `datagram_delivery_loss`. The quicprobe server sidecar again matched the
  delivered counts. Do not disable MsQuic send buffering by default from this
  evidence.
- 2026-06-09: Tested MsQuic's BBR congestion-control option on the same clean
  x86-control artifact with
  `QUICER_SETTINGS=congestion_control_algorithm=1`, suite
  `20260609T093717Z-issue40-x86-control-probed-suite-104330`. Reference
  remained healthy at 99.98% delivery. MOQX again sustained full offered rate
  but delivered only 72.11%, versus 70.57% for the immediately preceding Cubic
  control. This is not enough signal to change defaults: BBR does not close the
  current DATAGRAM gap, and the remaining loss still happens before the
  quicprobe server application receives the DATAGRAMs.
- 2026-06-09: Ran a clean lower-rate DATAGRAM bracket on the still-running
  x86-control lab, bracket
  `20260609T093717Z-issue40-x86-control-dgram-bracket-105141`, using clean
  artifact `moqxprobe-0.1.0-fe0a5db-linux_x86_64`, 1180-byte DATAGRAMs, 3
  second send windows, and default quicer settings. The result is useful but
  qualified. MOQX sustained target offered rate at every point and delivered
  95.76% at 20k pps, 94.45% at 26k pps, and 91.27% at 30k pps. The 24k and
  28k points were lower (69.04% and 80.83%), but the reference control itself
  collapsed at those same rates (13.71% and 12.02%), while reference was healthy
  at 26k and 30k (99.90% and 99.94%). Treat this as evidence that MOQX has a
  plausible usable envelope around 20k pps on this x86 path and remains
  full-offer up to 30k, but do not use this one-pass broad bracket as the final
  threshold. The next measurement loop should use repeated single-rate runs
  with valid reference controls before claiming a stable cliff.
- 2026-06-09: Followed the qualified bracket with two repeated single-rate
  suites each at 20k, 26k, and 30k pps (`probed-suite-122202`,
  `probed-suite-122238`, `probed-suite-122318`, `probed-suite-122359`,
  `probed-suite-122441`, `probed-suite-122521`). At 20k, MOQX sustained target
  offered rate and crossed the 95% delivery bar twice (95.87% and 95.27%); one
  reference run was clean and one reference run took too long to offer the
  target rate, but the server sidecar still received almost all reference
  DATAGRAMs. At 26k, the reference control collapsed in both runs, so those
  samples are not useful as a fair threshold. At 30k, the reference control was
  healthy twice (99.87% and 99.97%), while MOQX sustained full offered rate but
  delivered only 51.14% and 49.18%; the server sidecar received 46,033 and
  44,270 MOQX DATAGRAMs. Current working envelope: 20k pps is the first
  repeatable pass on this x86 path; 30k pps remains a clean MOQX-specific gap.
  Next implementation work should inspect MsQuic/quicer DATAGRAM send flags or
  queue/drop semantics rather than more BEAM pacing-loop changes.
- 2026-06-09: Bookkeeping checkpoint before the next implementation experiment:
  keep the existing x86-control lab up for the current tuning loop, use 30k pps
  with a healthy `quicprobe` reference control as the discriminator, and treat
  ARM as the later architecture-confirmation lane once CAX capacity is available.
  Any quicer/MsQuic DATAGRAM send-flag or queue/drop change should stay
  experimental until it improves the 30k MOQX gap on this path; if it does not,
  revert the change and retain only the negative evidence.
- 2026-06-09: Added experimental quicer DATAGRAM send-flag plumbing on branch
  state `baf6d2b-dirty-8ff4a84fd36f` with quicer NIF ref `3c6c6b0`, deployed
  it to the still-running x86-control lab, and ran 30k pps A/B suites against
  `quicprobe`. The no-flag dirty baseline
  `probed-suite-130837` reproduced the gap: reference 99.26% delivery, MOQX
  51.60%, both at valid offered rate. `dgram_priority` alone
  (`probed-suite-131804`) kept reference healthy at 99.91% and lifted MOQX only
  to 56.84%. `priority_work` alone (`probed-suite-131918`) kept reference
  healthy at 99.82% and left MOQX at 51.31%. The combined
  `dgram_priority,priority_work` case is materially better but still variable:
  `probed-suite-133025` recorded MOQX 79.50% while the reference client's
  offered-rate record was invalid, `probed-suite-133135` was the first clean
  30k pass with reference 99.80% and MOQX 95.19%, and
  `probed-suite-133250` kept reference healthy at 99.60% but MOQX fell back to
  84.57%. Keep the send-flag plumbing because it moves the bottleneck, but do
  not declare the 30k path fixed or change defaults yet. The next loop should
  explain the variance and verify whether the combined flags remain safe under
  mixed control-plus-DATAGRAM pressure.
