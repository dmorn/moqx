# Add reference client to quicer listener integration

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a tagged ExUnit integration test proving a reference QUIC client can connect to a `MOQX.Transport.Quicer` listener started by the test.

This covers the “listening” direction of the real transport boundary.

## Acceptance criteria

- [ ] The test module is tagged `:integration` and excluded by default.
- [ ] The test reads static local listener certificate/key/ALPN and CLI configuration from `config/test.exs` without mutating `Application` env.
- [ ] The test starts a `MOQX.Transport.Quicer` listener on localhost.
- [ ] The test invokes the reference CLI client via `System.cmd/3` or equivalent.
- [ ] The `MOQX.Transport.Quicer` listener accepts and handshakes the connection.
- [ ] The test accepts a bidirectional stream and verifies stream data behavior.
- [ ] The test can reuse shared stream contract expectations where practical.
- [ ] Failure output clearly identifies missing CLI/cert/harness prerequisites.

## Blocked by

- `.scratch/transport-layer-foundation/issues/17-add-quicprobe-reference-cli.md`
- `.scratch/transport-layer-foundation/issues/18-add-integration-test-configuration.md`

## Comments
