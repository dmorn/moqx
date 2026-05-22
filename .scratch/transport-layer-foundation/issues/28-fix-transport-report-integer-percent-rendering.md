# Fix transport report integer percent rendering

Status: needs-triage
Type: Bug

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## Problem

`moqx-transport-bench report` can crash while rendering valid benchmark JSONL
when a percentage field is encoded as an integer, for example
`datagram_delivery_ratio: 1`.

## Evidence

- 2026-05-22: `moqx-transport-bench report
  results/20260522T125804Z-arm-remote-test/reference-dgram-combined.jsonl
  --strict` crashed with:
  `ArgumentError` from `:io_lib.format("~.2f%", ~c"d")` in
  `MOQX.TransportBench.Report.percent/1`.
- The same seven-record JSONL file passed contract validation through
  `MOQX.TransportBench.Contract.validate_records/1` with `valid?: true` and no
  errors.
- The triggering records came from valid paced DATAGRAM runs where delivery was
  exactly `1`, encoded by JSON as an integer.

## Acceptance criteria

- [ ] `moqx-transport-bench report` renders integer and float percentage values
  without crashing.
- [ ] Report tests cover `datagram_delivery_ratio: 1` and another integer-like
  percentage field if present.
- [ ] Strict report validation still fails for truly invalid contract records.
