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
- [x] Cloud-init installs only base build tooling, `iperf3`, Go from the
      official Linux archive, and Erlang/Elixir from the official Elixir
      install script.
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
- Keep `mise` as a development-machine concern, not a disposable-server
  provisioning dependency.
- Install Go from the official Linux archive and Erlang/Elixir with the
  official Elixir install script. The server image defaults to Ubuntu 24.04.
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
- First live smoke, run `20260519-smoke`, using `profiles/arm-smoke.tfvars`
  with `cax21` endpoints in `fsn1` and `nbg1`:
  - cloud-init completed on both endpoints;
  - installed toolchain check passed for Go `1.26.3`, Erlang/OTP `28`,
    Elixir `1.19.5`, and `iperf3` `3.16`;
  - private-path `iperf3` baseline emitted three JSONL records under
    `bench/transport/results/20260519-smoke/iperf3-private.jsonl`;
  - Terraform drift was zero before destroy;
  - Terraform state was empty after destroy;
  - provider resources labelled `purpose=moqx-transport-bench` were verified
    absent after destroy.

## Comments
