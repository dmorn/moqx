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

## What to build (sketch)

A way to correlate a sent payload with its receiver-side arrival time, then
report end-to-end delivery latency percentiles (corrected for coordinated
omission the same way as issue 56). Options to evaluate:

- Per-object receive timestamps in quicprobe (extend `server_run_evidence` /
  interval evidence with per-object or per-stream arrival times) and a
  correlation key (e.g. an object/sequence id carried in the payload).
- A bidirectional/echo profile where the sender times the round trip and halves
  it (cruder; conflates both directions).

Prefer the receiver-timestamp approach; it needs a quicprobe change and a payload
correlation id, so it is a distinct, larger slice than issue 56.

## Non-goals

- Replacing the sender-completion latency from issue 56.
- Packet-level (qlog/pcap) timing — that is the wire-evidence tier.

## Notes

Filed as the deferred follow-up when issue 56's scope was narrowed to
sender-observable completion latency (2026-07-01). Left `needs-triage` because
the receiver-side correlation design is not yet settled.
