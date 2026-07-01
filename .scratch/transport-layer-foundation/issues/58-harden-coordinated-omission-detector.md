# Harden the open-loop coordinated-omission detector

Status: done
Type: enhancement
Category: performance

## Parent

`.scratch/transport-layer-foundation/issues/54-add-layered-benchmark-evidence-contract.md`

## Related

- ADR-0009 (open-loop mode, coordinated omission).
- Issue 56 (corrected latency histogram) — depends on a trustworthy detector.
- `MOQXProbe.OpenLoop.Accounting` (the current detector).

## Why this is needed

The first real reform measurement session (2026-07-01, ~90 Mbps path) exposed
two failure modes in the current sender-schedule-lag coordinated-omission (CO)
detector. The detector trips when `tick_lag_ms` stays above `--sustained-lag-ms`
for `--sustained-lag-ticks` consecutive ticks.

Observed on a rate sweep (16 streams, 1180 B, tick-ms 1, defaults
sustained-lag-ms 5, sustained-lag-ticks 10):

| offered ev/s | ~Mbps | delivery | drained/accepted | CO flag |
| --- | --- | --- | --- | --- |
| 5000 | 47 | valid | 20000/20000 | **true** (max lag 33 ms) |
| 8000 | 75 | valid | 32000/32000 | false |
| 10000 | 94 | valid | 40000/40000 | false |
| 12000 | 113 | **invalid** | 44448/48000 | **false** |
| 15000 | 141 | invalid | 44081/60000 | true |

Two problems:

1. **False positive at low rate (5000).** The path was only ~50% utilized and
   delivery was perfect, yet CO tripped — because connection setup / TLS / first
   sends produce a burst of tick lag at the very start of the run. With
   `tick_ms 1` and `sustained_lag_ticks 10`, a 10 ms startup hiccup trips it.

2. **False negative at moderate overload (12000).** Offered rate (113 Mbps) was
   well over the ~90 Mbps path ceiling and delivery clearly broke
   (`drained_completions 44448 < accepted 48000`, receiver evidence invalid),
   yet CO stayed **false**: the QUIC sender admits sends into its send buffer
   without blocking, so `tick_lag_ms` stayed low even though the network could
   not carry the offered load. Sender-schedule lag is simply the wrong signal
   for a buffered sender until the buffer backs up.

## What to build

1. **Warmup exclusion.** Ignore the first N ticks (or first W ms) of the run
   when evaluating the lag streak, via a `--warmup-ms` / `--warmup-ticks` flag,
   so connection setup does not false-trip CO. Record the excluded window in
   the sidecar.
2. **Complement the lag signal with a completion-deficit signal.** Surface
   `send_completions_drain_total` vs `accepted_payload_events_sender_active_total`
   as an explicit overload indicator: a sustained/large deficit means the
   transport accepted sends it could not complete — the truer saturation signal
   on a buffered QUIC sender. Consider a `sender_completion_deficit_ratio` in
   the summary and a combined `saturated?` verdict distinct from the raw
   `tick_lag` CO flag.
3. **Keep the raw `tick_lag` CO flag** (it still catches the sender genuinely
   failing to keep schedule, e.g. 15000 above), but document that it is a
   sender-scheduling signal, not a delivery/saturation verdict.
4. The report layer (issue 57) should prefer the completion-deficit /
   delivery-validity signal for saturation statements and treat a warmup-only
   lag trip as non-saturating.

## Acceptance criteria

- [x] A warmup window excludes startup ticks from the lag-streak evaluation;
      the low-rate false positive no longer trips CO on a healthy run.
- [x] The summary exposes a completion-deficit signal that flags the moderate-
      overload case (accepted >> completed) that the lag flag misses.
- [x] The raw tick-lag CO flag and its meaning are documented as distinct from
      the delivery/saturation verdict.
- [x] Pure `Accounting` logic stays unit-tested for both new signals.

## Non-goals

- Corrected latency percentiles (issue 56).
- Changing the receiver-side evidence.

## Comments

### 2026-07-01 — Implemented and confirmed on reform

`MOQXProbe.OpenLoop.Accounting` gained a `warmup_ms` window (ticks below it are
excluded from the lag streak) and a post-run `saturated` verdict driven by the
**completion deficit** (`accepted_total - settled_completed_total` over
`--completion-deficit-threshold`, default 1%) or a backlog trip — distinct from
the raw `coordinated_omission` tick-lag flag, which is now documented as a
sender-scheduling signal only. Wired `--warmup-ms` (default 500) and
`--completion-deficit-threshold` into `paced_stream.exs`; the report layer keys
its saturation statement off `saturated` and demotes a lag-only trip to a
scheduling note. 6 new unit tests; all gates green.

Re-ran the reform open-loop sweep (16 streams, 1180 B, tick-ms 1) to confirm
trustworthiness — `saturated` now matches receiver delivery validity 1:1:

| offered ev/s | ~Mbps | deficit | saturated | delivery |
| --- | --- | --- | --- | --- |
| 5000 | 47 | 0% | false (was false-positive) | valid |
| 8000 | 75 | 0% | false | valid |
| 10000 | 94 | 0% | false | valid |
| 12000 | 113 | 8.0% | true (was false-negative) | invalid |
| 15000 | 141 | 26.6% | true | invalid |

The startup false-positive at 5000 is gone; 12000 is now correctly flagged via
completion deficit. The raw tick-lag CO flag stayed false at every rate — on a
buffered QUIC sender the schedule is met while the path drops the excess, which
is exactly why the deficit signal was needed.

## Notes

Filed from the first trustworthy reform measurement session, which was the
whole point of the evidence contract: the numbers were good enough to expose
that the CO detector both over- and under-reports depending on regime.
