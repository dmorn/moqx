# Issue #7 Implementation Plan

Goal: implement raw transport-level fetch support for real-relay interoperability.

Scope boundary for this plan:

- Add public `MOQX.fetch/4`
- Add public `MOQX.fetch_catalog/2`
- Deliver raw fetch object payload bytes to Elixir
- Support catalog retrieval as raw UTF-8 JSON CMSF bytes
- Do **not** implement CMSF parsing or track discovery here; that is issue #8

## Message contract

Fetch requests must deliver mailbox messages in this shape:

- `{:moqx_fetch_started, ref, namespace, track_name}`
- `{:moqx_fetch_object, ref, group_id, object_id, payload}`
- `{:moqx_fetch_done, ref}`
- `{:moqx_fetch_error, ref, reason}`

## Phase 1 — Elixir API shell and validation

Status: done

Files:

- `lib/moqx.ex`
- `lib/moqx/native.ex`
- `test/moqx_test.exs`

Tasks:

- [x] Add fetch-related types to `lib/moqx.ex`
  - `fetch_ref`
  - `fetch_group_order`
  - `fetch_location`
  - `fetch_opt`
  - `fetch_message`
- [x] Add `MOQX.fetch/4`
- [x] Add `MOQX.fetch_catalog/2`
- [x] Add Elixir-side option validation helpers for:
  - `priority` in `0..255`
  - `group_order` in `:original | :ascending | :descending`
  - `start` as `{group_id, object_id}`
  - `end` as `{group_id, object_id}`
  - range ordering `end >= start`
- [x] Enforce subscriber-only fetch usage at the Elixir layer
- [x] Return `{:ok, ref}` on successful fetch submission
- [x] Add NIF stub for `fetch/8` in `lib/moqx/native.ex`
- [x] Add unit tests for API visibility and validation in `test/moqx_test.exs`

Exit criteria:

- Public API is present and documented in code
- Invalid fetch opts fail before reaching native code
- Tests cover validation behavior

## Phase 2 — Native session refactor for fetch runtime support

Status: done

Files:

- `native/moqx_native/src/lib.rs`

Tasks:

- [x] Extend native atoms with fetch lifecycle atoms
- [x] Add fetch-specific native structs/state
- [x] Extend `SessionRes` with fetch-related state for subscriber sessions
- [x] Add request ID generation and pending-fetch bookkeeping
- [x] Add rooted namespace normalization helper aligned with existing path behavior
- [x] Refactor connect/session setup enough to retain the state needed for raw fetch handling
- [x] Decide whether fetch helpers stay in `lib.rs` initially or are extracted into small modules
  - Kept in `lib.rs` for now; still small enough to avoid premature splitting.

Exit criteria:

- Subscriber sessions can hold fetch runtime state safely
- Native code has a place to track pending fetches by request ID
- Namespace normalization rules are explicit and testable

## Phase 3 — Native fetch implementation and mailbox delivery

Status: done

Files:

- `native/moqx_native/src/lib.rs`

Tasks:

- [x] Add native `fetch` NIF entrypoint
- [x] Re-check subscriber-only enforcement in native code
- [x] Normalize rooted namespace before issuing fetch
- [x] Generate request IDs monotonically per session
- [x] Store pending fetch metadata including caller pid and Elixir ref
- [x] Send `FETCH` control messages
- [x] Accept incoming uni streams for fetch responses
- [x] Parse `FetchHeader` and correlate by `request_id`
- [x] Parse fetch objects and deliver `{:moqx_fetch_object, ...}` messages
- [x] Emit `{:moqx_fetch_started, ...}` after request submission succeeds
- [x] Emit `{:moqx_fetch_done, ...}` on successful completion
- [x] Emit `{:moqx_fetch_error, ...}` on runtime/protocol failures and clean up pending state

Exit criteria:

- A subscriber can submit fetch requests and receive raw object payloads in its mailbox
- Multiple fetches can be correlated by ref/request ID
- Errors clean up pending state and deliver consistent mailbox messages

## Phase 4 — Integration coverage

Status: done

Implementation note recorded during Phase 3:

- Current native fetch path is intentionally scoped to the compiled Quinn transport and `moq-transport-17` for the first working raw-fetch milestone.
- Other transports/versions continue to use the existing connect/session path, but fetch currently returns a native error if the underlying fetch transport/runtime combination is not yet supported.
- Broader transport/version fetch support can be revisited after the Phase 4 relay validation proves the issue #7 milestone.

Files:

- `test/moqx_integration_test.exs`

Tasks:

- [x] Add helper functions for awaiting fetch lifecycle messages
- [x] Add integration test that fetch rejects publisher sessions
- [x] Add integration test that fetch_catalog rejects publisher sessions
- [x] Add env-gated external relay smoke test
  - default relay URL: `https://ord.abr.moqtail.dev`
  - default namespace: `moqtail`
- [x] In the external smoke test, assert:
  - fetch started message
  - one or more fetch object messages
  - fetch done message
- [x] Reassemble raw catalog bytes in Elixir for the smoke assertion
- [x] Assert only raw retrieval properties:
  - non-empty payload
  - valid UTF-8
  - JSON-looking content
- [x] Do **not** parse CMSF in this phase

Exit criteria:

- Test suite proves the raw catalog retrieval milestone
- Public relay test is opt-in and does not become a default CI dependency

## Phase 5 — Docs and polish

Status: done

Files:

- `README.md`
- `lib/moqx.ex`

Tasks:

- [x] Add README fetch section
- [x] Document `MOQX.fetch/4` and `MOQX.fetch_catalog/2`
- [x] Document fetch mailbox message contract
- [x] Add raw catalog example that stops at bytes delivery
- [x] Make issue boundary explicit:
  - issue #7 ends at raw UTF-8 JSON CMSF bytes delivered to Elixir
  - issue #8 handles parsing and track discovery
- [x] Ensure moduledoc and function docs match behavior

Exit criteria:

- README and API docs reflect the implemented fetch milestone
- Scope boundary between #7 and #8 is explicit

## Final verification

Status: done

Tasks:

- [x] Run `mix format`
- [x] Run `mix test`
- [x] Run `mix credo --strict`
- [x] Address any formatting, test, or credo findings

## Working notes

Implementation order:

1. Phase 1
2. Phase 2
3. Phase 3
4. Phase 4
5. Phase 5
6. Final verification

Progress rule:

- Update this file as phases move from `pending` to `in_progress` to `done`
- Check off completed tasks as work lands
- If implementation reality changes, revise the plan instead of drifting from it
