---
name: moqx-transport-bench
description: Run and evolve moqx transport benchmark workflows for controlled QUIC, MOQT-shaped, iperf3, and Hetzner smoke/performance tests. Use when the user mentions transport benchmarks, QUIC link limits, issue #8, Hetzner benchmark infra, iperf3 baselines, quicprobe, or real-server performance testing in this repo.
---

# moqx Transport Bench

Source of truth:

- `bench/README.md` for the bench subproject layout.
- `bench/ledger/README.md` for shared benchmark artifact specs.
- `bench/moqxprobe/README.md` for benchmark workloads, evidence tiers,
  output schema usage, stop conditions, and "breaks apart" semantics.
- `bench/infra/hetzner/README.md` for disposable Hetzner provisioning.
- `docs/adr/`, `CONTEXT.md`, and local issues under `.scratch/` for decisions
  and bookkeeping.

## Rules

- Treat local/loopback runs as calibration only, never real network evidence.
- Use controlled disposable servers for benchmark claims. Do not use production
  machines for pressure tests.
- Use a fresh per-run SSH key under `bench/moqxprobe/.keys/<run-id>/`; never
  put private keys in Terraform state or git.
- Keep `.env`, Terraform state, result artifacts, plans, and run keys ignored.
- Run `iperf3` first to establish the raw path ceiling before QUIC or
  MOQT-shaped pressure tests.
- Record machine-readable JSONL and path metadata for every benchmark run.
- Prefer the runtime `moqxprobe` CLI on remote nodes. Local Mix
  tasks under `mix moqx.transport.*` are development wrappers over the same
  runtime command modules.
- Build Linux/ARM64 `moqxprobe` Mix release artifacts with Docker via
  `just bench-transport-build-release linux_arm64`; deploy them to Terraform
  `client` and `server` roles with
  `just bench-transport-deploy-release linux_arm64`, or to one explicit target
  with `just bench-transport-deploy-target`.
- For Linux/x86_64 `moqxprobe`, prefer
  `just bench-transport-build-release-remote-role <run-id> client linux_x86_64`
  on an already-provisioned x86 node when Docker/OTP cross-architecture
  emulation is unreliable, then deploy with
  `just bench-transport-deploy-release linux_x86_64 <run-id>`.
- Build Linux `probed` Mix release artifacts with
  `just bench-transport-build-probed <target>` and deploy them with
  `just bench-transport-deploy-probed <target> <run-id>`.
- For Linux/x86_64 `probed`, use
  `just bench-transport-build-probed-remote-role <run-id> client linux_x86_64`
  on an already-provisioned x86 node when Docker/OTP cross-architecture
  emulation is unreliable.
- Build `quicprobe` with native Go cross-compilation through mise via
  `just bench-transport-build-quicprobe <target>`, where target is one of
  `linux_arm64`, `linux_x86_64`, `darwin_arm64`, or `darwin_x86_64`. Deploys
  are Linux-only and use the same Linux target alias as the first argument.
- Run repeated remote checks through the repo-owned `probed` suite driver:
  `just bench-transport-probed-suite <run-id>`. Keep `probed` as the process
  supervisor/artifact store; benchmark semantics stay in the suite arguments,
  `moqxprobe`, and `quicprobe`.
- For fast `moqxprobe` development on already-running lab nodes, use
  `just bench-transport-iterate-moqxprobe <run-id> <target> <tests>`. It
  snapshots the current dirty-or-clean worktree, builds remotely with caches,
  deploys to both roles, verifies `probed`, and runs the selected suite.
- Destroy disposable infrastructure immediately after validation or data
  capture, then verify no provider resources remain.
- For transport decisions, consult quicer and the relevant MOQT draft text
  before changing benchmark semantics.

## Standard Workflow

1. Confirm the question: raw path ceiling, QUIC stream pressure, QUIC datagram
   pressure, mixed MOQT-shaped pressure, interop comparison, or provisioning
   smoke.

2. Read the current contracts:

   ```bash
   sed -n '1,260p' bench/moqxprobe/README.md
   sed -n '1,220p' bench/infra/hetzner/README.md
   ```

3. Prepare a run id and per-run SSH key:

   ```bash
   just bench-transport-new-run
   just bench-transport-current-run
   ```

4. Validate Terraform before creating resources:

   ```bash
   just bench-transport-plan
   ```

5. Apply only the reviewed plan, verify cloud-init/toolchain, and save outputs
   under `bench/moqxprobe/results/<run-id>/`.

6. Build and deploy the benchmark CLI release:

   ```bash
   just bench-transport-apply-plan
   just bench-transport-build-release linux_arm64
   just bench-transport-deploy-release linux_arm64
   ```

7. Deploy and start `probed`, `moqxprobe`, and `quicprobe`, then run the
   repo-owned suite driver:

   ```bash
   just bench-transport-probed-suite <run-id>
   ```

   The default suite runs `iperf3`, `reference_stream`, and `moqx_stream`.
   Extend `PROBED_SUITE_TESTS` for DATAGRAM checks, for example
   `reference_datagram,moqx_datagram`, and keep offered load explicit through
   env such as `DATAGRAM_RATE`, `DURATION_SECONDS`, and `DATAGRAM_SIZE`.

   Once the lab is already running and the work is `moqxprobe` tuning, use the
   inner loop instead:

   ```bash
   just bench-transport-iterate-moqxprobe <run-id> linux_x86_64 iperf3,reference_stream,moqx_stream
   ```

8. Only after a valid path baseline, trust QUIC or MOQT-shaped pressure
   results. Keep workloads explicit: profile, direction, stream/datagram
   counts, payload size, offered load, duration, repetitions, and stop
   conditions.

9. Tear down and verify:

   ```bash
   just bench-transport-destroy
   just bench-transport-verify-clean
   ```

   Check provider resources by `purpose=moqxprobe` when credentials
   are available.

## Bookkeeping

- Summarize what was measured, where, profile used, result artifact paths, and
  whether infrastructure was destroyed.
- Keep one-off IPs, run ids, and measured values out of this skill. Put them in
  result artifacts, issue comments, or PR notes.
- Use `moqxprobe report <jsonl>` or the local
  `mix moqx.transport.report <jsonl>` wrapper to inspect JSONL artifacts
  without changing the canonical machine-readable format.
- Before committing code or benchmark-tooling changes, run the project gate from
  `AGENTS.md`: `mix format`, tests, `mix credo --strict`, plus the nested
  benchmark project gate when changing `bench/ledger/`, `bench/moqxprobe/`, or
  `bench/probed/`, and relevant Terraform checks. Documentation-only and
  issue-only bookkeeping commits do not require the Elixir gate.
