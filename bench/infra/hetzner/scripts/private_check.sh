#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  private_check.sh --run-id ID --key PATH --known-hosts PATH \
    --client TARGET --server TARGET \
    --client-private IP --server-private IP \
    --results-dir PATH [--port PORT]

Prove Hetzner private-network readiness for a benchmark pair. Cloud-init status
is collected as diagnostics, but benchmark readiness is decided by SSH,
toolchain availability, peer routes, ICMP, and TCP over the private path.
USAGE
}

run_id=""
key=""
known_hosts=""
client=""
server=""
client_private=""
server_private=""
results_dir=""
port="55209"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --run-id)
      run_id="${2:?missing value for --run-id}"
      shift 2
      ;;
    --key)
      key="${2:?missing value for --key}"
      shift 2
      ;;
    --known-hosts)
      known_hosts="${2:?missing value for --known-hosts}"
      shift 2
      ;;
    --client)
      client="${2:?missing value for --client}"
      shift 2
      ;;
    --server)
      server="${2:?missing value for --server}"
      shift 2
      ;;
    --client-private)
      client_private="${2:?missing value for --client-private}"
      shift 2
      ;;
    --server-private)
      server_private="${2:?missing value for --server-private}"
      shift 2
      ;;
    --results-dir)
      results_dir="${2:?missing value for --results-dir}"
      shift 2
      ;;
    --port)
      port="${2:?missing value for --port}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$run_id" ] ||
   [ -z "$key" ] ||
   [ -z "$known_hosts" ] ||
   [ -z "$client" ] ||
   [ -z "$server" ] ||
   [ -z "$client_private" ] ||
   [ -z "$server_private" ] ||
   [ -z "$results_dir" ]; then
  printf '%s\n' 'Missing required private-check arguments.' >&2
  usage >&2
  exit 2
fi

test -f "$key" || {
  printf 'Missing SSH key for run %s: %s\n' "$run_id" "$key" >&2
  exit 2
}

ssh_bin="${SSH_BIN:-ssh}"
mkdir -p "$results_dir" "$(dirname "$known_hosts")"

ssh_opts=(
  -i "$key"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="$known_hosts"
  -o BatchMode=yes
  -o ConnectTimeout=20
)

remote_log="/tmp/moqx-private-iperf3-$port.log"

run_ssh() {
  local target="$1"
  shift
  "$ssh_bin" "${ssh_opts[@]}" "$target" "$@"
}

check_ssh() {
  local role="$1"
  local target="$2"
  local out="$results_dir/$role-ssh.txt"

  if ! run_ssh "$target" "true" >"$out" 2>&1; then
    printf 'SSH readiness failed for %s (%s). See %s\n' "$role" "$target" "$out" >&2
    exit 1
  fi

  printf 'SSH %s: ok\n' "$role"
}

capture_cloud_init() {
  local role="$1"
  local target="$2"
  local wait_out="$results_dir/$role-cloud-init-status-wait.txt"
  local long_out="$results_dir/$role-cloud-init-status-long.txt"
  local wait_status=0
  local long_status=0

  set +e
  run_ssh "$target" "cloud-init status --wait" >"$wait_out" 2>&1
  wait_status=$?
  run_ssh "$target" "cloud-init status --long" >"$long_out" 2>&1
  long_status=$?
  set -e

  if [ "$wait_status" -eq 0 ] && [ "$long_status" -eq 0 ]; then
    printf 'Cloud-init %s: ok (diagnostics: %s, %s)\n' "$role" "$wait_out" "$long_out"
  else
    printf 'Cloud-init %s: warning (status exits wait=%s long=%s; diagnostics: %s, %s)\n' \
      "$role" "$wait_status" "$long_status" "$wait_out" "$long_out"
  fi
}

check_toolchain() {
  local role="$1"
  local target="$2"
  local out="$results_dir/$role-toolchain.txt"

  if ! run_ssh "$target" \
    "set -e; go version; elixir --version; iperf3 --version" \
    >"$out" 2>&1; then
    printf 'Toolchain check failed for %s. See %s\n' "$role" "$out" >&2
    exit 1
  fi

  printf 'Toolchain %s: ok\n' "$role"
}

check_route() {
  local role="$1"
  local target="$2"
  local peer_private="$3"
  local out="$results_dir/$role-private-route.txt"

  if ! run_ssh "$target" \
    "set -e; ip -4 address show; ip route get '$peer_private'" \
    >"$out" 2>&1; then
    printf 'Private route check failed for %s to %s. See %s\n' \
      "$role" "$peer_private" "$out" >&2
    exit 1
  fi

  printf 'Private route %s -> %s: ok\n' "$role" "$peer_private"
}

cleanup() {
  run_ssh "$server" "pkill -f 'iperf3 .*--port $port' >/dev/null 2>&1 || true" \
    >/dev/null 2>&1 || true
}
trap cleanup EXIT

check_ssh client "$client"
check_ssh server "$server"

capture_cloud_init client "$client"
capture_cloud_init server "$server"

check_toolchain client "$client"
check_toolchain server "$server"

check_route client "$client" "$server_private"
check_route server "$server" "$client_private"

run_ssh "$server" \
  "nohup iperf3 --server --bind '$server_private' --port '$port' --one-off > '$remote_log' 2>&1 &"
sleep 1

if ! run_ssh "$client" "ping -c 3 -W 2 '$server_private'" \
  >"$results_dir/client-private-ping.txt" 2>&1; then
  printf 'Private ICMP check failed from client to %s. See %s\n' \
    "$server_private" "$results_dir/client-private-ping.txt" >&2
  exit 1
fi
printf 'Private ICMP client -> %s: ok\n' "$server_private"

if ! run_ssh "$client" \
  "iperf3 --client '$server_private' --port '$port' --time 1 --json" \
  >"$results_dir/client-private-iperf3.json" 2>&1; then
  printf 'Private TCP iperf3 check failed from client to %s:%s. See %s\n' \
    "$server_private" "$port" "$results_dir/client-private-iperf3.json" >&2
  run_ssh "$server" "test -f '$remote_log' && cat '$remote_log' || true" \
    >"$results_dir/server-private-iperf3.log" 2>&1 || true
  exit 1
fi

run_ssh "$server" "test -f '$remote_log' && cat '$remote_log' || true" \
  >"$results_dir/server-private-iperf3.log" 2>&1 || true

printf 'Private TCP client -> %s:%s: ok\n' "$server_private" "$port"
printf 'Private network ready: %s -> %s over ICMP and TCP port %s (diagnostics: %s)\n' \
  "$client_private" "$server_private" "$port" "$results_dir"
