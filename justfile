set dotenv-load

bench_dir := "bench/transport"
infra_dir := bench_dir + "/infra/hetzner"
run_file := bench_dir + "/.run/current"

release_name := "moqx_transport_bench"
release_cli := "moqx-transport-bench"
release_version := `sed -n 's/.*version: "\([^"]*\)".*/\1/p' bench/transport/mix.exs | head -1`
git_sha := `git rev-parse --short HEAD 2>/dev/null || echo unknown`

target_os := env('TARGET_OS', 'linux')
target_arch := env('TARGET_ARCH', 'arm64')
docker_platform := target_os + "/" + target_arch
elixir_image := env('ELIXIR_IMAGE', 'elixir:1.19.5-otp-28')

artifact_dir := "build/artifacts"
artifact_name := release_cli + "-" + release_version + "-" + git_sha + "-" + target_os + "-" + target_arch + ".tar.gz"
artifact_rel := artifact_dir + "/" + artifact_name
artifact := bench_dir + "/" + artifact_rel
remote_dir := "/opt/moqx-bench/moqx-transport-bench"
current_run := `if [ -f bench/transport/.run/current ]; then cat bench/transport/.run/current; fi`

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
    ssh-keygen -t ed25519 -N '' -C "moqx-transport-bench-$run_id" -f "$key_dir/id_ed25519"
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
      -var="ssh_public_key_path=../../.keys/{{ run_id }}/id_ed25519.pub" \
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
      -var="ssh_public_key_path=../../.keys/{{ run_id }}/id_ed25519.pub"

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
      found="$(hcloud "$kind" list -l purpose=moqx-transport-bench -o noheader)"
      if [ -n "$found" ]; then
        printf '%s resources remain:\n%s\n' "$kind" "$found" >&2
        exit 1
      fi
    done

    printf '%s\n' 'No Terraform state entries or labelled Hetzner resources remain.'

# Build the Linux/ARM64 benchmark release artifact with Docker.
bench-transport-build-release:
    mkdir -p "{{ bench_dir }}/{{ artifact_dir }}"
    cd "{{ bench_dir }}" && docker buildx build \
      --platform "{{ docker_platform }}" \
      --file docker/Dockerfile.release \
      --target artifact \
      --output "type=local,dest={{ artifact_dir }}" \
      --build-arg "ELIXIR_IMAGE={{ elixir_image }}" \
      --build-arg "RELEASE_NAME={{ release_name }}" \
      --build-arg "BUILD_GIT_SHA={{ git_sha }}" \
      --build-arg "ARTIFACT_NAME={{ artifact_name }}" \
      ../..
    @test -f "{{ artifact }}"
    @printf 'Built %s\n' "{{ artifact }}"

# Print the release artifact path for the current defaults.
bench-transport-artifact-path:
    @printf '%s\n' "{{ artifact }}"

# Deploy the release artifact to both Terraform roles in parallel.
[parallel]
bench-transport-deploy run_id=current_run artifact=artifact_rel: (bench-transport-deploy-role run_id "client" artifact) (bench-transport-deploy-role run_id "server" artifact)

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

# Remove local transport benchmark release artifacts.
bench-transport-clean:
    rm -rf "{{ bench_dir }}/build"
