# Add Hetzner ephemeral benchmark infrastructure

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a repo-owned Terraform setup for short-lived Hetzner Cloud server pairs so
transport benchmark scripts can run against controlled non-production hosts.

The setup must be explicit infrastructure, not something benchmark scripts start
implicitly. The caller chooses a profile, applies Terraform, waits for
cloud-init, runs benchmark scripts against the returned endpoints, and destroys
the resources when finished.

## Acceptance criteria

- [x] A Terraform root module exists under `bench/transport/infra/hetzner/`.
- [x] The module creates exactly two benchmark endpoint servers.
- [x] Profile `.tfvars` files cover ARM smoke, ARM default, ARM stress,
      low-RTT ARM, and x86 dedicated-control variants.
- [x] The default operator CIDR is `95.254.174.121/32`.
- [x] The operator CIDR can contact all TCP ports, all UDP ports, and ICMP on
      both servers.
- [x] Benchmark peers can contact each other over public IPv4.
- [x] The module can create a private network for private-path comparison.
- [x] Inbound traffic from other public sources is denied.
- [x] Cloud-init installs only base build tooling, `iperf3`, `mise`, Go,
      Erlang, and Elixir.
- [x] Cloud-init does not clone the repo or start benchmark traffic.
- [x] Terraform outputs include SSH commands and benchmark path metadata.
- [x] Documentation explains apply, readiness check, and destroy flow.

## Blocked by

None.

## Design decisions

- Use Hetzner Cloud for the first non-production controlled server topology.
- Use CAX ARM profiles by default because they are cheap and sufficient for
  path experiments; keep a CCX x86 dedicated-control profile for comparison.
- Keep one Terraform module and multiple profile `.tfvars` files rather than
  copying infrastructure configurations.
- Keep cloud-init short to reduce provisioning rabbit holes.
- Install toolchain versions through `mise`, matching the repo-pinned
  Elixir/Erlang/Go versions.
- Allow the operator CIDR to all ports so edge-to-server client tests from the
  operator machine do not require repeated firewall edits.
- Keep provisioning separate from benchmark scripts. Scripts must still accept
  caller-provided endpoints.

## Resolution

Implemented by:

- `bench/transport/infra/hetzner/`
- `bench/transport/infra/hetzner/profiles/*.tfvars`
- `bench/transport/infra/hetzner/README.md`

The benchmark contract and PRD/ADR were updated to allow short-lived,
caller-operated benchmark infrastructure while keeping production deployment
automation and script-driven cloud lifecycle out of scope.

Validation:

- `terraform fmt -check -recursive bench/transport/infra/hetzner`
- `terraform init -backend=false`
- `terraform validate`

## Comments
