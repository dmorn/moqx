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
- Build Linux/ARM64 remote release artifacts with Docker via
  `just bench-transport-build-release`; deploy them to Terraform `client` and
  `server` roles with `just bench-transport-deploy`, or to one explicit target
  with `just bench-transport-deploy-target`.
- Build Burrito-wrapped Linux artifacts inside the target Linux Docker image
  with `just bench-transport-build-burrito-release linux_arm64`; deploy them
  with `just bench-transport-deploy-burrito linux_arm64`. Do not use
  host-local Burrito output for Linux deployment when native dependencies such
  as `quicer` are present.
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
   just bench-transport-build-release
   just bench-transport-deploy
   ```

7. Run the path baseline:
   start `iperf3 --server` on the receiver, run
   `moqxprobe iperf3-baseline --path-json ...` on the sender, then
   fetch the JSONL results. During local development, the equivalent wrapper is
   `mix moqx.transport.iperf3_baseline` from `bench/moqxprobe/`.

8. Only after a valid path baseline, run QUIC or MOQT-shaped pressure tasks.
   Keep workloads explicit: profile, direction, stream/datagram counts, payload
   size, offered load, duration, repetitions, and stop conditions.

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
- Before committing repo changes, run the project gate from `AGENTS.md`:
  `mix format`, tests, `mix credo --strict`, plus the nested benchmark project
  gate when changing `bench/ledger/`, `bench/moqxprobe/`, or `bench/probed/`,
  and relevant Terraform checks.
