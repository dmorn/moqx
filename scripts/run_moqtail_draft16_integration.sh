#!/usr/bin/env sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose="$repo_root/scripts/docker-compose-local"

cleanup() {
  "$compose" down --remove-orphans
}

trap cleanup EXIT INT TERM

"$compose" up --build -d moqtail-draft16-publisher
"$compose" build moqx-moqtail-draft16-test
"$compose" run --rm moqx-moqtail-draft16-test
