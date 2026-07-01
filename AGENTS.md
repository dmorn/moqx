- before committing, always run `mix format`, run the tests, run `mix credo --strict` (Elixir's linter), and refactor accordingly; ensure documentation stays consistent
- this redesign is based on QUIC via quicer and targets MOQT draft-14. Before making transport decisions, inspect quicer and the relevant MOQT draft text; use moqtail as an interop reference where useful, not as an implementation substrate
- this project is based on a series of MOQT IETF documents (linked in README), which should always be consulted before making decisions
- never use `Application` env as a test seam or mutable global configuration; prefer explicit arguments, pure modules, structs/options, behaviours passed directly, or dependency seams that do not require global state

## Agent skills

### Issue tracker

Issues are tracked as local markdown files under `.scratch/`. See `docs/agents/issue-tracker.md`.

### Triage labels

Each issue carries a `Status:` line. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo: use root `CONTEXT.md` and `docs/adr/` when present. See `docs/agents/domain.md`.

### Transport testing

How the transport is verified and measured (contract tests, integration tests, and the `bench/moqxprobe` + `bench/quicprobe` evidence loop). See `docs/agents/transport-testing.md`.
