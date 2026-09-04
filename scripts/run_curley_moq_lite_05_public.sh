#!/usr/bin/env sh

set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compose="$repo_root/scripts/docker-compose-local"

"$compose" build moqx-curley-moq-lite-05-public-test
"$compose" run --rm moqx-curley-moq-lite-05-public-test
