# Hetzner Transport Benchmark Infrastructure

This Terraform root module creates two short-lived Hetzner Cloud servers for
controlled transport benchmark runs. It does not start benchmark traffic.

## Requirements

- Terraform.
- A Hetzner Cloud API token in `HCLOUD_TOKEN`.
- A local SSH public key readable by Terraform. The default is
  `~/.ssh/id_ed25519.pub`.

## Profiles

Use profile files to choose the server type and locations:

| Profile | Type | Locations | Use |
| --- | --- | --- | --- |
| `profiles/arm-smoke.tfvars` | `cax21` | `fsn1` to `hel1` | Provisioning and build smoke. |
| `profiles/arm-default.tfvars` | `cax31` | `fsn1` to `hel1` | Default ARM benchmark pair. |
| `profiles/arm-stress.tfvars` | `cax41` | `fsn1` to `hel1` | Larger shared-ARM stress pair. |
| `profiles/arm-low-rtt.tfvars` | `cax31` | `fsn1` to `nbg1` | Lower-RTT EU path. |
| `profiles/x86-control.tfvars` | `ccx23` | `fsn1` to `hel1` | Dedicated x86 control pair. |

## Usage

```bash
cd bench/transport/infra/hetzner
export HCLOUD_TOKEN=...
terraform init
terraform apply -var-file=profiles/arm-default.tfvars
terraform output
```

Check cloud-init and the installed tools before running benchmarks:

```bash
terraform output -json toolchain_check_commands
```

Destroy the pair when the run is finished:

```bash
terraform destroy -var-file=profiles/arm-default.tfvars
```

Use a stable `run_id` when multiple pairs may exist at once:

```bash
terraform apply \
  -var-file=profiles/arm-default.tfvars \
  -var='run_id=20260519-a'
```

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

- installs build tools and `iperf3`;
- installs `mise` at `/usr/local/bin/mise`;
- installs the pinned Go, Erlang, and Elixir versions;
- writes a short note under `/opt/moqx-bench/`.

The benchmark repo is not cloned automatically, and no benchmark process is
started automatically. Run `elixir`, `mix`, and `go` directly after cloud-init
finishes, or use `mise exec -- ...` for explicit tool selection.

## Result Metadata

The outputs include `path_metadata_public` and `path_metadata_private` values
that match the benchmark contract shape in `bench/transport/README.md`. Scripts
should merge those values with the live host inventory they collect at run time.
