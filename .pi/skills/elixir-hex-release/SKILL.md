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
1. Update `CHANGELOG.md` with a new version section and release date.
2. Bump `version` in `mix.exs`.
3. If README install snippet includes pinned version, update it.
4. Commit:
   ```bash
   git add CHANGELOG.md mix.exs README.md
   git commit -m "release: vX.Y.Z"
   git push
   ```
5. Create and push annotated tag:
   ```bash
   git tag -a vX.Y.Z -m "vX.Y.Z"
   git push origin vX.Y.Z
   ```
6. Publish to Hex (required):
   ```bash
   mix hex.publish
   ```
   - For first release of a package, this step is the authoritative publication.
   - If Hex publication requires interactive OTP/2FA input, **do not run it automatically**.
     Pause and explicitly ask the user to run `mix hex.publish` themselves.
7. Publish docs (recommended):
   ```bash
   mix hex.docs
   ```
8. Create GitHub release (optional):
   ```bash
   gh release create vX.Y.Z --title "<project> vX.Y.Z" --notes-file /tmp/release-notes.md
   ```

## Notes for this repo
- Required before committing: `mix format`, `mix test`, `mix test.integration`, `mix docs`, `mix credo`.
- Existing tag/release operations may happen independently, but Hex publication is the critical ship step.
- Keep release notes aligned with `CHANGELOG.md`.

## Operator interaction directive
- For any command that requires interactive secrets/2FA (especially `mix hex.publish`), stop and ask the user to execute it manually.
- The assistant may prepare everything up to that point (commit, tag, push, docs), then hand off with exact next command(s).

## Quick operator checklist
- [ ] Preflight checks pass (`mix format`, `mix test`, `mix test.integration`, `mix docs`, `mix credo --strict`)
- [ ] Changelog updated
- [ ] `mix.exs` version bumped
- [ ] Commit pushed
- [ ] Tag created and pushed
- [ ] `mix hex.publish` completed
- [ ] `mix hex.docs` completed (recommended)
- [ ] GitHub release created/published (optional)
