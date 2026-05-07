# ADR-0004: Docker Compose driven QUIC integration harness

- Status: Accepted
- Date: 2026-05-07

## Context

The default transport contract tests run against deterministic support transports. They should remain fast, hermetic, and independent of Docker, UDP sockets, certificates, or external QUIC implementations.

`MOQX.Transport.Quicer` still needs verification against real QUIC peers. This is the beginning of integration-test territory: a real QUIC server must be available when testing the `moqx` client path, and a real QUIC client must be available when testing the `moqx` listener path.

Future integration work is also expected to need multiple real endpoints, including MOQ Lite, moqtail, and Cloudflare relay targets. The harness should therefore be explicit and scalable rather than hidden behind normal unit tests.

## Decision

Use a Docker Compose driven integration harness.

The caller is responsible for starting and stopping the harness:

```bash
docker compose -f docker-compose.integration.yml up -d --wait
mix test --only integration
```

Integration tests are ExUnit tests tagged with `:integration` and excluded by default. They are run explicitly when needed and before commits that touch integration-sensitive transport behavior.

There will be no `mix test.integration` task for now. The standard command remains ExUnit's tag filtering.

### Certificates

The compose stack should include a certificate-provisioning service. On startup it generates self-signed test certificates and stores them in a local mounted directory accessible to integration tests, for example:

```text
.tmp/integration-certs/
```

The generated certificates should cover local and container names needed by tests, including at least:

- `localhost`
- `127.0.0.1`
- the reference QUIC server service name
- `host.docker.internal` where useful

### Configuration

Static integration endpoint configuration belongs in `config/test.exs`.

Tests may read that configuration, but must not mutate `Application` env. `Application` env remains forbidden as a test seam or mutable global state.

Configuration should describe externally managed endpoints and file paths only, such as:

- reference QUIC server host/port/ALPN;
- certificate paths;
- local listener host/port defaults;
- CLI tool command/arguments used by listener-side tests.

### Reference QUIC implementation

Start with a repo-owned small reference tool, likely based on `quic-go`, rather than relying on a large external application.

The tool should support two modes:

- server mode, run by Docker Compose, for `MOQX.Transport.Quicer` client-to-reference-server tests;
- client mode, invoked from ExUnit via `System.cmd/3`, for reference-client-to-`MOQX.Transport.Quicer` listener tests.

It should support configurable ALPN and certificates. Initial behavior can be minimal stream echo/sink/source; datagrams can be added when the datagram contract is tackled.

### Test directions

Integration tests should cover both directions:

1. **moqx client -> reference QUIC server**
   - Docker Compose starts the server.
   - ExUnit connects using `MOQX.Transport.Quicer`.
   - Tests verify handshake, stream open/accept, and stream data behavior.

2. **reference QUIC client -> moqx listener**
   - ExUnit starts a `MOQX.Transport.Quicer` listener.
   - ExUnit invokes the reference CLI client.
   - Tests verify accept/handshake, stream events, and stream data behavior.

### Tooling

Use `mise.toml` for developer tools needed by the harness where practical, especially Go for the reference CLI.

## Consequences

Positive:

- Default tests stay fast and deterministic.
- Real QUIC behavior is verified explicitly without hiding Docker startup inside tests.
- The same harness can grow to include MOQ Lite, moqtail, and public relay interop later.
- Listener-side testing becomes possible through a repo-owned reference client CLI.

Tradeoffs:

- Developers must start Docker Compose before running integration tests.
- Integration tests depend on local UDP/Docker/certificate behavior and can be slower or more environment-sensitive.
- The reference CLI becomes part of test infrastructure that must be maintained.

## Non-goals

This ADR does not decide:

- the final reference QUIC implementation forever;
- MOQ Lite protocol integration behavior;
- moqtail or Cloudflare relay test scenarios;
- performance benchmark thresholds;
- adding a `mix test.integration` task.
