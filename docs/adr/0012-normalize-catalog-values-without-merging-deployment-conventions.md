# ADR-0012: Normalize catalog values without merging deployment conventions

- Status: Accepted
- Date: 2026-07-27

## Context

Cloudflare draft-14 and the current Moqtail draft-16 deployment expose
different version-1 catalog shapes.

Cloudflare publishes `.catalog` using the older common-catalog layout:

- shared values may appear in `commonTrackFields`;
- codec and media selection values live in `selectionParams`;
- CMAF initialization is delivered on a separately advertised `initTrack`.

Moqtail publishes `catalog` using its current CMSF player model:

- `name`, `role`, `packaging`, `codec`, dimensions, bitrate, and timescale are
  track-level fields;
- initialization bytes are base64 encoded in per-track `initData`;
- track entries may omit `namespace`, inheriting the namespace through which
  the catalog was subscribed.

Treating either shape as an undocumented special case would leak provider JSON
into applications. Treating them as one wire convention would silently change
the established Cloudflare behavior.

## Decision

`MOQX.Catalog` and `MOQX.Catalog.Track` are protocol-neutral normalized values.
They preserve the original JSON in `raw` and identify the decoded deployment
shape in `format`.

Concrete protocol implementations choose their expected shape explicitly:

- `MOQX.Protocol.CloudflareDraft14` decodes `format: :cloudflare`;
- `MOQX.Protocol.Draft16` decodes `format: :moqtail_cmsf`.

`MOQX.Catalog.decode/2` may infer the shape for standalone application use, but
protocol implementations do not rely on inference.

Both implementations emit `%MOQX.Event.CatalogReceived{}` through the stable
public event envelope. The event identifies the catalog subscription, and the
catalog retains that subscription's namespace as the fallback address for
tracks that omit `namespace`.

Current Moqtail fields are validated before normalization. Failures return a
typed `%MOQX.Catalog.Error{}` containing the failing field path, reason, and
value. Inline `initData` is strict base64 and becomes decoded bytes in
`Track.init_data`; its encoded source remains available in `Track.raw`.

`MOQX.Catalog.h264_tracks/1` includes only video-compatible `cmaf` or
`chunk-per-object` AVC tracks that advertise inline initialization bytes or a
separate initialization track. It orders candidates deterministically by:

1. resolution area, descending;
2. advertised bitrate, descending;
3. track name, ascending.

`MOQX.Catalog.track_ref/2` resolves an exact protocol-neutral media address
using the track namespace or the catalog subscription namespace.

`MOQX.CMAF.capture/4` uses inline initialization bytes directly for the
Moqtail shape. It preserves Cloudflare behavior by subscribing to `initTrack`
when inline bytes are absent.

## Consequences

Positive:

- applications receive one typed catalog and track surface across both active
  protocol implementations;
- Moqtail catalogs can drive exact media subscriptions without guessing a
  namespace;
- Cloudflare's separate initialization-track lifecycle remains unchanged;
- malformed catalogs fail with actionable field-level errors;
- H.264 selection is stable across JSON array order when candidates have
  different quality metadata.

Tradeoffs:

- catalog normalization contains explicit knowledge of both deployed shapes;
- a new catalog revision requires a deliberate parser extension rather than
  being accepted as version 1 by accident;
- the current Moqtail per-track `initData` model is distinct from newer
  evolving MSF/CMSF proposals such as root-level `initDataList`.

## References

- [Issue #34](https://github.com/dmorn/moqx/issues/34)
- [Moqtail pinned draft-16 reference](https://github.com/moqtail/moqtail/commit/c2ff7253479c6a0d7c8282a1cad289d591ebc302)
- [MOQT Streaming Format](https://datatracker.ietf.org/doc/draft-ietf-moq-msf/)
- [CMSF](https://datatracker.ietf.org/doc/draft-ietf-moq-cmsf/)
- `docs/adr/0010-compose-versioned-wire-packages-into-explicit-protocol-implementations.md`
