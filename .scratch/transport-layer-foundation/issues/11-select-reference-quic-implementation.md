# Select reference QUIC implementation

Status: closed
Type: HITL

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Choose the first reference QUIC implementation and remote benchmark topology to use in transport benchmark comparisons.

The decision should optimize for useful real-path performance signal, local developer ergonomics, deployability on remote servers, and scriptability. Candidates discussed include `quic-go`, `ngtcp2`, `picoquic`, and `quiche`.

## Acceptance criteria

- [x] A reference QUIC implementation is selected for the first benchmark iteration.
- [x] The decision records why this implementation was selected over the other candidates.
- [x] Installation/setup requirements are documented.
- [x] Remote server topology requirements are documented, including same-region and cross-region server pairs.
- [x] The selected implementation can support configurable ALPN for protocol-like benchmark profiles.
- [x] The selected implementation can support a simple stream/datagram measurement protocol or a practical equivalent.
- [x] The selected implementation can run as both a remote server and remote client where needed for bidirectional path comparisons.
- [x] Any missing datagram, priority, or stats capability is documented.
- [x] Follow-up benchmark issues can assume this choice without reopening the decision.

## Blocked by

None - issue 08 is closed.

## Design decisions

- This is a human-in-the-loop decision because remote server availability, deployability, and operational ergonomics matter as much as library capability.
- The repo-owned `tools/quicprobe` path remains a strong candidate for the first reference implementation because it already uses quic-go and is scriptable, but #11 should still record the tradeoff explicitly.
- The benchmark topology should favor caller-provided servers over public relays. Public relays are interop probes, not controlled baselines.
- The first decision does not need to select a permanent reference implementation forever.

## Progress

Issue 08 is closed. The human-in-the-loop decision on the first reference implementation and remote benchmark topology is captured below.

## Resolution

Selected reference implementation: repo-owned `tools/quicprobe`.

`tools/quicprobe` is the first benchmark reference because it is already in this repo, is based on quic-go, is scriptable, supports server and client modes, supports configurable UDP address, certificate, key, CA, server name, and ALPN, and is already used by the Docker Compose integration harness. That makes it easier to extend for benchmark-specific pressure patterns than adopting a larger external application as the first reference.

Tradeoffs against other candidates:

- `quic-go` via `tools/quicprobe`: selected because it is already present, Go tooling is already part of the integration harness, and we control the benchmark protocol.
- `ngtcp2`: useful as a lower-level external reference later, but more operational surface for the first benchmark pass.
- `picoquic`: useful protocol research implementation later, but not the fastest path from current repo state.
- `quiche`: useful production-grade comparison later, but would add more setup and tool ownership before the benchmark contract has scripts.

Installation/setup requirements:

- Go toolchain capable of building `tools/quicprobe`.
- UDP ingress open for the selected benchmark port.
- Certificate and key files on the server side.
- CA certificate on the client side.
- Caller-provided host metadata matching `bench/transport/README.md`.
- No cloud/server provisioning is introduced in the repo for this decision.

Remote topology:

- Use caller-managed controlled servers, not public relays, for benchmark baselines.
- Minimum first topology is a two-host server pair.
- Run at least one `same_region_pair` path for low-RTT real network evidence.
- Run at least one `cross_region_pair` path for higher-RTT and bandwidth-delay-product behavior.
- Optional `edge_to_server` runs can capture asymmetric or real-user-path behavior.
- For each path, collect `iperf3` TCP/UDP baseline before comparing QUIC results.

Benchmark roles:

- Reference server mode: `tools/quicprobe server` runs on the remote server; MOQX or the reference client connects to it.
- Reference client mode: `tools/quicprobe client` runs from the sender side; it connects to a MOQX listener or another `tools/quicprobe server`.
- Reference-to-reference runs should be supported where practical so later scripts can separate path/tool limits from MOQX limits.

Current capability notes:

- `tools/quicprobe` currently supports configurable ALPN/certs and bidirectional stream echo, which is enough for the first practical reference and control-plane smoke path.
- Datagram pressure, stream pressure, sustained throughput, latency sampling, and mixed control-plus-object benchmark modes may require extending `tools/quicprobe` in follow-up benchmark issues.
- Stream priority, transport stats, and deeper QUIC implementation telemetry are not available through the current `tools/quicprobe` surface and should be recorded as unsupported or unknown until explicitly added.

Follow-up issues can assume `tools/quicprobe` as the first reference implementation and controlled caller-managed same-region/cross-region server pairs as the benchmark topology.

## Comments
