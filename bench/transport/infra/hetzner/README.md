# Hetzner Transport Benchmark Infrastructure

This Terraform root module creates two short-lived Hetzner Cloud servers for
controlled transport benchmark runs. It does not start benchmark traffic.

## Requirements

- Terraform.
- A Hetzner Cloud API token in `HCLOUD_TOKEN`.
- A per-run SSH public key readable by Terraform.

## Profiles

Use profile files to choose the server type and locations:

| Profile | Type | Locations | Use |
| --- | --- | --- | --- |
| `profiles/arm-smoke.tfvars` | `cax21` | `fsn1` to `nbg1` | Provisioning and build smoke. |
| `profiles/arm-default.tfvars` | `cax31` | `fsn1` to `hel1` | Default ARM benchmark pair. |
| `profiles/arm-stress.tfvars` | `cax41` | `fsn1` to `hel1` | Larger shared-ARM stress pair. |
| `profiles/arm-low-rtt.tfvars` | `cax31` | `fsn1` to `nbg1` | Lower-RTT EU path. |
| `profiles/x86-control.tfvars` | `ccx23` | `fsn1` to `hel1` | Dedicated x86 control pair. |

## Usage

```bash
just bench-transport-new-run
just bench-transport-plan
just bench-transport-apply-plan
just bench-transport-outputs
```

The `just` recipes load `.env` automatically when present. Cloud-mutating
recipes still require `HCLOUD_TOKEN` to be available from `.env` or the
environment.

Check cloud-init and the installed tools before running benchmarks:

```bash
terraform output -json toolchain_check_commands
```

Destroy the pair when the run is finished:

```bash
just bench-transport-destroy
just bench-transport-verify-clean
```

Use a stable `run_id` when multiple pairs may exist at once:

```bash
just bench-transport-plan 20260519-a arm-default
just bench-transport-apply-plan 20260519-a
```

Generate a fresh SSH keypair for each run instead of reusing an operator key.
Terraform uploads the public key to Hetzner Cloud and records it as an
ephemeral `hcloud_ssh_key` resource; the private key stays local and out of
Terraform state.

Use the same `run_id`, profile, and SSH public key path for `apply`, `destroy`,
and any saved plan. The run key can be deleted locally after Terraform destroy
has completed and provider resources have been verified absent.

## Access Model

The module creates two firewalls:

- operator/private access is attached during server creation;
- peer-public access is attached after both public IPv4 addresses exist.

Inbound access is allowed from:

- `operator_cidr`, default `95.254.174.121/32`, to all TCP ports, all UDP
  ports, and ICMP;
- the private benchmark network CIDR, when enabled;
- each benchmark peer public IPv4 address.

Inbound access from other sources is denied. Outbound TCP, UDP, and ICMP are
allowed.

## Provisioning Contract

Cloud-init intentionally does little:

- installs build tools, `iperf3`, and small shell utilities;
- installs Go from the official Linux archive at `go.dev/dl`;
- installs Erlang/OTP and Elixir with the official Elixir install script;
- writes a short note under `/opt/moqx-bench/`.

The benchmark repo is not cloned automatically, and no benchmark process is
started automatically. Deploy a `moqx-transport-bench` release artifact or use
the installed Elixir/Mix toolchain for development-only checks after cloud-init
finishes.

## Deploy Benchmark CLI

Build the Linux/ARM64 release artifact locally with Docker:

```bash
just bench-transport-build-release
```

After Terraform apply and cloud-init readiness checks, deploy the release to
the Terraform `client` and `server` roles:

```bash
just bench-transport-deploy
```

The deploy step only resolves already-provisioned Terraform outputs,
copies/extracts the release, and runs `moqx-transport-bench help` remotely.
It does not provision infrastructure and does not start benchmark traffic.
Client and server deploys run as separate parallel units; the top-level recipe
fails if either role fails.

## Result Metadata

The outputs include `path_metadata_public` and `path_metadata_private` values
that match the benchmark contract shape in `bench/transport/README.md`. Scripts
should merge those values with the live host inventory they collect at run time.
