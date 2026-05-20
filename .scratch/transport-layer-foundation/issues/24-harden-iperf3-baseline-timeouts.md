# Harden iperf3 baseline timeout and failure handling

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Make `moqx-transport-bench iperf3-baseline` resilient when the caller provides
an unreachable endpoint or a path that silently drops TCP/UDP traffic.

The command currently shells out to `iperf3` without a caller-visible timeout.
During the Hetzner smoke run `20260520T134420Z-smoke`, a private-path attempt
to `10.88.0.12:55201` hung until manually interrupted because the server's
private interface was down.

## Acceptance criteria

- [ ] Each `iperf3` step has a configurable timeout greater than its requested
      duration.
- [ ] A timed-out `iperf3` process is terminated and does not leave child
      processes running.
- [ ] Timeout/failure is emitted as a valid `transport-bench-v1` JSONL record
      with clear `limits` and `errors` fields.
- [ ] The report command renders timed-out steps clearly.
- [ ] Tests cover a fake or controlled `iperf3` command that exceeds the
      timeout.
- [ ] Documentation explains how timeout values relate to TCP/UDP step
      duration.

## Blocked by

None.

## Context

This is not a throughput feature. It is operator safety for bad-path smoke
tests and future reference-comparison experiments.

The first implementation should stay local to the benchmark subproject. Do not
add retry orchestration, Terraform coupling, or global configuration.

## Comments

- 2026-05-20: Created from Hetzner smoke `20260520T134420Z-smoke`. The public
  IPv4 baseline completed, but the failed private-path attempt showed that an
  unreachable path can hold the runtime CLI until the operator interrupts it.
