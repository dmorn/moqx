#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

run_id="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-local-curl-smoke}"
lab_dir="${PROBED_LAB_DIR:-${TMPDIR:-/tmp}/moqx-probed-local-curl-smoke}"
token="${PROBED_TOKEN:-local-smoke-token}"
alpn="${PROBED_SMOKE_ALPN:-moqx-test}"

used_ports=""

pick_port() {
  local port

  for _attempt in $(seq 1 100); do
    port="$((49152 + (RANDOM % 12000)))"

    case " $used_ports " in
      *" $port "*) continue ;;
    esac

    if ! (: < "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      used_ports="$used_ports $port"
      printf '%s\n' "$port"
      return 0
    fi
  done

  printf '%s\n' 'could not pick an available local port' >&2
  exit 2
}

client_port="${PROBED_CLIENT_PORT:-$(pick_port)}"
server_port="${PROBED_SERVER_PORT:-$(pick_port)}"
quic_port="${QUICPROBE_PORT:-$(pick_port)}"
iperf_port="${IPERF3_PORT:-$(pick_port)}"

client_base="http://127.0.0.1:${client_port}"
server_base="http://127.0.0.1:${server_port}"
client_work="$lab_dir/client-work"
server_work="$lab_dir/server-work"
cert_dir="$lab_dir/certs"
bin_dir="$lab_dir/bin"
bundle_dir="$lab_dir/bundles"
logs_dir="$lab_dir/logs"

requested_moqxprobe_bin="${MOQXPROBE_BIN:-}"
quicprobe_bin="$bin_dir/quicprobe"
iperf3_bin="${IPERF3_BIN:-$(command -v iperf3 || true)}"

client_pid=""
server_pid=""

cleanup() {
  set +e

  if [ "${PROBED_KEEP_DAEMONS:-0}" != "1" ]; then
    if [ -n "$client_pid" ]; then kill "$client_pid" >/dev/null 2>&1 || true; fi
    if [ -n "$server_pid" ]; then kill "$server_pid" >/dev/null 2>&1 || true; fi
  fi
}
trap cleanup EXIT

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 2
  fi
}

require_tool curl
require_tool jq
require_tool openssl
require_tool mise

if [ -z "$iperf3_bin" ]; then
  printf '%s\n' 'Missing iperf3. Set IPERF3_BIN or install iperf3.' >&2
  exit 2
fi

rm -rf "$lab_dir"
mkdir -p "$bin_dir" "$bundle_dir" "$cert_dir" "$logs_dir" "$client_work" "$server_work"

if [ -n "$requested_moqxprobe_bin" ]; then
  moqxprobe_bin="$requested_moqxprobe_bin"
elif [ "${PROBED_BUILD_MOQXPROBE:-0}" = "1" ] ||
  [ "${PROBED_USE_MOQXPROBE_BURRITO:-0}" = "1" ]; then
  moqxprobe_bin="$repo_root/bench/moqxprobe/burrito_out/moqxprobe_burrito_darwin_arm64"
  (cd "$repo_root" && just bench-transport-build-burrito darwin_arm64)
else
  moqxprobe_bin="$bin_dir/moqxprobe"

  cat > "$moqxprobe_bin" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$repo_root/bench/moqxprobe"
exec mix run -e 'MOQXProbe.CLI.main(System.argv())' -- "\$@"
EOF

  chmod 0755 "$moqxprobe_bin"
fi

if [ ! -x "$moqxprobe_bin" ]; then
  printf 'Missing moqxprobe executable: %s\n' "$moqxprobe_bin" >&2
  exit 2
fi

(cd "$repo_root/bench/probed" && mix compile >/dev/null)
(cd "$repo_root/bench/quicprobe" && mise exec go@1.23 -- go build -trimpath -o "$quicprobe_bin" .)

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 7 \
  -subj "/CN=moqx local smoke CA" \
  -keyout "$cert_dir/ca-key.pem" \
  -out "$cert_dir/ca.pem" \
  >/dev/null 2>&1

openssl req \
  -newkey rsa:2048 \
  -nodes \
  -subj "/CN=localhost" \
  -keyout "$cert_dir/server-key.pem" \
  -out "$cert_dir/server.csr" \
  >/dev/null 2>&1

printf '%s\n' 'subjectAltName=DNS:localhost,IP:127.0.0.1' > "$cert_dir/server.ext"
printf '%s\n' 'extendedKeyUsage=serverAuth' >> "$cert_dir/server.ext"

openssl x509 \
  -req \
  -in "$cert_dir/server.csr" \
  -CA "$cert_dir/ca.pem" \
  -CAkey "$cert_dir/ca-key.pem" \
  -CAcreateserial \
  -days 7 \
  -sha256 \
  -extfile "$cert_dir/server.ext" \
  -out "$cert_dir/server.pem" \
  >/dev/null 2>&1

write_config() {
  local node_id="$1"
  local bind="$2"
  local work_dir="$3"
  local output="$4"

  jq -n \
    --arg node_id "$node_id" \
    --arg bind "$bind" \
    --arg work_dir "$work_dir" \
    --arg token "$token" \
    --arg moqxprobe "$moqxprobe_bin" \
    --arg quicprobe "$quicprobe_bin" \
    --arg iperf3 "$iperf3_bin" \
    '{
      node_id: $node_id,
      bind: $bind,
      work_dir: $work_dir,
      token: $token,
      tools: {
        moqxprobe: {path: $moqxprobe},
        quicprobe: {path: $quicprobe},
        iperf3: {path: $iperf3}
      }
    }' > "$output"
}

write_config "local-client" "127.0.0.1:${client_port}" "$client_work" "$lab_dir/client-probed.json"
write_config "local-server" "127.0.0.1:${server_port}" "$server_work" "$lab_dir/server-probed.json"

start_probed() {
  local config="$1"
  local log="$2"

  (
    cd "$repo_root/bench/probed"
    exec env PROBED_CONFIG="$config" mix run --no-halt
  ) > "$log" 2>&1 &

  printf '%s\n' "$!"
}

client_pid="$(start_probed "$lab_dir/client-probed.json" "$logs_dir/probed-client.log")"
server_pid="$(start_probed "$lab_dir/server-probed.json" "$logs_dir/probed-server.log")"

base_for() {
  case "$1" in
    client) printf '%s\n' "$client_base" ;;
    server) printf '%s\n' "$server_base" ;;
    *) printf 'unknown node: %s\n' "$1" >&2; exit 2 ;;
  esac
}

api() {
  local node="$1"
  local method="$2"
  local path="$3"
  local body="${4:-}"
  local base

  base="$(base_for "$node")"

  if [ -n "$body" ]; then
    curl -fsS \
      -X "$method" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      --data "$body" \
      "$base$path"
  else
    curl -fsS \
      -X "$method" \
      -H "Authorization: Bearer $token" \
      "$base$path"
  fi
}

wait_health() {
  local node="$1"

  for _attempt in $(seq 1 100); do
    if api "$node" GET /v1/health >/dev/null 2>&1; then
      return 0
    fi

    sleep 0.1
  done

  printf 'probed %s did not become healthy\n' "$node" >&2
  return 1
}

wait_process_state() {
  local node="$1"
  local process_id="$2"
  local expected="$3"
  local body
  local state

  for _attempt in $(seq 1 200); do
    body="$(api "$node" GET "/v1/runs/$run_id/processes/$process_id")"
    state="$(printf '%s' "$body" | jq -r '.state')"

    if [ "$state" = "$expected" ]; then
      printf '%s\n' "$body"
      return 0
    fi

    if [ "$state" = "failed" ] || [ "$state" = "timed_out" ]; then
      printf 'process %s on %s reached terminal state %s\n%s\n' \
        "$process_id" "$node" "$state" "$body" >&2
      return 1
    fi

    sleep 0.1
  done

  printf 'process %s on %s did not reach %s\n' "$process_id" "$node" "$expected" >&2
  api "$node" GET "/v1/runs/$run_id/processes/$process_id" >&2 || true
  return 1
}

start_process() {
  local node="$1"
  local body="$2"

  api "$node" POST "/v1/runs/$run_id/processes" "$body" | jq -r '.process_id'
}

common_measure_args() {
  local output="$1"

  jq -n \
    --arg run_id "$run_id" \
    --arg server "127.0.0.1" \
    --arg port "$quic_port" \
    --arg ca "$cert_dir/ca.pem" \
    --arg servername "localhost" \
    --arg alpn "$alpn" \
    --arg output "$output" \
    '[
      "--server", $server,
      "--port", $port,
      "--ca", $ca,
      "--servername", $servername,
      "--alpn", $alpn,
      "--stream-count", "1",
      "--payload-size", "256",
      "--payload-count", "2",
      "--timeout-seconds", "5",
      "--timeout-margin-seconds", "2",
      "--run-id", $run_id,
      "--output", $output
    ]'
}

wait_health client
wait_health server

for node in client server; do
  api "$node" POST /v1/runs "$(jq -n --arg run_id "$run_id" '{
    run_id: $run_id,
    metadata: {
      purpose: "local-curl-smoke",
      evidence_tier: "loopback_calibration"
    }
  }')" >/dev/null
done

iperf_server_process="$(
  start_process server "$(
    jq -n \
      --argjson port "$iperf_port" \
      '{
        role: "baseline_server",
        tool: "iperf3",
        argv: ["--server", "--bind", "127.0.0.1", "--port", ($port | tostring)],
        ready: {type: "tcp_port", port: $port, startup_delay_ms: 100},
        timeout_ms: 30000
      }'
  )"
)"
wait_process_state server "$iperf_server_process" ready >/dev/null

iperf_output="$client_work/runs/$run_id/artifacts/baseline/iperf3.jsonl"
iperf_client_process="$(
  start_process client "$(
    jq -n \
      --arg output "$iperf_output" \
      --arg iperf3 "$iperf3_bin" \
      --argjson port "$iperf_port" \
      '{
        role: "baseline_client",
        tool: "moqxprobe",
        argv: [
          "iperf3-baseline",
          "--server", "127.0.0.1",
          "--port", ($port | tostring),
          "--tcp-duration", "1",
          "--udp-duration", "1",
          "--udp-bitrates", "1M",
          "--iperf3-command", $iperf3,
          "--run-id", "local-curl-smoke-iperf3",
          "--output", $output
        ],
        timeout_ms: 15000,
        artifacts: {jsonl: "baseline/iperf3.jsonl"}
      }'
  )"
)"
wait_process_state client "$iperf_client_process" exited >/dev/null

quic_server_process="$(
  start_process server "$(
    jq -n \
      --arg addr "127.0.0.1:${quic_port}" \
      --arg cert "$cert_dir/server.pem" \
      --arg key "$cert_dir/server-key.pem" \
      --arg alpn "$alpn" \
      --arg stats "$server_work/runs/$run_id/artifacts/server/quicprobe-stats.jsonl" \
      --argjson port "$quic_port" \
      '{
        role: "reference_server",
        tool: "quicprobe",
        argv: [
          "server",
          "--addr", $addr,
          "--cert", $cert,
          "--key", $key,
          "--alpn", $alpn,
          "--stats-output", $stats
        ],
        ready: {type: "udp_port", port: $port, startup_delay_ms: 300},
        timeout_ms: 60000,
        artifacts: {stats: "server/quicprobe-stats.jsonl"}
      }'
  )"
)"
wait_process_state server "$quic_server_process" ready >/dev/null

reference_output="$client_work/runs/$run_id/artifacts/client/reference-stream.jsonl"
reference_args="$(common_measure_args "$reference_output")"
reference_process="$(
  start_process client "$(
    jq -n \
      --argjson common "$reference_args" \
      --arg quicprobe "$quicprobe_bin" \
      '{
        role: "reference_client",
        tool: "moqxprobe",
        argv: (
          ["measure", "--topology", "reference-client-to-reference-server"] +
          $common +
          ["--quicprobe-command", $quicprobe]
        ),
        timeout_ms: 15000,
        artifacts: {jsonl: "client/reference-stream.jsonl"}
      }'
  )"
)"
wait_process_state client "$reference_process" exited >/dev/null

moqx_output="$client_work/runs/$run_id/artifacts/client/moqx-stream.jsonl"
moqx_args="$(common_measure_args "$moqx_output")"
moqx_process="$(
  start_process client "$(
    jq -n \
      --argjson common "$moqx_args" \
      '{
        role: "moqx_client",
        tool: "moqxprobe",
        argv: (["measure", "--topology", "moqx-client-to-reference-server"] + $common),
        timeout_ms: 15000,
        artifacts: {jsonl: "client/moqx-stream.jsonl"}
      }'
  )"
)"
wait_process_state client "$moqx_process" exited >/dev/null

api server DELETE "/v1/runs/$run_id/processes/$quic_server_process" >/dev/null || true
api server DELETE "/v1/runs/$run_id/processes/$iperf_server_process" >/dev/null || true

curl -fsS \
  -H "Authorization: Bearer $token" \
  "$client_base/v1/runs/$run_id/bundle" \
  -o "$bundle_dir/client-bundle.tar.gz"

curl -fsS \
  -H "Authorization: Bearer $token" \
  "$server_base/v1/runs/$run_id/bundle" \
  -o "$bundle_dir/server-bundle.tar.gz"

"$moqxprobe_bin" report "$iperf_output" >/dev/null
"$moqxprobe_bin" report "$reference_output" >/dev/null
"$moqxprobe_bin" report "$moqx_output" >/dev/null

printf 'Local probed curl smoke passed.\n'
printf 'Run id: %s\n' "$run_id"
printf 'Client API: %s\n' "$client_base"
printf 'Server API: %s\n' "$server_base"
printf 'QUIC port: %s\n' "$quic_port"
printf 'iperf3 port: %s\n' "$iperf_port"
printf 'Lab dir: %s\n' "$lab_dir"
printf 'Client bundle: %s\n' "$bundle_dir/client-bundle.tar.gz"
printf 'Server bundle: %s\n' "$bundle_dir/server-bundle.tar.gz"
