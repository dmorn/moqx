#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../../.." && pwd)"
bracket="$script_dir/remote_datagram_bracket.sh"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/moqx-dgram-bracket-test.XXXXXX")"
run_id="local-dgram-bracket-test-$$"
bracket_id="local-check"

cleanup() {
  rm -rf "$tmpdir" "$repo_root/bench/moqxprobe/results/$run_id"
}
trap cleanup EXIT

fake_suite="$tmpdir/fake-remote-curl-suite.sh"
cat > "$fake_suite" <<'FAKE_SUITE'
#!/usr/bin/env bash
set -euo pipefail

repo_root="${FAKE_REPO_ROOT:?FAKE_REPO_ROOT is required}"
run_id=""
tests=""
api_run_id="${PROBED_API_RUN_ID:-}"

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
    --probed-port|--quic-port|--iperf3-port)
      shift 2
      ;;
    --api-run-id)
      api_run_id="$2"
      shift 2
      ;;
    *)
      printf 'unexpected fake suite option: %s\n' "$1" >&2
      exit 99
      ;;
  esac
done

test -n "$run_id"
test -n "$tests"
test -n "$api_run_id"

result_dir="$repo_root/bench/moqxprobe/results/$run_id/probed-suite/$api_run_id"
mkdir -p "$result_dir"

jq -n \
  --arg status "passed" \
  --arg run_id "$run_id" \
  --arg api_run_id "$api_run_id" \
  --arg tests "$tests" \
  --arg datagram_rate "${DATAGRAM_RATE:-}" \
  --arg datagram_size "${DATAGRAM_SIZE:-}" \
  --arg duration_seconds "${DURATION_SECONDS:-}" \
  --arg delivery_threshold "${DELIVERY_THRESHOLD:-}" \
  --arg quicer_settings "${QUICER_SETTINGS:-}" \
  --arg stream_count "${STREAM_COUNT:-}" \
  '{
    status: $status,
    run_id: $run_id,
    api_run_id: $api_run_id,
    tests: ($tests | split(",")),
    env: {
      datagram_rate: $datagram_rate,
      datagram_size: $datagram_size,
      duration_seconds: $duration_seconds,
      delivery_threshold: $delivery_threshold,
      quicer_settings: $quicer_settings,
      stream_count: $stream_count
    }
  }' > "$result_dir/manifest.json"

printf 'fake suite passed: %s\n' "$api_run_id"
FAKE_SUITE
chmod +x "$fake_suite"

FAKE_REPO_ROOT="$repo_root" \
PROBED_BRACKET_SUITE_BIN="$fake_suite" \
QUICER_SETTINGS="pacing_enabled=1" \
"$bracket" \
  --run-id "$run_id" \
  --bracket-id "$bracket_id" \
  --rates "30000,32000" \
  --probed-port 19157 \
  --quic-port 19443 \
  --iperf3-port 19501

manifest="$repo_root/bench/moqxprobe/results/$run_id/probed-datagram-bracket/$bracket_id/manifest.json"
test -s "$manifest"

jq -e '
  .status == "passed" and
  .configuration.datagram_rates == ["30000", "32000"] and
  .configuration.datagram_size_bytes == 1180 and
  .configuration.duration_seconds == 3 and
  .configuration.quicer_settings == "pacing_enabled=1" and
  (.suite_invocations | length) == 3 and
  .suite_invocations[0].kind == "baseline" and
  .suite_invocations[0].tests == ["iperf3", "reference_stream", "moqx_stream"] and
  .suite_invocations[1].datagram_rate == 30000 and
  .suite_invocations[1].tests == ["reference_datagram", "moqx_datagram"] and
  .suite_invocations[2].datagram_rate == 32000 and
  .suite_invocations[2].tests == ["reference_datagram", "moqx_datagram"]
' "$manifest" >/dev/null

first_datagram_manifest="$repo_root/bench/moqxprobe/results/$run_id/probed-suite/${run_id}-${bracket_id}-dgram-30000/manifest.json"
test -s "$first_datagram_manifest"
jq -e '
  .env.datagram_rate == "30000" and
  .env.datagram_size == "1180" and
  .env.duration_seconds == "3" and
  .env.delivery_threshold == "0.95" and
  .env.quicer_settings == "pacing_enabled=1"
' "$first_datagram_manifest" >/dev/null

printf '%s\n' 'remote_datagram_bracket.sh fake-suite regression passed.'
