# Add configurable ALPN and capability surface

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Add a transport-level surface for protocol/session code to configure ALPN and discover negotiated transport capabilities.

This is needed because MOQT draft-14 native QUIC uses ALPN `moq-00`, while MOQ Lite bare QUIC uses ALPN tokens such as `moq-lite-xx`. Draft-14 requires QUIC DATAGRAM support; MOQ Lite does not use datagrams.

## Acceptance criteria

- [ ] Connect/listen options can carry protocol-selected ALPN values without hard-coding draft-14 into the transport layer.
- [ ] A connection exposes negotiated ALPN or a documented unavailable result where the backend cannot provide it.
- [ ] A connection exposes datagram availability.
- [ ] A connection exposes max datagram payload size when available, or `:unknown`/`:unsupported` when not available.
- [ ] A connection exposes stream-direction support sufficient for bidirectional and unidirectional stream tests.
- [ ] A connection exposes optional feature support for stream priority and transport stats, or reports `:unsupported`.
- [ ] Capability results are normalized and do not leak raw `quicer` option/event shapes.
- [ ] Tests cover at least draft-14-like and MOQ Lite-like capability profiles in the support transport.

## Blocked by

- `.scratch/transport-layer-foundation/issues/01-establish-normalized-transport-event-helper.md`
- `.scratch/transport-layer-foundation/issues/02-normalize-quicer-elixir-inputs.md`

## Comments
