# Probe Ledger

`bench/ledger` owns the shared benchmark contract for transport experiments.

This project is intentionally small. It defines the deterministic data formats
shared by:

- `bench/moqxprobe`, which runs Elixir/quicer benchmark workloads;
- `bench/probed`, which exposes the control-plane API and accumulates
  result artifacts;
- `bench/quicprobe`, which is the Go/quic-go reference peer and must
  follow the same JSON contract at the wire/file boundary.

It must not depend on `moqx`, quicer, HTTP servers, container tooling, or
provider-specific infrastructure.

Owned here:

- `transport-bench-v1` JSONL record validation;
- JSONL parsing helpers;
- path metadata loading/unwrapping helpers;
- small shared format rules that are independent of how measurements are
  produced.

Not owned here:

- QUIC traffic generation;
- telemetry collection;
- report rendering;
- daemon HTTP API;
- Terraform/provider lifecycle.
