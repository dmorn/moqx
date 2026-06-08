#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
private_check="$script_dir/private_check.sh"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/moqx-private-check-test.XXXXXX")"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fake_ssh="$tmpdir/fake-ssh"
cat > "$fake_ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail

target=""
cmd=""
previous=""

for arg in "$@"; do
  target="$previous"
  cmd="$arg"
  previous="$arg"
done

case "$cmd" in
  true)
    exit 0
    ;;
  "cloud-init status --wait")
    printf '%s\n' 'status: error'
    exit 1
    ;;
  "cloud-init status --long")
    printf '%s\n' 'status: error'
    printf '%s\n' 'errors:'
    printf '%s\n' '  - can only concatenate str (not "NoneType") to str'
    exit 1
    ;;
  *"go version"*)
    if [ "${FAKE_PRIVATE_CHECK_FAIL_TOOLCHAIN:-0}" = "1" ]; then
      printf '%s\n' 'go: command not found' >&2
      exit 127
    fi
    printf '%s\n' 'go version go1.26.4 linux/amd64'
    printf '%s\n' 'Elixir 1.19.5 (compiled with Erlang/OTP 28)'
    printf '%s\n' 'iperf 3.16 (cJSON 1.7.15)'
    exit 0
    ;;
  *"ip -4 address show"*)
    printf 'route-ok target=%s command=%s\n' "$target" "$cmd"
    exit 0
    ;;
  *"nohup iperf3 --server"*)
    exit 0
    ;;
  *"ping -c 3"*)
    printf '%s\n' '3 packets transmitted, 3 received, 0% packet loss'
    exit 0
    ;;
  *"iperf3 --client"*)
    printf '%s\n' '{"end":{"sum_sent":{"bits_per_second":890000000,"retransmits":0}}}'
    exit 0
    ;;
  *"test -f '/tmp/moqx-private-iperf3-"*)
    printf '%s\n' 'server iperf3 log'
    exit 0
    ;;
  *"pkill -f"*)
    exit 0
    ;;
  *)
    printf 'unexpected fake ssh command: target=%s command=%s\n' "$target" "$cmd" >&2
    exit 99
    ;;
esac
FAKE_SSH
chmod +x "$fake_ssh"

touch "$tmpdir/id_ed25519"
results_dir="$tmpdir/results"

output="$(
  SSH_BIN="$fake_ssh" "$private_check" \
    --run-id test-run \
    --key "$tmpdir/id_ed25519" \
    --known-hosts "$tmpdir/known_hosts" \
    --client root@client.example \
    --server root@server.example \
    --client-private 10.88.0.11 \
    --server-private 10.88.0.12 \
    --results-dir "$results_dir" \
    --port 55209 2>&1
)"

printf '%s' "$output" | grep -q 'Cloud-init client: warning'
printf '%s' "$output" | grep -q 'Cloud-init server: warning'
printf '%s' "$output" | grep -q 'Private network ready: 10.88.0.11 -> 10.88.0.12'
test -s "$results_dir/client-cloud-init-status-long.txt"
test -s "$results_dir/server-cloud-init-status-long.txt"
test -s "$results_dir/client-private-iperf3.json"

if FAKE_PRIVATE_CHECK_FAIL_TOOLCHAIN=1 SSH_BIN="$fake_ssh" "$private_check" \
  --run-id test-run \
  --key "$tmpdir/id_ed25519" \
  --known-hosts "$tmpdir/known_hosts" \
  --client root@client.example \
  --server root@server.example \
  --client-private 10.88.0.11 \
  --server-private 10.88.0.12 \
  --results-dir "$tmpdir/fail-results" \
  --port 55210 >"$tmpdir/fail-output.txt" 2>&1; then
  printf '%s\n' 'private_check.sh passed despite missing toolchain' >&2
  exit 1
fi

grep -q 'Toolchain check failed' "$tmpdir/fail-output.txt"

printf '%s\n' 'private_check.sh fake-SSH regression passed.'
