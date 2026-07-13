# Add bounded subscriber demand and backpressure

Status: needs-triage

Design and implement a bounded demand model between the public subscriber API,
the protocol lifecycle, and transport stream activation. The design must define:

- how callers grant and replenish demand;
- whether limits count objects, bytes, or both;
- fair allocation across subscriptions sharing one connection;
- interaction with subgroup-stream activation and `PUBLISH_DONE` draining;
- overflow, cancellation, timeout, and slow-consumer behavior;
- a Membrane-friendly adapter seam without making Membrane a dependency of MOQX.

This work is intentionally deferred until typed events, explicit event routing,
completion/draining, and the packaged testing transport are established.

## Comments

- 2026-07-13: Saved for later at the user's request; excluded from issue 05 implementation.
- 2026-07-13: Transport benchmark evidence constrains this design: a stream
  `send_complete` event is stream-local backend-admission credit, never proof of
  peer delivery. Demand must preserve independent stream owners and enough
  per-stream/global send window to keep QUIC fed; a single synchronous demand
  loop must not serialize subgroup streams or turn completion callbacks into a
  connection-wide gate. Validate the eventual design with open-loop
  offered-versus-accepted measurements so coordinated omission cannot hide
  underfeeding, and keep receiver evidence separate from sender admission.
