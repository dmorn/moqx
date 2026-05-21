# Add reference QUIC benchmark scripts

Status: ready-for-agent
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

Reference-comparison command contract, first pass:

- Extend `tools/quicprobe` from an echo probe into a reference pressure peer.
  It should keep `server` and `client` modes, but add structured JSON output
  for measured client runs and server support for stream sink/echo, optional
  unidirectional streams, and later datagrams.
- Keep canonical benchmark JSONL in the Elixir benchmark project. `quicprobe`
  may emit reference-run JSON, but `moqx-transport-bench` is responsible for
  converting measured runs into `transport-bench-v1` records.
- Add one runtime command family under `moqx-transport-bench`, tentatively
  `reference-comparison`, with an explicit `--topology`:
  - `moqx-client-to-reference-server`;
  - `reference-client-to-moqx-listener`;
  - `reference-client-to-reference-server`.
- For real server paths, peer processes are explicit operator steps. The
  benchmark command should accept endpoints and path metadata; it should not
  provision infrastructure or hide server startup.
- Implement in this order:
  1. local loopback `reference-client-to-reference-server` using `quicprobe`
     JSON output;
  2. `moqx-client-to-reference-server` using `MOQX.Transport.Quicer`;
  3. `reference-client-to-moqx-listener` with a documented two-process remote
     shape;
  4. datagram pressure after stream-pressure records are stable.
- The first workload should be stream pressure, not mixed MOQT-shaped load.
  Mixed control-plus-object pressure should build on the same measurement
  primitives after the simple stream path is comparable.

Move this issue out of `needs-triage` once the `reference-comparison` CLI
shape is committed with the first local loopback reference-to-reference record.

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
- 2026-05-21: Design/experiment pass:
  `tools/quicprobe` is currently a minimal quic-go bidi echo peer, not a
  benchmark tool. quic-go exposes bidirectional streams, unidirectional streams,
  and RFC 9221 datagrams through `Config.EnableDatagrams`, so it can be grown
  into the selected reference pressure peer. Existing interop smoke is good:
  `mix test test/integration/quicer_listener_contract_test.exs --include
  integration` proved reference client to `MOQX.Transport` listener, and
  `mix test test/integration/quicer_reference_server_contract_test.exs
  --include integration` proved `MOQX.Transport` client to reference server
  against the running Docker harness. A bounded `go test` for quicprobe also
  passed when local UDP bind was allowed. Sandbox-blocked UDP bind exposed one
  test-hardening follow-up: quicprobe tests should select on readiness and
  server error channels instead of waiting on readiness forever.
- 2026-05-21: First reference-tool implementation slice:
  `tools/quicprobe client --json` now emits `quicprobe-v1` JSON for measured
  stream-pressure runs, with handshake latency, first-byte latency where
  applicable, byte counts, goodput, and stream latency percentiles. The
  reference server now supports bidirectional echo streams and unidirectional
  stream drains; bidirectional echo uses bounded streaming rather than buffering
  the entire payload. This is deliberately still reference-tool output, not
  canonical `transport-bench-v1` JSONL; the next slice is a
  `moqx-transport-bench` command that runs or ingests this output and emits the
  shared benchmark schema. Local loopback smoke passed with two bidirectional
  streams, 256-byte payloads, four writes per stream, and 2048 bytes sent and
  received.
- 2026-05-21: First canonical wrapper slice:
  `moqx-transport-bench reference-comparison` and Mix wrapper
  `mix moqx.transport.reference_comparison` now support the
  `reference-client-to-reference-server` topology. The command requires an
  explicit `--quicprobe-command`, caller-provided `--server` and `--ca`, and
  does not start the reference server implicitly. It converts `quicprobe-v1`
  client output into one `transport-bench-v1` JSONL `step_summary`. Local
  smoke `reference-smoke` used a temporary quicprobe binary against
  `127.0.0.1:4434`, produced 2048 bytes sent/received, and passed
  `mix moqx.transport.report /private/tmp/moqx-reference-comparison-smoke.jsonl
  --strict` with only the expected loopback-calibration warning.

Remaining slices:

- `moqx-client-to-reference-server` using `MOQX.Transport.Quicer`.
- `reference-client-to-moqx-listener` with a documented two-process shape.
- Packaging/deploy story for the quicprobe executable alongside benchmark
  releases.
- Datagram pressure after stream-pressure records are stable.
