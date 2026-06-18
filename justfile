set dotenv-load

bench_dir := "bench/moqxprobe"
artifact_dir := "build/artifacts"
quicprobe_go_cache := bench_dir + "/tmp/go-build-cache"
quicprobe_go_version := env('QUICPROBE_GO_VERSION', '1.25.6')
git_sha := `git rev-parse --short HEAD 2>/dev/null || echo unknown`

# Show available recipes.
default:
    @just --list

# Print the quicprobe artifact path relative to bench/moqxprobe.
bench-transport-quicprobe-artifact-rel quicprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ quicprobe_target }}" in
      linux_arm64) artifact_target="linux-arm64" ;;
      linux_x86_64) artifact_target="linux-x86_64" ;;
      darwin_arm64) artifact_target="darwin-arm64" ;;
      darwin_x86_64) artifact_target="darwin-x86_64" ;;
      *)
        printf 'Unsupported quicprobe target: %s\n' "{{ quicprobe_target }}" >&2
        printf '%s\n' 'Use linux_arm64, linux_x86_64, darwin_arm64, or darwin_x86_64.' >&2
        exit 2
        ;;
    esac

    printf '%s/quicprobe-%s-%s.tar.gz\n' \
      "{{ artifact_dir }}" \
      "{{ git_sha }}" \
      "$artifact_target"

# Print the quicprobe artifact path.
bench-transport-quicprobe-artifact-path quicprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    artifact_rel="$(just --quiet bench-transport-quicprobe-artifact-rel "{{ quicprobe_target }}")"
    printf '%s/%s\n' "{{ bench_dir }}" "$artifact_rel"

# Build the quicprobe reference peer artifact natively with mise-managed Go.
bench-transport-build-quicprobe quicprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ quicprobe_target }}" in
      linux_arm64)
        goos="linux"
        goarch="arm64"
        ;;
      linux_x86_64)
        goos="linux"
        goarch="amd64"
        ;;
      darwin_arm64)
        goos="darwin"
        goarch="arm64"
        ;;
      darwin_x86_64)
        goos="darwin"
        goarch="amd64"
        ;;
      *)
        printf 'Unsupported quicprobe target: %s\n' "{{ quicprobe_target }}" >&2
        printf '%s\n' 'Use linux_arm64, linux_x86_64, darwin_arm64, or darwin_x86_64.' >&2
        exit 2
        ;;
    esac

    repo_root="$(pwd)"
    cache_dir="$repo_root/{{ quicprobe_go_cache }}"
    artifact_rel="$(just --quiet bench-transport-quicprobe-artifact-rel "{{ quicprobe_target }}")"
    artifact_path="$repo_root/{{ bench_dir }}/$artifact_rel"
    staging="$(mktemp -d "${TMPDIR:-/tmp}/moqx-quicprobe.XXXXXX")"

    cleanup() {
      rm -rf "$staging"
    }
    trap cleanup EXIT

    mkdir -p "$(dirname "$artifact_path")" "$cache_dir" "$staging/bin"

    cd "$repo_root/bench/quicprobe"
    GOCACHE="$cache_dir" mise exec go@"{{ quicprobe_go_version }}" -- go test ./...
    GOCACHE="$cache_dir" CGO_ENABLED=0 GOOS="$goos" GOARCH="$goarch" \
      mise exec go@"{{ quicprobe_go_version }}" -- \
      go build -trimpath -ldflags "-s -w" -o "$staging/bin/quicprobe" .

    COPYFILE_DISABLE=1 tar -C "$staging" -czf "$artifact_path" bin
    printf 'Built %s\n' "{{ bench_dir }}/$artifact_rel"

# Run the local stream-client Benchee script. Pass script flags after `--`.
bench-transport-stream-clients *args:
    cd "{{ bench_dir }}" && mix run bench/stream_clients.exs -- {{ args }}

# Remove local benchmark build artifacts.
bench-transport-clean:
    rm -rf "{{ bench_dir }}/build"
