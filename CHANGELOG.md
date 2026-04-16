# Changelog

All notable changes to `moqx` will be documented in this file.

## [0.6.0] - 2026-04-15

This release automates the tag-driven release path and hardens release metadata
validation so publishing fails fast if the tag, `mix.exs`, and changelog drift.

### Added

- Added a tag-triggered GitHub Actions release workflow that reruns the full
  release preflight (`mix format --check-formatted`, `mix test`,
  `mix test.integration`, `mix docs`, and `mix credo --strict`) before
  publishing.
- Added automated Hex publishing on `v*` tags via `mix hex.publish --yes`,
  using the repository `HEX_API_KEY` secret.
- Added automated GitHub release creation/update on `v*` tags, with release
  notes extracted from the matching `CHANGELOG.md` section.
- Added release-time validation that the pushed tag version matches both
  `mix.exs` and a `CHANGELOG.md` heading for the same version.

### Documentation

- Clarified project release guidance in `AGENTS.md` and the local release skill,
  including `mix docs` in pre-release checks.
- Corrected the local Hex release skill to reflect actual Hex behavior:
  `mix hex.publish` publishes package + docs by default, while
  `mix hex.publish docs` remains the docs-only follow-up path.

## [0.5.0] - 2026-04-15

This release finalizes the low-level async core contract that `moqx` exposes.
`MOQX` is now explicitly documented as the thin async core layer, while
convenience flows live in `MOQX.Helpers` and future stateful ergonomics remain
out of the core contract.

### Migration notes

If you are upgrading from older `0.2.x`–`0.4.x` APIs:

- connect is now explicitly correlated by `connect_ref`
- publish namespace readiness is now explicit and correlated by `publish_ref`
- publisher writes are lifecycle-gated and no longer silently drop before
  downstream activation
- subscribe/fetch lifecycle messages now use typed structs and shared typed
  async error families
- helper catalog flows moved from `MOQX` into `MOQX.Helpers`
- `unsubscribe/1` now culminates in `{:moqx_publish_done, ...}` rather than the
  old `:moqx_track_ended` tuple contract
- `delivery_timeout_ms` remains the correct draft-14 subscribe timeout option
- `rendezvous_timeout_ms` was a mistaken rename based on newer-draft terminology and should not be used on the draft-14 stack
- local integration guidance now uses `mix test.integration` against a relay you
  keep running separately

### Changed

- **Breaking:** connect is now explicitly correlated. `connect/2`,
  `connect_publisher/2`, and `connect_subscriber/2` return `{:ok, connect_ref}`.
  Asynchronous connect outcomes are delivered as typed messages:
  `{:moqx_connect_ok, %MOQX.ConnectOk{...}}`,
  `{:moqx_request_error, %MOQX.RequestError{...}}`, and
  `{:moqx_transport_error, %MOQX.TransportError{...}}`.
- **Breaking:** publish namespace readiness is now explicit and correlated.
  `publish/2` returns `{:ok, publish_ref}` and the broadcast handle arrives only
  via `{:moqx_publish_ok, %MOQX.PublishOk{...}}` after relay ack.
  Failures are delivered as typed async request/transport errors with
  `op: :publish` and the matching `publish_ref`.
- **Breaking:** publisher write lifecycle now has explicit synchronous gating.
  Writes no longer silently drop before downstream activation.
  `write_frame/2` and `open_subgroup/3` now fail synchronously with typed
  `%MOQX.RequestError{code: :track_not_active | :track_closed}`.
- Subscriber data-path race handling now tolerates early subgroup streams that
  arrive just before local `SubscribeOk` state installation, reducing first-frame
  loss risk under control/data-plane reordering.
- **Breaking:** subgroup flush is now explicitly correlated.
  `flush_subgroup/1` returns `{:ok, flush_ref}` and asynchronous completion is
  delivered as `{:moqx_flush_ok, %MOQX.FlushDone{...}}` (or typed transport
  failure).
- **Breaking:** subscribe/fetch/object lifecycle messages now use typed payload
  structs and explicit message families.
  `:moqx_subscribed`/`:moqx_track_ended`/`:moqx_fetch_started`/`:moqx_fetch_error`
  tuple contracts are replaced by typed events such as
  `:moqx_subscribe_ok`, `:moqx_publish_done`, `:moqx_fetch_ok`, and the shared
  async error families.
- **Breaking:** asynchronous generic tuple errors (`{:error, reason}` and
  `{:moqx_error, ..., reason}`) are no longer the primary public contract.
  Async failures now flow through `%MOQX.RequestError{}` and
  `%MOQX.TransportError{}`.
- Added explicit publisher track lifecycle events for track owners:
  `{:moqx_track_active, %MOQX.TrackActive{...}}` and
  `{:moqx_track_closed, %MOQX.TrackClosed{...}}`.
- **Breaking:** helper-level convenience APIs moved out of core `MOQX` into
  `MOQX.Helpers` (`publish_catalog/2`, `update_catalog/2`, `fetch_catalog/2`,
  `await_catalog/2`).
- Mix tasks now expose primary names `moqx.roundtrip` and `moqx.inspect`.
  Legacy aliases `moqx.e2e.pubsub` and `moqx.moqtail.demo` remain available with
  deprecation notices.
- `moqx.inspect` can probe catalog tracks named either `"catalog"` or
  `".catalog"` (or an explicit `--catalog-track`), supports `--no-fetch` for
  relays that do not implement fetch yet, and now includes named relay presets
  plus interactive preset selection. This improves interop with Cloudflare
  `moq-rs` style relays and other early deployments.
- `MOQX.Helpers.fetch_catalog/2` now accepts `:track` so callers can override
  the catalog track name when relays do not use `"catalog"`.
- Mix tasks and integration helpers now follow the typed async contract.
- Integration tests now assume a relay endpoint provided by environment
  (`MOQX_EXTERNAL_RELAY_URL`) and trusted CA path (`MOQX_RELAY_CACERTFILE`),
  with Docker-based local/CI orchestration as the primary deterministic path.
- Removed `:public_relay_live` integration tests; public relay interop checks now
  live in manual mix tasks.
- Subscribe request rejections now carry typed `RequestError.code` values
  (for example `:track_does_not_exist` / `:timeout`).
- Corrected subscribe-timeout naming/docs back to draft-14 `delivery_timeout_ms`
  after auditing the wire parameter mapping against the spec and `moqtail`.
- Pinned README spec references to the explicit draft-14 target instead of the
  moving latest Internet-Draft URL.
- Hardened the early-subscribe integration coverage to use a short payload burst
  rather than assuming the very first write always survives the current
  `moqtail` relay's subscribe-activation race window.

### Documentation

- Rewrote README and module docs to align with the low-level async contract and
  remove stale tuple-era examples (`:moqx_frame`, `:moqx_subscribed`,
  `:moqx_track_ended`, `:moqx_error`, etc.).
- Clarified core vs helper-layer responsibilities and the intended separation
  from any future managed/stateful ergonomics layer.
- Added `0.5.0` migration guidance covering message-shape, lifecycle, helper,
  timeout-option, and integration-harness changes.
- Documented current moqtail standalone fetch behavior more explicitly:
  relay-backed fetch succeeds from relay cache, while cache misses surface as
  typed fetch request errors rather than hanging silently.
- Clarified core async message families and correlation behavior for connect,
  subscribe, fetch, and subgroup flush.

## [0.4.1] - 2026-04-12

### Fixed

- `MOQX.unsubscribe/1` and subscription handle `Drop` no longer panic the
  NIF with `send_and_clear: current thread is managed`. Environment work
  (message send to the caller) is now performed inside the Tokio runtime
  instead of on the BEAM scheduler thread invoking the NIF/GC.
- Added end-to-end integration coverage for `unsubscribe/1` (live relay
  roundtrip verifying `:moqx_track_ended`, frame cut-off, and idempotent
  double-unsubscribe).

## [0.4.0] - 2026-04-12

### Added

- `MOQX.unsubscribe/1` cancels an active track subscription by sending MOQ
  `Unsubscribe` to the relay. Idempotent and fire-and-forget; the caller
  subsequently receives `{:moqx_track_ended, handle}` when the relay
  acknowledges.
- Dropping a subscription handle (GC) now automatically cancels the
  subscription — short-lived subscribing processes no longer need to
  unsubscribe explicitly to free relay-side resources.
- `{:moqx_track_ended, handle}` is now emitted on publisher-side
  `PublishDone` (graceful `TrackEnded` / `SubscriptionEnded` status codes).
  The corresponding local subscription state is removed in the same path,
  fixing a small leak in `active_subscriptions`.
- `MOQX.Helpers.publish_catalog/2` helper to create and publish the initial `"catalog"` track object.
- `MOQX.Helpers.update_catalog/2` helper to publish subsequent catalog objects.
- Integration E2E coverage that verifies publisher-provided catalog objects are relayed downstream.

### Changed

- **Breaking:** `MOQX.subscribe/3,4` and `MOQX.subscribe_track/3,4` now
  return an opaque subscription handle (Rustler resource) instead of a
  bare `make_ref()`. Pattern-matching and `is_reference/1` continue to
  work; callers that depended on `make_ref()` semantics (serialization,
  external storage) need to adapt.
- README and module docs now explicitly document the publisher-driven catalog flow used with moqtail-style relays.

## [0.3.0] - 2026-04-09

### Added

- `MOQX.subscribe_track/3,4` convenience API for catalog-driven subscriptions.
- Track metadata helpers on `MOQX.Catalog.Track`:
  - `explicit_metadata/1`
  - `inferred_metadata/1`
  - `extra_metadata/1`
  - `describe/1`
- New relay debug task `mix moqx.moqtail.demo` (catalog listing, interactive selection, runtime stats, catalog fallback behavior).

### Changed

- **Breaking** subscription contract now returns and propagates `subscription_ref`:
  - `subscribe/3,4` now return `{:ok, sub_ref}`.
  - subscription messages now include `sub_ref`.
- **Breaking** subscription lifecycle now emits `{:moqx_track_init, sub_ref, init_data, track_meta}` once per subscription.
- Integration/E2E tasks and tests updated for the new subscription correlation model.
- README/docs/examples updated for the new API and task naming.

## [0.2.1] - 2026-04-09

### Added

- `mix moqx.e2e.pubsub` task for end-to-end publisher/subscriber relay smoke testing.
- README examples for running relay E2E smoke tests, including Cloudflare draft-14 relay endpoints.

### Changed

- integration test tagging split to keep CI deterministic (`:integration`) while keeping live public relay coverage opt-in (`:public_relay_live`).
- `mix test.integration` now excludes `:public_relay_live` tests by default.

## [0.2.0] - 2026-04-08

First release of the current Rustler + `moqtail-rs` based Elixir MOQ client library line.

### Added

- CMSF catalog decoding and media track discovery via `MOQX.Catalog`
- raw fetch and catalog retrieval APIs for subscriber sessions
- validated relay-backed integration coverage for v14/v17 interop and live relay behavior

### Changed

- native integration migrated to `moqtail-rs`
- publish flow aligned around `PublishNamespace` behavior
- docs and examples updated for the current client contract

### Notes

- `moqx` on Hex had prior unrelated releases; `0.2.0` marks this project line as the canonical continuation.

## [0.1.0] - 2026-03-30

Initial public client release.

### Added

- explicit split-role client API with `connect_publisher/1,2`, `connect_subscriber/1,2`, and `connect/2`
- Quinn-backed transport support for `:auto`, `:raw_quic`, `:webtransport`, and `:websocket`
- secure-by-default client TLS controls with optional custom root CA support and explicit local-dev insecure mode
- relay-authenticated client flows using rooted `?jwt=...` URLs
- relay-backed integration coverage for transport parity, TLS behavior, and authenticated rooted-path flows
- CI split between fast checks and relay-backed integration coverage

### Changed

- public docs now freeze the supported `v0.1` client contract and async message/error expectations
- package metadata now includes Hex-oriented description, license, source, changelog, and docs configuration
