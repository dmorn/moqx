# Model draft_14 and moq_lite_04 transport profiles

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add lightweight transport-profile fixtures or helpers that express what MOQT
draft-14 and MOQ Lite 04 need from the generic transport layer, without
implementing either full protocol.

These profiles should be used to prove the support transport and contract tests do not accidentally bake in a single protocol's assumptions.

## Acceptance criteria

- [x] A `:draft_14` profile configures native QUIC ALPN `moq-00`, datagram availability, one client-initiated bidirectional control stream expectation at the protocol-test level, and unidirectional data stream support.
- [x] A `:moq_lite_04` profile configures ALPN `moq-lite-04`, no datagrams, many bidirectional transaction streams, and unidirectional group stream support.
- [x] Tests demonstrate the transport layer supports both profiles without changing transport implementation code.
- [x] Tests cover at least draft-14 and MOQ Lite capability profiles in the support transport.
- [x] Draft-specific stream validation is kept outside the transport implementation.
- [x] Profile documentation clarifies that these are contract fixtures, not full protocol implementations.

## Blocked by

None - issues 13, 04, and 05 are closed.

## Progress

The support-transport-specific capability-profile criterion was moved here from issue 13 after issue 13 delivered the production capability surface in commit `746257a`.

Issue 03 added support transport profile coverage for draft-14 and MOQ Lite
capabilities. Issues 04, 05, and 13 are now closed, so the remaining profile
fixture/documentation work is structurally unblocked.

Implemented by:

- `MOQX.Transport.Profile`
- `test/moqx/transport/profile_test.exs`
- support-transport profile lookup through `MOQX.Transport.Profile`
- `CONTEXT.md`, `bench/transport/README.md`, and ADR-0001 documentation updates

Validation:

- `mix test test/moqx/transport/profile_test.exs test/moqx/transport/support_test.exs test/moqx/transport_test.exs test/moqx/transport/support_contract_test.exs`
- `mix format`
- `mix test`
- `mix credo --strict`

## Comments

- 2026-05-19: Marked ready after stale blockers were cleared. This can be
  implemented before or alongside issue 10 because the self-pair calibration
  benchmark needs the same `:draft_14` and `:moq_lite_04` profile vocabulary.
- 2026-05-19: Closed with canonical profile names `:draft_14` and
  `:moq_lite_04`. `:moq_lite_04` is versioned because the bare-QUIC ALPN is
  `moq-lite-xx`, and draft 04 currently maps to `moq-lite-04`.
