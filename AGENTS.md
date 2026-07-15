- before committing, always run `mix format`, run the tests, run `mix credo --strict` (Elixir's linter), and refactor accordingly; ensure documentation stays consistent
- this redesign is based on QUIC via quicer and targets MOQT draft-14. Before making transport decisions, inspect quicer and the relevant MOQT draft text; use moqtail as an interop reference where useful, not as an implementation substrate
- this project is based on a series of MOQT IETF documents (linked in README), which should always be consulted before making decisions
- never use `Application` env as a test seam or mutable global configuration; prefer explicit arguments, pure modules, structs/options, behaviours passed directly, or dependency seams that do not require global state

## Agent skills

### Issue tracker

- GitHub Issues in `dmorn/moqx` are the only issue tracker and source of truth.
- Do not create local issue, PRD, backlog, or status files under `.scratch` or
  another repository directory.
- Prefer the GitHub app for issue reads and writes; use authenticated `gh` as a
  fallback when the app is unavailable for the repository.
- Before creating an issue, search both open and closed GitHub issues for
  duplicates or superseded work.
- "Publish to the issue tracker" means create or update a GitHub issue in
  `dmorn/moqx` and return its URL.
- "Fetch the relevant ticket" means read the referenced GitHub issue, including
  its current body, labels, state, and relevant comments.
- Use GitHub issue state and repository labels rather than a parallel local
  status vocabulary. Record blockers, dependencies, and deferrals in the issue
  body or comments and link related issue numbers explicitly.
- Close an issue only after its acceptance criteria are implemented and
  verified. Record follow-up work as a new linked GitHub issue rather than
  reopening completed work.
- Durable architecture decisions belong in `docs/adr/`; durable operating or
  development guidance belongs in the relevant tracked documentation, not in
  an issue-tracker mirror.

### Domain docs

- Read `CONTEXT.md` before protocol or transport work.
- Read relevant ADRs under `docs/adr/` before changing an area governed by a decision.
- If these files are absent, proceed silently.
- Use `CONTEXT.md` vocabulary in issue titles, proposals, hypotheses, and test names.
- If output contradicts an ADR, call out the contradiction explicitly.

### Transport testing

- `mix test`: fast hermetic contract/unit tests, including the support transport.
- `mix test --only integration`: real QUIC integration tests; caller starts `docker-compose.integration.yml`.
- `bench/moqxprobe` and `bench/quicprobe`: separate benchmark projects, not part of root `mix test`.
- `docs/adr/0009-*` governs benchmark evidence: closed-loop vs open-loop, metric names, windows, tiers, and report interpretation.
- `docs/adr/0008-*` governs functional `Conn`/`Stream` ownership and send-completion-as-credit.
- `bench/moqxprobe/README.md` is the runnable benchmark loop.
- Fake and loopback runs are calibration only. Real network claims require an explicit `quicprobe` target and an `iperf3` preflight on the same path.
- Delivery evidence is collected outside timed Benchee functions. Hot telemetry handlers stay bounded: no file IO, JSON encoding, payload copies, synchronous calls, per-event `Process.info/2`, or unbounded cardinality.
- Benchmark setup is explicit flags, not environment variables or mutable `Application` config.
- For docs-only or issue-only changes, skip the Elixir/Go build gates unless the user asks for them.
