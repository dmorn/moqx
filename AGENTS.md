- before committing, always run `mix format`, run the tests, run `mix credo --strict` (Elixir's linter), and refactor accordingly; ensure documentation stays consistent
- this redesign is based on QUIC via quicer and targets MOQT draft-14. Before making transport decisions, inspect quicer and the relevant MOQT draft text; use moqtail as an interop reference where useful, not as an implementation substrate
- this project is based on a series of MOQT IETF documents (linked in README), which should always be consulted before making decisions
- never use `Application` env as a test seam or mutable global configuration; prefer explicit arguments, pure modules, structs/options, behaviours passed directly, or dependency seams that do not require global state

## Agent skills

### Issue tracker

- Local issues and PRDs live under `.scratch/<feature-slug>/`.
- PRD path: `.scratch/<feature-slug>/PRD.md`.
- Issue path: `.scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`.
- Each issue carries a `Status:` line near the top.
- Append conversation/progress under `## Comments`.
- "Publish to the issue tracker" means create the appropriate `.scratch/<feature-slug>/...` file.
- "Fetch the relevant ticket" means read the referenced path or issue number.

### Triage labels

- `needs-triage`: not yet evaluated.
- `needs-info`: blocked waiting on information.
- `ready-for-agent`: fully specified for an AFK agent.
- `ready-for-human`: needs judgement, access, or risk acceptance.
- `done`: implemented and verified.
- `wontfix`: will not be actioned.
- Record follow-up work as a new issue rather than reopening `done`.

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
