# Add Docker Compose QUIC integration harness

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Create the Docker Compose foundation for real QUIC integration tests. The compose stack should be caller-managed and should not be started from ExUnit.

It should provision self-signed certificates into a local mount and run a reference QUIC server suitable for `MOQX.Transport.Quicer` client-side integration tests.

## Acceptance criteria

- [x] `docker-compose.integration.yml` exists and can be started by the caller.
- [x] The compose stack provisions self-signed test certificates into `.tmp/integration-certs/` or an equivalent local mount.
- [x] Generated certificates cover localhost, loopback, and the reference server service name.
- [x] A reference QUIC server service is defined with configurable ALPN and mounted certificates.
- [x] The reference server exposes a UDP port to the host.
- [x] The harness documents that tests do not start Docker and require the caller to run Compose first.

## Blocked by

None - can start immediately

## Comments

- 2026-05-07: Implemented `docker-compose.integration.yml` with a caller-managed `certs` service and `quic-ref-server` using `tools/quicprobe`; validated with `docker compose -p moqx_integration_check -f docker-compose.integration.yml up -d --wait` and a host `quicprobe client` echo.
