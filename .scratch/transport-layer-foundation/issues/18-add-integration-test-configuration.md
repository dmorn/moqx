# Add integration test configuration

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add static integration endpoint configuration for the real QUIC harness.

Configuration belongs in `config/test.exs` and should describe externally managed endpoints, certificate paths, ALPN values, and CLI commands. Tests may read this configuration but must not mutate `Application` env.

## Acceptance criteria

- [ ] `config/test.exs` exists with integration endpoint configuration.
- [ ] Configuration includes reference QUIC server host, port, ALPN, and CA certificate path.
- [ ] Configuration includes local listener certificate/key/CA paths and ALPN defaults.
- [ ] Configuration includes reference CLI command/arguments or path for listener-side tests.
- [ ] `test/test_helper.exs` excludes `:integration` by default.
- [ ] Documentation explains how to run tagged integration tests with ExUnit tag filtering.
- [ ] No test mutates `Application` env.

## Blocked by

None - can start immediately

## Comments
