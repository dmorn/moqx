# Benchmark Infrastructure

`bench/infra` owns disposable infrastructure used by benchmark projects.

This directory is intentionally separate from `bench/moqxprobe` and
`bench/probed`:

- infrastructure modules create lab hosts and expose metadata;
- CLI and daemon projects decide which benchmark commands to run;
- provisioning must not start benchmark traffic implicitly;
- generated state, plans, and local per-run values stay ignored.

Current modules:

- `hetzner/` provisions short-lived Hetzner Cloud pairs for transport
  benchmarks.
