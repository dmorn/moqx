# Changelog

All notable changes to `moqx` will be documented in this file.

## [Unreleased]

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
- Mix tasks (`moqx.e2e.pubsub`, `moqx.moqtail.demo`) and integration helpers now
  follow the typed async contract.
- Integration tests now assume a relay endpoint provided by environment
  (`MOQX_EXTERNAL_RELAY_URL`) and trusted CA path (`MOQX_RELAY_CACERTFILE`),
  with Docker-based local/CI orchestration as the primary deterministic path.
- Removed `:public_relay_live` integration tests; public relay interop checks now
  live in manual mix tasks.
- Subscribe availability timeout is now exposed as
  `rendezvous_timeout_ms` (`delivery_timeout_ms` remains as a deprecated alias)
  and subscribe request rejections now carry typed `RequestError.code` values
  (for example `:track_does_not_exist` / `:timeout`).

### Documentation

- Rewrote README and module docs to align with the low-level async contract and
  remove stale tuple-era examples (`:moqx_frame`, `:moqx_subscribed`,
  `:moqx_track_ended`, `:moqx_error`, etc.).
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
- `MOQX.publish_catalog/2` helper to create and publish the initial `"catalog"` track object.
- `MOQX.update_catalog/2` helper to publish subsequent catalog objects.
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
