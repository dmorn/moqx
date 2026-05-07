# Add quicprobe reference CLI

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a small repo-owned reference QUIC tool, likely under `tools/quicprobe/`, to act as both a reference server and reference client for integration tests.

The initial tool should be minimal and focused on transport contract verification rather than MOQT protocol behavior.

## Acceptance criteria

- [ ] A reference CLI exists in the repository and can be run locally by integration tests.
- [ ] The CLI supports server mode with configurable address, certificate, key, and ALPN.
- [ ] The CLI supports client mode with configurable address, CA certificate, ALPN, and a simple stream operation.
- [ ] The initial stream operation can verify bidirectional stream send/receive behavior.
- [ ] The tool can be used by Docker Compose as the reference server.
- [ ] `mise.toml` includes required developer tool declarations where practical, especially Go if using `quic-go`.
- [ ] README or harness docs explain how to run the tool manually for debugging.

## Blocked by

None - can start immediately

## Comments
