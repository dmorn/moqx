---
name: moqx-transport-bench
description: Run and evolve moqx transport benchmark workflows around bench/moqxprobe, Benchee client implementations, quicprobe targets, iperf3 preflights, and caller-side QUIC performance work in this repo.
---

# moqx Transport Bench

Use this for transport benchmark work in `/Users/dmorn/projects/moqx`.

## Sources

- `bench/README.md` for the active bench layout.
- `bench/moqxprobe/README.md` for the current Benchee loop and target flags.
- `bench/quicprobe/` for the Go reference peer.
- `agent-skills/exe-dev-vm-ops/OPS.md` when operating a persistent VM target.
- `.scratch/transport-layer-foundation/issues/49-simplify-transport-bench-loop-around-benchee-targets.md`
  for the current cleanup/refactor plan.
- `docs/adr/` and `.scratch/transport-layer-foundation/PRD.md` for decisions.

## Rules

- Treat fake, same-host, and loopback runs as calibration only.
- For real network claims, use an explicit `quicprobe` target and run `iperf3`
  preflight on the same path first.
- Benchmark setup must be flags, not environment variables or mutable
  `Application` config.
- Keep the active loop small: Benchee results plus optional sidecars for target
  metadata, git SHA, `iperf3`, telemetry summaries, server stats, captures, and
  flamegraphs.
- Do not revive Terraform, `probed`, release-deploy suites, `bench/ledger`, or
  `transport-bench-v1` for new benchmark work unless the user explicitly
  reopens that design.
- Use `bench/quicprobe` as the reference peer. It can be local or remote.
- Listener/relay pressure is future work. Current v1 focus is caller-side
  publishing/subscribing process architecture.
- For code changes, run the AGENTS gate. For docs-only or issue-only changes,
  do not waste time on the Elixir test/lint suite.

## Standard Workflow

1. Identify the question: process model, stream pressure, DATAGRAM pressure,
   target path behavior, or reference-peer behavior.
2. Read the current benchmark docs:
   ```bash
   sed -n '1,220p' bench/README.md
   sed -n '1,260p' bench/moqxprobe/README.md
   ```
3. For process-model checks, run the fake target:
   ```bash
   cd bench/moqxprobe
   mix run bench/stream_clients.exs -- --target fake --benchee-time 3
   ```
4. For real QUIC checks, verify the target first:
   ```bash
   iperf3 --client <target> --port <iperf-port> --time 5 --json
   iperf3 --client <target> --port <iperf-port> --udp --bitrate 100M --time 5 --json
   ```
5. Run the Benchee script with explicit target flags:
   ```bash
   cd bench/moqxprobe
   mix run bench/stream_clients.exs -- \
     --target quicprobe \
     --host <target> \
     --quic-port <quic-port> \
     --ca <ca.pem> \
     --servername <server-name> \
     --benchee-time 3
   ```
6. Record what was measured, target/path, command flags, and artifacts in the
   relevant `.scratch/transport-layer-foundation/issues/*.md` issue.

## Validation

- Root Elixir code changes:
  ```bash
  mix format --check-formatted
  mix test
  mix credo --strict
  ```
- `bench/moqxprobe` code changes:
  ```bash
  cd bench/moqxprobe
  mix format --check-formatted
  mix test
  mix credo --strict
  ```
- `bench/quicprobe` changes:
  ```bash
  cd bench/quicprobe
  go test ./...
  ```

Skip these gates for docs-only and issue-only bookkeeping.
