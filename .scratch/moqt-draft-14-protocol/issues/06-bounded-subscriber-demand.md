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
