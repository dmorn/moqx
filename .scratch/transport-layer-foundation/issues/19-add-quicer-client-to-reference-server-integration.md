# Add quicer client to reference server integration

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a tagged ExUnit integration test proving `MOQX.Transport.Quicer` can act as a native QUIC client against the reference QUIC server started by Docker Compose.

This covers the “calling” direction of the real transport boundary.

## Acceptance criteria

- [ ] The test module is tagged `:integration` and excluded by default.
- [ ] The test reads static endpoint/cert/ALPN configuration from `config/test.exs` without mutating `Application` env.
- [ ] The test connects to the reference QUIC server using `MOQX.Transport.Quicer`.
- [ ] The test verifies handshake and negotiated capabilities where available.
- [ ] The test opens a bidirectional stream and verifies stream data send/receive behavior.
- [ ] The test can reuse shared stream contract expectations where practical.
- [ ] Failure output clearly says Docker Compose must be running if the reference endpoint is unavailable.

## Blocked by

- `.scratch/transport-layer-foundation/issues/16-add-docker-compose-quic-integration-harness.md`
- `.scratch/transport-layer-foundation/issues/17-add-quicprobe-reference-cli.md`
- `.scratch/transport-layer-foundation/issues/18-add-integration-test-configuration.md`

## Comments
