# ADR-0003: Validated endpoints above raw transport

- Status: Accepted
- Date: 2026-05-06

## Context

MOQT-family native QUIC endpoints are naturally URI-shaped. A native endpoint includes connection information such as host and port, and can also carry authority, path, and query information whose meaning differs by protocol profile.

For MOQT draft-14, native URI authority/path/query are sent in CLIENT_SETUP parameters. For MOQ Lite, there is no CLIENT_SETUP/SERVER_SETUP equivalent; URI-shaped values are connection/reconnect metadata, while broadcast paths are protocol message fields rather than transport endpoint fields.

Elixir's `URI.t()` is useful for parsing and representing URI-shaped input, but it is permissive and can represent values that are incomplete or invalid for `moqx` transport/session use.

The low-level `MOQX.Transport` behaviour currently exposes connection primitives in terms of host, port, options, and timeout. That boundary should remain focused on transport mechanics rather than MOQT endpoint semantics.

## Decision

Validate URI-shaped endpoint input above the raw transport boundary.

Variant-specific clients should initially accept strings or `URI.t()` values
directly and validate them at their public boundary. For example,
`MOQX.MOQLite04.connect/2` already implies the MOQ Lite draft-04
variant, so an additional endpoint struct carrying `protocol`, `profile`, or
`variant` would duplicate information already present in the module name.

Do not introduce `MOQX.Endpoint` for the first variant-specific client runner.
The module is deferred until a generic dispatcher such as `MOQX.connect/2`
needs a shared value that can select between protocol variants.

The validated URI should remain the source of truth for URI components already
represented by `URI.t()`, such as:

- scheme;
- authority;
- host;
- port;
- path;
- query.

Derived values should be exposed through functions where needed rather than
cached in a struct. For a variant-specific client, protocol defaults such as
ALPN come from the variant module or `MOQX.Transport.Profile`, not from the
URI value.

The raw transport API should continue to receive transport primitives:

- host;
- port;
- transport options;
- timeout.

Runtime transport selection and backend initialization options belong beside
the connect call, not in URI endpoint data. For example, a client runner may
accept `transport: {MOQX.Transport.Quicer, opts}` or
`transport: {MOQX.Transport.Support, opts}` while still validating the target
URI separately.

The transport layer should not own MOQT-family URI semantics such as path, query, authority SETUP parameters, reconnect URI behavior, broadcast paths, or scheme interpretation beyond what is necessary for connection setup.

Initial URI validation should reflect ADR-0002:

- accept native MOQT endpoint schemes only;
- require a host;
- apply explicit port/default-port rules;
- reject or clearly mark WebTransport/`https` endpoints as unsupported for now;
- preserve path and query for protocol-specific session establishment or reconnect handling;
- normalize authority consistently;
- select protocol-specific transport options, especially ALPN, without hard-coding them in `MOQX.Transport`.

## Consequences

Positive:

- User-facing APIs can be URI-friendly without contaminating the raw transport boundary.
- `MOQX.Transport` remains reusable and backend-focused.
- MOQT-family session code can retain path/query/authority information needed by draft-specific setup or reconnect logic.
- Invalid or unsupported endpoints can fail early with clear errors.
- Future WebTransport support can be represented as another endpoint transport mode without changing native QUIC primitives.
- Variant-specific clients avoid a redundant wrapper around `URI.t()`.
- Transport backend choice remains an explicit runtime dependency seam.

Tradeoffs:

- URI validation logic is initially owned by each variant-specific client rather
  than a shared endpoint module.
- URI scheme and default port rules must still be documented and tested.
- Session code must explicitly pass only host/port/options/capability choices to the transport adapter while retaining the rest of the endpoint for protocol setup or reconnect handling.

## Non-goals

This ADR does not decide:

- the final public connect/session API;
- exact native MOQT URI scheme names beyond initial native-only support;
- final default port rules;
- WebTransport endpoint behavior;
- MOQT SETUP parameter encoding;
- MOQ Lite reconnect or broadcast-path semantics.
- a generic `MOQX.Endpoint` struct or `MOQX.connect/2` dispatcher.
