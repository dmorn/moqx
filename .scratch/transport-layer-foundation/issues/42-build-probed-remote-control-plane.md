# Build probed remote benchmark control plane

Status: in-progress
Type: AFK

## Parent

`.scratch/transport-layer-foundation/issues/26-harden-transport-pressure-abstractions.md`

## What to build

Implement the first usable `bench/probed` remote control plane for transport
benchmarks.

The current CLI-plus-SSH loop is too slow for the performance hardening phase.
Each experiment still requires manual provisioning checks, release deployment,
remote server startup, client execution, log/result collection, and cleanup
decisions. The next benchmark loop should be:

1. provision disposable lab nodes;
2. deploy and start `probed` on each node;
3. keep the lab up while iterating;
4. use the local controller to start reference peers and MOQX caller-side
   benchmark clients;
5. fetch complete run bundles before teardown.

`probed` is intentionally not a benchmark framework. It is a remote process
supervisor plus artifact store. `bench/moqxprobe` owns benchmark semantics,
`bench/quicprobe` owns reference QUIC traffic, `bench/ledger` owns shared
artifact contracts, and `bench/infra` owns provisioning.

## Current decision

Introduce `probed` now. The operational pain is already blocking useful remote
validation of the new caller-side DATAGRAM and stream benchmark clients.

The v1 daemon is caller-side focused:

- first-class roles are `baseline_server`, `baseline_client`,
  `reference_server`, `reference_client`, and `moqx_client`;
- there is no listener/relay benchmark role in v1;
- relay/listener performance returns later as a new relay-scoped issue with an
  explicit serving model.

## Architecture decisions

- `bench/probed` is a separate Elixir project and should not depend on `moqx`,
  quicer, or `bench/moqxprobe`.
- `probed` may depend on `bench/ledger` to validate or describe shared
  artifact formats.
- `probed` executes configured tools by path and argv array using process APIs,
  not shell strings.
- `probed` does not create, destroy, or mutate cloud resources.
- `probed` does not infer benchmark semantics from command names. It records
  process metadata and artifacts; `moqxprobe report` remains the human reader.
- Failed partial runs must stay inspectable until the operator explicitly
  cleans them.
- HTTP without TLS is acceptable for v1 on private Hetzner/Tailscale networks
  if bearer-token auth is enabled and the daemon binds only to private
  interfaces by default.

## Configuration model

`probed` reads one config file, with minimal env overrides for deployment.

Default config path:

```text
/etc/moqx-bench/probed.json
```

Supported env overrides:

- `PROBED_CONFIG`
- `PROBED_BIND`
- `PROBED_TOKEN`
- `PROBED_WORK_DIR`
- `PROBED_NODE_ID`

Example config:

```json
{
  "node_id": "client-1",
  "bind": "10.88.0.11:9157",
  "work_dir": "/var/lib/probed",
  "token_file": "/etc/moqx-bench/probed.token",
  "tools": {
    "moqxprobe": {
      "path": "/opt/moqx-bench/moqxprobe/current/bin/moqxprobe"
    },
    "quicprobe": {
      "path": "/opt/moqx-bench/quicprobe/current/bin/quicprobe"
    },
    "iperf3": {
      "path": "/usr/bin/iperf3"
    }
  }
}
```

Tool lookup rules:

- only named configured tools can be executed;
- paths must be absolute;
- no fallback shell lookup in the daemon hot path;
- `GET /v1/tools` reports existence, executable bit, version/smoke status when
  cheap, and configured path;
- Phase 2 can add content-addressed upload/activation, but Phase 1 uses the
  existing SSH/just artifact deployment path.

## HTTP API v1

All endpoints require:

```text
Authorization: Bearer <token>
```

Core endpoints:

```text
GET    /v1/health
GET    /v1/node
GET    /v1/tools

POST   /v1/runs
GET    /v1/runs/:run_id
DELETE /v1/runs/:run_id

POST   /v1/runs/:run_id/processes
GET    /v1/runs/:run_id/processes
GET    /v1/runs/:run_id/processes/:process_id
DELETE /v1/runs/:run_id/processes/:process_id

GET    /v1/runs/:run_id/artifacts
GET    /v1/runs/:run_id/artifacts/:path
GET    /v1/runs/:run_id/bundle
```

Deferred Phase 2 endpoint:

```text
POST   /v1/tools/:name/activate
```

`POST /v1/runs` request:

```json
{
  "run_id": "20260605T120000Z-issue-40-probed",
  "metadata": {
    "purpose": "issue-40-datagram-validation"
  }
}
```

`POST /v1/runs/:run_id/processes` request:

```json
{
  "role": "reference_server",
  "tool": "quicprobe",
  "argv": [
    "server",
    "--addr",
    ":4433",
    "--cert",
    "/opt/moqx-bench/certs/server.pem",
    "--key",
    "/opt/moqx-bench/certs/server-key.pem",
    "--stats-output",
    "/var/lib/probed/runs/20260605T120000Z-issue-40-probed/artifacts/server/quicprobe-stats.jsonl"
  ],
  "env": {},
  "timeout_ms": 120000,
  "ready": {
    "type": "udp_port",
    "port": 4433
  },
  "artifacts": {
    "stdout": "server/stdout.log",
    "stderr": "server/stderr.log"
  }
}
```

`moqxprobe measure` request example:

```json
{
  "role": "moqx_client",
  "tool": "moqxprobe",
  "argv": [
    "measure",
    "--topology",
    "moqx-client-to-reference-server",
    "--workload",
    "datagram_pressure",
    "--server",
    "10.88.0.12",
    "--port",
    "4433",
    "--ca",
    "/opt/moqx-bench/certs/ca.pem",
    "--datagram-size",
    "1180",
    "--datagram-rate",
    "32000",
    "--duration-seconds",
    "3",
    "--output",
    "/var/lib/probed/runs/20260605T120000Z-issue-40-probed/artifacts/client/measure.jsonl"
  ],
  "timeout_ms": 30000,
  "artifacts": {
    "stdout": "client/stdout.log",
    "stderr": "client/stderr.log",
    "jsonl": "client/measure.jsonl"
  }
}
```

## State model

Run states:

```text
created -> active -> complete
created -> active -> aborted
complete/aborted -> cleaned
```

Process states:

```text
starting -> ready -> running -> exited
starting/running -> failed
running -> timed_out
running -> stopping -> exited
```

Readiness rules for Phase 1:

- `none`: process is considered started immediately after spawn;
- `stdout_contains`: ready after stdout contains a configured string;
- `tcp_port`: ready after a TCP connect succeeds locally;
- `udp_port`: ready after the daemon can confirm a local UDP socket is bound
  when practical, otherwise fallback to `none` plus a bounded startup delay.

For clients, `exited` is the important success state. For servers, `ready` is
the important state before a client is started.

## Run bundle layout

Each daemon writes only under its configured work directory.

```text
/var/lib/probed/runs/<run_id>/
  run.json
  node.json
  processes/
    <process_id>/
      command.json
      stdout.log
      stderr.log
      exit.json
  artifacts/
    client/
      measure.jsonl
    server/
      quicprobe-stats.jsonl
    baseline/
      iperf3.jsonl
```

The local controller fetches bundles from all nodes and stores them under:

```text
bench/moqxprobe/results/<run_id>/
```

The bundle must preserve:

- `transport-bench-v1` JSONL summaries;
- quicprobe native JSON/JSONL sidecars;
- iperf3 baseline artifacts;
- process stdout/stderr;
- command metadata;
- daemon/node metadata;
- path metadata supplied by the controller.

## Security model

- Bind to private network or Tailscale addresses by default.
- Require bearer-token auth for every endpoint.
- Store token outside git, preferably generated per lab/run.
- Do not store Terraform/provider credentials on benchmark nodes.
- Execute only configured tools.
- Do not execute shell strings.
- Restrict file access to the configured work directory plus configured tool
  paths.
- Keep partial failed runs until explicit cleanup.

## Phases

### Phase 1: Thin daemon runner and artifact API

Implement `probed` as an HTTP daemon with:

- config loading;
- bearer auth;
- health/node/tool endpoints;
- run create/status/delete;
- process start/status/stop;
- stdout/stderr capture;
- artifact list/fetch;
- bundle tarball fetch;
- unit tests around config, auth, process lifecycle, path safety, and artifact
  listing;
- local fake-tool smoke test.

This phase still deploys tools through existing SSH/just recipes.

### Phase 2: Packaging and deployment

Package and deploy `probed` to lab nodes:

- Burrito self-contained binary artifact under
  `/opt/moqx-bench/probed/current/bin/probed`;
- config under `/etc/moqx-bench/probed.json`;
- token under `/etc/moqx-bench/probed.token`;
- work dir `/var/lib/probed`;
- pidfile/log under `/var/lib/probed`;
- explicit SSH-start recipe;
- `just` recipes to build, deploy, start, stop, and health-check `probed`.

### Phase 3: Local controller loop

Add local operator commands or `just` recipes that use the daemon API to:

- start an iperf3 baseline;
- start a quicprobe reference server;
- run `moqxprobe measure` on the client node;
- run quicprobe reference-client controls;
- poll process status;
- fetch all node bundles;
- leave infrastructure running for iterative client hardening.

### Phase 4: Tool activation and cached updates

Add content-addressed artifact upload/activation if Phase 2 SSH deployment is
still too slow:

- upload or stage `moqxprobe`, `quicprobe`, and `probed` artifacts by hash;
- activate by name/hash through `POST /v1/tools/:name/activate`;
- keep previous versions available for rollback during a lab session.

### Phase 5: Remote validation loop

Use the daemon to run the next #40 validation:

- iperf3 baseline;
- quicprobe-to-quicprobe DATAGRAM control around 30k/32k pps;
- MOQX-client-to-quicprobe DATAGRAM bracket around 30k/32k pps;
- one stream-pressure smoke with the new `StreamSender`;
- fetch bundles and update #40/#26;
- keep infra up while tuning, then explicitly destroy when done.

## Acceptance criteria

- [ ] `bench/probed` exposes the Phase 1 HTTP API with bearer-token auth.
- [ ] `probed` loads config from file/env and reports node/tool status.
- [ ] Only configured absolute tool paths can be executed.
- [ ] Processes are started with argv arrays, not shell strings.
- [ ] Process stdout/stderr, command metadata, exit data, and declared
      artifacts are stored under the run directory.
- [ ] Run/process states follow the documented state model.
- [ ] Artifacts can be listed, fetched individually, and fetched as a bundle.
- [ ] Path traversal outside the work directory is rejected.
- [ ] A local fake-tool smoke test proves create-run, start-process,
      observe-status, fetch-artifact, fetch-bundle, and cleanup.
- [ ] Packaging/deploy recipes can put `probed` on a lab node and verify
      `/v1/health`.
- [ ] The first remote smoke starts quicprobe server through `probed`, runs a
      `moqxprobe measure` client through `probed`, fetches JSONL/log artifacts,
      and validates the JSONL with `moqxprobe report`.
- [ ] Documentation records that `probed` does not own benchmark semantics and
      does not manage cloud lifecycle.

## Out of scope

- cloud provisioning or teardown;
- listener/relay benchmark roles;
- public internet security hardening;
- dashboards, Prometheus, or long-lived collectors;
- replacing `transport-bench-v1`;
- Benchee as the distributed benchmark runner;
- MsQuic `secnetperf` in the immediate roadmap.

## Existing decisions carried forward

- 2026-05-29: Benchee is not the primary runner for distributed QUIC pressure
  tests. It may be used for isolated local microbenchmarks only.
- 2026-05-29: Do not add MsQuic `secnetperf` to the immediate roadmap. Keep
  repo-owned `bench/quicprobe` as the controlled reference peer.
- 2026-05-29: Provisioning stays under `bench/infra`; benchmark commands and
  daemon endpoints do not create or destroy cloud resources.
- 2026-05-29: Shared deterministic benchmark specs live in `bench/ledger`.
- 2026-06-05: `probed` is now the next transport-bench implementation step
  because remote validation is operationally painful enough to slow the client
  performance loop.
- 2026-06-05: `probed` v1 is caller-side only; listener/relay performance is
  future relay scope.

## Comments

- 2026-06-05: Consolidated the daemon/API/configuration design into this single
  implementation issue after deciding that the next useful remote performance
  loop is to deploy `probed` servers first, keep infrastructure up, and validate
  the new caller-side benchmark clients through the daemon.
- 2026-06-05: Implementation progress: added the first `bench/probed` HTTP
  daemon API, config-file/env loading, bearer auth, configured-tool validation,
  process lifecycle/readiness handling, run artifact listing/fetch/bundling,
  cleanup protection for active processes, local fake-tool smoke coverage,
  Docker release packaging, and `just` recipes to build/deploy/start/stop/check
  `probed`. Remote infrastructure smoke is intentionally not run yet per the
  current task constraint.
- 2026-06-05: Refined the daemon shape after checking current Bandit and Plug
  documentation: `probed` now serves `Probed.Router` through Bandit, uses
  `Plug.Router`/`Plug.Parsers` for the HTTP API, and keeps mutable run/process
  state in `Probed.Runner`. Tests use `Plug.Test` for router behavior plus one
  real Bandit smoke on an ephemeral local port.
- 2026-06-05: Switched the intended `probed` deployment artifact from a Mix
  release tarball to a Docker-built Burrito binary tarball, matching the
  self-contained binary deployment model already used for `moqxprobe`.
  The traditional Mix release remains as a fallback build sanity check; remote
  start/stop recipes now manage the Burrito binary with an explicit pidfile and
  verify health through the HTTP API.
- 2026-06-05: Kept the `probed` Burrito Docker build on the native Linux
  builder instead of forcing a target-architecture builder image. Unlike
  `moqxprobe`, `probed` does not compile quicer or other benchmark-path NIFs,
  so Burrito/Zig can select the Linux output target without requiring the whole
  Elixir build to run under target-architecture emulation.
- 2026-06-05: Chose `curl` plus a written playbook as the first controller
  surface instead of adding an Elixir client/controller layer. Added a local
  curl smoke script that starts two local `probed` daemons, drives iperf3,
  reference-client, and MOQX-client runs through the HTTP API, fetches bundles,
  and validates JSONL reports. Also tightened declared artifact handling:
  `probed` now prepares parent directories for declared tool-owned artifacts.
- 2026-06-05: Local curl smoke passed with run id
  `20260605T190155Z-local-curl-smoke`. It started local client/server
  `probed` daemons on dynamic ports, ran loopback iperf3 baseline,
  reference-client-to-reference-server stream measurement, and
  MOQX-client-to-reference-server stream measurement through the HTTP API,
  fetched client/server bundles, and validated all produced JSONL with
  `moqxprobe report`. This is loopback calibration only; it proves the
  orchestration/control-plane loop, not real network performance.
- 2026-06-08: Remote smoke attempt used run id
  `20260605T190822Z-psmoke`. Hetzner ARM placement was unavailable for the
  attempted tiny/smoke ARM profiles (`arm-hel1-tiny`, `arm-nbg1-tiny`, and
  `arm-smoke`), so the smoke fell back to the existing `x86-control` profile:
  `ccx23` client in `fsn1`, `ccx23` server in `hel1`, private path
  `10.88.0.11 -> 10.88.0.12`. Client cloud-init failed before package install
  at the private-network route check with `RTNETLINK answers: Network is
  unreachable`; the node still had the private address/route, so the smoke
  manually installed the minimal runtime tools (`curl`, `jq`, `tar`, `iperf3`)
  on that disposable client. Manual private readiness then passed with 0% ICMP
  loss, about 26.6 ms average RTT, and about 835 Mbps for a one-second TCP
  iperf check.
- 2026-06-08: `quicprobe` and `probed` x86_64 artifacts built and deployed.
  The normal local Docker x86_64 `moqxprobe` Burrito build is not usable on
  this Apple ARM host because the emulated amd64 `elixir:1.19.5-otp-28` image
  crashes in OTP `user_drv` before project compilation. A native x86 build was
  then produced on the disposable Hetzner server from `git archive HEAD`, and
  it compiled a correct x86_64 `libquicer_nif.so`, but deployment/start failed
  because Burrito's Linux runtime is musl-based while the quicer NIF expected
  the glibc symbol `malloc_stats`. This blocks the full remote
  `moqxprobe measure` smoke until `moqxprobe` packaging is redesigned for the
  quicer NIF, for example by using a glibc-compatible release artifact or by
  making the native dependency linkage compatible with Burrito's musl runtime.
- 2026-06-08: Remote `probed` Burrito itself is viable: both nodes started the
  daemon bound to their private IPs and authenticated health returned
  `{"status":"ok"}` for node ids `client` and `server`. The `just`
  `bench-transport-start-probed-role` health check currently reports a false
  failure because it curls `/v1/health` without the bearer token; the daemon was
  listening and correctly returned `401` unauthenticated.
- 2026-06-08: Because `moqxprobe` packaging blocked the full smoke, ran a
  minimal curl-driven remote `probed` API smoke with only `iperf3`:
  `20260605T190822Z-psmoke-minimal-iperf`. The controller created matching runs
  on both private probed endpoints, started an `iperf3 --server` process on the
  server through `probed`, started an `iperf3 --client` process on the client
  through `probed`, and fetched both bundles. Both processes exited with status
  0; the client JSON reported about 777 Mbps over 1.027 seconds. Bundles are
  stored under
  `bench/moqxprobe/results/20260605T190822Z-psmoke/probed-minimal-iperf/`.
  The disposable infrastructure was destroyed afterwards, and
  `just bench-transport-verify-clean` reported no Terraform state entries or
  labelled Hetzner resources remaining.
- 2026-06-08: Follow-up fix for the cloud-init blocker: private-route
  readiness now checks each node's peer private IP after netplan apply instead
  of probing the subnet gateway as if it were a routable endpoint. This is
  validated by Terraform fmt/validate and a plan render for
  `20260605T190822Z-psmoke` with the `x86-control` profile; the next disposable
  apply should confirm cloud-init reaches `done` on both nodes without manual
  package installation.
