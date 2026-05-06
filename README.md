# moqx

Clean-slate redesign of the Elixir Media over QUIC library targeting MOQT draft-14.

This branch intentionally removes the previous Rustler/moqtail-backed API. The new implementation starts from a small QUIC transport boundary backed by [`quicer`](https://github.com/dmorn/quic), so protocol code can be tested against an in-memory adapter.

## Current status

- package metadata, version, license, and changelog are preserved
- direct runtime dependency: `quicer` only
- previous public API and tests have been removed
- relay certificate/container setup is retained for future integration tests

## Development

```bash
mix deps.get
mix test
mix ci
```

Integration harness setup is still available:

```bash
scripts/generate_integration_certs.sh .tmp/integration-certs
docker compose -f docker-compose.integration.yml up
```

There are intentionally no integration tests in this reset yet.
