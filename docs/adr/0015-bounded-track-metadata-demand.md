# ADR-0015: Keep bounded metadata provisioning separate from subscription admission

- Status: Accepted
- Date: 2026-09-08

## Context

Lite05 peers may fetch TrackInfo before requesting a media subscription. A
subscription admission callback cannot provision a previously absent track in
that sequence: immediate metadata rejection ends the workflow first. The
application, not the protocol implementation, knows how to create the track.

## Decision

Publications explicitly opt into `missing_track_metadata: :controlled`.
Immediate `:reject` remains the default. The connection's existing event
recipient owns provisioning; no additional OTP processes or track factories are
introduced. Its existing monitor closes the connection when the owner exits.

Each valid absent-track request gets a connection-scoped opaque handle, typed
event, independent driver-owned timer, and one terminal outcome. The timeout
starts on receipt; the public request carries its duration, not a wall-clock
timestamp. A per-publication positive capacity bounds pending handles. Overflow
and unknown broadcasts are rejected without admitting new handles.

Application track registration resolves all pending requests for that exact
publication/name with the real immutable properties. Registration through
reactive subscription acceptance uses the same resolution path. Metadata
rejection targets one handle; peer cancellation, timeout and publication finish
do not cancel sibling requests or unrelated subscriptions. Connection shutdown
ends every pending request. FIN on the request half is normal request completion,
not cancellation; STOP_SENDING/reset/close terminates the pending request.

Metadata availability is not subscriber authorization. Existing controlled
subscription decisions remain mandatory and independent; neither metadata
registration nor metadata rejection decides them implicitly. Applications may
deduplicate expensive provisioning work by track address while retaining all
individual request handles for accounting.

## Consequences

Demand-driven publishers can work with relays which ask for metadata first,
without polling, transport codecs in applications, or pre-registering every
possible track. Applications still decide provisioning, admission and retry.
The library cannot promise a terminal notification to an owner that exited,
and a registered outcome is transport admission, not peer media delivery.

The current driver delivers events after all transition IO succeeds. An action
failure can therefore surface as an operation error or `ProtocolFailed` without
the request's terminal notification. Closing this failure-event boundary is a
release gate for strict terminal-event guarantees; normal-path tests do not
prove that stronger contract.

## References

- [Lite05 Track stream](https://datatracker.ietf.org/doc/html/draft-lcurley-moq-lite-05#section-5.1.4)
- ADR-0010: protocol implementation and runtime ownership
- `test/moqx/track_metadata_demand_test.exs`
- `test/integration/moq_lite_05_metadata_demand_test.exs`
