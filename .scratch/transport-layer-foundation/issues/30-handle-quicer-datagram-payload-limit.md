# Handle quicer DATAGRAM payload-size limit

Status: closed
Type: Bug

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## Problem

The benchmark and transport path do not handle the effective QUIC DATAGRAM
payload-size limit cleanly.

On the controlled Hetzner ARM path, `MOQX.Transport.Quicer` accepts and echoes
1192-byte DATAGRAM payloads, but returns
`{:dgram_send_error, :invalid_parameter}` at 1193 bytes and above. The current
benchmark code treats that return as an unexpected shape and emits a
`MatchError`-backed protocol-error record. Those records are contract-valid,
but they are not operationally clean: they obscure the real send error and can
lose the configured datagram size/rate metadata.

This blocks clean near-MTU DATAGRAM capacity claims for #12 until the harness
can report the transport limit directly.

## Evidence

- 2026-05-26: Same-region Hetzner ARM run
  `20260526T075945Z-issue-29-bidi` used disposable `cax21` nodes in
  `nbg1 -> nbg1` over the private path `10.88.0.11 -> 10.88.0.12`. The
  infrastructure was destroyed after artifact capture, and
  `just bench-transport-verify-clean` reported no remaining Terraform state or
  labelled Hetzner resources.
- The reference `quicprobe` client/server handled 1200-byte DATAGRAM paced
  steps at 5k/10k/20k pps with 100% delivery and zero drops, so the path and
  reference peer were not the first limit.
- MOQX-client-to-reference-server at 1200 bytes failed immediately with
  `{:dgram_send_error, :invalid_parameter}` wrapped in a benchmark
  `MatchError`.
- Reference-client-to-MOQX-listener at 1200 bytes logged
  `{:dgram_send_error, :invalid_parameter}` on the listener echo path.
- A focused MOQX-client size probe showed 1000, 1100, 1150, 1180, 1190, and
  1192-byte payloads delivered 100%; 1193, 1194, 1195, 1196, and 1200-byte
  payloads failed with the same `:invalid_parameter` send error.
- The valid near-limit 1192-byte paced sweep showed:
  reference-to-reference 5k/10k/20k pps delivered 100%;
  MOQX-client-to-reference-server delivered 100% at 5k/10k pps and first lost
  at 20k pps; reference-client-to-MOQX-listener delivered 100% at 5k pps and
  first lost at 10k pps.

Artifacts are under
`bench/transport/results/20260526T075945Z-issue-29-bidi/`:

- `measure-datagram-client-private.jsonl`
- `measure-datagram-listener-private-isolated.jsonl`
- `measure-datagram-size-probe-private.jsonl`
- `measure-datagram-size-probe-boundary-private.jsonl`
- `measure-datagram-1192-client-private.jsonl`
- `measure-datagram-1192-listener-private.jsonl`
- `moqx-listener-isolated-dgram-s1200-r*.log`

## Acceptance criteria

- [x] MOQX DATAGRAM send errors are handled explicitly in
      `moqx-transport-bench measure`; no `MatchError` is emitted
      for `{:dgram_send_error, reason}`.
- [x] Failure records preserve the caller-requested datagram size, target rate,
      duration, offered load, and topology even when the first send fails.
- [x] The benchmark or transport layer documents the effective max DATAGRAM
      payload-size behavior, or exposes enough capability metadata for callers
      to choose a valid size before running a pressure step.
- [x] #12 uses 1192 bytes as the current near-limit MOQX DATAGRAM payload until
      the transport capability surface says otherwise.
- [x] Tests cover both a successful near-limit DATAGRAM path and an explicit
      send-error path without using `Application` env as a seam.

## Notes

- Do not assume 1192 is universal across all peers and paths. Treat it as the
  observed limit for the current quicer/MSQUIC path until the transport exposes
  negotiated capability data.
- Keep this separate from performance optimization. This issue is about
  correctness of capability handling and benchmark reporting.

## Comments

- 2026-05-26: Fixed in the benchmark layer with a TDD slice against
  `MOQX.TransportBench.Measure.main/2` and explicit transport
  backend seams. MOQX-client DATAGRAM send errors now produce a structured
  `datagram_failure` measurement, `limits.first_break_symptom` and
  `limits.stopped_by` are `datagram_send_error`, and `errors.message` is a
  clean `moqx datagram send failed: <reason>` instead of a `MatchError`
  traceback. Failure records preserve requested datagram size, target rate,
  target duration, offered load, topology, offered count, accepted count, and
  failing sequence in `errors.details`.
- 2026-05-26: Added regression coverage for both sides of the observed limit:
  a successful 1192-byte MOQX DATAGRAM echo path and an explicit 1193-byte
  send-error path. The tests use explicit transport backend modules and do not
  rely on `Application` environment as a seam. The benchmark README now
  documents 1192 bytes as the current near-limit MOQX/quicer DATAGRAM payload
  size until negotiated capability metadata exists.
