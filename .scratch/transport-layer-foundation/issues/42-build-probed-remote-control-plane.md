# Build probed remote benchmark control plane

Status: ready-for-agent
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

- release artifact under `/opt/moqx-bench/probed/current/bin/probed`;
- config under `/etc/moqx-bench/probed.json`;
- token under `/etc/moqx-bench/probed.token`;
- work dir `/var/lib/probed`;
- systemd unit or explicit SSH-start recipe;
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
