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
