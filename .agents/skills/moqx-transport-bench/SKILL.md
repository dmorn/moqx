---
name: moqx-transport-bench
description: Run and evolve moqx transport benchmark workflows for controlled QUIC, MOQT-shaped, iperf3, and Hetzner smoke/performance tests. Use when the user mentions transport benchmarks, QUIC link limits, issue #8, Hetzner benchmark infra, iperf3 baselines, quicprobe, or real-server performance testing in this repo.
---

# moqx Transport Bench

Source of truth:

- `bench/transport/README.md` for benchmark contract, evidence tiers, output
  schema, workloads, stop conditions, and "breaks apart" semantics.
- `bench/transport/infra/hetzner/README.md` for disposable Hetzner provisioning.
- `docs/adr/`, `CONTEXT.md`, and local issues under `.scratch/` for decisions
  and bookkeeping.

## Rules

- Treat local/loopback runs as calibration only, never real network evidence.
- Use controlled disposable servers for benchmark claims. Do not use production
  machines for pressure tests.
- Use a fresh per-run SSH key under `bench/transport/.keys/<run-id>/`; never
  put private keys in Terraform state or git.
- Keep `.env`, Terraform state, result artifacts, plans, and run keys ignored.
- Run `iperf3` first to establish the raw path ceiling before QUIC or
  MOQT-shaped pressure tests.
- Record machine-readable JSONL and path metadata for every benchmark run.
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
   sed -n '1,260p' bench/transport/README.md
   sed -n '1,220p' bench/transport/infra/hetzner/README.md
   ```

3. Prepare a run id and per-run SSH key:

   ```bash
   mkdir -p bench/transport/.keys/<run-id>
   ssh-keygen -t ed25519 -N '' -C moqx-transport-bench-<run-id> \
     -f bench/transport/.keys/<run-id>/id_ed25519
   ```

4. Validate Terraform before creating resources:

   ```bash
   cd bench/transport/infra/hetzner
   terraform init
   terraform fmt -check -recursive .
   terraform validate
   terraform plan \
     -var-file=profiles/arm-smoke.tfvars \
     -var='run_id=<run-id>' \
     -var='ssh_public_key_path=../../.keys/<run-id>/id_ed25519.pub' \
     -out=/private/tmp/moqx-<run-id>.tfplan
   ```

5. Apply only the reviewed plan, verify cloud-init/toolchain, and save outputs
   under `bench/transport/results/<run-id>/`.

6. Run the path baseline:
   start `iperf3 --server` on the receiver, run
   `bench/transport/scripts/iperf3_baseline.exs` on the sender with
   `--path-json`, then fetch the JSONL results.

7. Only after a valid path baseline, run QUIC or MOQT-shaped pressure scripts.
   Keep workloads explicit: profile, direction, stream/datagram counts, payload
   size, offered load, duration, repetitions, and stop conditions.

8. Tear down and verify:

   ```bash
   terraform destroy \
     -var-file=profiles/arm-smoke.tfvars \
     -var='run_id=<run-id>' \
     -var='ssh_public_key_path=../../.keys/<run-id>/id_ed25519.pub'
   terraform state list
   ```

   Check provider resources by `purpose=moqx-transport-bench` when credentials
   are available.

## Bookkeeping

- Summarize what was measured, where, profile used, result artifact paths, and
  whether infrastructure was destroyed.
- Keep one-off IPs, run ids, and measured values out of this skill. Put them in
  result artifacts, issue comments, or PR notes.
- Before committing repo changes, run the project gate from `AGENTS.md`:
  `mix format`, tests, `mix credo --strict`, plus relevant Terraform checks.
