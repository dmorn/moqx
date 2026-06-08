# Probed Curl Playbook

This playbook uses `curl` and `jq` as the controller. It is intentionally
low-level: if the playbook feels awkward, the HTTP API is probably awkward.

`probed` is only the remote process supervisor and artifact store. Benchmark
semantics stay in `moqxprobe`; reference QUIC traffic stays in `quicprobe`;
path setup stays in `bench/infra`.

## Local Curl Smoke

Run the full loopback smoke:

```bash
bench/probed/scripts/local_curl_smoke.sh
```

By default the local smoke uses a generated wrapper that runs `moqxprobe` from
the current source tree with `mix`. This keeps the local orchestration loop
independent from release packaging.

To force a specific `moqxprobe` executable:

```bash
MOQXPROBE_BIN=/path/to/moqxprobe bench/probed/scripts/local_curl_smoke.sh
```

The script starts two local `probed` daemons on high random local ports unless
you override them:

```text
client: http://127.0.0.1:<PROBED_CLIENT_PORT>
server: http://127.0.0.1:<PROBED_SERVER_PORT>
```

It then drives these benchmark-shaped steps through the HTTP API:

- create the same run on both nodes;
- start an `iperf3` server through server `probed`;
- run `moqxprobe iperf3-baseline` through client `probed`;
- start a `quicprobe` reference server through server `probed`;
- run `moqxprobe measure --topology reference-client-to-reference-server`;
- run `moqxprobe measure --topology moqx-client-to-reference-server`;
- fetch client/server bundles;
- validate each JSONL with `moqxprobe report`;
- stop the long-lived server processes.

The output prints the run id, lab directory, and bundle paths. By default the
script stops the daemons but keeps the lab directory for inspection.

Useful overrides:

```bash
RUN_ID=manual-smoke \
PROBED_LAB_DIR=/private/tmp/probed-manual \
PROBED_CLIENT_PORT=9157 \
PROBED_SERVER_PORT=9158 \
QUICPROBE_PORT=55433 \
IPERF3_PORT=55201 \
bench/probed/scripts/local_curl_smoke.sh
```

## Manual API Shape

Set the common variables:

```bash
TOKEN=local-smoke-token
CLIENT=http://127.0.0.1:9157
SERVER=http://127.0.0.1:9158
RUN_ID=manual-smoke

api_client() {
  curl -fsS -H "Authorization: Bearer $TOKEN" "$@"
}

api_server() {
  curl -fsS -H "Authorization: Bearer $TOKEN" "$@"
}
```

Health:

```bash
api_client "$CLIENT/v1/health" | jq .
api_server "$SERVER/v1/health" | jq .
```

Create a run on both nodes:

```bash
body="$(jq -n --arg run_id "$RUN_ID" '{
  run_id: $run_id,
  metadata: {purpose: "manual-curl-smoke", evidence_tier: "loopback_calibration"}
}')"

api_client -X POST -H "Content-Type: application/json" --data "$body" "$CLIENT/v1/runs"
api_server -X POST -H "Content-Type: application/json" --data "$body" "$SERVER/v1/runs"
```

Start a server process:

```bash
server_body="$(jq -n '{
  role: "reference_server",
  tool: "quicprobe",
  argv: [
    "server",
    "--addr", "127.0.0.1:55433",
    "--cert", "/path/to/server.pem",
    "--key", "/path/to/server-key.pem",
    "--alpn", "moqx-test",
    "--stats-output", "/path/to/server-work/runs/manual-smoke/artifacts/server/quicprobe-stats.jsonl"
  ],
  ready: {type: "udp_port", port: 55433, startup_delay_ms: 300},
  timeout_ms: 60000,
  artifacts: {stats: "server/quicprobe-stats.jsonl"}
}')"

SERVER_PROCESS="$(
  api_server -X POST -H "Content-Type: application/json" \
    --data "$server_body" \
    "$SERVER/v1/runs/$RUN_ID/processes" | jq -r .process_id
)"
```

Poll process state:

```bash
api_server "$SERVER/v1/runs/$RUN_ID/processes/$SERVER_PROCESS" | jq .
```

Start a benchmark client process:

```bash
client_body="$(jq -n '{
  role: "moqx_client",
  tool: "moqxprobe",
  argv: [
    "measure",
    "--topology", "moqx-client-to-reference-server",
    "--server", "127.0.0.1",
    "--port", "55433",
    "--ca", "/path/to/ca.pem",
    "--servername", "localhost",
    "--stream-count", "1",
    "--payload-size", "256",
    "--payload-count", "2",
    "--output", "/path/to/client-work/runs/manual-smoke/artifacts/client/moqx-stream.jsonl"
  ],
  timeout_ms: 15000,
  artifacts: {jsonl: "client/moqx-stream.jsonl"}
}')"

CLIENT_PROCESS="$(
  api_client -X POST -H "Content-Type: application/json" \
    --data "$client_body" \
    "$CLIENT/v1/runs/$RUN_ID/processes" | jq -r .process_id
)"
```

Fetch artifacts and bundles:

```bash
api_client "$CLIENT/v1/runs/$RUN_ID/artifacts" | jq .
api_server "$SERVER/v1/runs/$RUN_ID/artifacts" | jq .

api_client "$CLIENT/v1/runs/$RUN_ID/bundle" > client-bundle.tar.gz
api_server "$SERVER/v1/runs/$RUN_ID/bundle" > server-bundle.tar.gz
```

Stop long-lived server processes:

```bash
api_server -X DELETE "$SERVER/v1/runs/$RUN_ID/processes/$SERVER_PROCESS"
```

Cleanup the run only after bundles are fetched:

```bash
api_client -X DELETE "$CLIENT/v1/runs/$RUN_ID"
api_server -X DELETE "$SERVER/v1/runs/$RUN_ID"
```

## Remote Use

The remote smoke should use the same API calls, with only these substitutions:

- `CLIENT` and `SERVER` become the private `probed` endpoints on the lab nodes;
- tool paths come from `/opt/moqx-bench/.../current/bin/...`;
- certificate paths come from the staged remote cert directory;
- output paths use `/var/lib/probed/runs/<run_id>/artifacts/...`;
- the server address passed to clients is the private IP of the server node.

Run the remote smoke only after the local curl smoke passes.
