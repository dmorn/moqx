# Normalize quicer Elixir inputs

Status: needs-triage
Type: AFK

## Parent

`.scratch/transport-layer-foundation/PRD.md`

## What to build

Harden the `quicer` adapter so Elixir callers can use Elixir-friendly values while backend-specific Erlang details remain hidden behind `MOQX.Transport`.

This should specifically address Erlang `string()` values being charlists and ensure host/listener/option inputs are normalized before calling `:quicer`.

## Acceptance criteria

- [ ] Hostnames accepted as Elixir strings are converted before they reach `:quicer` APIs that expect Erlang strings.
- [ ] IP tuple hosts continue to work.
- [ ] Textual listener inputs, if supported by the transport API, follow the same Elixir-facing convention.
- [ ] Binary stream and datagram payloads remain binaries and are not converted as text.
- [ ] Tests prove the adapter hides charlist-specific behavior from Elixir callers.
- [ ] Any MOQT-relevant default options handled at the transport boundary are documented.

## Blocked by

None - can start immediately

## Comments
