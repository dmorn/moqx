# Fix AMD64 benchmark release cross-build

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Make the Linux/AMD64 `moqx-transport-bench` release artifact build reliably
from the ARM development workstation, or provide an equally simple documented
operator path for producing that artifact before x86 benchmark runs.

## Acceptance criteria

- [ ] `TARGET_ARCH=amd64 just bench-transport-build-release` succeeds from the
  ARM workstation, or an alternative one-command AMD64 build path is documented.
- [ ] The produced artifact follows the existing naming convention:
  `moqx-transport-bench-<version>-<git>-linux-amd64.tar.gz`.
- [ ] The AMD64 release artifact can be deployed with the existing
  `bench-transport-deploy` recipes without special-case operator steps.
- [ ] The fix does not regress the working Linux/ARM64 release build.

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
