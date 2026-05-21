# Add reference QUIC benchmark scripts

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add benchmark scripts that compare `MOQX.Transport` against the selected reference QUIC implementation in both directions across caller-provided real server paths: our client to a reference server, and a reference client to our listener.

This isolates client-side and listener-side behavior while measuring raw transport characteristics and MOQT-shaped pressure patterns rather than full MOQT session semantics.

## Acceptance criteria

- [ ] A script measures `MOQX.Transport` client behavior against the selected reference server.
- [ ] A script measures selected reference client behavior against a `MOQX.Transport` listener.
- [ ] Scripts accept caller-provided endpoints for same-region, cross-region, and edge-to-server paths.
- [ ] Measurements include handshake latency, first-byte latency, stream throughput, datagram behavior where available, latency percentiles, resource usage, and stall/backpressure indicators.
- [ ] Scripts can run stream pressure, datagram pressure, and mixed control-plus-object patterns defined by issue 08.
- [ ] Scripts document how to start any required external reference process.
- [ ] Output follows the shared benchmark metadata/result schema defined by issue 08 and is comparable with the MOQX self-pair calibration benchmark.
- [ ] Any protocol mismatch or unsupported feature in the selected reference implementation is documented.

## Blocked by

None - issues 10 and 23 are closed.

## Design decisions

- Real server paths are the primary evidence for these scripts.
- Reference-to-reference runs should be supported where practical so MOQX behavior can be compared against the same path without the BEAM in the loop.
- Full MOQT session semantics remain out of scope; mixed load should be transport-level control trickle plus object-like stream/datagram pressure.
- Public relays may be used separately as interop probes, but their results should not be mixed with controlled benchmark baselines.

## Progress

Issue 08, issue 10, issue 11, and issue 23 are closed, so this issue is no
longer structurally blocked.

Current status:

- The selected reference implementation path is `tools/quicprobe`.
- The canonical operator surface should be runtime
  `moqx-transport-bench` commands, not standalone `.exs` scripts.
- The first implementation pass should define explicit command contracts for:
  - `moqx` client to reference server;
  - reference client to `moqx` listener;
  - reference client to reference server where practical.
- Output must remain `transport-bench-v1` JSONL and comparable with
  `self-pair` and `iperf3-baseline`.
- The next useful dependency is an end-to-end Hetzner smoke that proves
  provisioning, release deploy, remote command execution, result capture, and
  teardown work before reference-comparison commands are added.

Keep this issue at `needs-triage` until the runtime command shape is designed
from that smoke-test experience.

## Comments

- 2026-05-20: Hetzner ARM smoke `20260520T134420Z-smoke` proved the
  operator path for public IPv4: Terraform apply, cloud-init readiness, Docker
  release deploy, remote `moqx-transport-bench help`, public `iperf3-baseline`
  JSONL capture, report validation, destroy, empty Terraform state, and empty
  provider label query all succeeded. Before implementing this issue, address
  or consciously scope around follow-ups 24 and 25: failed path attempts should
  not hang indefinitely, and private-network readiness needs a deterministic
  answer if reference comparisons are expected to use private paths.
- 2026-05-21: Hetzner ARM smoke `20260521T070013Z-smoke` re-proved the
  operator path after replacing Make with `just`: fresh run key, Terraform
  plan/apply, cloud-init readiness, Docker release build, parallel role deploy,
  remote CLI smoke, public IPv4 `iperf3-baseline`, JSONL/report capture,
  destroy, and `just bench-transport-verify-clean` all succeeded. The public
  path reported TCP 5.18 Gbps and UDP 10/50/100 Mbps with 100% delivery. The
  smoke also exposed two benchmark CLI contract bugs fixed in `f605b99`:
  `--path-json` now accepts inline JSON as documented, and release records now
  embed the Docker build git SHA.
- 2026-05-21: Follow-up #24 is closed: bad `iperf3-baseline` paths now produce
  bounded timeout JSONL instead of hanging indefinitely. The remaining
  infrastructure decision before reference-comparison runs is #25: either make
  Hetzner private-network readiness deterministic or scope #12 explicitly to
  public IPv4 paths for the first implementation.
- 2026-05-21: Follow-up #25 is closed: Hetzner private-network readiness is now
  an explicit operator step with static guest netplan config and
  `just bench-transport-private-check`, validated by smoke
  `20260521T093427Z-private-smoke`. #12 can now design reference-comparison
  runtime command contracts against both public IPv4 and private-network paths.
