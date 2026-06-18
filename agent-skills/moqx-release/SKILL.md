---
name: moqx-release
description: Cut a moqx release by bumping version, updating CHANGELOG, committing, tagging, and pushing. CI handles Hex publish and GitHub release automatically.
argument-hint: [version]
---

# moqx Release

Releases are tag-driven. Pushing an annotated `vX.Y.Z` tag triggers
`.github/workflows/release.yml`, which runs preflight checks, publishes to
Hex.pm through the `HEX_API_KEY` secret, and creates the GitHub release. Do not
run `mix hex.publish` manually.

## Steps

### 1. Preflight

```bash
git status --short --branch
mix format --check-formatted
mix test
mix credo --strict
mix hex.build
```

The working tree must be clean and on `main`.

Hex packages cannot depend on Git/path deps. If `quicer` is still sourced from
a fork by Git, publish the fork as a Hex dependency or switch release-time
metadata to a Hex-publishable `quicer` package before cutting a release.

### 2. Decide the version

| Signal | Version bump |
|:---|:---|
| Breaking change in public API or message shapes | minor, `0.X.0` |
| New non-breaking features | minor, `0.X.0` while pre-1.0 |
| Bug fixes or docs only | patch, `0.0.X` |

Current version is in `mix.exs`. Confirm the `[Unreleased]` section of
`CHANGELOG.md` to understand what is shipping.

### 3. Update files

- `CHANGELOG.md`: rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and
  add a fresh `## [Unreleased]` above it.
- `mix.exs`: bump `version:`.
- `README.md`: update the install snippet, for example `{:moqx, "~> X.Y.Z"}`.

### 4. Commit, tag, push

```bash
git add CHANGELOG.md mix.exs README.md
git commit -m "release: vX.Y.Z"
git push

git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

Monitor the run:

```bash
gh run list --workflow=release.yml --limit 3
gh run watch
```

### 5. Verify

```bash
mix hex.info moqx
gh release view vX.Y.Z
```

## Quick Checklist

- [ ] Working tree clean, on `main`
- [ ] Preflight passes locally
- [ ] `CHANGELOG.md` updated
- [ ] `mix.exs` version bumped
- [ ] `README.md` install snippet updated
- [ ] Commit pushed
- [ ] Annotated tag created and pushed
- [ ] CI release workflow green
