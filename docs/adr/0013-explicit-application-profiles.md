# ADR-0013: Compose application profiles independently of wire protocols

- Status: Accepted
- Date: 2026-09-07
- Supersedes: ADR-0012's protocol-owned catalog interpretation only
- Issue: https://github.com/dmorn/moqx/issues/44

The maintainer approved explicit per-subscription/publication profiles and the
breaking migration from implicit CMSF decoding to opaque objects by default.
Transport protocol selection remains connection-scoped. Application profile
selection is handle-scoped; concurrent operations may choose different profiles.

The existing connection driver owns profile state alongside pure wire reducers.
No processes or mutable application configuration are introduced. Reducers emit
opaque objects. The shared profile boundary validates and interprets catalog
objects, and reports malformed catalogs only to the affected subscription.
CMSF deployment conventions and initialization remain distinct as in ADR-0012.
HANG has its own typed media and rendition metadata rather than CMSF raw fields.

Test boundaries approved by the maintainer are the public MOQX operations and
events, public catalog codecs, and actual receiver data over pinned real QUIC.
Module documentation is the public API contract.
