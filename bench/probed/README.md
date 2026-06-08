# Probed

`bench/probed` is the thin remote control-plane daemon for transport benchmark
lab nodes.

It is a process supervisor and artifact store. It does not own benchmark
semantics, does not create or destroy cloud resources, and does not depend on
`moqx`, `moqxprobe`, quicer, or `bench/quicprobe`. `bench/moqxprobe` owns
benchmark workloads and reporting, `bench/quicprobe` owns reference QUIC
traffic, `bench/ledger` owns shared artifact contracts, and `bench/infra` owns
provisioning.

## Configuration

The default config path is:

```text
/etc/moqx-bench/probed.json
```

Supported env overrides:

```text
PROBED_CONFIG
PROBED_BIND
PROBED_TOKEN
PROBED_WORK_DIR
PROBED_NODE_ID
```

Example:

```json
{
  "node_id": "client",
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

Tool paths must be absolute. `probed` executes only configured tools, using
argv arrays through process APIs. It does not execute shell command strings.

For curl-driven local and remote smoke runs, see `PLAYBOOK.md`.

## HTTP API

The HTTP surface is a `Plug.Router` served by Bandit. The router stays thin:
it authenticates requests, parses JSON bodies through `Plug.Parsers`, and
delegates process/run/artifact state to `Probed.Runner`.

Every endpoint requires:

```text
Authorization: Bearer <token>
```

Endpoints:

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

Phase 1 process roles are:

```text
baseline_server
baseline_client
reference_server
reference_client
moqx_client
```

There is no listener/relay benchmark role in v1.

## State Model

Run states:

```text
active -> complete
active -> aborted
complete/aborted -> cleaned
```

Process states:

```text
starting
ready
running
stopping
exited
timed_out
```

`ready: {"type":"none"}` starts immediately as `running`.
`ready: {"type":"stdout_contains","text":"..."}` starts as `starting` and
transitions to `ready` when stdout contains the configured text.
`ready: {"type":"tcp_port","port":4433}` polls localhost until a TCP connect
succeeds. `ready: {"type":"udp_port","port":4433}` uses a bounded startup delay
because UDP listener discovery is not portable enough for the thin v1 daemon.
Both port readiness modes accept `startup_delay_ms`, defaulting to `100`.
Clients are usually observed until `exited`; servers are usually observed until
`ready` before client work starts.

## Artifact Layout

Each run is stored under the configured work directory:

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

Artifact fetches are restricted to the run directory. Path traversal is
rejected. Partial and failed runs remain inspectable until the operator calls
`DELETE /v1/runs/:run_id`.

Process logs are automatic under `processes/<process_id>/`. Declared process
artifacts are tool-owned files under `artifacts/`; `probed` prepares their
parent directories before launching the process, but the tool must write the
file itself.

## Packaging

Build the Linux Mix release artifact:

```bash
just bench-transport-build-probed linux_arm64
```

When a target architecture cannot be built reliably through local Docker
emulation, build the release natively on an already-provisioned lab role and
fetch the artifact:

```bash
just bench-transport-build-probed-remote-role <run-id> client linux_x86_64
```

Deploy it to the disposable Terraform roles:

```bash
just bench-transport-deploy-probed linux_arm64
```

This artifact is a standard Elixir release tarball containing `bin/probed` and
an included ERTS. It is target-specific, matching the `moqxprobe` release
model, so the remote node does not need to provide a compatible runtime to run
the deployed daemon.

Start the daemon and verify `/v1/health` from each node:

```bash
just bench-transport-start-probed-role <run-id> client
just bench-transport-start-probed-role <run-id> server
```

Stop it:

```bash
just bench-transport-stop-probed-role <run-id> client
just bench-transport-stop-probed-role <run-id> server
```

The start recipe installs:

```text
/opt/moqx-bench/probed/current/bin/probed
/etc/moqx-bench/probed.json
/etc/moqx-bench/probed.token
/var/lib/probed
/var/lib/probed/probed.pid
/var/lib/probed/probed.log
```

The token is generated locally under the per-run key directory and copied to the
node over SSH.

## Suite Driver

`probed` is intentionally not the benchmark runner. The repo-owned controller
for repeated remote runs is:

```bash
just bench-transport-probed-suite <run-id>
```

By default it runs the fast remote suite
`iperf3,reference_stream,moqx_stream`. It drives all processes through the
`probed` HTTP API, fetches bundles from both nodes, validates every produced
JSONL with `moqxprobe report`, and writes a manifest under
`bench/moqxprobe/results/<run-id>/probed-suite/<api-run-id>/`.

For DATAGRAM checks, extend the suite instead of changing the daemon:

```bash
PROBED_SUITE_TESTS=iperf3,reference_stream,moqx_stream,reference_datagram,moqx_datagram \
DATAGRAM_RATE=1000 \
DURATION_SECONDS=1 \
just bench-transport-probed-suite <run-id>
```

For the current #40 validation loop, prefer the bracket wrapper once the lab is
already provisioned, private-path checked, and tools are deployed:

```bash
just bench-transport-probed-datagram-bracket <run-id> 30000,32000
```

It runs `iperf3,reference_stream,moqx_stream` once, then runs
`reference_datagram,moqx_datagram` once per requested DATAGRAM rate. Defaults
are tuned for the ARM near-limit check: 1180-byte DATAGRAMs, 3-second paced
steps, delivery threshold 0.95, and offered-rate tolerance 0.95. It writes an
aggregate manifest under
`bench/moqxprobe/results/<run-id>/probed-datagram-bracket/<bracket-id>/` while
leaving each underlying `remote_curl_suite.sh` run under the existing
`probed-suite/<api-run-id>/` layout.

When iterating on `moqxprobe`, prefer the update-and-run loop:

```bash
just bench-transport-iterate-moqxprobe <run-id> linux_x86_64 iperf3,reference_stream,moqx_stream
```

That command snapshots the current source tree, including dirty non-ignored
changes, builds a target release natively on the selected lab role with remote
caches preserved, deploys the resulting artifact to both nodes, verifies
`probed` health, and then runs the suite. The suite manifest records the
resolved `/opt/moqx-bench/*/current` symlinks and `moqxprobe` artifact metadata
before the run.

See `PLAYBOOK.md` for the full curl-level shape and environment overrides.
