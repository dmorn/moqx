---
name: NativeBinary lazy payload feature
description: Object payloads now arrive as %MOQX.NativeBinary{} (Rust heap) instead of BEAM binaries; zero-copy pipeline enabled
type: project
---

Implemented lazy native binary payloads (GitHub issue #23). Object payloads stay in Rust heap until explicitly materialised.

**Why:** Enable zero-copy media transcoding pipelines — subscribe, receive NativeBinary, pass directly to write_object/write_datagram without touching BEAM heap.

**How to apply:** When user asks about object payloads, NativeBinary, or zero-copy, recall this feature exists and is shipped. `MOQX.Object.payload` and `MOQX.FetchObject.payload` are now `%MOQX.NativeBinary{}` not `binary()`.

Key design decisions:
- `NativeBinary` is a Rustler `Resource` wrapping `bytes::Bytes` (Arc-backed, O(1) clone)
- `%MOQX.NativeBinary{ref: resource_ref, size: n}` — Elixir-visible struct
- `MOQX.NativeBinary.load/1` — only copy point (bytes → BEAM binary)
- `MOQX.NativeBinary.from_binary/1` — wrap existing binary into native heap (for testing/homogeneous APIs)
- `write_object/4` and `write_datagram/3` accept either `binary()` or `%MOQX.NativeBinary{}` — backward compatible
- Extension header values (binary type) still copy eagerly — they are small metadata
- Integration tests updated: all payload comparisons now call `NativeBinary.load/1` first
- 4 new integration tests (NativeBinary shape, subgroup roundtrip, datagram roundtrip, fetch path)
- 12 new unit tests (struct, round-trip, guard acceptance/rejection)
