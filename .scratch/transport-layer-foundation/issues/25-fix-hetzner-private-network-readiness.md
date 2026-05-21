# Fix Hetzner private-network readiness

Status: closed
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

- [x] After `terraform apply`, both nodes expose their configured private IPs
      on an UP interface.
- [x] A smoke check proves client-to-server ICMP and TCP connectivity over the
      private IPs before benchmark traffic starts.
- [x] The Hetzner README documents the private-path readiness check.
- [x] If explicit OS network configuration is needed, it is handled by
      Terraform/cloud-init without making cloud-init large or fragile.
- [x] If private paths are intentionally deferred, the README and outputs make
      that limitation clear. Not applicable: private paths are supported after
      the readiness check passes.

## Blocked by

None.

## Resolution

Implemented private-network readiness as a first-class Hetzner operator step:

- Cloud-init writes a small static netplan file for the first Hetzner private
  NIC when private networking is enabled.
- The private NIC defaults to `enp7s0`, uses the Terraform-assigned private IP
  as `/32`, MTU 1450, and routes the private network CIDR via the subnet
  gateway.
- Cloud-init stops and masks `hc-net-ifup@enp7s0.service`, flushes any early
  global address on the private NIC, then applies netplan.
- `just bench-transport-private-check` waits for cloud-init on both nodes,
  confirms peer routes, pings the server private IP from the client, and runs a
  one-second TCP `iperf3` probe over the private IP.
- Terraform outputs now include `private_network_check_command` so operators
  can discover the required readiness probe from the applied run.

## Comments

- 2026-05-20: Created from Hetzner smoke `20260520T134420Z-smoke`. Public IPv4
  benchmark traffic is usable; private-network benchmark traffic is not yet a
  reliable operator path.
- 2026-05-21: Implementation started. Direction: configure the first Hetzner
  private NIC explicitly in cloud-init using static netplan and add a
  `just bench-transport-private-check` readiness probe that proves peer route,
  ICMP, and TCP connectivity before private-path benchmarks.
- 2026-05-21: Closed after Hetzner ARM smoke
  `20260521T093427Z-private-smoke`. The client and server both exposed
  `enp7s0` as UP with `10.88.0.11/32` and `10.88.0.12/32`, respectively, and
  routes to the peer private IPs via `10.88.0.1`. The readiness check proved
  client-to-server ICMP with 3/3 packets delivered and TCP with
  `iperf3 --client 10.88.0.12 --port 55209 --time 1`. The Terraform pair was
  destroyed afterward, and `just bench-transport-verify-clean` confirmed no
  Terraform state entries or labelled Hetzner resources remained.
