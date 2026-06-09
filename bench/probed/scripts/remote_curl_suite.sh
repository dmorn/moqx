#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

run_file="$repo_root/bench/moqxprobe/.run/current"
run_id="${RUN_ID:-}"
tests="${PROBED_SUITE_TESTS:-iperf3,reference_stream,moqx_stream}"
probed_port="${PROBED_PORT:-9157}"
quic_port="${QUICPROBE_PORT:-55433}"
iperf3_port="${IPERF3_PORT:-55201}"
alpn="${ALPN:-moqx-test}"
api_run_id="${PROBED_API_RUN_ID:-}"

stream_count="${STREAM_COUNT:-1}"
payload_size="${PAYLOAD_SIZE:-256}"
payload_count="${PAYLOAD_COUNT:-2}"
timeout_seconds="${TIMEOUT_SECONDS:-5}"
timeout_margin_seconds="${TIMEOUT_MARGIN_SECONDS:-2}"

tcp_duration="${IPERF3_TCP_DURATION:-1}"
udp_duration="${IPERF3_UDP_DURATION:-1}"
udp_bitrates="${IPERF3_UDP_BITRATES:-1M}"
udp_length="${IPERF3_UDP_LENGTH:-}"

datagram_size="${DATAGRAM_SIZE:-1192}"
datagram_count="${DATAGRAM_COUNT:-1000}"
datagram_rate="${DATAGRAM_RATE:-}"
duration_seconds="${DURATION_SECONDS:-1}"
datagram_drain_limit="${DATAGRAM_DRAIN_LIMIT:-0}"
datagram_diagnostics="${DATAGRAM_DIAGNOSTICS:-summary}"
delivery_threshold="${DELIVERY_THRESHOLD:-1.0}"
offered_rate_tolerance="${OFFERED_RATE_TOLERANCE:-0.95}"
process_timeout_ms="${PROCESS_TIMEOUT_MS:-60000}"
quicer_settings="${QUICER_SETTINGS:-}"
quicer_datagram_send_flags="${QUICER_DATAGRAM_SEND_FLAGS:-}"

usage() {
  cat <<EOF
Usage:
  remote_curl_suite.sh [options]

Options:
  --run-id ID          Terraform/provisioning run id. Defaults to bench/moqxprobe/.run/current.
  --tests LIST         Comma-separated tests. Default: iperf3,reference_stream,moqx_stream.
  --probed-port PORT   probed HTTP port. Default: 9157.
  --quic-port PORT     quicprobe UDP port. Default: 55433.
  --iperf3-port PORT   iperf3 TCP/UDP port. Default: 55201.
  --api-run-id ID      probed run id. Defaults to <run-id>-probed-suite-<HHMMSS>.
  -h, --help           Show this help.

Supported tests:
  iperf3
  reference_stream
  moqx_stream
  reference_datagram
  moqx_datagram

Useful environment overrides:
  STREAM_COUNT PAYLOAD_SIZE PAYLOAD_COUNT
  IPERF3_TCP_DURATION IPERF3_UDP_DURATION IPERF3_UDP_BITRATES IPERF3_UDP_LENGTH
  DATAGRAM_SIZE DATAGRAM_COUNT DATAGRAM_RATE DURATION_SECONDS
  DATAGRAM_DRAIN_LIMIT DATAGRAM_DIAGNOSTICS DELIVERY_THRESHOLD OFFERED_RATE_TOLERANCE
  PROCESS_TIMEOUT_MS QUICER_SETTINGS QUICER_DATAGRAM_SEND_FLAGS
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --tests)
      tests="$2"
      shift 2
      ;;
    --probed-port)
      probed_port="$2"
      shift 2
      ;;
    --quic-port)
      quic_port="$2"
      shift 2
      ;;
    --iperf3-port)
      iperf3_port="$2"
      shift 2
      ;;
    --api-run-id)
      api_run_id="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$run_id" ] && [ -s "$run_file" ]; then
  run_id="$(cat "$run_file")"
fi

if [ -z "$run_id" ]; then
  printf '%s\n' 'Missing run id. Use --run-id or run just bench-transport-new-run first.' >&2
  exit 2
fi

if [ -z "$api_run_id" ]; then
  api_run_id="${run_id}-probed-suite-$(date -u +%H%M%S)"
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 2
  fi
}

require_tool curl
require_tool jq
require_tool openssl
require_tool ssh
require_tool scp
require_tool tar
require_tool just

test_enabled() {
  case ",$tests," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_tests() {
  local test_name

  IFS=',' read -r -a selected_tests <<< "$tests"

  for test_name in "${selected_tests[@]}"; do
    case "$test_name" in
      iperf3|reference_stream|moqx_stream|reference_datagram|moqx_datagram) ;;
      "")
        printf '%s\n' 'Empty test name in --tests.' >&2
        exit 2
        ;;
      *)
        printf 'Unsupported test: %s\n' "$test_name" >&2
        usage >&2
        exit 2
        ;;
    esac
  done
}

validate_tests

bench_dir="$repo_root/bench/moqxprobe"
infra_dir="$repo_root/bench/infra/hetzner"
result_dir="$bench_dir/results/$run_id/probed-suite/$api_run_id"
cert_dir="$result_dir/certs"
bundle_dir="$result_dir/bundles"
extract_dir="$result_dir/extracted"
report_dir="$result_dir/reports"
log_dir="$result_dir/logs"
manifest_path="$result_dir/manifest.json"

key="$bench_dir/.keys/$run_id/id_ed25519"
known_hosts="$bench_dir/.keys/$run_id/known_hosts"

test -f "$key" || {
  printf 'Missing SSH key for run %s at %s\n' "$run_id" "$key" >&2
  exit 2
}

mkdir -p "$cert_dir" "$bundle_dir" "$extract_dir" "$report_dir" "$log_dir"

servers_json="$(cd "$infra_dir" && terraform output -json servers)"
path_json="$(cd "$infra_dir" && terraform output -json path_metadata_private 2>/dev/null || true)"
evidence_tier="$(printf '%s' "$path_json" | jq -r '.evidence_tier // empty' 2>/dev/null || true)"

client_public="$(printf '%s' "$servers_json" | jq -r '.client.public_ipv4')"
server_public="$(printf '%s' "$servers_json" | jq -r '.server.public_ipv4')"
client_private="$(printf '%s' "$servers_json" | jq -r '.client.private_ip // empty')"
server_private="$(printf '%s' "$servers_json" | jq -r '.server.private_ip // empty')"
client_host_id="$(printf '%s' "$servers_json" | jq -r '.client.name')"
server_host_id="$(printf '%s' "$servers_json" | jq -r '.server.name')"

if [ -z "$client_public" ] || [ -z "$server_public" ]; then
  printf '%s\n' 'Terraform output "servers" is missing client/server public IPv4 values.' >&2
  exit 2
fi

server_endpoint="${server_private:-$server_public}"
client_base="${PROBED_CLIENT_BASE:-http://${client_private:-127.0.0.1}:$probed_port}"
server_base="${PROBED_SERVER_BASE:-http://${server_private:-127.0.0.1}:$probed_port}"
evidence_tier="${evidence_tier:-cross_region_pair}"

ssh_opts=(
  -i "$key"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$known_hosts"
)

api() {
  local node="$1"
  local method="$2"
  local path="$3"
  local body="${4:-}"
  local host
  local base

  case "$node" in
    client)
      host="$client_public"
      base="$client_base"
      ;;
    server)
      host="$server_public"
      base="$server_base"
      ;;
    *)
      printf 'unknown node: %s\n' "$node" >&2
      exit 2
      ;;
  esac

  if [ -n "$body" ]; then
    printf '%s' "$body" |
      ssh "${ssh_opts[@]}" "root@$host" \
        "curl -fsS -X '$method' -H 'Authorization: Bearer $token' -H 'Content-Type: application/json' --data-binary @- '$base$path'"
  else
    ssh "${ssh_opts[@]}" "root@$host" \
      "curl -fsS -X '$method' -H 'Authorization: Bearer $token' '$base$path'"
  fi
}

host_for() {
  case "$1" in
    client) printf '%s\n' "$client_public" ;;
    server) printf '%s\n' "$server_public" ;;
    *)
      printf 'unknown node: %s\n' "$1" >&2
      exit 2
      ;;
  esac
}

remote_readlink() {
  local node="$1"
  local path="$2"
  local host

  host="$(host_for "$node")"
  ssh "${ssh_opts[@]}" "root@$host" "readlink -f '$path' 2>/dev/null || true"
}

quicer_setting_args() {
  jq -n --arg settings "$quicer_settings" '
    if $settings == "" then
      []
    else
      $settings
      | split(",")
      | map(select(length > 0))
      | map(["--quicer-setting", .])
      | add // []
    end
  '
}

quicer_datagram_send_flag_args() {
  jq -n --arg flags "$quicer_datagram_send_flags" '
    if $flags == "" then
      []
    else
      $flags
      | split(",")
      | map(select(length > 0))
      | map(["--quicer-datagram-send-flag", .])
      | add // []
    end
  '
}

remote_json_file() {
  local node="$1"
  local path="$2"
  local host

  host="$(host_for "$node")"
  ssh "${ssh_opts[@]}" "root@$host" "if [ -f '$path' ]; then cat '$path'; else printf '{}'; fi" |
    jq -c .
}

wait_process_state() {
  local node="$1"
  local process_id="$2"
  local expected="$3"
  local body
  local state
  local exit_status

  for _attempt in $(seq 1 240); do
    body="$(api "$node" GET "/v1/runs/$api_run_id/processes/$process_id")"
    state="$(printf '%s' "$body" | jq -r '.state')"
    printf '%s\n' "$body" > "$log_dir/$node-process-$process_id.json"

    if [ "$state" = "$expected" ]; then
      if [ "$expected" = "exited" ]; then
        exit_status="$(printf '%s' "$body" | jq -r '.exit_status')"

        if [ "$exit_status" != "0" ]; then
          printf 'process %s on %s exited with status %s\n%s\n' \
            "$process_id" "$node" "$exit_status" "$body" >&2
          return 1
        fi
      fi

      printf '%s\n' "$body"
      return 0
    fi

    if [ "$state" = "failed" ] || [ "$state" = "timed_out" ] || [ "$state" = "exited" ]; then
      printf 'process %s on %s reached terminal state %s while waiting for %s\n%s\n' \
        "$process_id" "$node" "$state" "$expected" "$body" >&2
      return 1
    fi

    sleep 0.25
  done

  printf 'process %s on %s did not reach %s\n' "$process_id" "$node" "$expected" >&2
  return 1
}

start_process() {
  local node="$1"
  local body="$2"

  api "$node" POST "/v1/runs/$api_run_id/processes" "$body" | jq -r '.process_id'
}

stop_process() {
  local node="$1"
  local process_id="$2"

  if [ -n "$process_id" ]; then
    api "$node" DELETE "/v1/runs/$api_run_id/processes/$process_id" >/dev/null 2>&1 || true
  fi
}

iperf_server_process=""
quic_server_process=""
token=""

cleanup() {
  set +e
  stop_process server "$quic_server_process"
  stop_process server "$iperf_server_process"
}
trap cleanup EXIT

token="$(cd "$repo_root" && just --quiet bench-transport-probed-token "$run_id")"

client_moqxprobe_current="$(remote_readlink client /opt/moqx-bench/moqxprobe/current)"
server_moqxprobe_current="$(remote_readlink server /opt/moqx-bench/moqxprobe/current)"
client_quicprobe_current="$(remote_readlink client /opt/moqx-bench/quicprobe/current)"
server_quicprobe_current="$(remote_readlink server /opt/moqx-bench/quicprobe/current)"
client_probed_current="$(remote_readlink client /opt/moqx-bench/probed/current)"
server_probed_current="$(remote_readlink server /opt/moqx-bench/probed/current)"
client_moqxprobe_artifact="$(remote_json_file client /opt/moqx-bench/moqxprobe/current/.moqx-bench-artifact.json)"
server_moqxprobe_artifact="$(remote_json_file server /opt/moqx-bench/moqxprobe/current/.moqx-bench-artifact.json)"

tests_json="$(printf '%s' "$tests" | jq -R 'split(",")')"
jq -n \
  --arg run_id "$run_id" \
  --arg api_run_id "$api_run_id" \
  --arg status "starting" \
  --arg client_public "$client_public" \
  --arg server_public "$server_public" \
  --arg client_private "$client_private" \
  --arg server_private "$server_private" \
  --arg client_base "$client_base" \
  --arg server_base "$server_base" \
  --arg client_moqxprobe_current "$client_moqxprobe_current" \
  --arg server_moqxprobe_current "$server_moqxprobe_current" \
  --arg client_quicprobe_current "$client_quicprobe_current" \
  --arg server_quicprobe_current "$server_quicprobe_current" \
  --arg client_probed_current "$client_probed_current" \
  --arg server_probed_current "$server_probed_current" \
  --arg quicer_settings "$quicer_settings" \
  --arg quicer_datagram_send_flags "$quicer_datagram_send_flags" \
  --argjson client_moqxprobe_artifact "$client_moqxprobe_artifact" \
  --argjson server_moqxprobe_artifact "$server_moqxprobe_artifact" \
  --argjson tests "$tests_json" \
  '{
    run_id: $run_id,
    api_run_id: $api_run_id,
    status: $status,
    tests: $tests,
    client: {public_ipv4: $client_public, private_ip: $client_private, probed: $client_base},
    server: {public_ipv4: $server_public, private_ip: $server_private, probed: $server_base},
    env: {
      quicer_settings: $quicer_settings,
      quicer_datagram_send_flags: $quicer_datagram_send_flags
    },
    tools: {
      client: {
        moqxprobe: {current: $client_moqxprobe_current, artifact: $client_moqxprobe_artifact},
        quicprobe: {current: $client_quicprobe_current},
        probed: {current: $client_probed_current}
      },
      server: {
        moqxprobe: {current: $server_moqxprobe_current, artifact: $server_moqxprobe_artifact},
        quicprobe: {current: $server_quicprobe_current},
        probed: {current: $server_probed_current}
      }
    }
  }' > "$manifest_path"

openssl req \
  -x509 \
  -newkey rsa:2048 \
  -nodes \
  -days 7 \
  -subj "/CN=moqx remote suite CA" \
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

{
  printf '%s\n' "subjectAltName=DNS:localhost,IP:$server_endpoint,IP:$server_public"
  printf '%s\n' 'extendedKeyUsage=serverAuth'
} > "$cert_dir/server.ext"

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

remote_cert_dir="/opt/moqx-bench/certs/$api_run_id"

for host in "$client_public" "$server_public"; do
  ssh "${ssh_opts[@]}" "root@$host" "install -d -m 0755 '$remote_cert_dir'"
done

scp "${ssh_opts[@]}" "$cert_dir/ca.pem" "root@$client_public:$remote_cert_dir/ca.pem"
scp "${ssh_opts[@]}" "$cert_dir/ca.pem" "root@$server_public:$remote_cert_dir/ca.pem"
scp "${ssh_opts[@]}" "$cert_dir/server.pem" "$cert_dir/server-key.pem" \
  "root@$server_public:$remote_cert_dir/"

api client GET /v1/health | tee "$log_dir/client-health.json" >/dev/null
api server GET /v1/health | tee "$log_dir/server-health.json" >/dev/null
api client GET /v1/tools | tee "$log_dir/client-tools.json" >/dev/null
api server GET /v1/tools | tee "$log_dir/server-tools.json" >/dev/null

run_body="$(jq -n \
  --arg run_id "$api_run_id" \
  --arg client "$client_host_id" \
  --arg server "$server_host_id" \
  --arg evidence_tier "$evidence_tier" \
  '{
  run_id: $run_id,
  metadata: {
    purpose: "remote-probed-suite",
    evidence_tier: $evidence_tier,
    client_host_id: $client,
    server_host_id: $server
  }
}')"

api client POST /v1/runs "$run_body" >/dev/null
api server POST /v1/runs "$run_body" >/dev/null

path_args() {
  if [ -n "$path_json" ] && [ "$path_json" != "null" ]; then
    jq -n --arg path_json "$path_json" '["--path-json", $path_json]'
  else
    jq -n '[]'
  fi
}

iperf_args() {
  local output="$1"
  local extra_path_args

  extra_path_args="$(path_args)"

  jq -n \
    --arg server "$server_endpoint" \
    --arg port "$iperf3_port" \
    --arg tcp_duration "$tcp_duration" \
    --arg udp_duration "$udp_duration" \
    --arg udp_bitrates "$udp_bitrates" \
    --arg udp_length "$udp_length" \
    --arg iperf3 "/usr/bin/iperf3" \
    --arg run_id "$api_run_id-iperf3" \
    --arg output "$output" \
    --argjson path_args "$extra_path_args" \
    '[
      "iperf3-baseline",
      "--server", $server,
      "--port", $port,
      "--tcp-duration", $tcp_duration,
      "--udp-duration", $udp_duration,
      "--udp-bitrates", $udp_bitrates,
      "--iperf3-command", $iperf3,
      "--run-id", $run_id,
      "--output", $output
    ] + (if $udp_length == "" then [] else ["--udp-length", $udp_length] end) + $path_args'
}

measure_args() {
  local output="$1"
  local workload="$2"
  local extra_path_args

  extra_path_args="$(path_args)"

  jq -n \
    --arg server "$server_endpoint" \
    --arg port "$quic_port" \
    --arg ca "$remote_cert_dir/ca.pem" \
    --arg servername "localhost" \
    --arg alpn "$alpn" \
    --arg stream_count "$stream_count" \
    --arg payload_size "$payload_size" \
    --arg payload_count "$payload_count" \
    --arg timeout_seconds "$timeout_seconds" \
    --arg timeout_margin_seconds "$timeout_margin_seconds" \
    --arg run_id "$api_run_id" \
    --arg output "$output" \
    --arg workload "$workload" \
    --arg datagram_size "$datagram_size" \
    --arg datagram_count "$datagram_count" \
    --arg datagram_rate "$datagram_rate" \
    --arg duration_seconds "$duration_seconds" \
    --arg datagram_drain_limit "$datagram_drain_limit" \
    --arg datagram_diagnostics "$datagram_diagnostics" \
    --arg delivery_threshold "$delivery_threshold" \
    --arg offered_rate_tolerance "$offered_rate_tolerance" \
    --argjson path_args "$extra_path_args" \
    '[
      "measure",
      "--server", $server,
      "--port", $port,
      "--ca", $ca,
      "--servername", $servername,
      "--alpn", $alpn,
      "--stream-count", $stream_count,
      "--payload-size", $payload_size,
      "--payload-count", $payload_count,
      "--timeout-seconds", $timeout_seconds,
      "--timeout-margin-seconds", $timeout_margin_seconds,
      "--run-id", $run_id,
      "--output", $output
    ] + (
      if $workload == "datagram_pressure" then
        [
          "--workload", "datagram_pressure",
          "--datagram-size", $datagram_size,
          "--datagram-drain-limit", $datagram_drain_limit,
          "--datagram-diagnostics", $datagram_diagnostics,
          "--delivery-threshold", $delivery_threshold,
          "--offered-rate-tolerance", $offered_rate_tolerance
        ] + (
          if $datagram_rate == "" then
            ["--datagram-count", $datagram_count]
          else
            ["--datagram-rate", $datagram_rate, "--duration-seconds", $duration_seconds]
          end
        )
      else
        []
      end
    ) + $path_args'
}

run_iperf3() {
  local output="/var/lib/probed/runs/$api_run_id/artifacts/baseline/iperf3.jsonl"
  local process

  iperf_server_process="$(
    start_process server "$(
      jq -n \
        --arg bind "$server_endpoint" \
        --arg port "$iperf3_port" \
        --argjson port_number "$iperf3_port" \
        '{
          role: "baseline_server",
          tool: "iperf3",
          argv: ["--server", "--bind", $bind, "--port", $port],
          ready: {type: "udp_port", port: $port_number, startup_delay_ms: 500},
          timeout_ms: 120000
        }'
    )"
  )"
  wait_process_state server "$iperf_server_process" ready >/dev/null

  process="$(
    start_process client "$(
      jq -n \
        --argjson argv "$(iperf_args "$output")" \
        --argjson timeout "$process_timeout_ms" \
        '{
          role: "baseline_client",
          tool: "moqxprobe",
          argv: $argv,
          timeout_ms: $timeout,
          artifacts: {jsonl: "baseline/iperf3.jsonl"}
        }'
    )"
  )"
  wait_process_state client "$process" exited >/dev/null
  stop_process server "$iperf_server_process"
  iperf_server_process=""
}

start_quic_server() {
  if [ -n "$quic_server_process" ]; then
    return 0
  fi

  quic_server_process="$(
    start_process server "$(
      jq -n \
        --arg addr "$server_endpoint:$quic_port" \
        --arg cert "$remote_cert_dir/server.pem" \
        --arg key "$remote_cert_dir/server-key.pem" \
        --arg alpn "$alpn" \
        --arg stats "/var/lib/probed/runs/$api_run_id/artifacts/server/quicprobe-stats.jsonl" \
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
          ready: {type: "udp_port", port: $port, startup_delay_ms: 500},
          timeout_ms: 180000,
          artifacts: {stats: "server/quicprobe-stats.jsonl"}
        }'
    )"
  )"
  wait_process_state server "$quic_server_process" ready >/dev/null
}

run_measure() {
  local test_name="$1"
  local topology="$2"
  local workload="$3"
  local role="$4"
  local output="/var/lib/probed/runs/$api_run_id/artifacts/client/$test_name.jsonl"
  local process
  local argv

  start_quic_server
  argv="$(measure_args "$output" "$workload")"

  if [ "$topology" = "reference-client-to-reference-server" ]; then
    argv="$(jq -n \
      --argjson argv "$argv" \
      --arg quicprobe "/opt/moqx-bench/quicprobe/current/bin/quicprobe" \
      --arg topology "$topology" \
      '["measure", "--topology", $topology] + ($argv | .[1:]) + ["--quicprobe-command", $quicprobe]')"
  else
    argv="$(jq -n \
      --argjson argv "$argv" \
      --arg topology "$topology" \
      '["measure", "--topology", $topology] + ($argv | .[1:])')"
  fi

  if [ "$role" = "moqx_client" ] && [ -n "$quicer_settings" ]; then
    argv="$(jq -n \
      --argjson argv "$argv" \
      --argjson quicer_args "$(quicer_setting_args)" \
      '$argv + $quicer_args')"
  fi

  if [ "$role" = "moqx_client" ] && [ -n "$quicer_datagram_send_flags" ]; then
    argv="$(jq -n \
      --argjson argv "$argv" \
      --argjson quicer_args "$(quicer_datagram_send_flag_args)" \
      '$argv + $quicer_args')"
  fi

  process="$(
    start_process client "$(
      jq -n \
        --arg role "$role" \
        --argjson argv "$argv" \
        --arg artifact "client/$test_name.jsonl" \
        --argjson timeout "$process_timeout_ms" \
        '{
          role: $role,
          tool: "moqxprobe",
          argv: $argv,
          timeout_ms: $timeout,
          artifacts: {jsonl: $artifact}
        }'
    )"
  )"
  wait_process_state client "$process" exited >/dev/null
}

if test_enabled iperf3; then
  run_iperf3
fi

if test_enabled reference_stream; then
  run_measure reference-stream reference-client-to-reference-server stream_pressure reference_client
fi

if test_enabled moqx_stream; then
  run_measure moqx-stream moqx-client-to-reference-server stream_pressure moqx_client
fi

if test_enabled reference_datagram; then
  run_measure reference-datagram reference-client-to-reference-server datagram_pressure reference_client
fi

if test_enabled moqx_datagram; then
  run_measure moqx-datagram moqx-client-to-reference-server datagram_pressure moqx_client
fi

stop_process server "$quic_server_process"
quic_server_process=""

ssh "${ssh_opts[@]}" "root@$client_public" \
  "curl -fsS -H 'Authorization: Bearer $token' '$client_base/v1/runs/$api_run_id/bundle'" \
  > "$bundle_dir/client-bundle.tar.gz"

ssh "${ssh_opts[@]}" "root@$server_public" \
  "curl -fsS -H 'Authorization: Bearer $token' '$server_base/v1/runs/$api_run_id/bundle'" \
  > "$bundle_dir/server-bundle.tar.gz"

rm -rf "$extract_dir/client" "$extract_dir/server"
mkdir -p "$extract_dir/client" "$extract_dir/server"
tar -xzf "$bundle_dir/client-bundle.tar.gz" -C "$extract_dir/client"
tar -xzf "$bundle_dir/server-bundle.tar.gz" -C "$extract_dir/server"

report_jsonl() {
  local label="$1"
  local jsonl="$2"

  (
    cd "$repo_root/bench/moqxprobe"
    REPORT_JSONL="$jsonl" mix run -e 'MOQXProbe.CLI.main(["report", System.fetch_env!("REPORT_JSONL")])'
  ) > "$report_dir/$label-report.txt"
}

validated_jsonl=()

validate_artifact() {
  local label="$1"
  local path
  local report_label

  path="$(find "$extract_dir/client" -path "*/artifacts/$label.jsonl" -print -quit)"

  if [ -z "$path" ]; then
    printf 'missing expected JSONL artifact: %s\n' "$label.jsonl" >&2
    exit 1
  fi

  report_label="$(printf '%s' "$label" | tr '/' '-')"
  report_jsonl "$report_label" "$path"
  validated_jsonl+=("$path")
}

if test_enabled iperf3; then
  validate_artifact baseline/iperf3
fi

if test_enabled reference_stream; then
  validate_artifact client/reference-stream
fi

if test_enabled moqx_stream; then
  validate_artifact client/moqx-stream
fi

if test_enabled reference_datagram; then
  validate_artifact client/reference-datagram
fi

if test_enabled moqx_datagram; then
  validate_artifact client/moqx-datagram
fi

jq \
  --arg status "passed" \
  --arg result_dir "$result_dir" \
  --arg client_bundle "$bundle_dir/client-bundle.tar.gz" \
  --arg server_bundle "$bundle_dir/server-bundle.tar.gz" \
  --argjson validated "$(printf '%s\n' "${validated_jsonl[@]}" | jq -R . | jq -s .)" \
  '. + {
    status: $status,
    result_dir: $result_dir,
    bundles: {client: $client_bundle, server: $server_bundle},
    validated_jsonl: $validated
  }' "$manifest_path" > "$manifest_path.tmp"
mv "$manifest_path.tmp" "$manifest_path"

printf 'Remote probed suite passed.\n'
printf 'Infra run id: %s\n' "$run_id"
printf 'API run id: %s\n' "$api_run_id"
printf 'Tests: %s\n' "$tests"
printf 'Client API via SSH: %s\n' "$client_base"
printf 'Server API via SSH: %s\n' "$server_base"
printf 'Server endpoint: %s\n' "$server_endpoint"
printf 'Results dir: %s\n' "$result_dir"
