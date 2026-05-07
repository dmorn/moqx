# Add reference client to quicer listener integration

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a tagged ExUnit integration test proving a reference QUIC client can connect to a `MOQX.Transport.Quicer` listener started by the test.

This covers the “listening” direction of the real transport boundary.

## Acceptance criteria

- [x] The test module is tagged `:integration` and excluded by default.
- [x] The test reads static local listener certificate/key/ALPN and CLI configuration from `config/test.exs` without mutating `Application` env.
- [x] The test starts a `MOQX.Transport.Quicer` listener on localhost.
- [x] The test invokes the reference CLI client via `System.cmd/3` or equivalent.
- [x] The `MOQX.Transport.Quicer` listener accepts and handshakes the connection.
- [x] The test accepts a bidirectional stream and verifies stream data behavior.
- [x] The test can reuse shared stream contract expectations where practical.
- [x] Failure output clearly identifies missing CLI/cert/harness prerequisites.

## Blocked by

- `.scratch/transport-layer-foundation/issues/17-add-quicprobe-reference-cli.md`
- `.scratch/transport-layer-foundation/issues/18-add-integration-test-configuration.md`

## Comments

- 2026-05-07: Added an integration-tagged parameterized transport contract scenario for `quicprobe` as a reference client to a test-started `MOQX.Transport.Quicer` listener. The fixture reads static listener and CLI config, invokes the CLI with `System.cmd/3`, and verifies listener accept/handshake plus bidirectional stream echo behavior.
