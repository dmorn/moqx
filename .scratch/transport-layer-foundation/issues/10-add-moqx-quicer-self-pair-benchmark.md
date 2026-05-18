# Add MOQX quicer self-pair calibration benchmark

Status: ready-for-agent
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a benchmark script that runs a `MOQX.Transport.Quicer` client against a `MOQX.Transport.Quicer` listener using a tiny measurement protocol over QUIC streams and datagrams.

This establishes calibration data for the Elixir transport wrapper, `quicer`, and the BEAM without introducing MOQT protocol semantics. It is useful for understanding local overhead and harness behavior, but it must not be presented as evidence about real network path saturation.

## Acceptance criteria

- [ ] A standalone Elixir script can start a local listener and client using `MOQX.Transport.Quicer`.
- [ ] The script can run with protocol-like ALPN/capability profiles, at minimum draft-14-like and MOQ Lite-like modes.
- [ ] The script measures handshake latency and first-byte latency.
- [ ] The script measures stream throughput for configurable payload size and duration/count.
- [ ] The script measures datagram send/receive rate where datagrams are available.
- [ ] Output follows the shared benchmark metadata/result schema defined by issue 08.
- [ ] Documentation labels self-pair and loopback results as calibration only.
- [ ] The script does not require adding benchmark dependencies to the library dependency graph.

## Blocked by

None - issue 08 is closed.

## Design decisions

- Self-pair is still valuable because it estimates local BEAM/quicer overhead and validates benchmark machinery.
- Self-pair does not answer how much of a real network path `moqx` can fill.
- The benchmark should use the same output schema as real-path scripts so local overhead can be compared with server-pair results.
- Prior blockers for stream lifecycle, datagrams, capability surface, and issue 08 are closed.

## Progress

Issue 08 is closed, so this issue is ready for an agent to implement against the benchmark contract in `bench/transport/README.md`.

## Comments
