# Add the Cloudflare draft-14 publisher slice

Status: done
Type: enhancement

## Goal

Add publishing as a separate `MOQX.Protocol.CloudflareDraft14` vertical slice
without widening or coupling the completed subscriber API.

## Agreed design

- expose protocol-neutral publication and published-track handles through the
  existing `MOQX.Client` connection;
- model media objects independently from the direction in which they travel;
- let applications register tracks and publish objects without handling wire
  request IDs, aliases, or inbound relay messages;
- implement the demonstrated Cloudflare lifecycle:
  PUBLISH_NAMESPACE, PUBLISH_NAMESPACE_OK or ERROR, inbound SUBSCRIBE,
  SUBSCRIBE_OK or ERROR, subgroup delivery, UNSUBSCRIBE, PUBLISH_DONE, and
  PUBLISH_NAMESPACE_DONE or CANCEL;
- keep publisher-initiated PUBLISH/PUBLISH_OK outside this first slice. It is a
  separate draft-14 facility and is not needed for Cloudflare's
  announce-and-serve path;
- retain the latest catalog and initialization objects for new subscribers;
  live media may be discarded while no subscription is active;
- build CMAF catalog, initialization, and H.264 media publication on the
  protocol-neutral publication API;
- prove the lifecycle hermetically and perform a manual publisher/subscriber
  roundtrip against an actual Cloudflare relay; exercise managed-token
  enforcement when a disposable managed credential is available.

## Authorization boundary

- The draft-14 wire package owns the standard AUTHORIZATION TOKEN parameter,
  Token structure, and encoding.
- `CloudflareDraft14` owns when and how a caller-supplied Cloudflare credential
  is attached and how authorization failures are mapped.
- Token issuance, permissions, rotation, and secret lookup are outside the
  protocol and library. A caller or test harness resolves the token and passes
  it explicitly.
- Credential values must have redacted inspection and must never appear in
  fixtures, logs, errors, issue comments, or git.
- Do not use `Application` environment. Live verification credentials are
  obtained through the configured 1Password integration.

## Acceptance criteria

- public operations create a namespace publication, add tracks, publish typed
  objects, and finish the publication;
- namespace acceptance, rejection, cancellation, and graceful withdrawal are
  deterministic reducer transitions;
- an inbound SUBSCRIBE for a registered track receives SUBSCRIBE_OK and data;
- an unknown track receives SUBSCRIBE_ERROR;
- subgroup streams are encoded through the shared draft-14 wire package and
  use graceful send-side completion;
- UNSUBSCRIBE stops the corresponding delivery and source completion emits
  PUBLISH_DONE only after all subgroup streams have been opened and finished;
- credentials remain explicit and redacted while standard draft-14 token bytes
  are covered by codec tests;
- CMAF H.264 published through Cloudflare can be subscribed, reconstructed,
  inspected by `ffprobe`, and decoded by `ffmpeg`;
- `mix format`, `mix test`, and `mix credo --strict` pass.

## Constraints

- compose the shared `MOQX.Protocol.MOQTDraft14` wire package;
- keep publisher state and lifecycle in the Cloudflare implementation;
- do not add mutable application configuration;
- keep credentials in 1Password and out of fixtures, logs, and git;
- do not fold CI relay orchestration into this implementation issue.

## Comments

- 2026-07-13: Created when the subscriber-only issue was completed. The user
  explicitly reserved publishing for a separate slice.
- 2026-07-13: Design accepted. Corrected the initial PUBLISH/PUBLISH_OK focus:
  the first Cloudflare publisher path announces a namespace and serves inbound
  SUBSCRIBE requests. Authorization has a standard draft-14 wire carrier but
  Cloudflare-specific credentials and policy stay in the concrete protocol
  implementation and caller-owned secret resolution.
- 2026-07-13: Implemented the protocol-neutral publication, track, and object
  operations; Cloudflare namespace/subscription lifecycle; shared draft-14
  publisher codecs and subgroup encoder; redacted credential and sensitive
  wire wrappers; retained content policy; and fragmented-MP4 CMAF publisher.
- 2026-07-13: Manual proof against Cloudflare's public draft-14 relay published
  and subscribed 120 H.264 CMAF fragments totaling 3,528,160 media bytes. The
  reconstructed MP4 was byte-identical to the input, `ffprobe` reported H.264
  AVC at 424x240, and a full `ffmpeg` video decode completed without errors.
  Managed-token live enforcement was not exercised because the available
  1Password developer environments contained no MOQX/Cloudflare relay secret;
  no existing token was rotated or exposed.
- 2026-07-13: Final repository gates passed: `mix format`, `mix test` with 196
  passing tests and 19 integration-tagged exclusions, and
  `mix credo --strict` with no findings. Managed-relay CI orchestration remains
  tracked separately in issue 03.
