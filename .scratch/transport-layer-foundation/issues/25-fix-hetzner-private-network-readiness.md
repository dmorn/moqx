# Fix Hetzner private-network readiness

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Make Hetzner private-network paths deterministic for benchmark runs, or narrow
the documented smoke path to public IPv4 until private paths are explicitly
supported.

During the Hetzner smoke run `20260520T134420Z-smoke`, Terraform attached both
servers to the private network and emitted private path metadata, but the
server private interface was down:

- client: `enp7s0 UP 10.88.0.11/32`
- server: `enp7s0 DOWN`
- client ping to `10.88.0.12`: 100% packet loss

The public IPv4 path worked and produced valid benchmark JSONL.

## Acceptance criteria

- [ ] After `terraform apply`, both nodes expose their configured private IPs
      on an UP interface.
- [ ] A smoke check proves client-to-server ICMP and TCP connectivity over the
      private IPs before benchmark traffic starts.
- [ ] The Hetzner README documents the private-path readiness check.
- [ ] If explicit OS network configuration is needed, it is handled by
      Terraform/cloud-init without making cloud-init large or fragile.
- [ ] If private paths are intentionally deferred, the README and outputs make
      that limitation clear.

## Blocked by

None.

## Comments

- 2026-05-20: Created from Hetzner smoke `20260520T134420Z-smoke`. Public IPv4
  benchmark traffic is usable; private-network benchmark traffic is not yet a
  reliable operator path.
