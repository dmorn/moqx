# Fix MOQX client bidirectional stream pressure

Status: closed
Type: Bug

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## Problem

The `moqx-client-to-reference-server` reference-comparison topology does not
survive real-path concurrent bidirectional echo pressure. It is correct at one
and two streams, but stalls at four and eight streams and crashes at higher
stream counts when the echo receive path observes a closed stream.

This blocks closing the #12 stream-pressure matrix because the reference path
and the MOQX unidirectional stream path both show the controlled ARM private
link can carry much more traffic than the MOQX bidirectional client result.

## Evidence

- 2026-05-22: ARM private-path run `20260522T141346Z-strm` used disposable
  Hetzner `cax21` nodes from `fsn1` to `nbg1` over
  `10.88.0.11 -> 10.88.0.12`, MTU 1450. Private readiness passed with 0%
  ping loss and about 3.8 ms average RTT. The iperf3 baseline reported 4.25
  Gbps TCP goodput and 100 Mbps UDP with 100% delivery.
- Reference-client-to-reference-server scaled on the same path: one
  bidirectional stream reached 107 Mbps, 16 reached 769 Mbps, 64 reached 843
  Mbps, and 64 unidirectional streams reached 1.36 Gbps.
- MOQX-client-to-reference-server bidirectional echo reached only 24.48 Mbps
  with one stream and 25.00 Mbps with two streams.
- The same topology timed out at four and eight bidirectional streams with
  `reference comparison step timed out after 150s`.
- The same topology crashed at 16 and 64 bidirectional streams with
  `reference_comparison_nonzero_exit`; the error begins with
  `** (MatchError) no match of right hand side value:` and the failing receive
  branch saw a closed stream.
- MOQX-client-to-reference-server with 64 unidirectional streams reached 851.82
  Mbps on the same run, so the issue is specific to bidirectional echo
  feedback or concurrent bidirectional stream bookkeeping, not to all stream
  sends.

Artifacts are under
`bench/transport/results/20260522T141346Z-strm/`:

- `stream-combined.jsonl`
- `stream-m2r-bidi-bracket.jsonl`

## Acceptance criteria

- [x] The failure is reproducible with a focused local or controlled-path test
      for `reference-comparison --topology moqx-client-to-reference-server`
      using at least four bidirectional streams.
- [x] Closed stream events in the echo receive path are handled explicitly and
      never crash the benchmark with a `MatchError`.
- [x] Timeout, closed-stream, or protocol-error outcomes still emit
      contract-valid `transport-bench-v1` records with useful `limits` and
      `errors` fields.
- [x] The root cause of the four/eight-stream stall is identified: receive
      collection, FIN ordering, peer echo semantics, stream scheduling, or
      transport API behavior.
- [x] After the fix, the ARM bidirectional bracket is rerun and #12 is updated
      with the new evidence.

## Notes

- Preserve the async stream-send model. The benchmark needs application-level
  echo feedback for delivery evidence, but it must not turn that feedback into
  serial send admission.
- Keep this in the benchmark/reference-comparison layer unless the root cause
  proves to be a `MOQX.Transport` contract bug.

## Comments

- 2026-05-22: Local diagnosis reproduced the original crash shape with
  `reference-comparison --topology moqx-client-to-reference-server` and four
  bidirectional streams: the benchmark matched on `{:ok, data, ctx}` from
  `Transport.recv_stream/3`, but quicer can return peer close signals such as
  `{:error, :peer_send_shutdown, ctx}` or `{:error, :closed, ctx}`. The first
  fix turns those into contract-valid benchmark records with structured
  stream diagnostics instead of a `MatchError`.
- 2026-05-22: The benchmark now collects MOQX bidirectional echo pressure
  through active transport events rather than passive `recv_stream/3`. This
  lets the loop observe echo bytes, send completions, send cancellations, peer
  FIN, timeout phase, per-stream byte counts, and mailbox depth in one place.
  The send side remains async and uses a bounded per-stream send window so the
  benchmark applies pressure through completion feedback instead of enqueueing
  the entire stream body blindly.
- 2026-05-26: Clean loopback validation against a freshly started
  `tools/quicprobe server` on port 4444 passed for
  MOQX-client-to-reference-server bidirectional echo with 1000 payloads of
  1200 bytes per stream. The repo-local `.tmp/integration-certs` server
  certificate had expired on 2026-05-25, so this rerun used a throwaway
  `/tmp/moqx-29-certs` CA/certificate pair. Four streams echoed 4.8 MB at
  about 161 Mbps, eight streams echoed 9.6 MB at about 157 Mbps, and 16
  streams echoed 19.2 MB at about 137 Mbps. Diagnostics reported all streams
  completed, zero failed streams, full payload acceptance, and low mailbox
  depth for all three runs. All emitted strict-valid `transport-bench-v1`
  records with no break symptom. This is loopback calibration only; #29 still
  needs the ARM bidirectional bracket rerun before it can be closed against the
  original real-path evidence.
- 2026-05-26: A controlled ARM rerun was attempted with run id
  `20260526T075945Z-issue-29-bidi` after committing the active-event fix.
  Hetzner returned `resource_unavailable` during server placement for the
  available EU ARM combinations tried: `arm-smoke` (`cax21`, `fsn1 -> nbg1`),
  `arm-low-rtt` (`cax31`, `fsn1 -> nbg1`), `arm-nbg1-hel1` (`cax31`,
  `nbg1 -> hel1`), `arm-nbg1-hel1-stress` (`cax41`, `nbg1 -> hel1`), and
  `arm-nbg1-hel1-tiny` (`cax11`, `nbg1 -> hel1`). Each partial apply was
  destroyed immediately and `bench-transport-verify-clean` confirmed no
  Terraform state entries or labelled Hetzner resources remained. No remote
  benchmark evidence was captured in this attempt.
- 2026-05-26: Remote ARM rerun succeeded after preserving partial resources
  and switching this round to a same-region private path because `fsn1` and
  `hel1` ARM placement kept returning `resource_unavailable`. The measured
  path was disposable Hetzner `cax21` nodes in `nbg1 -> nbg1`,
  `10.88.0.11 -> 10.88.0.12`, using deployed
  `moqx-transport-bench`/`quicprobe` artifacts from git `7b63f0a`.
  Manual private readiness passed with 0% ping loss and about 1.45 ms average
  RTT. The structured iperf3 baseline reported 6.85 Gbps TCP, 100 Mbps UDP
  with 100% delivery, 500 Mbps UDP with 99.96% delivery, and 1 Gbps UDP with
  99.63% delivery.
- 2026-05-26: The fixed MOQX-client bidirectional bracket is now remote-valid
  for the original failure shape. Against the reference `quicprobe` server on
  the same private path, all MOQX-client runs completed with full echoed byte
  counts, no timeout, no nonzero exit, no closed-stream crash, and no break
  symptom: four streams echoed 4.8 MB at about 78.64 Mbps with p99 latency
  about 487 ms; eight streams echoed 9.6 MB at about 69.72 Mbps with p99 about
  1.10 s; 16 streams echoed 19.2 MB at about 60.79 Mbps with p99 about
  2.52 s. The reference-client-to-reference-server control on the same path
  reached about 541/844/932 Mbps at 4/8/16 streams with p99 latency about
  70/91/164 ms. The root cause for #29 was therefore the benchmark's previous
  passive/serial echo collection and closed-stream event handling, not a
  QUIC-link break. The remaining large MOQX throughput and latency gap is a
  separate performance/observability follow-up, not this correctness bug.
  Canonical artifacts are under
  `bench/transport/results/20260526T075945Z-issue-29-bidi/`, especially
  `iperf3-baseline-private.jsonl` and
  `reference-comparison-stream-private.jsonl`. Infrastructure was still
  intentionally running at the time this note was written.
