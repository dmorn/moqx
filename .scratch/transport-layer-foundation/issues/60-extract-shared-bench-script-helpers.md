# Extract the remaining duplicated bench-script helpers

Status: ready-for-agent
Type: enhancement
Category: tooling

## Parent

`.scratch/transport-layer-foundation/issues/54-add-layered-benchmark-evidence-contract.md`

## Why this is needed

`bench/stream_clients.exs`, `bench/paced_stream.exs`, and
`bench/datagram_clients.exs` still duplicate several verbatim (or near-verbatim)
helpers. The CLI/format helpers were already centralized in
`MOQXProbe.BenchCLI`, but these larger ones remain copied across scripts:

- **quicprobe experiment-lease** acquire/release (stream + paced; ~50 lines).
- **quicprobe evidence URL** builder (`quicprobe_evidence_url/2` +
  default) (all three).
- **delivery-evidence writing** (`write_evidence!/1`) (stream + datagram).
- **Benchee evidence hooks** (`maybe_put_evidence_hooks`, `evidence_before_each`,
  `evidence_after_each*`) (stream + datagram).

## What to build

Extract these into shared, unit-testable modules (e.g.
`MOQXProbe.Benchee.Quicprobe` for lease + evidence URL, and a small evidence-hook
builder), parameterizing the small per-script differences (owner/metadata,
input shape) rather than copying. The scripts call the shared module.

## Acceptance criteria

- [ ] Lease acquire/release, evidence URL, evidence writing, and Benchee
      evidence hooks live in shared modules; the three scripts call them.
- [ ] No behaviour change: each script still runs `--target fake` and its
      `--help`, and a loopback/quicprobe run still produces valid evidence.
- [ ] All gates green (mix format/test/credo; the scripts load without
      warnings).

## Non-goals

- Changing the measurement semantics or evidence formats.
- The pre-existing base-script credo items (explicit `try` in `cleanup_run`,
  `apply/2` in `main`, single-branch `cond` in `quicprobe_evidence_url`, alias
  order) — address those opportunistically, not as a requirement.

## Notes

Filed from the 2026-07-02 codebase simplify pass, which centralized the CLI
helpers (BenchCLI floats + datagram alignment), deduped the paced drain loop,
and fixed a report double-sort, but deferred this larger cross-script
extraction because it touches three IO-heavy scripts that are not compile-gated
by `mix test` and each needs a smoke.
