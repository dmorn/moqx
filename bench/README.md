# Bench

Benchmark-related projects live under `bench/`.

Current layout:

- `infra/` owns disposable provisioning modules and provider-specific setup.
- `ledger/` is the shared deterministic benchmark artifact specs project.
- `moqxprobe/` is the Elixir/quicer transport benchmark CLI project.
- `quicprobe/` is the repo-owned Go/quic-go QUIC reference peer.
- `probed/` is the future Elixir remote control-plane daemon project.

The CLI and daemon may consume infrastructure metadata, but provisioning should
stay explicit and caller-operated. Benchmark commands must accept endpoints and
must not create or destroy cloud resources implicitly.
