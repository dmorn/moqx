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
cd bench/transport/infra/hetzner
export HCLOUD_TOKEN=...
mkdir -p ../../.keys/20260519-a
ssh-keygen -t ed25519 -N '' -C moqx-transport-bench-20260519-a \
  -f ../../.keys/20260519-a/id_ed25519
terraform init
terraform apply \
  -var-file=profiles/arm-default.tfvars \
  -var='run_id=20260519-a' \
  -var='ssh_public_key_path=../../.keys/20260519-a/id_ed25519.pub'
terraform output
```

Check cloud-init and the installed tools before running benchmarks:

```bash
terraform output -json toolchain_check_commands
```

Destroy the pair when the run is finished:

```bash
terraform destroy \
  -var-file=profiles/arm-default.tfvars \
  -var='run_id=20260519-a' \
  -var='ssh_public_key_path=../../.keys/20260519-a/id_ed25519.pub'
```

Use a stable `run_id` when multiple pairs may exist at once:

```bash
terraform apply \
  -var-file=profiles/arm-default.tfvars \
  -var='run_id=20260519-a' \
  -var='ssh_public_key_path=../../.keys/20260519-a/id_ed25519.pub'
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
started automatically. Run `elixir`, `mix`, and `go` directly after cloud-init
finishes.

## Result Metadata

The outputs include `path_metadata_public` and `path_metadata_private` values
that match the benchmark contract shape in `bench/transport/README.md`. Scripts
should merge those values with the live host inventory they collect at run time.
