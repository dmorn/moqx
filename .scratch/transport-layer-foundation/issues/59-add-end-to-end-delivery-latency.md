# Add true end-to-end delivery latency to the open-loop measurement

Status: needs-triage
Type: enhancement
Category: performance

## Parent

`.scratch/transport-layer-foundation/issues/54-add-layered-benchmark-evidence-contract.md`

## Related

- Issue 56 — send-completion latency (sender-observable), which this extends to
  the receiver side.
- ADR-0009 — receiver-evidence layer.

## Why this is needed

Issue 56 measures **send-completion** latency: scheduled time → the sender's
`send_completed` (QUIC send-buffer / flow-control credit). That reflects
sender-side backpressure, but it is not what an application experiences —
**end-to-end delivery latency** is scheduled time → the byte arriving at the
receiver. On a buffered path the two diverge exactly when it matters (the send
buffer drains while bytes are still in flight or queued on the wire).

## Design (2026-07-01)

**The clock problem is decisive.** Sender (silver) and receiver (reform) clocks
are not synchronized, so absolute one-way latency `arrival - send` carries an
unknown constant offset θ and cannot be reported as-is. The honest,
clock-offset-free metric is **delivery delay above the run minimum**: θ cancels
when we subtract the run's minimum `arrival - send`, leaving the path/queueing
delay each object actually experienced (≈ 0 when healthy, large under
saturation). No NTP/PTP dependency.

Mechanism (fixed-size object framing on the existing stream workload):

- **Sender** (`paced_stream.exs`): embed an 8-byte send timestamp
  (`System.os_time(:nanosecond)`) as the first bytes of each fixed-size payload.
  Total bytes per send are unchanged, so delivery-evidence reconciliation holds.
- **quicprobe** (`--object-size N`): chunk each uni-stream's bytes into N-byte
  objects (the stream is a concatenation of equal-size payloads, in order), read
  the embedded send timestamp from each object's first 8 bytes, and record
  `arrival_ns - send_ns` into a bounded histogram. Report `object_count` and the
  delivery-delay distribution (min + p50/p90/p99, all including θ) in
  `server_run_evidence`.
- **Report** (`MOQXProbe.Report`): compute delay-above-min = `pXX - min` and
  surface it as `object_delivery_delay_above_min_ms` (receiver, e2e), with an
  explicit note that absolute one-way latency is not recoverable without clock
  sync.

This keeps the established uni-stream sweep workload (no one-stream-per-object
change) so results stay comparable across issues 56/58/59.

## Non-goals

- Replacing the sender-completion latency from issue 56.
- Packet-level (qlog/pcap) timing — that is the wire-evidence tier.

## Notes

Filed as the deferred follow-up when issue 56's scope was narrowed to
sender-observable completion latency (2026-07-01). Left `needs-triage` because
the receiver-side correlation design is not yet settled.
