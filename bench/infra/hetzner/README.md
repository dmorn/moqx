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
| `profiles/arm-nbg1-hel1.tfvars` | `cax31` | `nbg1` to `hel1` | Alternate ARM EU path when `fsn1` ARM capacity is unavailable. |
| `profiles/arm-nbg1-hel1-stress.tfvars` | `cax41` | `nbg1` to `hel1` | Larger alternate ARM EU path when smaller ARM capacity is unavailable. |
| `profiles/arm-nbg1-hel1-tiny.tfvars` | `cax11` | `nbg1` to `hel1` | Smallest alternate ARM EU path for correctness smokes during regional capacity pressure. |
| `profiles/arm-nbg1-tiny.tfvars` | `cax11` | `nbg1` to `nbg1` | Smallest same-region ARM pair for correctness smokes. |
| `profiles/arm-hel1-tiny.tfvars` | `cax11` | `hel1` to `hel1` | Smallest same-region ARM pair for correctness smokes. |
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

When the private network is enabled, prove private-path readiness before using
private IPs for benchmarks:

```bash
just bench-transport-private-check
```

The check waits for cloud-init on both nodes, verifies that each node has a
route to its peer private IP, pings the server private IP from the client, and
runs a one-second `iperf3` TCP probe bound to the server private IP. Do not use
`path_metadata_private` for benchmark results until this check passes.

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

- writes a static netplan file for the first Hetzner private NIC when private
  networking is enabled;
- installs build tools, `iperf3`, and small shell utilities;
- installs Go from the official Linux archive at `go.dev/dl`;
- installs Erlang/OTP and Elixir with the official Elixir install script;
- writes a short note under `/opt/moqx-bench/`.

For the current CAX/CCX profiles, the first Hetzner private interface is
configured as `enp7s0` with the assigned private IP as `/32`, MTU 1450, and a
route to the private network CIDR via the network gateway. The Terraform
variable `private_network_interface` exists so a future profile can override
the guest interface name if needed.

The benchmark repo is not cloned automatically, and no benchmark process is
started automatically. Deploy a `moqxprobe` release artifact or use
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

Reference-comparison runs also need the repo-owned `bench/quicprobe` binary on
the benchmark nodes. Build the Linux target that matches the nodes and deploy it
separately:

```bash
just bench-transport-build-quicprobe linux_arm64
just bench-transport-deploy-quicprobe linux_arm64
```

The deploy step only resolves already-provisioned Terraform outputs,
copies/extracts the release, and runs `moqxprobe help` remotely.
It does not provision infrastructure and does not start benchmark traffic.
Client and server deploys run as separate parallel units; the top-level recipe
fails if either role fails.

The `quicprobe` deploy step follows the same role-based model and installs
under `/opt/moqx-bench/quicprobe/current/bin/quicprobe`. It verifies that the
binary starts, but it does not start a long-lived reference server.

## Result Metadata

The outputs include `path_metadata_public` and `path_metadata_private` values
that match the benchmark contract shape in `bench/moqxprobe/README.md`. Scripts
should merge those values with the live host inventory they collect at run time.
