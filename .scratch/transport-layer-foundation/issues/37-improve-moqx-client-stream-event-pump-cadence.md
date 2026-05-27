# Improve MOQX-client stream event-pump cadence

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Improve the MOQX-client stream-pressure path that #33 identified as the first
real bottleneck: the caller/event pump plus per-payload async completion
cadence.

The ARM run `20260527T131746Z-issue-33-streamdiag` showed that the MOQX client
is correct and drains its final mailbox, but the event owner only drains about
8k-10k transport events/sec under the #29 stream shape. Because the benchmark
sends 1200-byte payloads and schedules new sends from completion feedback, that
event cadence becomes the throughput ceiling: roughly 54-72 Mbps while the
same path's reference-client-to-reference-server control reaches roughly
345-704 Mbps.

Do not remove async completion feedback. The fix should preserve explicit send
admission and completion accounting while reducing avoidable event-pump
overhead or proving which layer owns it.

## Acceptance criteria

- [x] Add a focused regression or benchmark-harness test that captures the
      current stream-pressure completion/event cadence shape without using
      `Application` env or mutable global configuration.
- [x] Add an experimental knob or internal strategy that can distinguish
      per-payload completion-event volume from raw byte throughput, for example
      configurable stream send windows, payload coalescing for pressure runs,
      or a batched drain/scheduling loop.
- [x] Preserve existing diagnostics: accepted sends, completed sends,
      cancellations, pending completions, stream data events, mailbox peak, and
      per-stream completion status must remain visible.
- [x] Run local calibration showing the new path still emits strict-valid
      `transport-bench-v1` records and does not regress correctness.
- [x] Rerun the same-region ARM stream-pressure bracket, or a smaller justified
      ARM bracket, and compare against #33 to prove whether throughput improves
      or the bottleneck moves.
- [x] Record the result in #26 with enough detail to decide the next
      optimization target.

## Blocked by

#33 - the real-path diagnostics are the evidence for this issue.

## Notes

The first hypothesis is event volume, not network capacity: #33 completed all
send completions with zero final pending completions and bounded final mailbox
depth, but active send duration stretched across the whole run and event-drain
rate declined as stream count increased. A useful fix should either raise
goodput without losing completion feedback, or prove that the next bottleneck
is inside `quicer`/msquic scheduling rather than the benchmark caller loop.

## Progress

- 2026-05-27 local loopback diagnosis found the bottleneck was in the
  benchmark client, not in `MOQX.Transport.send_stream/4`, `receive_event/2`,
  quicer callback cadence, or the quicprobe server. Before the fix, the
  8-stream/1200-byte/1000-payload MOQX-client loopback run delivered about
  165 Mbps while `send_stream/4` admission took only about 19.5 ms total for
  8000 sends and `receive_event/2` took only about 6.8 ms total for 12,533
  receives. The missing wall time was benchmark-side event handling:
  synchronous per-phase `Agent.update/2` diagnostics plus byte-by-byte payload
  validation using `:binary.bin_to_list/1`.
- The fix keeps the detailed `event` diagnostics mode available, but makes
  `--stream-diagnostics-sampling final` skip live phase-agent updates and rely
  on the final in-memory stream state. Payload validation now builds the
  expected chunk as binary/iodata instead of enumerating every byte in Elixir.
  The same local MOQX-client run then reached about 844 Mbps with strict-valid
  records. A local reference-client-to-reference-server control on the same
  quicprobe server reached about 747 Mbps, and MOQX-client with detailed
  `event` diagnostics reached about 594 Mbps. The next required proof is an
  ARM same-region rerun against the #33 bracket.
- 2026-05-27 ARM same-region rerun
  `20260527T154046Z-issue-37-final` closed the issue. The run used disposable
  `cax11` nodes in `nbg1 -> nbg1` over the private path
  `10.88.0.11 -> 10.88.0.12`, matching the #33 topology. iperf3 established a
  comparable raw path: 6.59 Gbps TCP, 100 Mbps UDP at 100%, 500 Mbps UDP at
  99.71%, and 1 Gbps UDP at 98.25%. Reference-client-to-reference-server
  reached about 472.5/730.2/816.9 Mbps at 4/8/16 bidirectional streams.
  MOQX-client-to-reference-server with `--stream-diagnostics-sampling final`
  reached about 440.9/505.5/521.8 Mbps at 4/8/16 streams, versus #33's
  72.2/61.7/53.6 Mbps. All MOQX sends completed with zero pending
  completions and final mailbox depth 3/3/4. p99 latency improved from
  530 ms/1.24 s/2.86 s in #33 to about 85/149/291 ms. The original bottleneck
  was therefore benchmark-side observer/validation overhead. The remaining
  gap versus reference at 8 and 16 streams is a new optimization target, not
  the #37 bug. Artifacts are under
  `bench/transport/results/20260527T154046Z-issue-37-final/`. Infrastructure
  was destroyed and verified clean.
