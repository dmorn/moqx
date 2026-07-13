# Public subscription lifecycle and testing seam

Status: done

Implement the public subscriber/runtime gaps selected after the Cloudflare publisher slice:

- decode `PUBLISH_DONE` and drain already-open or late subgroup streams before completion;
- expose protocol output as typed public event structs;
- allow a connection's event recipient/router to be selected explicitly;
- package the deterministic support transport as a public downstream testing seam.

Subscription completion must preserve draft-14 ordering: `PUBLISH_DONE` may precede
the final subgroup streams. Completion is delivered only after the advertised stream
count has been processed, or after the configured delivery timeout.

## Comments

- 2026-07-13: Started as one cohesive public API slice. Demand/backpressure is deliberately excluded and tracked separately in issue 06.
- 2026-07-13: Implemented typed public events, explicit `events_to:` routing, runtime-owned delivery timers, `PUBLISH_DONE` stream draining, and the packaged `MOQX.Testing.Transport` seam. Verified with 201 hermetic tests and `mix credo --strict`.
