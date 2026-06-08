#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/source_snapshot.sh --output PATH --metadata PATH [--id-output PATH]

Create a source archive from the current git worktree, including tracked files,
tracked modifications, and untracked non-ignored files. Ignored files such as
build outputs, Terraform state, keys, results, and dependency directories stay
out of the archive.
USAGE
}

output=""
metadata=""
id_output=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      output="${2:?missing value for --output}"
      shift 2
      ;;
    --metadata)
      metadata="${2:?missing value for --metadata}"
      shift 2
      ;;
    --id-output)
      id_output="${2:?missing value for --id-output}"
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

if [ -z "$output" ] || [ -z "$metadata" ]; then
  printf '%s\n' 'Missing --output or --metadata.' >&2
  usage >&2
  exit 2
fi

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required tool: %s\n' "$1" >&2
    exit 2
  fi
}

require_tool git
require_tool jq
require_tool shasum
require_tool tar

repo_root="$(git rev-parse --show-toplevel)"
head_sha="$(git rev-parse --short HEAD 2>/dev/null || printf '%s' unknown)"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/moqx-source-snapshot.XXXXXX")"

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

file_list="$tmpdir/files.list"
hash_input="$tmpdir/hash-input.txt"
status_path="$tmpdir/status.txt"

cd "$repo_root"

git status --porcelain --untracked-files=normal > "$status_path"

git ls-files --cached --modified --others --exclude-standard --deduplicate -z |
  while IFS= read -r -d '' path; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf '%s\0' "$path"
    fi
  done > "$file_list"

if [ ! -s "$file_list" ]; then
  printf '%s\n' 'Source snapshot would be empty.' >&2
  exit 1
fi

: > "$hash_input"

while IFS= read -r -d '' path; do
  if [ -L "$path" ]; then
    printf 'link %s %s\n' "$path" "$(readlink "$path")" >> "$hash_input"
  elif [ -f "$path" ]; then
    shasum -a 256 "$path" | awk -v path="$path" '{print "file " $1 " " path}' >> "$hash_input"
  fi
done < "$file_list"

source_hash="$(shasum -a 256 "$hash_input" | awk '{print substr($1, 1, 12)}')"

if [ -s "$status_path" ]; then
  dirty=true
  artifact_id="${head_sha}-dirty-${source_hash}"
else
  dirty=false
  artifact_id="$head_sha"
fi

mkdir -p "$(dirname "$output")" "$(dirname "$metadata")"
COPYFILE_DISABLE=1 tar --null -T "$file_list" -czf "$output"

file_count="$(tr '\0' '\n' < "$file_list" | wc -l | tr -d ' ')"
dirty_count="$(wc -l < "$status_path" | tr -d ' ')"
status_text="$(cat "$status_path")"

jq -n \
  --arg artifact_id "$artifact_id" \
  --arg git_sha "$head_sha" \
  --arg source_hash "$source_hash" \
  --arg created_at "$created_at" \
  --argjson dirty "$dirty" \
  --argjson file_count "$file_count" \
  --argjson dirty_file_count "$dirty_count" \
  --arg status "$status_text" \
  '{
    artifact_id: $artifact_id,
    git_sha: $git_sha,
    source_hash: $source_hash,
    dirty: $dirty,
    created_at: $created_at,
    file_count: $file_count,
    dirty_file_count: $dirty_file_count,
    git_status_porcelain: $status
  }' > "$metadata"

if [ -n "$id_output" ]; then
  printf '%s\n' "$artifact_id" > "$id_output"
fi

printf '%s\n' "$artifact_id"
