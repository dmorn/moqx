# ADR-0008: Functional Conn and Stream ownership

- Status: Accepted
- Date: 2026-06-12

## Context

`MOQX.Transport` is a functional boundary over native QUIC. Calls receive
explicit state and return updated state instead of owning OTP processes or
using global configuration. This keeps protocol reducers and transport contract
tests deterministic.

The stream pressure work in #45 and #46 exposed a design pressure point. QUIC
streams are independent byte streams, but the current transport state shape
stores connection registry state, stream registry state, stream pending-send
queues, and finished-send markers in one caller-owned context. That encourages
one process to send on many streams, receive every stream completion, and then
re-enter a global pump. This is a poor fit for high-pressure object publishing,
where each stream can be modeled as a demand-driven component whose send budget
is replenished by backend send-completion feedback.

At the `quicer`/MsQuic boundary, stream send completion is backend/buffer
feedback. It is not peer delivery or application acknowledgement. For streams,
`send_complete` returns the send context to the process that called
`:quicer.async_send/3`. For DATAGRAMs, the current transport path is already
admission-driven and intentionally avoids per-DATAGRAM send-state messages in
the hot path. The remaining architectural problem is stream ownership and
stream-local completion correlation.

The library is still pre-stable. Backward compatibility is not a constraint;
the transport API should use the cleanest names and ownership model now.

## Decision

Keep `MOQX.Transport` as a functional core. Do not move OTP supervision,
GenStage, process mailboxes, or benchmark-specific pump logic into the
transport library.

Rename the connection vocabulary to `Conn` and use it consistently. The
transport API must not expose both `MOQX.Transport.Conn` and
`MOQX.Transport.Connection`.

Use the connection hierarchy as the public mental model:

```text
MOQX.Transport
MOQX.Transport.Conn
MOQX.Transport.Conn.Stream
MOQX.Transport.Conn.Stream.Info
MOQX.Transport.Conn.Stream.Send
MOQX.Transport.Conn.Stream.Sender
```

`MOQX.Transport.Conn` owns connection-scoped functional state and operations:

- connect, accept, and handshake;
- local address and negotiated capabilities;
- opening and accepting streams;
- DATAGRAM local admission and DATAGRAM receive events;
- connection close and connection-level events;
- connection-level ownership transfer where supported.

`MOQX.Transport.Conn.Stream` is the stable stream handle. Stream-scoped
functional state lives under the same namespace. In particular,
`MOQX.Transport.Conn.Stream.Sender` owns send-side completion-credit state and
operations:

- stream metadata, including direction, initiator, local role, and side
  availability;
- send-side pending send correlation;
- backend send-completion and cancellation handling;
- receive-side data/event handling where the stream has a receive side;
- FIN, RESET_STREAM, STOP_SENDING, and stream lifecycle events.

A single `Conn.Stream` data structure represents bidirectional streams,
locally initiated unidirectional streams, and peer-initiated unidirectional
streams. Direction and side availability are data in
`Conn.Stream.Info`, not separate top-level modules.

Stream send completion is modeled as stream-local backend credit:

- `send/3` returns once the backend accepts the send request;
- `send_complete` releases the accepted send token from the stream's pending
  queue;
- completion is not peer-delivery proof;
- process architectures above transport may use completion feedback as demand
  credit, but delivery must be observed separately.

The broad caller-owned context is decomposed into narrower functional state.
One logical owner updates one state value at a time:

- a connection process may own a `Conn`;
- a stream sender or stream process may own a `Conn.Stream`;
- protocol session reducers remain process-free and consume normalized
  transport events/actions.

The transport layer may provide primitives that make ownership transfer and
stream checkout explicit, but those primitives remain functional data
transitions. OTP process trees and GenStage stages are built above them.

## Benchmark Impact

Existing stream and mixed benchmark results remain valid evidence for the old
transport shape, but they are not closure evidence for the new stream ownership
model.

After this refactor, the benchmark harness must re-baseline stream and mixed
workloads because these changes can alter:

- stream completion event ownership;
- sender mailbox pressure;
- completion batch cadence;
- in-flight window accounting;
- the ability to run one sender process per stream;
- same-run reference-relative goodput and control latency.

At the time of this refactor, the active remote harness used
`transport-bench-v1` as its durable output format. That output contract is now
legacy for the removed remote lab workflow; current follow-up measurements use
the Benchee-based `bench/moqxprobe` loop and should still identify sender
topology, such as single-pump versus per-stream sender ownership.

## Consequences

Positive:

- Transport names align with the real hierarchy: connection first, streams
  scoped under a connection.
- Stream-local state can support process architectures that exploit QUIC stream
  independence without putting OTP inside the transport core.
- `send_complete` semantics stay explicit as backend credit, not delivery.
- DATAGRAM and stream send semantics remain deliberately distinct where the
  protocol differs.
- The protocol session layer can stay a pure reducer above transport actions.

Tradeoffs:

- This is a breaking transport API refactor.
- Existing tests, support transport fixtures, protocol reducers, and benchmark
  tooling must be migrated in one coherent slice rather than kept in a mixed
  naming state.
- Remote benchmark baselines need to be refreshed after the new stream
  ownership topology exists.

## Non-goals

This ADR does not decide:

- a production OTP supervision tree;
- exact GenStage modules for stream senders;
- a permanent benchmark pass/fail threshold;
- relay/listener-side performance architecture;
- WebTransport support.
