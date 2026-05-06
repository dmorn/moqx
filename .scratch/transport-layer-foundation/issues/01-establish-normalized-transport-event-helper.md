# Establish normalized transport event helper

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Define the normalized event consumption path for transport users so protocol code can receive `MOQX.Transport.event()` values without pattern-matching raw backend messages.

The slice should make the helper-based model from ADR-0001 concrete and documented, while keeping the implementation lightweight enough to evolve into a router process later if needed.

## Acceptance criteria

- [ ] A public helper exists for receiving/normalizing transport events from a configured transport implementation.
- [ ] The helper returns normalized transport events, `:unknown`, or a timeout result with documented semantics.
- [ ] Transport documentation states that protocol code must not match raw `quicer` messages directly.
- [ ] Tests cover known message normalization and timeout/unknown-message behavior.
- [ ] The design does not require introducing a dedicated transport-router process.

## Blocked by

None - can start immediately

## Comments
