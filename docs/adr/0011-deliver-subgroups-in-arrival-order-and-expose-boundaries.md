# ADR-0011: Deliver subgroups in arrival order and expose boundaries

- Status: Accepted
- Date: 2026-07-27

## Context

MOQT objects can arrive on independent QUIC streams. A QUIC stream preserves
byte order within one subgroup, but neither MOQT draft-14 nor draft-16 promises
coordinate order across subgroups or groups. Both drafts explicitly allow
groups to arrive out of order.

Applications such as a live Membrane source need two distinct facts:

1. whether an object can be consumed immediately without waiting for another
   subgroup; and
2. whether a subgroup ended completely or might have missing objects.

A hidden global reorder buffer would add head-of-line blocking and would need
arbitrary byte, object, gap, and timeout limits. MOQT already provides the
appropriate subgroup boundary: FIN proves that every object in that subgroup
from the subscription start was received, while RESET means more objects may
exist.

## Decision

MOQX delivers subscribed objects immediately in the order in which the
protocol implementation processes normalized transport events.

- Objects decoded from one subgroup stream preserve that stream's order.
- No total coordinate, group, or cross-subgroup order is promised.
- Datagrams are delivered immediately and have no subgroup boundary.
- MOQX does not allocate a protocol-level reorder buffer. Applications that
  need stronger ordering own their buffer, limits, gap policy, and latency
  tradeoff.

MOQX exposes `%MOQX.Event.SubgroupEnded{}` after every object or status event
accepted from the corresponding stream:

- `outcome: :complete` means the peer sent FIN after a complete object. All
  subgroup objects from the subscription start were received.
- `outcome: :reset` means the peer reset the stream. More subgroup objects may
  exist; the subscription remains active.
- `outcome: :closed` means the stream closed without an observed FIN or reset.
  Completeness is unknown.
- `error_code` preserves a reset application error code when supplied by the
  transport.
- `end_of_group?` is true only when a complete FIN validates the protocol's
  end-of-group header bit. It identifies the final object location in the group;
  it does not prove that every other subgroup in that group has arrived.

A RESET or otherwise incomplete subgroup is still accounted as a processed
data stream for `PUBLISH_DONE` draining. The subgroup boundary is emitted
before a resulting `%MOQX.Event.SubscriptionDone{}`. A FIN in the middle of a
serialized object is a protocol failure rather than a complete boundary.

`ObjectStatus` and object `end_of_group?` metadata preserve the peer's semantic
markers, but MOQX does not infer missing groups, missing objects, or group
completion from coordinate gaps. If a stream reset arrives before enough of
its header is available to identify a subscription, no subgroup event can be
correlated; normal subscription delivery timeout remains the terminal fallback.

`ConnectionClosed` or `ProtocolFailed` abandons every still-open subgroup.
Consumers must release any buffers retained for that client when either event
arrives.

## Consequences

Positive:

- the default path preserves QUIC's independent-stream latency and requires no
  unbounded state;
- live consumers get an explicit release/abandon boundary per subgroup;
- terminal subscription events cannot overtake accepted subgroup delivery;
- reset handling follows the MOQT rule that one canceled data stream does not
  cancel the subscription;
- future sharded stream owners may process streams independently as long as
  each stream's event order and the boundary-before-terminal contract remain
  intact.

Tradeoffs:

- consumers that require total coordinate order must implement and bound it;
- there is no protocol-neutral group-complete event because MOQT does not
  enumerate all subgroups in advance;
- datagram delivery has no completeness boundary beyond object status,
  subscription termination, or connection termination.

## Alternatives rejected

### Global coordinate reordering by default

This would serialize independent streams, add head-of-line blocking, and require
limits that cannot be chosen correctly for every media format.

### Emit objects immediately without subgroup boundaries

This preserves latency but leaves live consumers unable to distinguish a
complete subgroup from a reset one.

### Treat RESET as subscription failure

The MOQT drafts state that RESET on one subscription data stream does not affect
other subgroups or the subscription.

## References

- [MOQT draft-14, Closing Subgroup Streams](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-14#section-10.4.3)
- [MOQT draft-16, Closing Subgroup Streams](https://datatracker.ietf.org/doc/html/draft-ietf-moq-transport-16#section-10.4.3)
- [Issue #29](https://github.com/dmorn/moqx/issues/29)
- `docs/adr/0010-compose-versioned-wire-packages-into-explicit-protocol-implementations.md`
