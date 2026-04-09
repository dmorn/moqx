# Changelog

All notable changes to `moqx` will be documented in this file.

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
