# ADR-0016: Media processing belongs downstream

- Status: Accepted
- Date: 2026-09-16

## Context

MOQX transports named tracks and implements explicit application catalog
profiles. CMSF and HANG catalogs advertise codec, packaging, dimensions,
bitrate, timescale, and initialization metadata that downstream consumers need
to configure media pipelines.

The package also exposed `MOQX.CMAF` file capture/publication and
H.264-specific catalog ranking. Those conveniences parsed fragmented MP4,
selected one codec, reordered media objects, performed file IO, and selected a
catalog initialization convention from `client.protocol`. This made the package
as a whole media-policy-aware and coupled an application format to a wire
protocol, contrary to the explicit profile boundary in ADR-0013.

## Decision

MOQX owns:

- MOQT and MoQ Lite session and wire behavior;
- opaque object delivery and publication;
- explicit application-profile selection;
- catalog decoding, validation, normalized metadata, and track addressing.

Downstream media code owns:

- codec and rendition selection policy;
- container parsing, fragment assembly, muxing, and file IO;
- decoder lifecycle, synchronization, and playback.

Remove `MOQX.CMAF`, `MOQX.Catalog.h264_tracks/1`, and
`MOQX.Catalog.select_h264/1` from the published library. The MOQtail CMAF
operator remains an unshipped script and selects `:moqtail_cmsf` explicitly.
Script-only helpers live under `scripts/`, which is excluded from the Hex
package. Any helper supporting multiple catalog conventions dispatches on an
explicit application profile; it never infers packaging from the wire protocol.

## Consequences

- Protocol implementations and public object APIs remain packaging-agnostic.
- Catalog metadata remains directly usable by downstream media libraries.
- MOQX no longer promises H.264 ranking, fragmented-MP4 parsing, capture, or
  playback behavior.
- Existing callers of the removed pre-1.0 convenience APIs must move that
  policy into application code or a companion media package.
- Operator scripts may still provide reproducible interoperability workflows
  without expanding the library contract.

## References

- `docs/adr/0012-normalize-catalog-values-without-merging-deployment-conventions.md`
- `docs/adr/0013-explicit-application-profiles.md`
