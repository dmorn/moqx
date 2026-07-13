# Investigate public Cloudflare selected-track subscription regression

Status: needs-triage
Type: interoperability

## Goal

Restore the independently selected public Cloudflare catalog-and-media smoke
test without coupling it to the repo-owned Docker relay integration job.

## Current evidence

- On 2026-07-13,
  `test/integration/cloudflare_catalog_test.exs --include integration`
  connected to `draft-14.cloudflare.mediaoverquic.com`, completed setup, and
  received the `bbb/.catalog` catalog.
- `MOQX.CMAF.capture/4` then returned `{:error, :unknown_subscribe_request}`
  while subscribing to the catalog-selected H.264 track.
- The Dockerized publisher/subscriber roundtrip against the pinned draft-14
  `moq-rs` relay passes, so this is not a generic setup, catalog decoding, or
  object-delivery failure.

## Next investigation

- capture the exact selected track reference and control/object ordering from
  the public endpoint;
- determine whether an early `PUBLISH_DONE`, alias reuse, or changed catalog
  track convention removes the lifecycle before the subgroup stream arrives;
- add a deterministic reducer regression before changing protocol code;
- keep the public smoke external and separately selectable from CI's repo-owned
  Docker relay evidence.

## Comments

- 2026-07-13: Created from live evidence gathered while implementing issue 03.
  Issue 03 remains complete because its pinned Docker relay roundtrip and CI
  boundary are independently green.
