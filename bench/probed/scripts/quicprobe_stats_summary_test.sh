#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
summary="$script_dir/quicprobe_stats_summary.sh"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/moqx-quicprobe-stats-summary-test.XXXXXX")"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

stats="$tmpdir/quicprobe-stats.jsonl"
output="$tmpdir/summary.json"

cat > "$stats" <<'JSONL'
{"schema_version":"quicprobe-server-stats-v1","record_type":"server_datagram_summary","duration_ms":27.6,"datagrams_received":0,"datagrams_echo_accepted":0,"bytes_received":0,"bytes_echo_accepted":0,"receive_error":"Application error 0x0 (remote): done"}
{"schema_version":"quicprobe-server-stats-v1","record_type":"server_datagram_summary","duration_ms":26.0,"datagrams_received":0,"datagrams_echo_accepted":0,"bytes_received":0,"bytes_echo_accepted":0,"receive_error":"Application error 0x0 (remote)"}
{"schema_version":"quicprobe-server-stats-v1","record_type":"server_datagram_summary","duration_ms":7976.9,"datagrams_received":89988,"datagrams_echo_accepted":63409,"bytes_received":106185840,"bytes_echo_accepted":74822620,"echo_queue_capacity":131072,"echo_queue_max_depth":80077,"receive_error":"Application error 0x0 (remote): done","send_error":"Application error 0x0 (remote): done"}
{"schema_version":"quicprobe-server-stats-v1","record_type":"server_datagram_summary","duration_ms":8023.0,"datagrams_received":90000,"datagrams_echo_accepted":90000,"bytes_received":106200000,"bytes_echo_accepted":106200000,"echo_queue_capacity":131072,"echo_queue_max_depth":40695,"receive_error":"Application error 0x0 (remote)"}
JSONL

"$summary" \
  --stats-jsonl "$stats" \
  --tests "iperf3,reference_stream,moqx_stream,reference_datagram,moqx_datagram" \
  --datagram-rate 30000 \
  --duration-seconds 3 \
  --output "$output"

jq -e '
  .schema_version == "probed-suite-quicprobe-stats-summary-v1" and
  .expected_datagrams == 90000 and
  .connection_count == 4 and
  .expected_connection_count == 4 and
  .missing_connection_count == 0 and
  .unmatched_connection_count == 0 and
  .connections[0].test == "reference_stream" and
  .connections[1].test == "moqx_stream" and
  .connections[2].test == "reference_datagram" and
  .connections[2].ingress_ratio == 0.9998666666666667 and
  .connections[2].echo_queue_max_depth == 80077 and
  .connections[3].test == "moqx_datagram" and
  .connections[3].ingress_ratio == 1 and
  .datagram_ingress == [
    {
      "test": "reference_datagram",
      "connection_index": 2,
      "expected_datagrams": 90000,
      "datagrams_received": 89988,
      "datagrams_echo_accepted": 63409,
      "ingress_ratio": 0.9998666666666667,
      "echo_queue_capacity": 131072,
      "echo_queue_max_depth": 80077,
      "receive_error": "Application error 0x0 (remote): done",
      "send_error": "Application error 0x0 (remote): done"
    },
    {
      "test": "moqx_datagram",
      "connection_index": 3,
      "expected_datagrams": 90000,
      "datagrams_received": 90000,
      "datagrams_echo_accepted": 90000,
      "ingress_ratio": 1,
      "echo_queue_capacity": 131072,
      "echo_queue_max_depth": 40695,
      "receive_error": "Application error 0x0 (remote)",
      "send_error": null
    }
  ]
' "$output" >/dev/null

printf '%s\n' 'quicprobe_stats_summary.sh regression passed.'

mixed_stats="$tmpdir/quicprobe-mixed-stats.jsonl"
mixed_output="$tmpdir/mixed-summary.json"

cat > "$mixed_stats" <<'JSONL'
{"schema_version":"quicprobe-server-stats-v1","record_type":"server_datagram_summary","duration_ms":1040.1,"datagrams_received":0,"datagrams_echo_accepted":0,"bytes_received":0,"bytes_echo_accepted":0,"receive_error":"Application error 0x0 (remote): done"}
{"schema_version":"quicprobe-server-stats-v1","record_type":"server_datagram_summary","duration_ms":1039.7,"datagrams_received":0,"datagrams_echo_accepted":0,"bytes_received":0,"bytes_echo_accepted":0,"receive_error":"Application error 0x0 (remote)"}
JSONL

"$summary" \
  --stats-jsonl "$mixed_stats" \
  --tests "reference_mixed,moqx_mixed" \
  --output "$mixed_output"

jq -e '
  .expected_datagrams == null and
  .connection_count == 2 and
  .expected_connection_count == 2 and
  .connections[0].test == "reference_mixed" and
  .connections[0].datagram_test == false and
  .connections[1].test == "moqx_mixed" and
  .connections[1].datagram_test == false and
  .datagram_ingress == []
' "$mixed_output" >/dev/null

printf '%s\n' 'quicprobe_stats_summary.sh mixed regression passed.'
