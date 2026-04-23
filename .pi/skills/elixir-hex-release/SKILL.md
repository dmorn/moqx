---
name: elixir-hex-release
description: Run a safe, repeatable Elixir library release flow (changelog, version bump, tag, GitHub release, Hex publish), including preflight checks and Hex package-name ownership validation.
---

# Elixir Hex Release

## When to use
- Releasing this repository as a new Hex version.
- User asks to "cut a release", "publish to hex", or "bump version + tag + release".

## Preflight (must pass first)
1. Confirm clean working tree:
   ```bash
   git status --short --branch
   ```
2. Run required project quality checks:
   ```bash
   mix format
   mix test
   mix test.integration
   mix docs
   mix credo --strict
   ```
3. Confirm intended release version (example: `0.1.1`).
4. Validate Hex package target and ownership:
   ```bash
   mix hex.info moqx
   # if authenticated:
   mix hex.owner list moqx
   ```
   - If package name already exists and you are not an owner, stop and choose a different package name in `mix.exs` (`package: [name: "..."]`).

## Release workflow
1. Update `CHANGELOG.md`: move `[Unreleased]` content into a new `## [X.Y.Z] - YYYY-MM-DD`
   section, then add a fresh empty `## [Unreleased]` above it.
2. Bump `version` in `mix.exs`.
3. If README install snippet includes a pinned version, update it.
4. Commit and push:
   ```bash
   git add CHANGELOG.md mix.exs README.md
   git commit -m "release: vX.Y.Z"
   git push
   ```
5. Create and push an annotated tag — **this is the only manual trigger needed**:
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```

The tag push triggers `.github/workflows/release.yml`, which automatically:
- Validates that the tag, `mix.exs` version, and `CHANGELOG.md` section all agree.
- Runs `mix format --check-formatted`, `mix test`, relay-backed `mix test.integration`,
  `mix docs`, and `mix credo --strict`.
- Publishes the package and docs to Hex.pm via `mix hex.publish --yes` (uses the
  `HEX_API_KEY` repository secret — no interactive 2FA needed).
- Creates or updates the GitHub release with notes extracted from `CHANGELOG.md`.

**Do not run `mix hex.publish` manually** — the CI workflow handles it.

## Notes for this repo
- Required before committing: `mix format`, `mix test`, `mix test.integration`, `mix docs`, `mix credo --strict`.
- Keep release notes aligned with `CHANGELOG.md` — the workflow will fail if a matching section is absent.

## Quick operator checklist
- [ ] Preflight checks pass (`mix format`, `mix test`, `mix test.integration`, `mix docs`, `mix credo --strict`)
- [ ] `CHANGELOG.md` updated (new versioned section + fresh `[Unreleased]` above it)
- [ ] `mix.exs` version bumped
- [ ] README install snippet updated
- [ ] Commit pushed
- [ ] Annotated tag created and pushed (`git tag -a vX.Y.Z -m "vX.Y.Z" && git push origin vX.Y.Z`)
- [ ] CI release workflow passes (Hex publish + GitHub release happen automatically)
