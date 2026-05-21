# Add reference QUIC benchmark scripts

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add benchmark scripts that compare `MOQX.Transport` against the selected reference QUIC implementation in both directions across caller-provided real server paths: our client to a reference server, and a reference client to our listener.

This isolates client-side and listener-side behavior while measuring raw transport characteristics and MOQT-shaped pressure patterns rather than full MOQT session semantics.

## Acceptance criteria

- [x] A script measures `MOQX.Transport` client behavior against the selected reference server.
- [x] A script measures selected reference client behavior against a `MOQX.Transport` listener.
- [x] Scripts accept caller-provided endpoints for same-region, cross-region, and edge-to-server paths.
- [ ] Measurements include handshake latency, first-byte latency, stream throughput, datagram behavior where available, latency percentiles, resource usage, and stall/backpressure indicators.
- [ ] Scripts can run stream pressure, datagram pressure, and mixed control-plus-object patterns defined by issue 08.
- [x] Scripts document how to start any required external reference process.
- [x] Output follows the shared benchmark metadata/result schema defined by issue 08 and is comparable with the MOQX self-pair calibration benchmark.
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
- The next useful dependency is packaging and deploying `tools/quicprobe`
  alongside the runtime benchmark CLI so reference-comparison smokes can run on
  controlled Hetzner paths without rebuilding or cloning the repo on targets.

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
- 2026-05-21: Added the `moqx-client-to-reference-server` topology to
  `moqx-transport-bench reference-comparison`. It uses
  `MOQX.Transport.Quicer` against an explicit `tools/quicprobe server`, emits
  canonical `transport-bench-v1` JSONL, records `quicer_version`, byte counts,
  handshake latency, first-byte latency, goodput, payload send rate, stream
  latency percentiles, and `stream_scheduling=sequential`. Local smoke
  `moqx-client-reference-smoke` against `127.0.0.1:4434` produced 2048 bytes
  sent/received and passed strict report validation with only the expected
  loopback-calibration warning.
- 2026-05-21: Async stream send contract landed in `b07f15b`. Post-commit
  loopback self-pair smoke confirmed the benchmark still runs and emits valid
  `transport-bench-v1` JSONL. A 4-stream, 1000-payload stream-pressure smoke
  reported 216.79 Mbps and 22.58k sends/s on loopback. A 1000-datagram smoke
  reported 100% delivery; a 5000-datagram burst intentionally found local
  datagram delivery loss, proving the harness still detects break symptoms.
  These are loopback calibration only, not real network evidence. The next
  operational blocker for #12 is deploying `tools/quicprobe` to the same
  controlled nodes as `moqx-transport-bench`.
- 2026-05-21: Added Docker packaging and `just` deploy recipes for
  `tools/quicprobe`. `just bench-transport-build-quicprobe` now builds the
  Linux/ARM64 reference peer artifact through `golang:1.23-bookworm`, runs
  `go test ./...` inside the build, and emits
  `bench/transport/build/artifacts/quicprobe-<git>-linux-arm64.tar.gz`.
  `just bench-transport-deploy-quicprobe` deploys the artifact to each
  Terraform role under `/opt/moqx-bench/quicprobe` and smoke-checks that the
  binary starts. The remaining #12 blocker is exercising this on disposable
  Hetzner nodes, then adding the reference-client-to-MOQX-listener command.
- 2026-05-21: Disposable Hetzner smoke passed for run
  `20260521T133654Z-smoke` on the `arm-smoke` profile: `cax21` client in
  `fsn1`, `cax21` server in `nbg1`, private path
  `10.88.0.11 -> 10.88.0.12`, MTU 1450. `just
  bench-transport-private-check` proved ICMP and TCP readiness with 0% ping
  loss and ~3.6 ms average RTT. Both `moqx-transport-bench` and `quicprobe`
  Linux/ARM64 artifacts for git `ae52d74` deployed and smoke-checked on both
  nodes. A tiny canonical `iperf3-baseline` record on the private path reported
  5.18 Gbps TCP goodput and a 10 Mbps UDP step with 100% delivery. Two tiny
  reference-comparison records passed report validation: quicprobe client to
  quicprobe server reported 17.849 ms handshake latency, 4.419 ms first byte,
  and 4.32 Mbps goodput; MOQX client to quicprobe server reported 41.265 ms
  handshake latency, 7.417 ms first byte, and 2.59 Mbps goodput. Result
  artifacts are under
  `bench/transport/results/20260521T133654Z-smoke/`. Infrastructure was
  destroyed and `just bench-transport-verify-clean` confirmed no Terraform
  state entries or labelled Hetzner resources remain. These are smoke records,
  not capacity claims.
- 2026-05-21: Redesigned the MOQX-client reference-comparison stream pressure
  loop to open all requested streams first, schedule payload rounds across all
  streams, and attach FIN to each final payload with `send_stream(..., finish:
  true)`. The topology now records `stream_scheduling=concurrent`. This keeps
  send admission asynchronous and lets multiple stream sends remain outstanding;
  bidirectional runs still use echoed bytes as the application-level delivery
  feedback. Docker-backed loopback smoke against `quicprobe server` passed with
  3 streams, 2 payloads per stream, 1536 bytes sent and echoed,
  `stream_scheduling=concurrent`, and no break symptom.
- 2026-05-21: Added the `reference-client-to-moqx-listener` topology and the
  explicit `moqx-transport-bench moqx-listener` peer command. Operators start
  the MOQX listener on the server endpoint, then run
  `reference-comparison --topology reference-client-to-moqx-listener` from the
  client side with caller-provided endpoint, CA, SNI, and path metadata. The
  listener receives stream payloads through `MOQX.Transport.recv_stream/3`,
  echoes with async `MOQX.Transport.send_stream/4`, waits for local send
  completions, and waits for the peer close before closing locally. Local
  loopback smoke `local-reference-client-listener-smoke` passed with 3
  bidirectional streams, 2 payloads per stream, 1536 bytes sent and echoed,
  `server_implementation=moqx`, `stream_scheduling=concurrent`, and no break
  symptom. This remains loopback calibration only, not real network evidence.
- 2026-05-21: Added the burst-mode `datagram_pressure` workload to #12
  reference-comparison tooling. `tools/quicprobe` now enables QUIC DATAGRAM and
  echoes datagrams from the reference server; `reference-comparison
  --workload datagram_pressure` emits canonical `transport-bench-v1` records
  for `reference-client-to-reference-server`,
  `moqx-client-to-reference-server`, and `reference-client-to-moqx-listener`.
  `moqx-transport-bench moqx-listener` can serve datagram echo runs when
  started with the same workload and expected datagram count. Datagram records
  distinguish offered, locally accepted, and echoed datagrams, and map delivery
  loss to `datagram_delivery_loss` rather than a protocol error. Local loopback
  smokes for all three topologies used 4 datagrams of 64 bytes, reported 256
  bytes sent and received, 100% delivery, zero drops, and no break symptom.
  These are loopback calibration only, not real network evidence; rate-stepped
  datagram ramps and mixed control-plus-object pressure remain future slices.

Remaining slices:

- Mixed control-plus-object pressure after stream and datagram records are stable.
- Resource usage, mailbox pressure, and backpressure indicators for higher-rate
  controlled-path runs.
