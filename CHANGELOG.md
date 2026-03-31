# Changelog

All notable changes to `moqx` will be documented in this file.

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
