#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"

run_file="$repo_root/bench/moqxprobe/.run/current"
run_id="${RUN_ID:-}"
rates="${DATAGRAM_RATES:-30000,32000}"
probed_port="${PROBED_PORT:-9157}"
quic_port="${QUICPROBE_PORT:-55433}"
iperf3_port="${IPERF3_PORT:-55201}"
bracket_id="${PROBED_BRACKET_ID:-}"
suite_bin="${PROBED_BRACKET_SUITE_BIN:-$script_dir/remote_curl_suite.sh}"

datagram_size="${DATAGRAM_SIZE:-1180}"
duration_seconds="${DURATION_SECONDS:-3}"
delivery_threshold="${DELIVERY_THRESHOLD:-0.95}"
offered_rate_tolerance="${OFFERED_RATE_TOLERANCE:-0.95}"
process_timeout_ms="${PROCESS_TIMEOUT_MS:-120000}"
datagram_diagnostics="${DATAGRAM_DIAGNOSTICS:-summary}"
datagram_drain_limit="${DATAGRAM_DRAIN_LIMIT:-0}"
quicer_settings="${QUICER_SETTINGS:-}"

stream_count="${STREAM_COUNT:-1}"
payload_size="${PAYLOAD_SIZE:-256}"
payload_count="${PAYLOAD_COUNT:-2}"
iperf3_tcp_duration_default="${IPERF3_TCP_DURATION:-1}"
iperf3_udp_duration_default="${IPERF3_UDP_DURATION:-1}"
iperf3_udp_bitrates_default="${IPERF3_UDP_BITRATES:-1M}"
iperf3_udp_length_default="${IPERF3_UDP_LENGTH:-}"

usage() {
  cat <<EOF
Usage:
  remote_datagram_bracket.sh [options]

Options:
  --run-id ID          Terraform/provisioning run id. Defaults to bench/moqxprobe/.run/current.
  --rates LIST         Comma-separated DATAGRAM rates. Default: 30000,32000.
  --bracket-id ID      Bracket id. Defaults to <run-id>-dgram-bracket-<HHMMSS>.
  --probed-port PORT   probed HTTP port. Default: 9157.
  --quic-port PORT     quicprobe UDP port. Default: 55433.
  --iperf3-port PORT   iperf3 TCP/UDP port. Default: 55201.
  -h, --help           Show this help.

Environment overrides forwarded to remote_curl_suite.sh:
  DATAGRAM_SIZE DATAGRAM_DIAGNOSTICS DATAGRAM_DRAIN_LIMIT
  DURATION_SECONDS DELIVERY_THRESHOLD OFFERED_RATE_TOLERANCE PROCESS_TIMEOUT_MS
  QUICER_SETTINGS
  STREAM_COUNT PAYLOAD_SIZE PAYLOAD_COUNT
  IPERF3_TCP_DURATION IPERF3_UDP_DURATION IPERF3_UDP_BITRATES IPERF3_UDP_LENGTH

The bracket runs one baseline/stream-smoke suite, then one
reference_datagram+moqx_datagram suite per requested rate. It writes an
aggregate manifest under:

  bench/moqxprobe/results/<run-id>/probed-datagram-bracket/<bracket-id>/manifest.json
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)
      run_id="$2"
      shift 2
      ;;
    --rates)
      rates="$2"
      shift 2
      ;;
    --bracket-id)
      bracket_id="$2"
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

if [ -z "$rates" ]; then
  printf '%s\n' 'Missing DATAGRAM rates. Use --rates or DATAGRAM_RATES.' >&2
  exit 2
fi

if [ -z "$bracket_id" ]; then
  bracket_id="${run_id}-dgram-bracket-$(date -u +%H%M%S)"
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 2
  fi
}

require_tool jq
require_tool date

test -x "$suite_bin" || {
  printf 'Suite driver is not executable: %s\n' "$suite_bin" >&2
  exit 2
}

IFS=',' read -r -a selected_rates <<< "$rates"
for rate in "${selected_rates[@]}"; do
  if [ -z "$rate" ]; then
    printf '%s\n' 'Empty DATAGRAM rate in --rates.' >&2
    exit 2
  fi

  case "$rate" in
    *[!0-9]*)
      printf 'DATAGRAM rate must be an integer: %s\n' "$rate" >&2
      exit 2
      ;;
  esac
done

bench_dir="$repo_root/bench/moqxprobe"
result_dir="$bench_dir/results/$run_id/probed-datagram-bracket/$bracket_id"
manifest_path="$result_dir/manifest.json"
invocations_file="$result_dir/invocations.jsonl"
mkdir -p "$result_dir"
: > "$invocations_file"

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rates_json="$(printf '%s' "$rates" | jq -R 'split(",") | map(select(length > 0))')"

jq -n \
  --arg status "running" \
  --arg run_id "$run_id" \
  --arg bracket_id "$bracket_id" \
  --arg started_at "$timestamp" \
  --arg suite_bin "$suite_bin" \
  --arg probed_port "$probed_port" \
  --arg quic_port "$quic_port" \
  --arg iperf3_port "$iperf3_port" \
  --arg datagram_size "$datagram_size" \
  --arg duration_seconds "$duration_seconds" \
  --arg delivery_threshold "$delivery_threshold" \
  --arg offered_rate_tolerance "$offered_rate_tolerance" \
  --arg process_timeout_ms "$process_timeout_ms" \
  --arg datagram_diagnostics "$datagram_diagnostics" \
  --arg datagram_drain_limit "$datagram_drain_limit" \
  --arg quicer_settings "$quicer_settings" \
  --arg stream_count "$stream_count" \
  --arg payload_size "$payload_size" \
  --arg payload_count "$payload_count" \
  --argjson rates "$rates_json" \
  '{
    status: $status,
    run_id: $run_id,
    bracket_id: $bracket_id,
    started_at: $started_at,
    suite_driver: $suite_bin,
    ports: {
      probed: ($probed_port | tonumber),
      quicprobe: ($quic_port | tonumber),
      iperf3: ($iperf3_port | tonumber)
    },
    configuration: {
      datagram_rates: $rates,
      datagram_size_bytes: ($datagram_size | tonumber),
      duration_seconds: ($duration_seconds | tonumber),
      delivery_threshold: ($delivery_threshold | tonumber),
      offered_rate_tolerance: ($offered_rate_tolerance | tonumber),
      process_timeout_ms: ($process_timeout_ms | tonumber),
      datagram_diagnostics: $datagram_diagnostics,
      datagram_drain_limit: ($datagram_drain_limit | tonumber),
      quicer_settings: $quicer_settings,
      stream_smoke: {
        stream_count: ($stream_count | tonumber),
        payload_size_bytes: ($payload_size | tonumber),
        payload_count: ($payload_count | tonumber)
      }
    },
    suite_invocations: []
  }' > "$manifest_path"

record_invocation() {
  local label="$1"
  local kind="$2"
  local rate="$3"
  local tests="$4"
  local api_run_id="$5"
  local exit_status="$6"
  local suite_manifest="$bench_dir/results/$run_id/probed-suite/$api_run_id/manifest.json"
  local status="failed"
  local suite_status=""

  if [ -f "$suite_manifest" ]; then
    suite_status="$(jq -r '.status // empty' "$suite_manifest")"
  fi

  if [ "$exit_status" -eq 0 ]; then
    status="passed"
  fi

  jq -n \
    --arg label "$label" \
    --arg kind "$kind" \
    --arg rate "$rate" \
    --arg tests "$tests" \
    --arg api_run_id "$api_run_id" \
    --arg status "$status" \
    --arg suite_status "$suite_status" \
    --arg suite_manifest "$suite_manifest" \
    --arg result_dir "$bench_dir/results/$run_id/probed-suite/$api_run_id" \
    --argjson exit_status "$exit_status" \
    '{
      label: $label,
      kind: $kind,
      datagram_rate: (if $rate == "" then null else ($rate | tonumber) end),
      tests: ($tests | split(",")),
      api_run_id: $api_run_id,
      status: $status,
      suite_status: (if $suite_status == "" then null else $suite_status end),
      exit_status: $exit_status,
      suite_manifest: $suite_manifest,
      result_dir: $result_dir
    }' >> "$invocations_file"
}

finish_manifest() {
  local status="$1"
  local finished_at
  local invocations

  finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  invocations="$(jq -s '.' "$invocations_file")"

  jq \
    --arg status "$status" \
    --arg finished_at "$finished_at" \
    --argjson invocations "$invocations" \
    '. + {
      status: $status,
      finished_at: $finished_at,
      suite_invocations: $invocations
    }' "$manifest_path" > "$manifest_path.tmp"
  mv "$manifest_path.tmp" "$manifest_path"
}

run_suite() {
  local label="$1"
  local kind="$2"
  local rate="$3"
  local tests="$4"
  local api_run_id="$5"
  local exit_status=0

  printf 'Running %s (%s) as API run %s\n' "$label" "$tests" "$api_run_id"

  set +e
  if [ -n "$rate" ]; then
    PROBED_API_RUN_ID="$api_run_id" \
      PROBED_SUITE_TESTS="$tests" \
      DATAGRAM_RATE="$rate" \
      DATAGRAM_SIZE="$datagram_size" \
      DURATION_SECONDS="$duration_seconds" \
      DATAGRAM_DRAIN_LIMIT="$datagram_drain_limit" \
      DATAGRAM_DIAGNOSTICS="$datagram_diagnostics" \
      QUICER_SETTINGS="$quicer_settings" \
      DELIVERY_THRESHOLD="$delivery_threshold" \
      OFFERED_RATE_TOLERANCE="$offered_rate_tolerance" \
      PROCESS_TIMEOUT_MS="$process_timeout_ms" \
      "$suite_bin" \
        --run-id "$run_id" \
        --tests "$tests" \
        --probed-port "$probed_port" \
        --quic-port "$quic_port" \
        --iperf3-port "$iperf3_port" \
        --api-run-id "$api_run_id"
  else
    PROBED_API_RUN_ID="$api_run_id" \
      PROBED_SUITE_TESTS="$tests" \
      STREAM_COUNT="$stream_count" \
      PAYLOAD_SIZE="$payload_size" \
      PAYLOAD_COUNT="$payload_count" \
      IPERF3_TCP_DURATION="$iperf3_tcp_duration_default" \
      IPERF3_UDP_DURATION="$iperf3_udp_duration_default" \
      IPERF3_UDP_BITRATES="$iperf3_udp_bitrates_default" \
      IPERF3_UDP_LENGTH="$iperf3_udp_length_default" \
      PROCESS_TIMEOUT_MS="$process_timeout_ms" \
      "$suite_bin" \
        --run-id "$run_id" \
        --tests "$tests" \
        --probed-port "$probed_port" \
        --quic-port "$quic_port" \
        --iperf3-port "$iperf3_port" \
        --api-run-id "$api_run_id"
  fi
  exit_status=$?
  set -e

  record_invocation "$label" "$kind" "$rate" "$tests" "$api_run_id" "$exit_status"

  if [ "$exit_status" -ne 0 ]; then
    finish_manifest "failed"
    printf 'DATAGRAM bracket failed at %s. Manifest: %s\n' "$label" "$manifest_path" >&2
    exit "$exit_status"
  fi
}

safe_bracket_id="$(printf '%s' "$bracket_id" | tr -c '[:alnum:]_.-' '-')"
baseline_api_run_id="${run_id}-${safe_bracket_id}-baseline"

run_suite "baseline-stream-smoke" "baseline" "" \
  "iperf3,reference_stream,moqx_stream" "$baseline_api_run_id"

for rate in "${selected_rates[@]}"; do
  api_run_id="${run_id}-${safe_bracket_id}-dgram-${rate}"
  run_suite "datagram-${rate}" "datagram" "$rate" \
    "reference_datagram,moqx_datagram" "$api_run_id"
done

finish_manifest "passed"

printf 'Remote DATAGRAM bracket passed.\n'
printf 'Infra run id: %s\n' "$run_id"
printf 'Bracket id: %s\n' "$bracket_id"
printf 'Rates: %s\n' "$rates"
printf 'Results dir: %s\n' "$result_dir"
printf 'Manifest: %s\n' "$manifest_path"
