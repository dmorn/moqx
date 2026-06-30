# Add coordinated-omission-corrected latency histogram to the paced sender

Status: ready-for-agent
Type: enhancement
Category: performance

## Parent

`.scratch/transport-layer-foundation/issues/54-add-layered-benchmark-evidence-contract.md`

## Related

- ADR-0009 (`docs/adr/0009-layered-benchmark-evidence-contract.md`) — open-loop
  mode and coordinated omission.
- Slice 4 of issue 54 — the open-loop paced sender, which records
  offered-vs-accepted and a coordinated-omission flag but does **not** yet
  correct latency.

## Why this is needed

Slice 4 makes coordinated omission *detectable*: the paced sender records
offered, accepted, backlog, and per-tick lag, and flags when it falls behind
its schedule. That tells us *whether* the measurement is coordinated-omitting,
but it does not yet produce a *trustworthy latency distribution* under load.

When a sender stalls on backpressure, the long latencies that should have been
recorded for the requests held back are simply missing. Gil Tene's correction
(record each sample with an expected interval, back-filling the omitted samples
the schedule implies) reconstructs the distribution the open-loop workload
actually experienced. Without it, p99/p99.9 latency under load is optimistic.

## What to build

1. Add a latency histogram to the paced sender output (HdrHistogram-style, or a
   bounded log-linear bucket histogram if a dependency is undesirable).
2. Implement record-with-expected-interval correction keyed off the paced
   schedule, so omitted samples are back-filled when the sender runs behind.
3. Emit corrected and uncorrected percentile sets side by side so the gap is
   visible, not hidden. Name them explicitly per ADR-0009 (window + tier).
4. Tie the correction to the coordinated-omission flag the slice-4 sender
   already records.

## Acceptance criteria

- [ ] The paced sender emits a latency histogram with explicit percentiles
      (at least p50/p90/p99/p99.9).
- [ ] Both coordinated-omission-corrected and uncorrected percentiles are
      reported, clearly labelled.
- [ ] The correction uses the paced schedule's expected interval.
- [ ] Metric names follow ADR-0009 (source layer, window, confidence tier).

## Non-goals

- Replacing Benchee's closed-loop service-time stats.
- A generic histogram/dashboard library.

## Notes

Deferred deliberately from slice 4 to keep that slice an honest "detect only"
step. The correction math is easy to get subtly wrong, so it deserves its own
slice and its own verification.
