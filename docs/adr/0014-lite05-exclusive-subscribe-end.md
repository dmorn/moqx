# ADR-0014: Follow the deployed exclusive Lite05 completion boundary

- Status: Accepted by the maintainer
- Date: 2026-09-07
- Related issue: https://github.com/dmorn/moqx/issues/44

Submitted `draft-lcurley-moq-lite-05` section 7.12 defines SUBSCRIBE_END as an
inclusive last sequence. Upstream subsequently found that this cannot distinguish
an empty track from a track whose only group is zero. In moq-dev/moq issue #2309
and PR #2333 (merge fccda01366197c9be47e55783a799b438d31c554), upstream aligned
JavaScript and the working draft with Rust's exclusive boundary. Its tests
explicitly use Lite05. The working draft lists the correction under -06 because
-05 was already submitted; the deployed -05 contract uses the correction.

References:

- https://datatracker.ietf.org/doc/html/draft-lcurley-moq-lite-05#section-7.12
- https://github.com/moq-dev/moq/issues/2309
- https://github.com/moq-dev/moq/pull/2333

MOQX follows the corrected deployed contract under `:moq_lite_05`: END is the
first sequence that will never arrive. Publishers emit max delivered group + 1,
or 0 if no group was delivered. Subscription finish, track withdrawal and
publication finish share one encoder. Subscribers account only for groups below
END, including when END/FIN arrives before the final Group stream. They preserve
the existing bounded drain deadline. Publishing reserves room for the exclusive
boundary in a QUIC varint; the maximum representable varint itself is not a valid
published group ID.

This supersedes MOQX's earlier choice to preserve the submitted inclusive wording.
It is an explicit compatibility decision, not endpoint inference, an ALPN change,
a second compatibility mode, or adoption of the remaining draft-06 protocol.
Comments beside the sender, receiver and message type record this rationale so
future changes do not accidentally restore the stale inclusive interpretation.

Validation covers exact sender boundaries, empty ranges, the native QUIC race
where END precedes the final group, and final/empty-track completion through the
pinned moq.dev relay. The release remains separate from merge and test evidence.
