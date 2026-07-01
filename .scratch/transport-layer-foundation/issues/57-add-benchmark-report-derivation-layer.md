# Add benchmark report/derivation layer over the evidence contract

Status: done
Type: enhancement
Category: performance

## Parent

`.scratch/transport-layer-foundation/issues/54-add-layered-benchmark-evidence-contract.md`

## Related

- ADR-0009 (`docs/adr/0009-layered-benchmark-evidence-contract.md`) — the
  measurement contract this layer consumes.
- Issue 56 — coordinated-omission-corrected latency histogram (a derivation
  this layer will surface once available).

## Why this is needed

Issue 54 landed the raw evidence layers (quicprobe interval bins, the BEAM/host
sampler, the open-loop paced sender with offered-vs-accepted, and the run
manifest) but deliberately stopped at RAW counts. Nothing yet turns those raw
sidecars into the derived, comparison-ready numbers a human actually reads, and
nothing enforces ADR-0009's naming/mode/tier discipline at report time.

Today a reader still has to hand-derive rates from bins and denominators, and a
number can be quoted without its mode/tier — exactly the "we can't trust the
numbers" trap ADR-0009 was written to close. The contract exists; the reader on
top of it does not.

## What to build

A report/derivation layer that consumes a run's manifest + sidecars and emits a
`report.md` (and optionally a machine-readable summary) under the run bundle:

1. Derive rates from raw evidence with EXPLICIT names and windows per ADR-0009:
   `receiver_payload_goodput_active_bps`,
   `receiver_payload_goodput_interval_p95_bps` (from quicprobe interval bins and
   the first/last timestamps), `client_payload_goodput_sender_active_bps`,
   `stream_payload_events_per_second`, `datagrams_received_per_second`. Never
   emit a naked `bandwidth`/`goodput` or a stream `pkts/s`.
2. Respect the interval-bin caveats recorded on issue 54: the final
   cap-folded bin's effective window is not `bin_width_ms`, and the two datagram
   clocks have different origins.
3. Enforce ADR-0009 cross-mode/tier discipline: refuse (hard error) forbidden
   metric names; warn (soft) when a closed-loop number is presented against a
   `remote_quic_*` tier or when numbers from different modes are placed in one
   comparison. Carry the confidence tier on every derived number.
4. Compare receiver-derived goodput against the iperf3 path baseline only when
   target and path are explicit, labelling the baseline used.
5. Fold in the coordinated-omission flag (and, once issue 56 lands, corrected
   latency percentiles), so a report cannot present latency under an
   unsustained offered rate without the correction/flag visible.
6. Keep the derivation PURE and unit-tested (a module taking parsed
   manifest+sidecars and returning the report data), with the script/CLI as a
   thin shell — mirroring RunManifest/Pacer/Accounting.

## Acceptance criteria

- [x] A pure, unit-tested derivation module turns manifest + sidecars into
      named derived metrics with explicit windows and confidence tier.
- [x] Derived metric names follow ADR-0009; forbidden names are rejected and
      cross-mode/remote-tier misuse is warned.
- [x] Interval-derived rates honor the cap-folding and dual-clock caveats.
- [x] iperf3 baseline comparison is emitted only with explicit target/path.
- [x] A `report.md` is produced under the run bundle and linked from the
      manifest sidecar map.

## Non-goals

- A live dashboard, Prometheus/StatsD export, or a daemon (ADR-0009 non-goals).
- Re-deriving latency correction here — that math lives in issue 56.
- Changing the raw evidence formats from issue 54.

## Notes

Filed as the natural successor to issue 54: the contract and raw evidence exist;
this is the reader that makes the numbers trustworthy and comparison-safe.

## Comments

### 2026-07-01 — Implemented

- `lib/moqxprobe/report.ex` (pure) + `test/moqxprobe/report_test.exs` (14
  tests): derives `receiver_payload_goodput_active_bps` (distribution over the
  receiver-active window), `receiver_payload_goodput_interval_p95_bps` (pooled
  per-bin), `client_payload_goodput_sender_active_bps`, and
  `datagrams_received_per_second`. `build_metric/1` rejects forbidden names;
  closed-loop + `remote_quic_*` and coordinated omission raise warnings; the
  cap-folding and dual-clock caveats are honored; iperf3 utilization only with
  an explicit target.
- `bench/report.exs`: reads a run bundle, writes `report.md`, links it in the
  manifest's new `report` sidecar slot (`RunManifest`).
- Smoke: ran on two real reform bundles (closed + open) and one fresh loopback
  bundle with real interval bins (receiver goodput median ~1.38 Gbps, p95
  1.63 Gbps over n=67; interval p95 75.5 Mbps — the two windows correctly
  reported apart).
- Adversarial review caught and fixed: iperf3 baseline read string keys but
  `RunMetadata` returns atom keys (baseline was silently dead); a `put_in`
  crash when a manifest lacks `sidecars`; and a `format_number` catch-all that
  could raise on a non-scalar.

Deferred: coordinated-omission-corrected latency percentiles (issue 56).
