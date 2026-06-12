#!/usr/bin/env bash
set -euo pipefail

stats_jsonl=""
tests=""
output=""
datagram_count=""
datagram_rate=""
duration_seconds=""

usage() {
  cat <<EOF
Usage:
  quicprobe_stats_summary.sh --stats-jsonl PATH --tests LIST --output PATH [options]

Options:
  --stats-jsonl PATH       quicprobe server stats JSONL.
  --tests LIST             Comma-separated probed suite tests.
  --output PATH            Output summary JSON path.
  --datagram-count N       Expected DATAGRAM count for burst workloads.
  --datagram-rate N        Expected DATAGRAM rate for paced workloads.
  --duration-seconds N     Duration used with --datagram-rate.
  -h, --help               Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --stats-jsonl)
      stats_jsonl="$2"
      shift 2
      ;;
    --tests)
      tests="$2"
      shift 2
      ;;
    --output)
      output="$2"
      shift 2
      ;;
    --datagram-count)
      datagram_count="$2"
      shift 2
      ;;
    --datagram-rate)
      datagram_rate="$2"
      shift 2
      ;;
    --duration-seconds)
      duration_seconds="$2"
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

if [ -z "$stats_jsonl" ] || [ -z "$tests" ] || [ -z "$output" ]; then
  usage >&2
  exit 2
fi

if [ ! -f "$stats_jsonl" ]; then
  printf 'Missing quicprobe stats JSONL: %s\n' "$stats_jsonl" >&2
  exit 1
fi

mkdir -p "$(dirname "$output")"

tests_json="$(printf '%s' "$tests" | jq -R 'split(",") | map(select(length > 0))')"
quic_tests_json="$(
  printf '%s' "$tests" | jq -R '
    split(",") as $enabled |
    [
      "reference_stream",
      "moqx_stream",
      "reference_object_stream",
      "moqx_object_stream",
      "moqx_object_stream_owner",
      "reference_datagram",
      "moqx_datagram",
      "reference_mixed",
      "moqx_mixed"
    ]
    | map(. as $candidate | select($enabled | index($candidate)))
  '
)"
expected_datagrams="$(
  jq -n \
    --arg datagram_count "$datagram_count" \
    --arg datagram_rate "$datagram_rate" \
    --arg duration_seconds "$duration_seconds" \
    'if $datagram_rate != "" and $duration_seconds != "" then
       (($datagram_rate | tonumber) * ($duration_seconds | tonumber))
     elif $datagram_count != "" then
       ($datagram_count | tonumber)
     else
       null
     end'
)"

jq -s \
  --arg stats_jsonl "$stats_jsonl" \
  --argjson tests "$tests_json" \
  --argjson quic_tests "$quic_tests_json" \
  --argjson expected_datagrams "$expected_datagrams" \
  '
  def datagram_test($test):
    $test == "reference_datagram" or $test == "moqx_datagram";

  def stream_test($test):
    $test == "reference_stream" or
    $test == "moqx_stream" or
    $test == "reference_object_stream" or
    $test == "moqx_object_stream" or
    $test == "moqx_object_stream_owner" or
    $test == "reference_mixed" or
    $test == "moqx_mixed";

  def ingress_ratio($received):
    if $expected_datagrams == null or $expected_datagrams <= 0 then
      null
    else
      ($received / $expected_datagrams)
    end;

  [
    to_entries[] as $entry |
    ($entry.value // {}) as $row |
    ($quic_tests[$entry.key] // null) as $test |
    ($row.datagrams_received // 0) as $received |
    {
      connection_index: $entry.key,
      test: $test,
      datagram_test: datagram_test($test),
      datagrams_received: $received,
      datagrams_echo_accepted: ($row.datagrams_echo_accepted // 0),
      bytes_received: ($row.bytes_received // 0),
      bytes_echo_accepted: ($row.bytes_echo_accepted // 0),
      stream_test: stream_test($test),
      bidi_streams_accepted: ($row.bidi_streams_accepted // 0),
      uni_streams_accepted: ($row.uni_streams_accepted // 0),
      streams_completed: ($row.streams_completed // 0),
      stream_bytes_received: ($row.stream_bytes_received // 0),
      stream_bytes_echo_accepted: ($row.stream_bytes_echo_accepted // 0),
      stream_receive_error_count: ($row.stream_receive_error_count // 0),
      stream_send_error_count: ($row.stream_send_error_count // 0),
      stream_receive_error: ($row.stream_receive_error // null),
      stream_send_error: ($row.stream_send_error // null),
      first_stream_byte_latency_ms: ($row.first_stream_byte_latency_ms // null),
      echo_queue_capacity: ($row.echo_queue_capacity // null),
      echo_queue_max_depth: ($row.echo_queue_max_depth // null),
      receive_error: ($row.receive_error // null),
      send_error: ($row.send_error // null),
      duration_ms: ($row.duration_ms // null),
      ingress_ratio: (
        if datagram_test($test) then ingress_ratio($received) else null end
      )
    }
  ] as $connections |
  {
    schema_version: "probed-suite-quicprobe-stats-summary-v1",
    stats_jsonl: $stats_jsonl,
    tests: $tests,
    quic_tests: $quic_tests,
    expected_datagrams: $expected_datagrams,
    connection_count: ($connections | length),
    expected_connection_count: ($quic_tests | length),
    missing_connection_count: (
      (($quic_tests | length) - ($connections | length)) as $missing |
      if $missing > 0 then $missing else 0 end
    ),
    unmatched_connection_count: (
      [$connections[] | select(.test == null)] | length
    ),
    connections: $connections,
    datagram_ingress: [
      $connections[]
      | select(.datagram_test)
      | {
          test,
          connection_index,
          expected_datagrams: $expected_datagrams,
          datagrams_received,
          datagrams_echo_accepted,
          ingress_ratio,
          echo_queue_capacity,
          echo_queue_max_depth,
          receive_error,
          send_error
        }
    ],
    stream_ingress: [
      $connections[]
      | select(.stream_test)
      | {
          test,
          connection_index,
          bidi_streams_accepted,
          uni_streams_accepted,
          streams_completed,
          stream_bytes_received,
          stream_bytes_echo_accepted,
          stream_receive_error_count,
          stream_send_error_count,
          stream_receive_error,
          stream_send_error,
          first_stream_byte_latency_ms
        }
    ]
  }' "$stats_jsonl" > "$output"
