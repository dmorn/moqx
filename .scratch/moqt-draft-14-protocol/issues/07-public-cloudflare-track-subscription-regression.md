# Restore public Cloudflare selected-track subscription

Status: done
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

## Resolution

`MOQX.unsubscribe/2` removed the subscription lifecycle and track alias as soon
as it sent `UNSUBSCRIBE`. Cloudflare subsequently sent the matching
`PUBLISH_DONE`, as required before the publisher destroys its subscription
state, so MOQX rejected that valid completion as an unknown request.

Local unsubscribe now removes the subscription from the application-active set
while retaining its protocol lifecycle, alias, and stream associations. The
existing `PUBLISH_DONE` completion path drains the advertised subgroup stream
count and then removes all retained state.

## Comments

- 2026-07-13: Created from live evidence gathered while implementing issue 03.
  Issue 03 remains complete because its pinned Docker relay roundtrip and CI
  boundary are independently green.
- 2026-07-13: Reproduced the failure with a reducer regression covering object
  delivery, local `UNSUBSCRIBE`, matching `PUBLISH_DONE`, and late stream FIN.
  The focused test failed with `:unknown_subscribe_request` before the fix and
  passes afterward.
- 2026-07-13: Verified 204 hermetic tests and the independently selected public
  Cloudflare integration test. The live test captured the catalog-selected H.264
  track into a non-empty MP4 containing its initialization segment and 30 media
  objects. A local rerun of the Docker relay harness was unavailable because the
  machine's Docker symlink points to a missing OrbStack installation; issue 03's
  previously committed Docker evidence is unchanged.
