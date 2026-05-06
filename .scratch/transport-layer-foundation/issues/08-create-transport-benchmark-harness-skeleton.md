# Create transport benchmark harness skeleton

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Create the dedicated transport research harness structure for measuring raw transport performance and limits outside the normal test suite.

The harness should establish conventions for standalone Elixir scripts that use `Mix.install([])`, metric reporting, and repeatable benchmark execution.

## Acceptance criteria

- [ ] A benchmark directory exists for transport research.
- [ ] A README explains the purpose of the harness and states that it is not part of normal tests.
- [ ] The README defines expected metrics such as handshake latency, throughput, first-byte latency, datagram rate/loss, concurrent streams, memory, and mailbox growth.
- [ ] The README explains the benchmark matrix: raw baseline, MOQX self-pair, our client to reference server, reference client to our listener, and optional reference-to-reference.
- [ ] Script conventions use standalone Elixir scripts with `Mix.install([])`.
- [ ] No benchmark-only dependencies are added to the library dependency graph.

## Blocked by

None - can start immediately

## Comments
