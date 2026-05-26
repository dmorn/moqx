# Fix MOQX client bidirectional stream pressure

Status: ready-for-agent
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
- [ ] The root cause of the four/eight-stream stall is identified: receive
      collection, FIN ordering, peer echo semantics, stream scheduling, or
      transport API behavior.
- [ ] After the fix, the ARM bidirectional bracket is rerun and #12 is updated
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
