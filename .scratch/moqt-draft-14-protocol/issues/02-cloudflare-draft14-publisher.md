# Add the Cloudflare draft-14 publisher slice

Status: needs-triage
Type: enhancement

## Goal

Add publishing as a separate `MOQX.Protocol.CloudflareDraft14` vertical slice
without widening or coupling the completed subscriber API.

## Scope to specify

- public publish operations and typed results;
- PUBLISH_NAMESPACE lifecycle and errors;
- PUBLISH/PUBLISH_OK/PUBLISH_DONE lifecycle;
- subgroup-object production for a catalog, initialization track, and media;
- managed-relay authentication and token permissions;
- subscriber/publisher roundtrip evidence against a disposable relay.

## Constraints

- compose the shared `MOQX.Protocol.MOQTDraft14` wire package;
- keep publisher state and lifecycle in the Cloudflare implementation;
- do not add mutable application configuration;
- keep credentials in 1Password and out of fixtures, logs, and git;
- do not fold CI relay orchestration into this implementation issue.

## Comments

- 2026-07-13: Created when the subscriber-only issue was completed. The user
  explicitly reserved publishing for a separate slice.
