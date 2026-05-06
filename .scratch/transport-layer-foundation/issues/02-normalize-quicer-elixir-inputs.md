# Normalize quicer Elixir inputs

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Harden the `quicer` adapter so Elixir callers can use Elixir-friendly values while backend-specific Erlang details remain hidden behind `MOQX.Transport`.

This should specifically address Erlang `string()` values being charlists and ensure host, listener, ALPN, and option inputs are normalized before calling `:quicer`.

## Acceptance criteria

- [ ] Hostnames accepted as Elixir strings are converted before they reach `:quicer` APIs that expect Erlang strings.
- [ ] IP tuple hosts continue to work.
- [ ] Textual listener inputs, if supported by the transport API, follow the same Elixir-facing convention.
- [ ] ALPN values can be supplied as Elixir-friendly values and are converted for `:quicer` as needed.
- [ ] ALPN is not hard-coded to MOQT draft-14; callers can select protocol-specific ALPN such as `moq-00` or a MOQ Lite ALPN token.
- [ ] Binary stream and datagram payloads remain binaries and are not converted as text.
- [ ] Tests prove the adapter hides charlist-specific behavior from Elixir callers.

## Blocked by

None - can start immediately

## Comments
