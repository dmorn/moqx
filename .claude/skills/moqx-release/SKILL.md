---
name: moqx-release
description: Cut a moqx release — bump version, update CHANGELOG, commit, tag, push. CI handles Hex publish and GitHub release automatically.
argument-hint: [version]
---

# moqx Release

Releases are tag-driven. Pushing an annotated `vX.Y.Z` tag triggers
`.github/workflows/release.yml`, which runs preflight checks, publishes to
Hex.pm (`mix hex.publish --yes` via `HEX_API_KEY` secret), and creates the
GitHub release. **No manual `mix hex.publish` needed.**

## Steps

### 1. Preflight

```bash
git status --short --branch          # must be clean, on main
mix format --check-formatted
mix test
MOQX_RELAY_CACERTFILE=.tmp/integration-certs/ca.pem mix test.integration
mix docs
mix credo --strict
```

If the relay container is not running, start it first:

```bash
scripts/generate_integration_certs.sh .tmp/integration-certs
docker compose -f docker-compose.integration.yml up -d relay
```

If integration tests fail with TLS errors (`BadSignature`, `UnknownIssuer`),
recreate the relay container — it may have stale certs:

```bash
docker compose -f docker-compose.integration.yml down --remove-orphans
docker compose -f docker-compose.integration.yml up -d relay
```

### 2. Decide the version

| Signal | Version bump |
|:---|:---|
| Breaking change in public API or message shapes | **minor** (0.X.0) |
| New non-breaking features | **minor** (0.X.0) while pre-1.0 |
| Bug fixes / docs only | **patch** (0.0.X) |

Current version is in `mix.exs`. Confirm the `[Unreleased]` section of
`CHANGELOG.md` to understand what's shipping.

### 3. Update files

**`CHANGELOG.md`** — rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD`
and add a fresh `## [Unreleased]` above it.

**`mix.exs`** — bump `version:`.

**`README.md`** — update the install snippet (`{:moqx, "~> X.Y.Z"}`).

### 4. Commit, tag, push

```bash
git add CHANGELOG.md mix.exs README.md
git commit -m "release: vX.Y.Z"
git push

git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z
```

The tag push is the only trigger CI needs. Monitor the run:

```bash
gh run list --workflow=release.yml --limit 3
gh run watch   # stream the active run
```

### 5. Verify

Once CI is green:

```bash
mix hex.info moqx   # confirm new version appears
gh release view vX.Y.Z
```

## What CI does (do not do these manually)

- Validates tag == `mix.exs` version == `CHANGELOG.md` section heading
- Runs `mix format --check-formatted`, unit tests, relay-backed integration tests, `mix docs`, `mix credo --strict`
- `mix hex.publish --yes` (publishes package + docs)
- Creates/updates the GitHub release with notes extracted from `CHANGELOG.md`

## Quick checklist

- [ ] Working tree clean, on `main`
- [ ] Preflight passes locally
- [ ] `CHANGELOG.md` updated (versioned section + fresh `[Unreleased]`)
- [ ] `mix.exs` version bumped
- [ ] `README.md` install snippet updated
- [ ] Commit pushed
- [ ] Annotated tag created and pushed
- [ ] CI release workflow green
