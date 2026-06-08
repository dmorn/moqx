set dotenv-load

bench_dir := "bench/moqxprobe"
probed_dir := "bench/probed"
infra_dir := "bench/infra/hetzner"
run_file := bench_dir + "/.run/current"

release_name := "moqxprobe_runtime"
release_cli := "moqxprobe"
release_version := `sed -n 's/.*version: "\([^"]*\)".*/\1/p' bench/moqxprobe/mix.exs | head -1`
probed_release_name := "probed"
probed_release_version := `sed -n 's/.*version: "\([^"]*\)".*/\1/p' bench/probed/mix.exs | head -1`
git_sha := `git rev-parse --short HEAD 2>/dev/null || echo unknown`

elixir_image := env('ELIXIR_IMAGE', 'elixir:1.19.5-otp-28')
go_image := env('GO_IMAGE', 'golang:1.23-bookworm')
quicprobe_go_version := env('QUICPROBE_GO_VERSION', '1.25.6')

artifact_dir := "build/artifacts"
artifact_rel := artifact_dir + "/" + release_cli + "-" + release_version + "-" + git_sha + "-linux-arm64.tar.gz"
artifact := bench_dir + "/" + artifact_rel
remote_dir := "/opt/moqx-bench/moqxprobe"
probed_remote_dir := "/opt/moqx-bench/probed"
probed_port := "9157"
quicprobe_artifact_rel := artifact_dir + "/quicprobe-" + git_sha + "-linux-arm64.tar.gz"
quicprobe_artifact := bench_dir + "/" + quicprobe_artifact_rel
quicprobe_remote_dir := "/opt/moqx-bench/quicprobe"
quicprobe_go_cache := bench_dir + "/tmp/go-build-cache"
current_run := `if [ -f bench/moqxprobe/.run/current ]; then cat bench/moqxprobe/.run/current; fi`

# Show available recipes.
default:
    @just --list

# Create a new benchmark run id and its ephemeral SSH key.
bench-transport-new-run suffix="smoke":
    #!/usr/bin/env bash
    set -euo pipefail

    run_file="{{ run_file }}"

    if [ -s "$run_file" ]; then
      printf 'Current run already exists: %s\n' "$(cat "$run_file")" >&2
      printf '%s\n' 'Run `just bench-transport-clear-run` after destroying/recording the current run.' >&2
      exit 2
    fi

    if [ -n "{{ suffix }}" ]; then
      run_id="$(date -u +%Y%m%dT%H%M%SZ)-{{ suffix }}"
    else
      run_id="$(date -u +%Y%m%dT%H%M%SZ)"
    fi

    key_dir="{{ bench_dir }}/.keys/$run_id"
    mkdir -p "$(dirname "$run_file")" "$key_dir"
    printf '%s\n' "$run_id" > "$run_file"
    ssh-keygen -t ed25519 -N '' -C "moqxprobe-$run_id" -f "$key_dir/id_ed25519"
    printf '%s\n' "$run_id"

# Print the current benchmark run id.
bench-transport-current-run:
    @test -s "{{ run_file }}" || (printf '%s\n' 'No current run. Run `just bench-transport-new-run` first.' >&2; exit 2)
    @cat "{{ run_file }}"

# Clear only the local current-run pointer. This does not destroy cloud resources.
bench-transport-clear-run:
    @rm -f "{{ run_file }}"

# Initialize the Hetzner Terraform module.
bench-transport-tf-init:
    cd "{{ infra_dir }}" && terraform init

# Format-check and validate the Hetzner Terraform module.
bench-transport-tf-validate: bench-transport-tf-init
    cd "{{ infra_dir }}" && terraform fmt -check -recursive .
    cd "{{ infra_dir }}" && terraform validate

# Create a reviewed Terraform plan for a benchmark run.
bench-transport-plan run_id=current_run profile="arm-smoke": bench-transport-tf-validate
    #!/usr/bin/env bash
    set -euo pipefail

    : "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required. Put it in .env or export it.}"

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    test -f "{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519.pub" || {
      printf 'Missing SSH public key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    cd "{{ infra_dir }}"
    terraform plan \
      -var-file="profiles/{{ profile }}.tfvars" \
      -var="run_id={{ run_id }}" \
      -var="ssh_public_key_path=../../moqxprobe/.keys/{{ run_id }}/id_ed25519.pub" \
      -out="/private/tmp/moqx-{{ run_id }}.tfplan"

# Apply a previously reviewed Terraform plan.
bench-transport-apply-plan run_id=current_run:
    #!/usr/bin/env bash
    set -euo pipefail

    : "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required. Put it in .env or export it.}"

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    cd "{{ infra_dir }}"
    terraform apply -auto-approve "/private/tmp/moqx-{{ run_id }}.tfplan"

# Destroy the Hetzner resources for a benchmark run.
bench-transport-destroy run_id=current_run profile="arm-smoke":
    #!/usr/bin/env bash
    set -euo pipefail

    : "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required. Put it in .env or export it.}"

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    cd "{{ infra_dir }}"
    terraform destroy -auto-approve \
      -var-file="profiles/{{ profile }}.tfvars" \
      -var="run_id={{ run_id }}" \
      -var="ssh_public_key_path=../../moqxprobe/.keys/{{ run_id }}/id_ed25519.pub"

# Print Terraform outputs for the current benchmark pair.
bench-transport-outputs:
    cd "{{ infra_dir }}" && terraform output

# Prove private-network readiness with ICMP and TCP before benchmark traffic.
bench-transport-private-check run_id=current_run port="55209":
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    servers_json="$(cd "{{ infra_dir }}" && terraform output -json servers)"
    client_public="$(printf '%s' "$servers_json" | jq -r '.client.public_ipv4')"
    server_public="$(printf '%s' "$servers_json" | jq -r '.server.public_ipv4')"
    client_private="$(printf '%s' "$servers_json" | jq -r '.client.private_ip // empty')"
    server_private="$(printf '%s' "$servers_json" | jq -r '.server.private_ip // empty')"

    if [ -z "$client_private" ] || [ -z "$server_private" ]; then
      printf '%s\n' 'Terraform outputs do not include private IPs. Private network is disabled or not applied.' >&2
      exit 2
    fi

    ssh_opts=(
      -i "$key"
      -o IdentitiesOnly=yes
      -o StrictHostKeyChecking=accept-new
      -o UserKnownHostsFile="{{ bench_dir }}/.keys/{{ run_id }}/known_hosts"
    )

    client="root@$client_public"
    server="root@$server_public"
    remote_log="/tmp/moqx-private-iperf3-{{ port }}.log"

    cleanup() {
      ssh "${ssh_opts[@]}" "$server" "pkill -f 'iperf3 .*--port {{ port }}' >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT

    ssh "${ssh_opts[@]}" "$client" "cloud-init status --wait >/dev/null && ip -4 address show && ip route get '$server_private'"
    ssh "${ssh_opts[@]}" "$server" "cloud-init status --wait >/dev/null && ip -4 address show && ip route get '$client_private'"
    ssh "${ssh_opts[@]}" "$server" "nohup iperf3 --server --bind '$server_private' --port '{{ port }}' --one-off > '$remote_log' 2>&1 &"
    sleep 1
    ssh "${ssh_opts[@]}" "$client" "ping -c 3 -W 2 '$server_private'"
    ssh "${ssh_opts[@]}" "$client" "iperf3 --client '$server_private' --port '{{ port }}' --time 1 --json >/tmp/moqx-private-check.json"

    printf 'Private network ready: %s -> %s over ICMP and TCP port %s\n' "$client_private" "$server_private" "{{ port }}"

# Verify Terraform state and Hetzner labelled resources are clean after destroy.
bench-transport-verify-clean:
    #!/usr/bin/env bash
    set -euo pipefail

    : "${HCLOUD_TOKEN:?HCLOUD_TOKEN is required. Put it in .env or export it.}"

    state="$(cd "{{ infra_dir }}" && terraform state list)"
    if [ -n "$state" ]; then
      printf '%s\n' "$state" >&2
      printf '%s\n' 'Terraform state is not empty.' >&2
      exit 1
    fi

    for kind in server firewall network ssh-key; do
      found="$(hcloud "$kind" list -l purpose=moqxprobe -o noheader)"
      if [ -n "$found" ]; then
        printf '%s resources remain:\n%s\n' "$kind" "$found" >&2
        exit 1
      fi
    done

    printf '%s\n' 'No Terraform state entries or labelled Hetzner resources remain.'

# Print the deployable moqxprobe Mix release artifact path for one Linux target.
bench-transport-release-artifact-rel moqxprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ moqxprobe_target }}" in
      linux_arm64) artifact_target="linux-arm64" ;;
      linux_x86_64) artifact_target="linux-x86_64" ;;
      *)
        printf 'Unsupported moqxprobe target: %s\n' "{{ moqxprobe_target }}" >&2
        printf '%s\n' 'Remote moqxprobe builds are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    printf '%s/%s-%s-%s-%s.tar.gz\n' \
      "{{ artifact_dir }}" \
      "{{ release_cli }}" \
      "{{ release_version }}" \
      "{{ git_sha }}" \
      "$artifact_target"

# Print the deployable moqxprobe Mix release artifact path for one Linux target.
bench-transport-release-artifact-path moqxprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    artifact_rel="$(just --quiet bench-transport-release-artifact-rel "{{ moqxprobe_target }}")"
    printf '%s/%s\n' "{{ bench_dir }}" "$artifact_rel"

# Print the most recently built moqxprobe artifact path for one Linux target.
bench-transport-latest-release-artifact-rel moqxprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    marker="{{ bench_dir }}/{{ artifact_dir }}/.last-moqxprobe-{{ moqxprobe_target }}.txt"

    if [ ! -s "$marker" ]; then
      printf 'No latest moqxprobe artifact recorded for %s. Build it first.\n' "{{ moqxprobe_target }}" >&2
      exit 2
    fi

    cat "$marker"

# Build the moqxprobe Mix release artifact with Docker for one Linux target.
bench-transport-build-release moqxprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ moqxprobe_target }}" in
      linux_arm64)
        docker_platform="linux/arm64"
        ;;
      linux_x86_64)
        docker_platform="linux/amd64"
        ;;
      *)
        printf 'Unsupported moqxprobe target: %s\n' "{{ moqxprobe_target }}" >&2
        printf '%s\n' 'Docker moqxprobe builds are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    artifact_rel="$(just --quiet bench-transport-release-artifact-rel "{{ moqxprobe_target }}")"
    artifact_name="$(basename "$artifact_rel")"
    artifact_path="{{ bench_dir }}/$artifact_rel"

    mkdir -p "$(dirname "$artifact_path")"
    cd "{{ bench_dir }}"
    docker buildx build \
      --platform "$docker_platform" \
      --file docker/Dockerfile.release \
      --target artifact \
      --output "type=local,dest={{ artifact_dir }}" \
      --build-arg "ELIXIR_IMAGE={{ elixir_image }}" \
      --build-arg "RELEASE_NAME={{ release_name }}" \
      --build-arg "BUILD_GIT_SHA={{ git_sha }}" \
      --build-arg "ARTIFACT_NAME=$artifact_name" \
      ../..
    test -f "$artifact_rel"
    printf 'Built %s\n' "$artifact_path"

# Build the moqxprobe Mix release natively on one Terraform role and fetch it locally.
bench-transport-build-release-remote-role run_id role moqxprobe_target="linux_x86_64":
    #!/usr/bin/env bash
    set -euo pipefail

    target="$(just --quiet bench-transport-target "{{ role }}")"
    just bench-transport-build-release-remote-target "$target" "{{ run_id }}" "{{ moqxprobe_target }}"

# Build the moqxprobe Mix release natively on one explicit SSH target and fetch it locally.
bench-transport-build-release-remote-target target run_id moqxprobe_target="linux_x86_64":
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    case "{{ moqxprobe_target }}" in
      linux_arm64)
        expected_uname="aarch64"
        artifact_target="linux-arm64"
        ;;
      linux_x86_64)
        expected_uname="x86_64"
        artifact_target="linux-x86_64"
        ;;
      *)
        printf 'Unsupported moqxprobe target: %s\n' "{{ moqxprobe_target }}" >&2
        printf '%s\n' 'Remote moqxprobe builds are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    local_stage="$(mktemp -d "${TMPDIR:-/tmp}/moqxprobe-source.XXXXXX")"

    cleanup() {
      rm -rf "$local_stage"
    }
    trap cleanup EXIT

    source_archive="$local_stage/source.tar.gz"
    source_metadata="$local_stage/source-metadata.json"
    source_id="$("{{ bench_dir }}/scripts/source_snapshot.sh" \
      --output "$source_archive" \
      --metadata "$source_metadata")"

    artifact_name="{{ release_cli }}-{{ release_version }}-$source_id-$artifact_target.tar.gz"
    artifact_rel="{{ artifact_dir }}/$artifact_name"
    artifact_name="$(basename "$artifact_rel")"
    artifact_path="{{ bench_dir }}/$artifact_rel"
    artifact_metadata="$local_stage/artifact-metadata.json"
    last_artifact="{{ bench_dir }}/{{ artifact_dir }}/.last-moqxprobe-{{ moqxprobe_target }}.txt"
    remote_root="/var/tmp/moqxprobe-native-build"
    remote_cache="$remote_root/cache/{{ moqxprobe_target }}"
    remote_source="/tmp/moqxprobe-source-$source_id.tar.gz"
    remote_metadata="/tmp/moqxprobe-source-$source_id.json"
    remote_work="$remote_root/sources/$source_id"
    remote_artifact="$remote_root/artifacts/$artifact_name"

    mkdir -p "$(dirname "$artifact_path")"
    jq \
      --arg app "{{ release_cli }}" \
      --arg version "{{ release_version }}" \
      --arg release_name "{{ release_name }}" \
      --arg artifact_name "$artifact_name" \
      --arg artifact_rel "$artifact_rel" \
      --arg target "{{ moqxprobe_target }}" \
      --arg artifact_target "$artifact_target" \
      '. + {
        app: $app,
        version: $version,
        release_name: $release_name,
        artifact_name: $artifact_name,
        artifact_rel: $artifact_rel,
        target: $target,
        artifact_target: $artifact_target
      }' "$source_metadata" > "$artifact_metadata"

    SSH_OPTS="-i {{ bench_dir }}/.keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={{ bench_dir }}/.keys/{{ run_id }}/known_hosts"

    # shellcheck disable=SC2086
    remote_uname="$(ssh $SSH_OPTS "{{ target }}" "uname -m")"
    if [ "$remote_uname" != "$expected_uname" ]; then
      printf 'Target architecture mismatch for %s: got %s, expected %s\n' \
        "{{ moqxprobe_target }}" "$remote_uname" "$expected_uname" >&2
      exit 1
    fi

    # shellcheck disable=SC2086
    scp $SSH_OPTS "$source_archive" "{{ target }}:$remote_source"
    # shellcheck disable=SC2086
    scp $SSH_OPTS "$artifact_metadata" "{{ target }}:$remote_metadata"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "{{ target }}" \
      "set -e; \
       export MIX_ENV=prod LANG=C.UTF-8 MOQXPROBE_BUILD_GIT_SHA=$source_id; \
       export MIX_HOME='$remote_cache/mix_home'; \
       export HEX_HOME='$remote_cache/hex_home'; \
       export REBAR_CACHE_DIR='$remote_cache/rebar3'; \
       export MIX_DEPS_PATH='$remote_cache/deps'; \
       export MIX_BUILD_ROOT='$remote_cache/build'; \
       mkdir -p '$remote_root/artifacts' '$remote_cache/mix_home' '$remote_cache/hex_home' '$remote_cache/rebar3' '$remote_cache/deps' '$remote_cache/build'; \
       if [ ! -f '$remote_artifact' ]; then \
         rm -rf '$remote_work'; \
         mkdir -p '$remote_work'; \
         tar -xzf '$remote_source' -C '$remote_work'; \
         cd '$remote_work/bench/moqxprobe'; \
         mix local.hex --force; \
         mix local.rebar --force; \
         mix deps.get --only prod; \
         mix release '{{ release_name }}' --overwrite; \
         test -x '_build/prod/rel/{{ release_name }}/bin/moqxprobe'; \
         cp '$remote_metadata' '_build/prod/rel/{{ release_name }}/.moqx-bench-artifact.json'; \
         tar -C '_build/prod/rel/{{ release_name }}' -czf '$remote_artifact' .; \
       fi; \
       rm -f '$remote_source' '$remote_metadata'; \
       test -f '$remote_artifact'"

    # shellcheck disable=SC2086
    scp $SSH_OPTS "{{ target }}:$remote_artifact" "$artifact_path"
    cp "$artifact_metadata" "$artifact_path.json"
    printf '%s\n' "$artifact_rel" > "$last_artifact"
    printf 'Built %s on %s and fetched %s\n' "{{ moqxprobe_target }}" "{{ target }}" "$artifact_path"

# Print the quicprobe artifact path for one target.
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
        exit 2
        ;;
    esac

    printf '%s/quicprobe-%s-%s.tar.gz\n' \
      "{{ artifact_dir }}" \
      "{{ git_sha }}" \
      "$artifact_target"

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

    tar -C "$staging" -czf "$artifact_path" .
    printf 'Built %s\n' "{{ bench_dir }}/$artifact_rel"

# Build the quicprobe reference peer artifact with Docker.
bench-transport-build-quicprobe-docker quicprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ quicprobe_target }}" in
      linux_arm64)
        docker_platform="linux/arm64"
        ;;
      linux_x86_64)
        docker_platform="linux/amd64"
        ;;
      *)
        printf 'Unsupported quicprobe target: %s\n' "{{ quicprobe_target }}" >&2
        printf '%s\n' 'Docker quicprobe builds are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    artifact_rel="$(just --quiet bench-transport-quicprobe-artifact-rel "{{ quicprobe_target }}")"
    artifact_name="$(basename "$artifact_rel")"

    mkdir -p "{{ bench_dir }}/{{ artifact_dir }}"
    docker buildx build \
      --platform "$docker_platform" \
      --file "{{ bench_dir }}/docker/Dockerfile.quicprobe" \
      --target artifact \
      --output "type=local,dest={{ bench_dir }}/{{ artifact_dir }}" \
      --build-arg "GO_IMAGE={{ go_image }}" \
      --build-arg "ARTIFACT_NAME=$artifact_name" \
      .
    test -f "{{ bench_dir }}/$artifact_rel"
    printf 'Built %s\n' "{{ bench_dir }}/$artifact_rel"

# Print the deployable probed Mix release artifact path for one Linux target.
bench-transport-probed-artifact-rel probed_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ probed_target }}" in
      linux_arm64) artifact_target="linux-arm64" ;;
      linux_x86_64) artifact_target="linux-x86_64" ;;
      *)
        printf 'Unsupported probed target: %s\n' "{{ probed_target }}" >&2
        printf '%s\n' 'Remote probed builds are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    printf '%s/probed-%s-%s-%s.tar.gz\n' \
      "{{ artifact_dir }}" \
      "{{ probed_release_version }}" \
      "{{ git_sha }}" \
      "$artifact_target"

# Build the probed Mix release artifact with Docker for one Linux target.
bench-transport-build-probed probed_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ probed_target }}" in
      linux_arm64)
        docker_platform="linux/arm64"
        ;;
      linux_x86_64)
        docker_platform="linux/amd64"
        ;;
      *)
        printf 'Unsupported probed target: %s\n' "{{ probed_target }}" >&2
        printf '%s\n' 'Remote probed builds are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    artifact_rel="$(just --quiet bench-transport-probed-artifact-rel "{{ probed_target }}")"
    artifact_name="$(basename "$artifact_rel")"

    mkdir -p "{{ probed_dir }}/{{ artifact_dir }}"
    docker buildx build \
      --platform "$docker_platform" \
      --file "{{ probed_dir }}/docker/Dockerfile.release" \
      --target artifact \
      --output "type=local,dest={{ probed_dir }}/{{ artifact_dir }}" \
      --build-arg "ELIXIR_IMAGE={{ elixir_image }}" \
      --build-arg "RELEASE_NAME={{ probed_release_name }}" \
      --build-arg "BUILD_GIT_SHA={{ git_sha }}" \
      --build-arg "ARTIFACT_NAME=$artifact_name" \
      .
    test -f "{{ probed_dir }}/$artifact_rel"
    printf 'Built %s\n' "{{ probed_dir }}/$artifact_rel"

# Build the probed Mix release natively on one Terraform role and fetch it locally.
bench-transport-build-probed-remote-role run_id role probed_target="linux_x86_64":
    #!/usr/bin/env bash
    set -euo pipefail

    target="$(just --quiet bench-transport-target "{{ role }}")"
    just bench-transport-build-probed-remote-target "$target" "{{ run_id }}" "{{ probed_target }}"

# Build the probed Mix release natively on one explicit SSH target and fetch it locally.
bench-transport-build-probed-remote-target target run_id probed_target="linux_x86_64":
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    case "{{ probed_target }}" in
      linux_arm64)
        expected_uname="aarch64"
        ;;
      linux_x86_64)
        expected_uname="x86_64"
        ;;
      *)
        printf 'Unsupported probed target: %s\n' "{{ probed_target }}" >&2
        printf '%s\n' 'Remote probed builds are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    artifact_rel="$(just --quiet bench-transport-probed-artifact-rel "{{ probed_target }}")"
    artifact_name="$(basename "$artifact_rel")"
    artifact_path="{{ probed_dir }}/$artifact_rel"
    local_stage="$(mktemp -d "${TMPDIR:-/tmp}/probed-source.XXXXXX")"
    remote_root="/var/tmp/probed-native-build"
    remote_source="/tmp/probed-source-{{ git_sha }}.tar.gz"
    remote_work="$remote_root/{{ git_sha }}"
    remote_artifact="$remote_root/artifacts/$artifact_name"

    cleanup() {
      rm -rf "$local_stage"
    }
    trap cleanup EXIT

    mkdir -p "$(dirname "$artifact_path")"
    git archive --format=tar.gz --output "$local_stage/source.tar.gz" HEAD

    SSH_OPTS="-i {{ bench_dir }}/.keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={{ bench_dir }}/.keys/{{ run_id }}/known_hosts"

    # shellcheck disable=SC2086
    remote_uname="$(ssh $SSH_OPTS "{{ target }}" "uname -m")"
    if [ "$remote_uname" != "$expected_uname" ]; then
      printf 'Target architecture mismatch for %s: got %s, expected %s\n' \
        "{{ probed_target }}" "$remote_uname" "$expected_uname" >&2
      exit 1
    fi

    # shellcheck disable=SC2086
    scp $SSH_OPTS "$local_stage/source.tar.gz" "{{ target }}:$remote_source"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "{{ target }}" \
      "set -e; \
       export MIX_ENV=prod LANG=C.UTF-8; \
       mkdir -p '$remote_root/artifacts'; \
       if [ ! -f '$remote_artifact' ]; then \
         rm -rf '$remote_work'; \
         mkdir -p '$remote_work'; \
         tar -xzf '$remote_source' -C '$remote_work'; \
         cd '$remote_work/bench/probed'; \
         mix local.hex --force; \
         mix local.rebar --force; \
         mix deps.get --only prod; \
         mix release '{{ probed_release_name }}' --overwrite; \
         test -x '_build/prod/rel/{{ probed_release_name }}/bin/probed'; \
         tar -C '_build/prod/rel/{{ probed_release_name }}' -czf '$remote_artifact' .; \
       fi; \
       rm -f '$remote_source'; \
       test -f '$remote_artifact'"

    # shellcheck disable=SC2086
    scp $SSH_OPTS "{{ target }}:$remote_artifact" "$artifact_path"
    printf 'Built %s on %s and fetched %s\n' "{{ probed_target }}" "{{ target }}" "$artifact_path"

# Print the moqxprobe Mix release artifact path for one Linux target.
bench-transport-artifact-path moqxprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    artifact_rel="$(just --quiet bench-transport-release-artifact-rel "{{ moqxprobe_target }}")"
    printf '%s/%s\n' "{{ bench_dir }}" "$artifact_rel"

# Print the quicprobe artifact path for one target.
bench-transport-quicprobe-artifact-path quicprobe_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    artifact_rel="$(just --quiet bench-transport-quicprobe-artifact-rel "{{ quicprobe_target }}")"
    printf '%s/%s\n' "{{ bench_dir }}" "$artifact_rel"

# Print the probed artifact path for one Linux target.
bench-transport-probed-artifact-path probed_target="linux_arm64":
    #!/usr/bin/env bash
    set -euo pipefail

    artifact_rel="$(just --quiet bench-transport-probed-artifact-rel "{{ probed_target }}")"
    printf '%s/%s\n' "{{ probed_dir }}" "$artifact_rel"

# Deploy the release artifact to both Terraform roles in parallel.
[parallel]
bench-transport-deploy run_id=current_run artifact=artifact_rel: (bench-transport-deploy-role run_id "client" artifact) (bench-transport-deploy-role run_id "server" artifact)

# Deploy the moqxprobe Mix release artifact for one Linux target to both Terraform roles.
[parallel]
bench-transport-deploy-release moqxprobe_target="linux_arm64" run_id=current_run: (bench-transport-deploy-release-role moqxprobe_target run_id "client") (bench-transport-deploy-release-role moqxprobe_target run_id "server")

# Deploy the quicprobe reference peer artifact to both Terraform roles in parallel.
[parallel]
bench-transport-deploy-quicprobe quicprobe_target="linux_arm64" run_id=current_run: (bench-transport-deploy-quicprobe-role quicprobe_target run_id "client") (bench-transport-deploy-quicprobe-role quicprobe_target run_id "server")

# Deploy the probed daemon artifact to both Terraform roles in parallel.
[parallel]
bench-transport-deploy-probed probed_target="linux_arm64" run_id=current_run: (bench-transport-deploy-probed-role probed_target run_id "client") (bench-transport-deploy-probed-role probed_target run_id "server")

# Build the current worktree moqxprobe release on a lab node and deploy it to both roles.
bench-transport-update-moqxprobe run_id=current_run moqxprobe_target="linux_x86_64" builder_role="client":
    #!/usr/bin/env bash
    set -euo pipefail

    just bench-transport-build-release-remote-role "{{ run_id }}" "{{ builder_role }}" "{{ moqxprobe_target }}"
    artifact="$(just --quiet bench-transport-latest-release-artifact-rel "{{ moqxprobe_target }}")"
    just bench-transport-deploy "{{ run_id }}" "$artifact"

# Deploy the release artifact to one Terraform role.
bench-transport-deploy-role run_id role artifact=artifact_rel:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    target="$(just --quiet bench-transport-target {{ role }})"
    just bench-transport-deploy-target "$target" "{{ run_id }}" "{{ artifact }}"

# Deploy the moqxprobe Mix release artifact for one Linux target to one Terraform role.
bench-transport-deploy-release-role moqxprobe_target run_id role:
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ moqxprobe_target }}" in
      linux_arm64|linux_x86_64) ;;
      *)
        printf 'Unsupported deploy target for moqxprobe: %s\n' "{{ moqxprobe_target }}" >&2
        printf '%s\n' 'Remote deploys are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    artifact="$(just --quiet bench-transport-release-artifact-rel "{{ moqxprobe_target }}")"
    target="$(just --quiet bench-transport-target {{ role }})"
    just bench-transport-deploy-target "$target" "{{ run_id }}" "$artifact"

# Deploy the quicprobe artifact to one Terraform role.
bench-transport-deploy-quicprobe-role quicprobe_target run_id role:
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ quicprobe_target }}" in
      linux_arm64|linux_x86_64) ;;
      *)
        printf 'Unsupported deploy target for quicprobe: %s\n' "{{ quicprobe_target }}" >&2
        printf '%s\n' 'Remote deploys are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    artifact="$(just --quiet bench-transport-quicprobe-artifact-rel "{{ quicprobe_target }}")"
    target="$(just --quiet bench-transport-target {{ role }})"
    just bench-transport-deploy-quicprobe-target "$target" "{{ run_id }}" "$artifact"

# Deploy the probed daemon artifact to one Terraform role.
bench-transport-deploy-probed-role probed_target run_id role:
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ probed_target }}" in
      linux_arm64|linux_x86_64) ;;
      *)
        printf 'Unsupported deploy target for probed: %s\n' "{{ probed_target }}" >&2
        printf '%s\n' 'Remote deploys are Linux-only; use linux_arm64 or linux_x86_64.' >&2
        exit 2
        ;;
    esac

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    artifact="$(just --quiet bench-transport-probed-artifact-rel "{{ probed_target }}")"
    target="$(just --quiet bench-transport-target {{ role }})"
    just bench-transport-deploy-probed-target "$target" "{{ run_id }}" "$artifact"

# Print the public SSH target for a Terraform role.
bench-transport-target role:
    #!/usr/bin/env bash
    set -euo pipefail

    case "{{ role }}" in
      client|server) ;;
      *)
        printf 'Unknown role: %s\n' "{{ role }}" >&2
        exit 2
        ;;
    esac

    cd "{{ infra_dir }}"
    terraform output -json servers | jq -r --arg role "{{ role }}" '.[$role].public_ipv4 | "root@" + .'

# Print the preferred probed bind address for a Terraform role.
bench-transport-probed-bind role port=probed_port:
    #!/usr/bin/env bash
    set -euo pipefail

    cd "{{ infra_dir }}"
    private_ip="$(terraform output -json servers | jq -r --arg role "{{ role }}" '.[$role].private_ip // empty')"

    if [ -n "$private_ip" ]; then
      printf '%s:%s\n' "$private_ip" "{{ port }}"
    else
      printf '127.0.0.1:%s\n' "{{ port }}"
    fi

# Deploy the release artifact to one explicit SSH target.
bench-transport-deploy-target target run_id=current_run artifact=artifact_rel:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    mkdir -p "{{ bench_dir }}/results/{{ run_id }}"
    safe_target="$(printf '%s' "{{ target }}" | tr -c 'A-Za-z0-9_.@-' '_')"
    log="{{ bench_dir }}/results/{{ run_id }}/deploy-$safe_target.log"

    cd "{{ bench_dir }}"
    SSH_OPTS="-i .keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.keys/{{ run_id }}/known_hosts" \
      scripts/deploy_release.sh \
        --artifact "{{ artifact }}" \
        --remote-dir "{{ remote_dir }}" \
        --smoke \
        -- "{{ target }}" 2>&1 | tee "../../$log"

# Deploy the quicprobe artifact to one explicit SSH target.
bench-transport-deploy-quicprobe-target target run_id=current_run artifact=quicprobe_artifact_rel:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    mkdir -p "{{ bench_dir }}/results/{{ run_id }}"
    safe_target="$(printf '%s' "{{ target }}" | tr -c 'A-Za-z0-9_.@-' '_')"
    log="{{ bench_dir }}/results/{{ run_id }}/deploy-quicprobe-$safe_target.log"

    cd "{{ bench_dir }}"
    SSH_OPTS="-i .keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=.keys/{{ run_id }}/known_hosts" \
      scripts/deploy_release.sh \
        --artifact "{{ artifact }}" \
        --remote-dir "{{ quicprobe_remote_dir }}" \
        --smoke-command "bin/quicprobe 2>&1 | grep -q usage:" \
        -- "{{ target }}" 2>&1 | tee "../../$log"

# Deploy the probed daemon artifact to one explicit SSH target.
bench-transport-deploy-probed-target target run_id=current_run artifact="":
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    if [ -z "{{ artifact }}" ]; then
      printf '%s\n' 'Missing probed artifact path.' >&2
      exit 2
    fi

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    mkdir -p "{{ bench_dir }}/results/{{ run_id }}"
    safe_target="$(printf '%s' "{{ target }}" | tr -c 'A-Za-z0-9_.@-' '_')"
    log="{{ bench_dir }}/results/{{ run_id }}/deploy-probed-$safe_target.log"

    SSH_OPTS="-i {{ bench_dir }}/.keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={{ bench_dir }}/.keys/{{ run_id }}/known_hosts" \
      "{{ bench_dir }}/scripts/deploy_release.sh" \
        --artifact "{{ probed_dir }}/{{ artifact }}" \
        --remote-dir "{{ probed_remote_dir }}" \
        --smoke-command "test -x bin/probed" \
        -- "{{ target }}" 2>&1 | tee "$log"

# Print or create the local bearer token used by probed for a run.
bench-transport-probed-token run_id=current_run:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    token_path="{{ bench_dir }}/.keys/{{ run_id }}/probed.token"
    mkdir -p "$(dirname "$token_path")"

    if [ ! -s "$token_path" ]; then
      openssl rand -hex 32 > "$token_path"
      chmod 0600 "$token_path"
    fi

    cat "$token_path"

# Start probed for one Terraform role and verify /v1/health from the node.
bench-transport-start-probed-role run_id role port=probed_port:
    #!/usr/bin/env bash
    set -euo pipefail

    target="$(just --quiet bench-transport-target "{{ role }}")"
    bind="$(just --quiet bench-transport-probed-bind "{{ role }}" "{{ port }}")"
    just bench-transport-start-probed-target "$target" "{{ run_id }}" "{{ role }}" "$bind"

# Start probed on one explicit SSH target and verify /v1/health from the node.
bench-transport-start-probed-target target run_id node_id bind:
    #!/usr/bin/env bash
    set -euo pipefail

    if [ -z "{{ run_id }}" ]; then
      printf '%s\n' 'Missing run_id. Run `just bench-transport-new-run` first or pass run_id explicitly.' >&2
      exit 2
    fi

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    token="$(just --quiet bench-transport-probed-token "{{ run_id }}")"
    staging="$(mktemp -d "${TMPDIR:-/tmp}/moqx-probed-config.XXXXXX")"

    cleanup() {
      rm -rf "$staging"
    }
    trap cleanup EXIT

    printf '%s\n' "$token" > "$staging/probed.token"

    jq -n \
      --arg node_id "{{ node_id }}" \
      --arg bind "{{ bind }}" \
      --arg work_dir "/var/lib/probed" \
      --arg token_file "/etc/moqx-bench/probed.token" \
      '{
        node_id: $node_id,
        bind: $bind,
        work_dir: $work_dir,
        token_file: $token_file,
        tools: {
          moqxprobe: {path: "/opt/moqx-bench/moqxprobe/current/bin/moqxprobe"},
          quicprobe: {path: "/opt/moqx-bench/quicprobe/current/bin/quicprobe"},
          iperf3: {path: "/usr/bin/iperf3"}
        }
      }' > "$staging/probed.json"

    SSH_OPTS="-i {{ bench_dir }}/.keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={{ bench_dir }}/.keys/{{ run_id }}/known_hosts"

    # shellcheck disable=SC2086
    scp $SSH_OPTS "$staging/probed.token" "$staging/probed.json" "{{ target }}:/tmp/"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "{{ target }}" \
      "set -e; \
       install -d -m 0755 /etc/moqx-bench /var/lib/probed; \
       install -m 0600 /tmp/probed.token /etc/moqx-bench/probed.token; \
       install -m 0644 /tmp/probed.json /etc/moqx-bench/probed.json; \
       rm -f /tmp/probed.token /tmp/probed.json; \
       pid_file=/var/lib/probed/probed.pid; \
       log_file=/var/lib/probed/probed.log; \
       if [ -f \"\$pid_file\" ]; then \
         old_pid=\"\$(cat \"\$pid_file\")\"; \
         if [ -n \"\$old_pid\" ]; then kill \"\$old_pid\" >/dev/null 2>&1 || true; fi; \
         rm -f \"\$pid_file\"; \
         sleep 1; \
       fi; \
       PROBED_CONFIG=/etc/moqx-bench/probed.json nohup {{ probed_remote_dir }}/current/bin/probed start > \"\$log_file\" 2>&1 & \
       echo \$! > \"\$pid_file\"; \
       sleep 1; \
       curl -fsS -H 'Authorization: Bearer $token' 'http://{{ bind }}/v1/health'"

# Stop probed for one Terraform role.
bench-transport-stop-probed-role run_id role:
    #!/usr/bin/env bash
    set -euo pipefail

    target="$(just --quiet bench-transport-target "{{ role }}")"
    just bench-transport-stop-probed-target "$target" "{{ run_id }}"

# Stop probed on one explicit SSH target.
bench-transport-stop-probed-target target run_id=current_run:
    #!/usr/bin/env bash
    set -euo pipefail

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    SSH_OPTS="-i {{ bench_dir }}/.keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={{ bench_dir }}/.keys/{{ run_id }}/known_hosts"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "{{ target }}" \
      "set -e; \
       pid_file=/var/lib/probed/probed.pid; \
       if [ -f \"\$pid_file\" ]; then \
         pid=\"\$(cat \"\$pid_file\")\"; \
         if [ -n \"\$pid\" ]; then kill \"\$pid\" >/dev/null 2>&1 || true; fi; \
         rm -f \"\$pid_file\"; \
       fi"

# Verify probed /v1/health for one Terraform role from the node itself.
bench-transport-probed-health-role run_id role port=probed_port:
    #!/usr/bin/env bash
    set -euo pipefail

    target="$(just --quiet bench-transport-target "{{ role }}")"
    bind="$(just --quiet bench-transport-probed-bind "{{ role }}" "{{ port }}")"
    just bench-transport-probed-health-target "$target" "{{ run_id }}" "$bind"

# Verify probed /v1/health on one explicit SSH target from the node itself.
bench-transport-probed-health-target target run_id bind:
    #!/usr/bin/env bash
    set -euo pipefail

    key="{{ bench_dir }}/.keys/{{ run_id }}/id_ed25519"
    test -f "$key" || {
      printf 'Missing SSH key for run %s\n' "{{ run_id }}" >&2
      exit 2
    }

    token="$(just --quiet bench-transport-probed-token "{{ run_id }}")"
    SSH_OPTS="-i {{ bench_dir }}/.keys/{{ run_id }}/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile={{ bench_dir }}/.keys/{{ run_id }}/known_hosts"

    # shellcheck disable=SC2086
    ssh $SSH_OPTS "{{ target }}" "curl -fsS -H 'Authorization: Bearer $token' 'http://{{ bind }}/v1/health'"

# Run a remote multi-test benchmark suite through probed.
bench-transport-probed-suite run_id=current_run tests="iperf3,reference_stream,moqx_stream" port=probed_port quic_port="55433" iperf3_port="55201":
    bench/probed/scripts/remote_curl_suite.sh \
      --run-id "{{ run_id }}" \
      --tests "{{ tests }}" \
      --probed-port "{{ port }}" \
      --quic-port "{{ quic_port }}" \
      --iperf3-port "{{ iperf3_port }}"

# Build/deploy the current moqxprobe worktree, then run selected tests through probed.
bench-transport-iterate-moqxprobe run_id=current_run moqxprobe_target="linux_x86_64" tests="iperf3,reference_stream,moqx_stream" builder_role="client" port=probed_port quic_port="55433" iperf3_port="55201":
    #!/usr/bin/env bash
    set -euo pipefail

    just bench-transport-update-moqxprobe "{{ run_id }}" "{{ moqxprobe_target }}" "{{ builder_role }}"
    just bench-transport-probed-health-role "{{ run_id }}" client "{{ port }}"
    just bench-transport-probed-health-role "{{ run_id }}" server "{{ port }}"
    just bench-transport-probed-suite "{{ run_id }}" "{{ tests }}" "{{ port }}" "{{ quic_port }}" "{{ iperf3_port }}"

# Remove local transport benchmark release artifacts.
bench-transport-clean:
    rm -rf "{{ bench_dir }}/build" "{{ probed_dir }}/build"
