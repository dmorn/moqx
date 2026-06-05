# Add reference QUIC benchmark scripts

Status: closed
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
- [x] Measurements include handshake latency, first-byte latency, stream throughput, datagram behavior where available, latency percentiles, resource usage, and stall/backpressure indicators.
- [x] Scripts can run stream pressure, datagram pressure, and mixed control-plus-object patterns defined by issue 08.
- [x] Scripts document how to start any required external reference process.
- [x] Output follows the shared benchmark metadata/result schema defined by issue 08 and is comparable with the MOQX self-pair calibration benchmark.
- [x] Any protocol mismatch or unsupported feature in the selected reference implementation is documented.

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
  alongside the runtime benchmark CLI so measure smokes can run on
  controlled Hetzner paths without rebuilding or cloning the repo on targets.

Measure command contract, first pass:

- Extend `tools/quicprobe` from an echo probe into a reference pressure peer.
  It should keep `server` and `client` modes, but add structured JSON output
  for measured client runs and server support for stream sink/echo, optional
  unidirectional streams, and later datagrams.
- Keep canonical benchmark JSONL in the Elixir benchmark project. `quicprobe`
  may emit reference-run JSON, but `moqx-transport-bench` is responsible for
  converting measured runs into `transport-bench-v1` records.
- Add one runtime command family under `moqx-transport-bench`, tentatively
  `measure`, with an explicit `--topology`:
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

Move this issue out of `needs-triage` once the `measure` CLI
shape is committed with the first local loopback reference-to-reference record.

## Comments

- 2026-05-20: Hetzner ARM smoke `20260520T134420Z-smoke` proved the
  operator path for public IPv4: Terraform apply, cloud-init readiness, Docker
  release deploy, remote `moqx-transport-bench help`, public `iperf3-baseline`
  JSONL capture, report validation, destroy, empty Terraform state, and empty
  provider label query all succeeded. Before implementing this issue, address
  or consciously scope around follow-ups 24 and 25: failed path attempts should
  not hang indefinitely, and private-network readiness needs a deterministic
  answer if measurement runs are expected to use private paths.
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
  infrastructure decision before measure runs is #25: either make
  Hetzner private-network readiness deterministic or scope #12 explicitly to
  public IPv4 paths for the first implementation.
- 2026-05-21: Follow-up #25 is closed: Hetzner private-network readiness is now
  an explicit operator step with static guest netplan config and
  `just bench-transport-private-check`, validated by smoke
  `20260521T093427Z-private-smoke`. #12 can now design measure
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
  `moqx-transport-bench measure` and Mix wrapper
  `mix moqx.transport.measure` now support the
  `reference-client-to-reference-server` topology. The command requires an
  explicit `--quicprobe-command`, caller-provided `--server` and `--ca`, and
  does not start the reference server implicitly. It converts `quicprobe-v1`
  client output into one `transport-bench-v1` JSONL `step_summary`. Local
  smoke `reference-smoke` used a temporary quicprobe binary against
  `127.0.0.1:4434`, produced 2048 bytes sent/received, and passed
  `mix moqx.transport.report /private/tmp/moqx-measure-smoke.jsonl
  --strict` with only the expected loopback-calibration warning.
- 2026-05-21: Added the `moqx-client-to-reference-server` topology to
  `moqx-transport-bench measure`. It uses
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
  measure records passed report validation: quicprobe client to
  quicprobe server reported 17.849 ms handshake latency, 4.419 ms first byte,
  and 4.32 Mbps goodput; MOQX client to quicprobe server reported 41.265 ms
  handshake latency, 7.417 ms first byte, and 2.59 Mbps goodput. Result
  artifacts are under
  `bench/transport/results/20260521T133654Z-smoke/`. Infrastructure was
  destroyed and `just bench-transport-verify-clean` confirmed no Terraform
  state entries or labelled Hetzner resources remain. These are smoke records,
  not capacity claims.
- 2026-05-21: Redesigned the MOQX-client measure stream pressure
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
  `measure --topology reference-client-to-moqx-listener` from the
  client side with caller-provided endpoint, CA, SNI, and path metadata. The
  listener receives stream payloads through `MOQX.Transport.recv_stream/3`,
  echoes with async `MOQX.Transport.send_stream/4`, waits for local send
  completions, and waits for the peer close before closing locally. Local
  loopback smoke `local-reference-client-listener-smoke` passed with 3
  bidirectional streams, 2 payloads per stream, 1536 bytes sent and echoed,
  `server_implementation=moqx`, `stream_scheduling=concurrent`, and no break
  symptom. This remains loopback calibration only, not real network evidence.
- 2026-05-21: Added the burst-mode `datagram_pressure` workload to #12
  measure tooling. `tools/quicprobe` now enables QUIC DATAGRAM and
  echoes datagrams from the reference server; `measure
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
- 2026-05-21: Disposable Hetzner datagram smoke passed for run
  `20260521T155945Z-datagram-smoke` on the `arm-smoke` profile: `cax21`
  client in `fsn1`, `cax21` server in `nbg1`, private path
  `10.88.0.11 -> 10.88.0.12`, MTU 1450. `just
  bench-transport-private-check` proved ICMP and TCP readiness with 0% ping
  loss and ~3.8 ms average RTT. Both `moqx-transport-bench` and `quicprobe`
  Linux/ARM64 artifacts for git `17c4774` deployed and smoke-checked on both
  nodes. A tiny canonical `iperf3-baseline` record on the private path reported
  5.27 Gbps TCP goodput and a 10 Mbps UDP step with 100% delivery. Three
  burst-mode `datagram_pressure` measure records passed strict
  report validation with 100 datagrams of 64 bytes, 6,400 bytes sent and
  received, 100% delivery, zero drops, and no break symptom:
  reference-client-to-reference-server, MOQX-client-to-reference-server, and
  reference-client-to-MOQX-listener. Result artifacts are under
  `bench/transport/results/20260521T155945Z-datagram-smoke/`. Infrastructure
  was destroyed and `just bench-transport-verify-clean` confirmed no Terraform
  state entries or labelled Hetzner resources remain. These are smoke records,
  not capacity claims.
- 2026-05-22: Follow-up from inspecting the datagram-smoke reports: the human
  report table now displays `datagram_pressure` for measure
  datagram records instead of only `measurement`, and MOQX-originated
  datagram probe timestamps now encode signed monotonic timestamps correctly.
  The old `20260521T155945Z-datagram-smoke` MOQX-client-to-reference-server
  artifact has invalid negative datagram latency percentiles, but its
  delivery, byte-count, drop-count, handshake, and first-byte fields remain
  useful smoke evidence. A local loopback MOQX-client datagram smoke after the
  fix produced positive latency percentiles and a strict report with
  `step=datagram_pressure`.
- 2026-05-22: Added the first fixed-rate datagram pressure primitive. The
  measure CLI now accepts `--datagram-rate`,
  `--duration-seconds`, and `--delivery-threshold`; paced mode offers
  `rate * duration` datagrams and records target offered rate separately from
  actual send and delivered rates. The reference client and MOQX-client paths
  now receive datagram echoes while sending paced traffic so latency
  percentiles do not include artificial post-send queueing. Local loopback
  smokes at 10 datagrams/sec for 1 second passed for all three topologies with
  100% delivery and sub-millisecond p50 latency; these remain calibration
  checks, not real-network capacity claims.
- 2026-05-22: Hetzner paced-datagram smoke
  `20260522T104552Z-paced-datagram-smoke` used a disposable `x86-control`
  fallback after both `arm-smoke` and `arm-default` failed Hetzner placement.
  The actual path was `ccx23` fsn1 -> hel1 over the private network
  `10.88.0.11 -> 10.88.0.12`. Private ICMP was healthy with 0% loss and
  roughly 26.8 ms average RTT. `iperf3` on the private path reported roughly
  1.15 Gbps TCP with 0 retransmits, and 100 Mbps UDP with 0% loss and about
  0.011 ms jitter. The Linux/amd64 Elixir release build failed under Docker
  cross-architecture emulation on the Apple ARM workstation, so the smoke
  captured raw `quicprobe-v1` evidence rather than canonical
  `transport-bench-v1` wrapper records. The important finding was tool-side:
  the current `quicprobe` paced sender was the first bottleneck, not the
  network. At 64-byte datagrams, target 100/500/1000 pps delivered 100% but
  actually sent about 94/436/804 pps. At target 2000/5000/10000 pps, actual
  send rates were about 916/1236/2148 pps and runs became timeout-dominated
  with delivery ratios 91.4%/49.3%/42.9%. Artifacts are under
  `bench/transport/results/20260522T104552Z-paced-datagram-smoke/`.
  Infrastructure was destroyed and `just bench-transport-verify-clean`
  confirmed no Terraform state entries or labelled Hetzner resources remain.
- 2026-05-22: `quicprobe` paced datagram sender now uses absolute-deadline
  pacing and reports `offered_rate_ratio`, `offered_rate_tolerance`, and
  `offered_rate_valid`. The benchmark wrapper passes the tolerance through and
  marks paced datagram records with missed offered-rate targets as
  `tool_output_invalid` instead of treating them as network delivery loss.
  Local loopback smokes after the fix held the target rate at 1000 pps for 2
  seconds (`offered_rate_ratio` about 1.0005) and 10000 pps for 2 seconds
  (`offered_rate_ratio` about 1.0000), both with 100% delivery. These are still
  calibration checks; the Hetzner rate sweep needs to be rerun before making
  real-network capacity claims.
- 2026-05-22: attempted a follow-up ARM Hetzner run
  `20260522T115741Z-arm-pacing-smoke` after the pacing fix. All ARM profiles
  failed provider placement before benchmark traffic could run:
  `arm-smoke` (`cax21`, fsn1 -> nbg1) created the server but failed client
  placement, while `arm-default` (`cax31`, fsn1 -> hel1), `arm-stress`
  (`cax41`, fsn1 -> hel1), and `arm-low-rtt` (`cax31`, fsn1 -> nbg1) failed
  both node placements. Each partial state was destroyed, and
  `just bench-transport-verify-clean` confirmed no Terraform state entries or
  labelled Hetzner resources remain. No iperf3 or QUIC measurements were
  collected in this attempt.
- 2026-05-22: ARM private-path paced datagram run
  `20260522T125804Z-arm-remote-test` succeeded on `arm-smoke`: `cax21` client
  in `fsn1` (`91.99.116.201`, private `10.88.0.11`) to `cax21` server in
  `nbg1` (`188.245.79.185`, private `10.88.0.12`), MTU 1450. Private readiness
  passed with 0% ping loss and about 4.15 ms average RTT. Canonical iperf3
  baseline on the private path reported 5.39 Gbps TCP goodput and 100 Mbps UDP
  with 100% delivery. `moqx-transport-bench` and `quicprobe` ARM64 artifacts
  for git `951ee7c` deployed to both roles; client release deploy needed a
  manual artifact recopy after an interrupted deploy left a truncated tarball.
  Reference `quicprobe` client to reference `quicprobe` server paced 64-byte
  QUIC DATAGRAM results were contract-valid and offered-rate-valid at every
  step: 1k/5k/10k/20k pps delivered 100% with zero drops, p99 latency about
  4.08/4.45/4.96/4.51 ms. The first loss point observed was 30k pps with
  97.10% delivery and 8,701 drops; 40k pps delivered 95.52% with 17,903 drops;
  50k pps delivered 92.24% with 38,824 drops. Result artifacts are under
  `bench/transport/results/20260522T125804Z-arm-remote-test/`.
- 2026-05-22: ARM private-path near-MTU datagram run
  `20260522T133552Z-mtu-dgram` repeated the `arm-smoke` shape on the same
  private path (`cax21` fsn1 -> nbg1, private `10.88.0.11 -> 10.88.0.12`, MTU
  1450) using git `18134ab` artifacts. Private readiness passed with 0% ping
  loss and about 5.40 ms average RTT. The iperf3 baseline reported 5.04 Gbps
  TCP goodput and 100 Mbps UDP with 100% delivery at 1200-byte UDP datagrams.
  Reference `quicprobe` client to reference `quicprobe` server then ran
  1200-byte QUIC DATAGRAM paced steps at 5k/10k/20k/30k pps, corresponding to
  roughly 48/96/192/288 Mbps offered payload bandwidth. Offered-rate validation
  passed at each step. The 5k pps step delivered 100% with zero drops and p99
  latency about 3.61 ms. The first strict-threshold loss appeared at 10k pps:
  one dropped datagram out of 100k offered, displayed as 100.00% after
  rounding but marked `datagram_delivery_loss`. At 20k pps delivery was 99.70%
  with 608 drops and p99 about 5.90 ms; at 30k pps delivery was 99.18% with
  2,453 drops and p99 about 8.93 ms. Result artifacts are under
  `bench/transport/results/20260522T133552Z-mtu-dgram/`. Infrastructure was
  destroyed and `just bench-transport-verify-clean` confirmed no Terraform
  state entries or labelled Hetzner resources remain.
- 2026-05-22: Interpretation of the two ARM paced-datagram runs: the private
  path itself is not the first observed bottleneck. The same path sustained
  about 5 Gbps TCP and 100 Mbps raw UDP without loss, while QUIC DATAGRAM loss
  appeared much earlier in protocol-shaped runs. The 64-byte run found a
  packet-rate/process-pressure limit: 30k pps is only about 15.36 Mbps payload,
  yet that is where delivery loss became obvious. The 1200-byte run showed the
  useful-payload shape: 5k pps, about 48 Mbps payload, stayed clean; the first
  strict 100% delivery failure appeared around 10k pps, about 96 Mbps payload,
  with one drop in 100k offered; 20k and 30k pps continued to deliver
  99%+ while latency and drops grew. For #12, this means DATAGRAM completion
  should report several thresholds, not a single "break" number: first loss,
  99.9% delivery, 99% delivery, latency growth, and offered-rate validity.
- 2026-05-22: ARM private-path stream-pressure run
  `20260522T141346Z-strm` succeeded on `arm-smoke`: `cax21` client in `fsn1`
  to `cax21` server in `nbg1` over the private network
  `10.88.0.11 -> 10.88.0.12`, MTU 1450. Private readiness passed with 0%
  ping loss and about 3.8 ms average RTT. The iperf3 baseline reported 4.25
  Gbps TCP goodput and 100 Mbps UDP with 100% delivery. The 12 canonical
  stream-pressure records in `stream-combined.jsonl` passed strict contract
  validation, and infrastructure was destroyed with
  `just bench-transport-verify-clean` confirming no state entries or labelled
  Hetzner resources remain.
- 2026-05-22: Stream-pressure interpretation from `20260522T141346Z-strm`:
  reference-client-to-reference-server showed the path/reference baseline
  scaling from 107 Mbps with one bidirectional stream to 769 Mbps with 16
  streams, 843 Mbps with 64 streams, and 1.36 Gbps with 64 unidirectional
  streams. MOQX-client-to-reference-server reached only about 24.5 Mbps with
  one bidirectional stream and 25.0 Mbps with two, then timed out at four and
  eight bidirectional streams and crashed at 16/64 streams with a closed-echo
  `MatchError`; this is split to follow-up #29. The same MOQX client path did
  reach 852 Mbps with 64 unidirectional streams, so the failure is specific to
  concurrent bidirectional echo feedback rather than all stream sending.
  Reference-client-to-MOQX-listener stayed correct but plateaued around 185
  Mbps at 16/64 bidirectional streams while p99 latency grew from about 787 ms
  to 3.27 s; 64 unidirectional streams reached only 290 Mbps with about 2.09 s
  p99 latency. Treat the current MOQX listener as correctness evidence, not a
  performance ceiling for a future optimized listener.
- 2026-05-26: #29 remote rerun filled the missing MOQX-client bidirectional
  correctness evidence after the active-event fix. Run
  `20260526T075945Z-issue-29-bidi` used same-region disposable ARM nodes
  (`cax21`, `nbg1 -> nbg1`) over the private network
  `10.88.0.11 -> 10.88.0.12`, after `fsn1` and `hel1` ARM placements were
  repeatedly unavailable. Manual private readiness passed with 0% ping loss and
  about 1.45 ms average RTT. The structured iperf3 baseline reported 6.85 Gbps
  TCP goodput; UDP steps showed 100 Mbps at 100% delivery, 500 Mbps at 99.96%
  delivery, and 1 Gbps at 99.63% delivery.
- 2026-05-26: The same run produced strict-valid
  `transport-bench-v1` stream-pressure records for
  `reference-client-to-reference-server` and
  `moqx-client-to-reference-server` at 4/8/16 bidirectional streams with 1200
  byte payloads and 1000 payloads per stream. The reference control delivered
  4.8/9.6/19.2 MB at about 541/844/932 Mbps with p99 latency about
  70/91/164 ms. The MOQX-client topology delivered the same byte counts with
  no timeout, no nonzero exit, and no break symptom, but only about
  78.6/69.7/60.8 Mbps with p99 latency about 487 ms/1.10 s/2.52 s. This
  closes the #29 correctness gap for #12, while preserving a separate
  performance question: the MOQX client is now correct under concurrent
  bidirectional echo pressure, but much slower than the reference peer on the
  same path. Artifacts are under
  `bench/transport/results/20260526T075945Z-issue-29-bidi/`:
  `path_metadata_private.json`, `iperf3-baseline-private.jsonl`, and
  `measure-stream-private.jsonl`. The preserved server still
  reported a cloud-init status error from Hetzner network-config schema
  handling, so this round used manual toolchain and private-route readiness
  checks. Infrastructure was still intentionally running at the time this note
  was written.
- 2026-05-26: The same preserved ARM pair was used for the #12 paced
  DATAGRAM matrix on the same-region private path. The reference peer stayed
  clean at all requested steps: 64-byte DATAGRAMs at 1k/5k/10k/20k/30k pps
  delivered 100% with zero drops, and 1200-byte DATAGRAMs at 5k/10k/20k pps
  delivered 100% with zero drops. This confirms the path/reference ceiling for
  this same-region run was at least 30k pps for small DATAGRAMs and about
  192 Mbps payload goodput for 1200-byte DATAGRAMs.
- 2026-05-26: MOQX-involved DATAGRAM evidence is now split by payload-size
  behavior. With 64-byte DATAGRAMs, MOQX-client-to-reference-server delivered
  100% at 1k/5k/10k pps, then showed first loss at 20k pps with 52 drops
  out of 200k offered and 99.974% delivery; 30k pps delivered 99.599% with
  1203 drops. Reference-client-to-MOQX-listener, rerun with one isolated UDP
  port per step, delivered 100% at 1k/5k/10k pps, then failed/degraded at
  20k/30k pps. The initial listener sweep without isolated ports is retained
  as an orchestration artifact: a lossy `moqx-listener` step can keep waiting
  for the exact expected datagram count and contaminate the next step by
  holding the port.
- 2026-05-26: 1200-byte DATAGRAMs are not a valid MOQX/quicer measurement with
  the current transport path. Reference-to-reference handles them, but both
  MOQX-client sends and MOQX-listener echoes hit
  `{:dgram_send_error, :invalid_parameter}`. A focused size probe found 1192
  bytes is accepted with 100% delivery, while 1193, 1194, 1195, 1196, and
  1200 bytes fail immediately on the MOQX send path. Follow-up #30 tracks
  clean error handling, preserving configured size metadata in failure
  records, and documenting or exposing the negotiated/max DATAGRAM payload
  size.
- 2026-05-26: The usable near-limit comparison for this run is therefore
  1192-byte DATAGRAMs. Reference-client-to-reference-server delivered
  5k/10k/20k pps at 100% delivery, about 47.7/95.4/190.7 Mbps payload
  goodput. MOQX-client-to-reference-server matched reference at 5k and 10k
  pps with 100% delivery, then first lost at 20k pps with 147 drops and
  99.9265% delivery. Reference-client-to-MOQX-listener delivered 5k pps at
  100%, then first lost at 10k pps with 5 drops and 99.995% delivery; 20k pps
  also delivered 99.995% with 10 drops. Strict report validation passed for all
  DATAGRAM JSONL artifacts.
- 2026-05-26: DATAGRAM artifacts for this round are under
  `bench/transport/results/20260526T075945Z-issue-29-bidi/`:
  `measure-datagram-client-private.jsonl`,
  `measure-datagram-listener-private.jsonl`,
  `measure-datagram-listener-private-isolated.jsonl`,
  `measure-datagram-size-probe-private.jsonl`,
  `measure-datagram-size-probe-boundary-private.jsonl`,
  `measure-datagram-1192-client-private.jsonl`, and
  `measure-datagram-1192-listener-private.jsonl`, plus listener
  logs for the failed/isolated runs.
- 2026-05-26: After artifact capture and issue updates, the disposable Hetzner
  infrastructure for `20260526T075945Z-issue-29-bidi` was destroyed.
  `just bench-transport-verify-clean` reported no Terraform state entries or
  labelled Hetzner resources remaining.
- 2026-05-26: Follow-up #30 is closed. `measure` now records
  MOQX DATAGRAM send failures explicitly as `datagram_send_error` instead of
  emitting a `MatchError`, and the README documents 1192 bytes as the current
  near-limit MOQX/quicer DATAGRAM payload until capability metadata exists.
- 2026-05-26: Added the first `mixed_moqt_shaped` measure
  workload. The workload is transport-shaped, not full MOQT session semantics:
  one low-rate bidirectional control stream plus object-like unidirectional
  streams. It is supported by `tools/quicprobe`,
  `moqx-client-to-reference-server`, and `reference-client-to-moqx-listener`.
  Loopback calibration passed for all three topologies using
  `/private/tmp/quicprobe-mixed` and fresh temporary loopback certificates:
  `mixed-loopback-reference`, `mixed-loopback-moqx-client`, and
  `mixed-loopback-listener`. During calibration the listener path exposed and
  fixed a mixed-control read-size deadlock: the listener must read control
  streams at `--control-payload-size` granularity because the reference client
  waits for each small control echo before sending the next control message.
- 2026-05-26: Controlled same-region ARM mixed MOQT-shaped smoke passed for
  run `20260526T135920Z-mixed-smoke` on `arm-nbg1-tiny`: `cax11` client and
  server in `nbg1` over the private network `10.88.0.11 -> 10.88.0.12`, MTU
  1450. The first `hel1` same-region attempt failed Hetzner placement; the
  successful `nbg1` run reused the same run id and partial-state retry model.
  The client reported a Hetzner/cloud-init `network-config-v1` schema status
  error, so the scripted `just bench-transport-private-check` failed, but
  manual readiness checks showed Go, Elixir, iperf3, private addresses, and
  peer routes were present on both nodes. Manual private ICMP had 0% loss, and
  a one-second TCP iperf sample reported about 6.37 Gbps.
- 2026-05-26: The canonical private-path `iperf3-baseline` for the same run
  reported 6.33 Gbps TCP goodput. Aggressive raw UDP steps at 1/3/6 Gbps
  reported delivery ratios of 95.30%/98.07%/97.54%, so they are useful as
  lossy-path evidence for this tiny same-region shape, not as a clean UDP
  ceiling. The mixed workload used 32 object-like unidirectional streams, 1000
  payloads per stream, 1200-byte payloads, plus one bidirectional control
  stream with 100 messages of 64 bytes at 20 messages/sec. All three mixed
  topology records passed report validation with no break symptom:
  reference-to-reference reached 62.04 Mbps, MOQX-client-to-reference reached
  59.68 Mbps, and reference-client-to-MOQX-listener reached 53.26 Mbps.
  MOQX-client diagnostics recorded `message_queue_len=32234` at the end of the
  run, which is a useful hint for the remaining observability/performance
  slice but was not classified as a break symptom by the current contract.
  Artifacts are under
  `bench/transport/results/20260526T135920Z-mixed-smoke/`. The release records
  say git `b23c93c` because the smoke artifact was built from the current dirty
  worktree before the mixed-workload changes were committed. Infrastructure
  was destroyed afterward, and `just bench-transport-verify-clean` reported no
  Terraform state entries or labelled Hetzner resources remaining.
- 2026-05-27: Receiver-side DATAGRAM evidence is now valid after the
  `moqx-listener --accept-timeout-seconds` split. ARM same-region run
  `20260527T080234Z-receiver-dgram-ramp` used `cax11` nodes in `nbg1` over
  private path `10.88.0.11 -> 10.88.0.12`. Raw iperf3 showed about
  33.10 Gbps TCP goodput and 1192-byte UDP delivery of 100% at 100 Mbps,
  99.626% at 250 Mbps, and 99.271% at 500 Mbps. The
  reference-client-to-MOQX-listener DATAGRAM path produced clean offered-rate
  records through 30k pps: 100% delivery at 5k/10k, 99.625% at 20k, and
  99.489% at 30k. At 35k/40k/50k the reference client only offered about
  87.5%/79.3%/63.3% of the requested rate against MOQX, so those records are
  not clean capacity measurements. The listener still received nearly all
  attempted datagrams with bounded mailbox peaks, which moves the remaining
  question to #31: explain why the reference client cannot sustain more than
  about 31k pps against the MOQX listener while it can sustain target offered
  rates against the quicprobe server. Infrastructure was destroyed afterward,
  and `just bench-transport-verify-clean` reported no Terraform state entries
  or labelled Hetzner resources remaining.

Closure notes:

- 2026-05-27: Closed #12 as the reference QUIC benchmark script/tooling
  contract. The selected reference implementation is `tools/quicprobe`; the
  canonical operator surface is `moqx-transport-bench measure`
  plus the explicit `moqx-transport-bench moqx-listener` peer command. The
  implemented topologies are reference-client-to-reference-server,
  MOQX-client-to-reference-server, and reference-client-to-MOQX-listener.
  Operators provide endpoints, certificates, path metadata, and peer process
  startup explicitly; the benchmark scripts do not provision infrastructure or
  hide server startup.
- 2026-05-27: The implemented workload set covers the issue-08 pressure
  shapes: stream pressure, DATAGRAM pressure in burst and paced modes, and the
  mixed MOQT-shaped control-plus-object workload. The records use
  `transport-bench-v1` JSONL, carry the same path/run/profile metadata as
  self-pair and iperf3 baselines, and expose handshake latency, first-byte
  latency where applicable, throughput/goodput, latency percentiles,
  offered-rate validity, DATAGRAM offered/accepted/delivered/drop counts, and
  current pressure indicators such as sender/receiver mailbox diagnostics,
  send-completion counts, listener echo-send timings, and quicprobe
  `SendDatagram` call timing.
- 2026-05-27: Known comparability limits are documented here and in the
  benchmark README. `moqx-listener` remains primarily a correctness peer unless
  #26 changes its serving model. MOQX/quicer DATAGRAM payloads currently have a
  near-limit of 1192 bytes in this harness path; 1193+ is handled as an
  explicit send failure after #30. Paced DATAGRAM records with
  `offered_rate_valid=false` are load-generator evidence, not receiver or
  network capacity evidence. #31 closed the specific high-rate
  reference-client-to-MOQX-listener ambiguity: above the clean 30k pps range,
  quic-go `SendDatagram` call cost in the reference client consumed the pacing
  budget, so those invalid 35k+ pps points are not MOQX listener capacity
  claims.
- 2026-05-27: Remaining work is intentionally moved out of #12. #26 owns the
  performance-hardening loop: deeper CPU/scheduler/flow-control/backpressure
  observability, stream-pressure optimization, DATAGRAM receive/drain cadence,
  mixed workload real-path reruns after the event-pump fix, and any decision to
  make `moqx-listener` a performance peer instead of a correctness peer.
  Cross-region repetitions are valuable for capacity research, but they are
  not required to close this script/tooling issue because the scripts already
  accept caller-provided same-region, cross-region, and edge-to-server paths.
