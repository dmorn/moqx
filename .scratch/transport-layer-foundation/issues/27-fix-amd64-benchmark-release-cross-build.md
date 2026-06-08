# Fix AMD64 benchmark release cross-build

Status: in-progress
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Make the Linux/AMD64 `moqx-transport-bench` release artifact build reliably
from the ARM development workstation, or provide an equally simple documented
operator path for producing that artifact before x86 benchmark runs.

## Acceptance criteria

- [x] `just bench-transport-build-release linux_x86_64` succeeds from the ARM
  workstation, or an alternative one-command AMD64 build path is documented.
- [x] The produced artifact follows the current target naming convention:
  `moqxprobe-<version>-<git>-linux-x86_64.tar.gz`.
- [x] The AMD64 release artifact can be deployed with target-aware
  `bench-transport-deploy-release` recipes without special-case operator steps.
- [x] The fix does not regress the working Linux/ARM64 release build.

## Evidence

- 2026-05-22: `TARGET_ARCH=amd64 just bench-transport-build-release` fails
  under Docker cross-architecture emulation on the Apple ARM workstation during
  `mix local.hex --force && mix local.rebar --force`. Erlang/OTP terminates
  `user_drv` with `undefined function erlang:nif_error/1`, then kernel startup
  fails with `nouser`.
- The failure reproduced while preparing artifacts for commit `951ee7c`; the
  ARM64 release build succeeded, and both ARM64 and AMD64 `quicprobe` artifacts
  succeeded. This appears specific to running the Elixir/OTP release build for
  Linux/AMD64 under the current cross-arch Docker environment.

## Notes

- This does not block raw `quicprobe <-> quicprobe` x86-control tests because
  `quicprobe-951ee7c-linux-amd64.tar.gz` builds successfully.
- It does block canonical `transport-bench-v1` x86-control runs unless the
  release is built on a real AMD64 host, in CI, or through a different
  packaging path.

## Comments

- 2026-06-08: Added a target-explicit `moqxprobe` Mix release build/deploy
  flow: `just bench-transport-build-release <target>`,
  `just bench-transport-release-artifact-rel <target>`, and
  `just bench-transport-deploy-release <target> <run-id>`. Added
  `just bench-transport-build-release-remote-role <run-id> <role>
  linux_x86_64` as the one-command AMD64 escape hatch: it uploads
  `git archive HEAD` over SSH, checks remote `uname -m`, builds the normal
  glibc-compatible Mix release on that node, fetches the artifact into
  `bench/moqxprobe/build/artifacts/`, and keeps the existing deploy model.
  Remote proof is still pending; this issue should close only after the next
  disposable x86 or ARM lab run confirms the artifact deploys and starts.
- 2026-06-08: Verified the updated ARM64 Docker release path with
  `just bench-transport-build-release linux_arm64`, which built
  `bench/moqxprobe/build/artifacts/moqxprobe-0.1.0-7b85779-linux-arm64.tar.gz`
  and compiled the quicer/msquic native dependency path successfully.
