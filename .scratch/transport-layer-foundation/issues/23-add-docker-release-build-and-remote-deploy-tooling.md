# Add Docker release build and remote deploy tooling

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add operator tooling that builds the `bench/transport` runtime CLI as a
Linux/ARM64 Elixir release artifact with Docker, then deploys that artifact to
caller-provided benchmark hosts and verifies the remote CLI starts.

This is the missing handoff between the benchmark Mix project and the
caller-operated Hetzner server pairs. It must stay separate from Terraform
provisioning and from benchmark execution: the caller provisions hosts, passes
host/SSH details to the deploy tooling, and explicitly runs benchmark commands.

## Acceptance criteria

- [x] A Docker-based build path exists for a Linux/ARM64
      `moqx-transport-bench` release artifact.
- [x] The build path produces a versioned tarball artifact under an ignored
      benchmark build/artifact directory.
- [x] The artifact includes the release wrapper
      `bin/moqx-transport-bench`.
- [x] The deploy path accepts caller-provided SSH targets and does not read
      Terraform state directly.
- [x] The deploy path copies the release artifact to one or more remote hosts
      and extracts it under an operator-selected directory.
- [x] The deploy path can run a remote smoke command:
      `moqx-transport-bench help`.
- [x] Documentation explains the build, deploy, and smoke flow against
      Hetzner Terraform outputs.
- [x] The tooling does not provision, destroy, or mutate cloud resources.
- [x] The tooling does not run benchmark traffic implicitly.

## Blocked by

- `.scratch/transport-layer-foundation/issues/08-create-transport-benchmark-harness-skeleton.md`
- `.scratch/transport-layer-foundation/issues/22-add-hetzner-ephemeral-benchmark-infra.md`

## Design decisions

- Use Docker, not Apple containers, for the first cross-architecture release
  build path.
- Target Linux/ARM64 first because the preferred Hetzner profiles use CAX ARM
  instances.
- Keep build/deploy tooling operator-driven and boring: Make targets and small
  shell scripts are preferred over a new orchestration dependency.
- Treat release artifacts as local/generated outputs. They must not be
  committed.
- Deployment tooling receives SSH targets explicitly. Terraform can produce
  useful output, but the deploy tool should not couple itself to Terraform
  state or apply/destroy workflows.
- A successful deploy smoke only proves the packaged CLI starts on the remote
  host. Real benchmark evidence still starts with an `iperf3-baseline` run.

## Resolution

Implemented by:

- `bench/transport/Makefile`
- `bench/transport/docker/Dockerfile.release`
- `bench/transport/scripts/deploy_release.sh`

The build target creates a Linux/ARM64 release tarball under
`bench/transport/build/artifacts/`. The deploy target requires explicit
`TARGETS`, copies the artifact over SSH, extracts it under
`/opt/moqx-bench/moqx-transport-bench/releases/<artifact>/`, updates the
`current` symlink, and runs `moqx-transport-bench help` as the remote smoke.

Documentation was updated in:

- `bench/transport/README.md`
- `bench/transport/infra/hetzner/README.md`
- `docs/adr/0001-transport-boundary-support-transport-and-benchmark-harness.md`
- `.scratch/transport-layer-foundation/PRD.md`
- `.agents/skills/moqx-transport-bench/SKILL.md`

Validation:

- `make -C bench/transport help`
- `sh -n bench/transport/scripts/deploy_release.sh`
- `git diff --check`
- `make -C bench/transport docker-release`
- `tar -tzf bench/transport/build/artifacts/moqx-transport-bench-0.1.0-553d2c6-linux-arm64.tar.gz`
- `docker run --platform linux/arm64 --rm -v /Users/dmorn/projects/moqx/bench/transport/build/artifacts:/artifacts elixir:1.19.5-otp-28 sh -c 'mkdir -p /tmp/moqx-release && tar -xzf /artifacts/moqx-transport-bench-0.1.0-553d2c6-linux-arm64.tar.gz -C /tmp/moqx-release && /tmp/moqx-release/bin/moqx-transport-bench help'`
- `make -C bench/transport deploy-release`
  - Expected failure without `TARGETS`: the deploy target refuses to run
    without explicit SSH targets.

## Comments

- 2026-05-20: Created after the benchmark subproject/release wrapper landed.
  This issue captures the agreed next step: Docker-built release artifacts and
  simple SSH deploy/smoke tooling before running real server-pair experiments.
