# Design distributed benchmark control plane

Status: needs-triage
Type: HITL

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Design the next benchmark harness shape around a small remote control plane for
distributed QUIC pressure tests.

The current CLI-plus-SSH loop works, but it is too slow for the performance
hardening phase: each experiment requires manual orchestration of provisioning,
release deployment, remote process startup, log/result collection, and teardown
decisions. The next harness should make the common case cheap: start remote
roles, configure a run, trigger the client/listener/reference peers, observe
progress, fetch results, and preserve the run bundle before infrastructure is
destroyed.

The candidate shape is a tiny `probed` HTTP service in its own
`bench/probed` Mix project. The daemon would run on disposable benchmark
nodes, expose a deliberately small API, and execute the same benchmark clients
and listeners as the CLI. The local machine remains the controller.

## Scope

- Decide whether `probed` should be introduced now as part of
  the benchmark hardening loop.
- Define a minimal HTTP API for remote roles:
  - health/capability checks;
  - prepare a run and role configuration;
  - start/stop a role;
  - stream or poll status;
  - fetch canonical JSONL, diagnostics, logs, and metadata;
  - clean local run artifacts.
- Define how the daemon is secured for disposable remote infra:
  - bind only to private/Tailscale interfaces by default;
  - require a per-run token or equivalent simple auth;
  - avoid exposing Terraform/provider secrets;
  - keep run keys, tokens, and result bundles ignored by git.
- Define the run bundle layout so results survive teardown:
  - `transport-bench-v1` JSONL summaries;
  - benchmark telemetry sidecars;
  - daemon logs;
  - role stdout/stderr;
  - host/path metadata;
  - iperf3/quicprobe/reference artifacts.
- Define how reference tooling is managed by the control plane:
  - repo-owned `bench/quicprobe`;
  - `iperf3` baselines;
  - avoid adding external reference tools unless they answer a question
    `quicprobe` cannot answer;
  - Docker/container-based smoke services where they reduce local setup
    mistakes without becoming benchmark evidence.
- Define how the local controller talks to daemons:
  - `just` recipes may remain the operator entry point;
  - controller commands should be idempotent where practical;
  - failed partial runs should be inspectable before cleanup.
- Define the provisioning boundary:
  - `bench/infra` owns Terraform/provider setup;
  - `bench/ledger` owns shared JSONL/path metadata specs;
  - `bench/moqxprobe` owns benchmark commands and reports;
  - `bench/probed` owns remote execution/control-plane API;
  - no benchmark command or daemon endpoint creates/destroys cloud resources
    implicitly.
- Define the distribution/update model for remote nodes:
  - cached `bench/quicprobe` binaries by target architecture and hash;
  - `moqxprobe` CLI release updates by hash;
  - `probed` daemon release updates by hash;
  - candidate Burrito-wrapped single executable for the bench daemon/CLI;
  - no recompilation during normal benchmark runs.
- Decide how, if at all, Benchee fits:
  - as an inner local benchmark runner for isolated functions;
  - as a result formatter/exporter;
  - or not at all for distributed network pressure tests.

## Acceptance criteria

- [ ] The design states whether a daemon/API becomes part of the immediate
      benchmark roadmap or remains deferred.
- [ ] The design defines remote roles and lifecycle states for client,
      listener, reference peer, and baseline peer.
- [ ] The design defines the minimal HTTP API with request/response shapes
      precise enough for implementation.
- [ ] The design explains how a local controller starts runs, observes status,
      fetches results, and handles partial failure.
- [ ] The design preserves `transport-bench-v1` as the stable summary artifact
      and explains what additional sidecar artifacts are collected.
- [ ] The design decides which reference peers are first-class control-plane
      roles and how their native stats are converted into common benchmark
      artifacts.
- [ ] The design includes a security model suitable for disposable Hetzner
      nodes and optional Tailscale/private-network use.
- [ ] The design includes a fast-loop testing strategy: pure unit tests,
      local fake-daemon/controller tests, local loopback smoke, and remote
      end-to-end smoke.
- [ ] The design chooses a distribution strategy for `probed`
      and CLI updates: current Mix release, Burrito single binary, or a
      hybrid, with explicit handling for the quicer NIF.
- [ ] The Benchee evaluation is recorded with a concrete decision: use it,
      use only a small part of it, or avoid it for this harness.
- [ ] The MsQuic `secnetperf` evaluation is recorded with a concrete decision:
      keep relying on `bench/quicprobe` for the immediate roadmap.
- [ ] Follow-up implementation issues are opened for the first thin daemon
      slice and any controller/deployment changes.

## Blocked by

None. This is a design issue and can proceed in parallel with #41.

## Notes

The daemon should not become a benchmark framework inside a benchmark
framework. The goal is operational leverage: make distributed experiments
repeatable, observable, and cheap to run, while keeping the measurement contract
stable and explicit.

For v1, optimize caller-side use first: publish to relay, subscribe from relay,
and generate controlled caller-side pressure. Listener/relay benchmark roles
are still needed for controlled tests, but relay implementation performance is
not the first product target.

Prefer a minimal, boring HTTP API over a rich distributed system. If a local CLI
can still produce the exact same result by calling a module directly, the daemon
should be a remote orchestration adapter over that module, not the owner of the
benchmark semantics.

Remote nodes should be treated as long-lived lab executors while a performance
session is active. Provisioning creates the machines and starts the control
plane once; subsequent iteration should upload only changed CLI/tool artifacts
or select already-cached artifact hashes. Normal benchmark runs must not
recompile Elixir, quicer, or `quicprobe` on the remote host.

## Candidate decisions

- 2026-05-29: Benchee is not a good fit as the primary runner for distributed
  QUIC stream/DATAGRAM pressure experiments. It is local function
  microbenchmark tooling, while this harness needs remote role orchestration,
  path metadata, peer readiness, artifact fetch, failure classification, and
  `transport-bench-v1` records. Keep `moqxprobe` plus the proposed
  daemon/controller as the primary runner. Benchee may still be useful for
  isolated local microbenchmarks such as pacer math, payload encoding,
  telemetry collector overhead, and sender-admission internals; those results
  must remain sidecar/local calibration evidence, not canonical path evidence.
- 2026-05-29: Do not add MsQuic `secnetperf` to the immediate control-plane
  roadmap. The exploration showed that it is useful as a native MsQuic
  stream/RPS/HPS ceiling tool, but it speaks ALPN `perf`, has no DATAGRAM
  workload, does not model the draft_14 or MOQ Lite transport profiles, and
  would add another reference protocol/output adapter to manage. Keep
  repo-owned `bench/quicprobe` as the single controlled reference peer for the
  current stream, DATAGRAM, and mixed MOQT-shaped matrix. Revisit `secnetperf`
  only if a future question specifically needs a native MsQuic stream/RPS/HPS
  ceiling that `quicprobe` cannot answer.
- 2026-05-29: Evaluate Burrito as the preferred distribution format for the
  benchmark daemon/CLI. The desired operating model is: provision remote
  servers, start the control plane, keep the lab up while iterating, and push
  only new content-addressed CLI/tool updates. Burrito is attractive because it
  can package BEAM code plus ERTS into one executable and cache the unpacked
  payload on first run, which would simplify remote updates. The gating risk is
  quicer: our QUIC path depends on a native rebar/Make/CMake NIF, and Burrito's
  documented automatic NIF story is strongest for `elixir_make`-style NIFs.
  The first spike must prove a Burrito-wrapped bench binary can include and
  load quicer/msquic on Linux ARM64 and AMD64. If cross-compilation is brittle,
  keep Docker/native-target builds and use the daemon artifact cache instead of
  forcing Burrito into the critical path.
- 2026-05-29: Split provisioning into its own bench root. Terraform/provider
  modules belong under `bench/infra` rather than inside `bench/moqxprobe`
  or `bench/probed`. The CLI and daemon consume provisioned endpoint
  metadata but do not own cloud lifecycle. The current concrete module is
  `bench/infra/hetzner`.
- 2026-05-29: Split shared transport benchmark specs into `bench/ledger`.
  This project owns deterministic artifact contracts such as
  `transport-bench-v1` validation, JSONL parsing, and path metadata helpers.
  `bench/moqxprobe` and `bench/quicprobe` are the traffic-producing
  peers; `bench/probed` is the relaxed-trust HTTP control plane and
  accumulator. Do not make `probed` depend on `moqx`, quicer, or benchmark
  runner internals just to understand result files.
