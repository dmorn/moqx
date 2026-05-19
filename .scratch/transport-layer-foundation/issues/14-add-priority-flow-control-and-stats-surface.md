# Add priority, flow-control, and stats surface

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Expose capability-aware priority, flow-control, and transport-stat signals needed by higher-level MOQT-family schedulers.

MOQT draft-14 expects the control stream to be prioritized over data and warns about flow-control deadlocks. MOQ Lite relies on stream scheduling, group expiry resets, and optional probing for bitrate/RTT. The transport layer should not implement protocol schedulers, but it should expose enough information and optional knobs for those schedulers to be built above it.

## Acceptance criteria

- [ ] Stream open/send options can carry a priority or scheduling hint where the backend supports it.
- [ ] Unsupported priority hints fail clearly or are reported as ignored according to documented semantics.
- [ ] Normalized events expose stream availability or flow-control pressure where the backend provides it.
- [ ] The transport exposes optional stats such as RTT or send-rate/congestion estimate where available, or reports `:unsupported`.
- [ ] The support transport can simulate priority/flow-control/stat capabilities for deterministic protocol tests.
- [ ] The API does not embed draft-14 or MOQ Lite priority comparison rules; those remain protocol-layer concerns.
- [ ] Tests cover supported and unsupported capability paths.

## Blocked by

None - issues 13 and 04 are closed.

## Comments

- 2026-05-19: Structural blockers are closed, but this remains
  `needs-triage`. The surface should be designed against a concrete benchmark
  or protocol caller so transport stats, priority hints, and flow-control
  pressure are not over-generalized.
