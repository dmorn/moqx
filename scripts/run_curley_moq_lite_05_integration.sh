#!/usr/bin/env sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose="$repo_root/scripts/docker-compose-local"

cleanup() {
  "$compose" down --remove-orphans
}

trap cleanup EXIT INT TERM

"$compose" up --build --wait curley-moq-lite-05-relay
"$compose" build moqx-curley-moq-lite-05-test
"$compose" run --rm moqx-curley-moq-lite-05-test
