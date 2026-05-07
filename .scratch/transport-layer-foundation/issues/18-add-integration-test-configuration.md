# Add integration test configuration

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add static integration endpoint configuration for the real QUIC harness.

Configuration belongs in `config/test.exs` and should describe externally managed endpoints, certificate paths, ALPN values, and CLI commands. Tests may read this configuration but must not mutate `Application` env.

## Acceptance criteria

- [x] `config/test.exs` exists with integration endpoint configuration.
- [x] Configuration includes reference QUIC server host, port, ALPN, and CA certificate path.
- [x] Configuration includes local listener certificate/key/CA paths and ALPN defaults.
- [x] Configuration includes reference CLI command/arguments or path for listener-side tests.
- [x] `test/test_helper.exs` excludes `:integration` by default.
- [x] Documentation explains how to run tagged integration tests with ExUnit tag filtering.
- [x] No test mutates `Application` env.

## Blocked by

None - can start immediately

## Comments

- 2026-05-07: Added static `config/test.exs` integration endpoint configuration, default ExUnit exclusion for `:integration`, and setup tests that read config without mutating `Application` env.
