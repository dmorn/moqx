# Harden transport pressure abstractions

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Tighten the transport and benchmark abstractions that became visible while
adding reference-comparison stream pressure, before those shapes become
implicit constraints on larger real-network pressure tests.

This is not a blocker for the first datagram slice. It records follow-up work
that should be designed against real benchmark evidence rather than refactored
preemptively.

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
- `reference-comparison` is stream-shaped today. Datagram pressure should add a
  workload adapter rather than stretching the current stream-path assumptions
  too far.
- The self-pair datagram pressure step is burst-only: it sends all datagrams as
  fast as possible, then drains received events. Real-link datagram pressure
  needs both burst and rate-stepped modes.

## Acceptance criteria

- [x] Benchmark docs distinguish correctness peers from performance peers and
      call out known listener serialization limits.
- [x] Datagram benchmark records distinguish offered datagrams, locally
      accepted sends, and peer-delivered datagrams.
- [ ] High-rate datagram runs can record or bound receiver mailbox pressure.
- [x] Reference-comparison datagram support is modeled as an explicit workload
      mode, not hidden inside stream-pressure fields.
- [ ] Self-pair and reference-comparison datagram workloads support both burst
      and rate-stepped modes, or document why one mode is intentionally absent.
- [ ] Any transport API refactor preserves explicit dependency seams and does
      not introduce `Application` environment as mutable configuration.

## Blocked by

None. Use #12 datagram results to decide which parts are worth implementing
first.

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
