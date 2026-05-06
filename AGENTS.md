- before committing, ensure you `mix format`, run the tests, run `mix credo` (elixir's linter) and refactor accordingly; ensure documentation stays consistent
- this redesign is based on QUIC via quicer and targets MOQT draft-14. Before making transport decisions, inspect quicer and the relevant MOQT draft text; use moqtail as an interop reference where useful, not as an implementation substrate
- this project is based on a series of MOQT IETF documents (linked in README), which should always be consulted before making decisions

## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `dmorn/moqx`. See `docs/agents/issue-tracker.md`.

### Triage labels

Use the default five-label triage vocabulary. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo: use root `CONTEXT.md` and `docs/adr/` when present. See `docs/agents/domain.md`.
