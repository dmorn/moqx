# Add quicer client to reference server integration

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a tagged ExUnit integration test proving `MOQX.Transport.Quicer` can act as a native QUIC client against the reference QUIC server started by Docker Compose.

This covers the “calling” direction of the real transport boundary.

## Acceptance criteria

- [x] The test module is tagged `:integration` and excluded by default.
- [x] The test reads static endpoint/cert/ALPN configuration from `config/test.exs` without mutating `Application` env.
- [x] The test connects to the reference QUIC server using `MOQX.Transport.Quicer`.
- [x] The test verifies handshake and negotiated capabilities where available.
- [x] The test opens a bidirectional stream and verifies stream data send/receive behavior.
- [x] The test can reuse shared stream contract expectations where practical.
- [x] Failure output clearly says Docker Compose must be running if the reference endpoint is unavailable.

## Blocked by

- `.scratch/transport-layer-foundation/issues/16-add-docker-compose-quic-integration-harness.md`
- `.scratch/transport-layer-foundation/issues/17-add-quicprobe-reference-cli.md`
- `.scratch/transport-layer-foundation/issues/18-add-integration-test-configuration.md`

## Comments

- 2026-05-07: Added an integration-tagged parameterized transport contract scenario for `MOQX.Transport.Quicer` as a client to the Compose-managed `quicprobe` reference server. The shared client echo behavior now runs through `test/support/transport_contract.ex`, with fixtures providing setup glue for support and reference-server topologies.
