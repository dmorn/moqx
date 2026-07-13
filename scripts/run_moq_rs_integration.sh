#!/usr/bin/env sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose="$repo_root/scripts/docker-compose-local"

cleanup() {
  "$compose" down --remove-orphans
}

trap cleanup EXIT INT TERM

"$compose" up --build --wait moq-rs-relay
"$compose" build moqx-moq-rs-test
"$compose" run --rm moqx-moq-rs-test
