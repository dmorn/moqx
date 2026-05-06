# ADR-0003: Validated endpoints above raw transport

- Status: Accepted
- Date: 2026-05-06

## Context

MOQT native QUIC endpoints are naturally URI-shaped. A native MOQT URI includes connection information such as host and port, and can also carry authority, path, and query information that may matter to MOQT session establishment and SETUP parameters.

Elixir's `URI.t()` is useful for parsing and representing URI-shaped input, but it is permissive and can represent values that are incomplete or invalid for `moqx` transport/session use.

The low-level `MOQX.Transport` behaviour currently exposes connection primitives in terms of host, port, options, and timeout. That boundary should remain focused on transport mechanics rather than MOQT endpoint semantics.

## Decision

Use validated endpoint values above the raw transport boundary.

A future endpoint module should parse and validate URI-shaped input, likely using a struct such as:

```elixir
%MOQX.Endpoint{
  uri: %URI{},
  scheme: :moqt,
  host: "relay.example.com",
  port: 4433,
  authority: "relay.example.com:4433",
  path: "/live",
  query: "track=video",
  transport: :native_quic
}
```

Public/session APIs may accept strings or `URI.t()` values and convert them into validated endpoints.

The raw transport API should continue to receive transport primitives:

- host;
- port;
- transport options;
- timeout.

The transport layer should not own MOQT-specific URI semantics such as path, query, authority SETUP parameters, or scheme interpretation beyond what is necessary for connection setup.

Initial endpoint validation should reflect ADR-0002:

- accept native MOQT endpoint schemes only;
- require a host;
- apply explicit port/default-port rules;
- reject or clearly mark WebTransport/`https` endpoints as unsupported for now;
- preserve path and query for future MOQT session establishment;
- normalize authority consistently.

## Consequences

Positive:

- User-facing APIs can be URI-friendly without contaminating the raw transport boundary.
- `MOQX.Transport` remains reusable and backend-focused.
- MOQT session code can retain path/query/authority information needed by draft-specific setup logic.
- Invalid or unsupported endpoints can fail early with clear errors.
- Future WebTransport support can be represented as another endpoint transport mode without changing native QUIC primitives.

Tradeoffs:

- A dedicated endpoint validation layer is required instead of passing `%URI{}` directly everywhere.
- Endpoint defaults and scheme rules must be documented and tested.
- Session code must explicitly pass only host/port/options to the transport adapter while retaining the rest of the endpoint for protocol setup.

## Non-goals

This ADR does not decide:

- the final public connect/session API;
- exact native MOQT URI scheme names beyond initial native-only support;
- final default port rules;
- WebTransport endpoint behavior;
- MOQT SETUP parameter encoding.
