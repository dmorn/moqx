# Add configurable ALPN and capability surface

Status: closed
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a transport-level surface for protocol/session code to configure ALPN and discover negotiated transport capabilities.

This is needed because MOQT draft-14 native QUIC uses ALPN `moq-00`, while MOQ Lite bare QUIC uses ALPN tokens such as `moq-lite-xx`. Draft-14 requires QUIC DATAGRAM support; MOQ Lite does not use datagrams.

## Acceptance criteria

- [x] Connect/listen options can carry protocol-selected ALPN values without hard-coding draft-14 into the transport layer.
- [x] A connection exposes negotiated ALPN or a documented unavailable result where the backend cannot provide it.
- [x] A connection exposes datagram availability.
- [x] A connection exposes max datagram payload size when available, or `:unknown`/`:unsupported` when not available.
- [x] A connection exposes stream-direction support sufficient for bidirectional and unidirectional stream tests.
- [x] A connection exposes optional feature support for stream priority and transport stats, or reports `:unsupported`.
- [x] Capability results are normalized and do not leak raw `quicer` option/event shapes.

## Blocked by

- `.scratch/transport-layer-foundation/issues/01-establish-normalized-transport-event-helper.md`
- `.scratch/transport-layer-foundation/issues/02-normalize-quicer-elixir-inputs.md`

## Resolution

Closed by commit `746257a`.

Implemented the production capability surface:

- `MOQX.Transport.capabilities/2`
- `%MOQX.Transport.Capabilities{}`
- `MOQX.Transport.Capabilities.from_quicer/3`
- `MOQX.Transport.Quicer.capabilities/1`
- protocol-selected ALPN normalization through `MOQX.Transport.Quicer.Options`

Support-transport-specific profile coverage was moved to `.scratch/transport-layer-foundation/issues/15-model-draft14-and-moq-lite-transport-profiles.md` because the support transport does not exist yet.

## Comments
