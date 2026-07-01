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
- Issue 58 — the completion-deficit signal whose never-completed intents this
  issue back-fills into the corrected distribution.
- Issue 59 — true end-to-end delivery latency (the follow-up this issue defers).

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

## Scope (adjusted 2026-07-01)

The paced sender measures **no latency at all** today — it counts send
completions (`drain_completions`) but never times them. So this issue is two
jobs: *measure* latency, then *correct* it for coordinated omission.

Decisions:

- **Latency measured = send-completion latency**, the sender-observable time
  from when an intent was *scheduled* to when its `send_completed` arrives. On a
  buffered QUIC sender, admission latency (`send_stream` return) is ~0 even under
  overload and tick lag stays low, so completion latency is the signal that
  actually reflects backpressure.
- **True end-to-end delivery latency is out of scope** — it needs per-object
  receiver timestamps quicprobe does not emit. Tracked as a follow-up (issue 59).
- **Hand-rolled bounded log-linear histogram** (no new dependency), matching the
  pure-module pattern already used.
- **Coordinated-omission correction = measure from the scheduled time** (not the
  actual send time): a held-back intent's clock starts when it *should* have been
  sent, so the correction is by construction (Tene's record-with-expected-
  interval). Additionally, **back-fill never-completed intents** (the completion
  deficit from issue 58) with `run_end - scheduled` so the worst cases are not
  silently dropped from the corrected distribution.

## What to build

1. A pure `MOQXProbe.Histogram` (bounded log-linear, record/merge/percentile/
   summary) — unit-tested for percentile accuracy within tolerance.
2. A pure `MOQXProbe.OpenLoop.Latency`: per-stream FIFO of pending
   `{scheduled_ms, sent_ms}`; on completion, pop oldest and record **corrected**
   (`completed - scheduled`) and **uncorrected** (`completed - sent`); `finalize`
   back-fills still-pending intents into the corrected histogram
   (`run_end - scheduled`). Unit-tested for the FIFO correlation and back-fill.
3. Wire it into `paced_stream.exs`: stamp each offered intent, drain completions
   (bounded per tick + at settle) feeding the latency collector, finalize at run
   end, and merge corrected/uncorrected percentiles into the paced summary.
4. Report layer (issue 57): surface corrected and uncorrected percentiles side
   by side with explicit ADR-0009 names (source layer + window + tier).

## Acceptance criteria

- [ ] The paced sender emits send-completion latency percentiles (p50/p90/p99/
      p99.9), corrected and uncorrected, clearly labelled.
- [ ] The correction measures from each intent's scheduled time and back-fills
      never-completed intents, so the corrected tail reflects the stalls.
- [ ] Metric names follow ADR-0009 (source layer, window, confidence tier).
- [ ] Histogram and latency-correlation logic are pure and unit-tested.
- [ ] A reform open-loop check shows corrected p99 markedly above uncorrected
      p99 under saturation, and both modest below the knee.

## Non-goals

- Replacing Benchee's closed-loop service-time stats.
- A generic histogram/dashboard library.
- True end-to-end delivery latency (issue 59).

## Notes

Deferred deliberately from slice 4 to keep that slice an honest "detect only"
step. The correction math is easy to get subtly wrong, so it deserves its own
slice and its own verification.
