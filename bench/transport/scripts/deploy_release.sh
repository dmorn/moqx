#!/usr/bin/env sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  scripts/deploy_release.sh --artifact PATH [--remote-dir DIR] [--smoke] [--smoke-command COMMAND] -- TARGET...

Environment:
  SSH_OPTS   Extra options passed to ssh and scp.

Example:
  scripts/deploy_release.sh \
    --artifact build/artifacts/moqx-transport-bench-0.1.0-<git>-linux-arm64.tar.gz \
    --remote-dir /opt/moqx-bench/moqx-transport-bench \
    --smoke \
    -- root@203.0.113.10 root@203.0.113.11

  scripts/deploy_release.sh \
    --artifact build/artifacts/quicprobe-<git>-linux-arm64.tar.gz \
    --remote-dir /opt/moqx-bench/quicprobe \
    --smoke-command "bin/quicprobe 2>&1 | grep -q usage:" \
    -- root@203.0.113.10
USAGE
}

artifact=""
remote_dir="/opt/moqx-bench/moqx-transport-bench"
smoke=0
smoke_command="bin/moqx-transport-bench help"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --artifact)
      artifact="${2:?missing value for --artifact}"
      shift 2
      ;;
    --remote-dir)
      remote_dir="${2:?missing value for --remote-dir}"
      shift 2
      ;;
    --smoke)
      smoke=1
      shift
      ;;
    --smoke-command)
      smoke=1
      smoke_command="${2:?missing value for --smoke-command}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -z "$artifact" ]; then
  printf '%s\n' 'Missing --artifact PATH.' >&2
  exit 2
fi

if [ ! -f "$artifact" ]; then
  printf 'Artifact not found: %s\n' "$artifact" >&2
  exit 2
fi

if [ "$#" -eq 0 ]; then
  printf '%s\n' 'At least one SSH target is required.' >&2
  exit 2
fi

case "$remote_dir" in
  *"'"*|*" "*)
    printf 'Unsupported --remote-dir with spaces or single quotes: %s\n' "$remote_dir" >&2
    exit 2
    ;;
esac

case "$smoke_command" in
  *"'"*)
    printf 'Unsupported --smoke-command with single quotes: %s\n' "$smoke_command" >&2
    exit 2
    ;;
esac

artifact_base=$(basename "$artifact")
release_id=${artifact_base%.tar.gz}
remote_releases="$remote_dir/releases"
remote_release="$remote_releases/$release_id"
remote_tar="$remote_releases/$artifact_base"
remote_current="$remote_dir/current"
SSH_OPTS=${SSH_OPTS:-}

for target do
  printf 'Deploying %s to %s:%s\n' "$artifact_base" "$target" "$remote_release"

  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$target" "mkdir -p '$remote_releases' && rm -rf '$remote_release' && mkdir -p '$remote_release'"

  # shellcheck disable=SC2086
  scp $SSH_OPTS "$artifact" "$target:$remote_tar"

  # shellcheck disable=SC2086
  ssh $SSH_OPTS "$target" "tar -xzf '$remote_tar' -C '$remote_release' && rm -rf '$remote_current' && ln -s '$remote_release' '$remote_current'"

  if [ "$smoke" -eq 1 ]; then
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$target" "cd '$remote_current' && $smoke_command"
  fi
done
