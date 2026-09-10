---
title: Updates
nav_order: 10
---

# Updates: Renovate pipeline

[Renovate](https://ghcr.io/renovatebot/renovate) runs self-hosted in a GitHub Actions workflow
and opens pull requests that bump the pinned image tags in `stacks/*/compose.yaml`. Review and
merge the PR, then pull and re-create the containers on the server. It's the automation upgrade
over the local `just check-updates` (which stays useful for a quick CLI look).

## How it works

- `.github/workflows/renovate.yml` runs daily at `06:00 UTC` (and on manual
  `workflow_dispatch`).
- `.github/renovate-config.json` is the **global** config. The basename deliberately avoids the
  auto-discovered repo-config names (`renovate.json`, `.renovaterc`, ...) so Renovate loads it as
  _global_ config — the only place global-only options like `repositories` are accepted. It
  restricts Renovate to the `docker-compose` manager (only `image:` lines).
- minor/patch bumps are grouped into one PR; **major** bumps each get their own PR.
- `automerge: false` — nothing merges without you.
- A **dependency dashboard** issue lists every managed image and which have updates pending; the
  schedule/blocker per dependency can be toggled via issue comments.
- Pins are preserved: bumps go `:v3.4.1` → `:v3.5.0`, never `:latest`.

## Prerequisites (one time)

1. Repo hosted on GitHub (it is).
2. A **Personal Access Token** with write access, stored as the `RENOVATE_TOKEN` Actions secret:
   - Create at <https://github.com/settings/tokens>.
   - Classic: scope `repo` (simplest — includes branch push).
   - Fine-grained: `Contents`, `Pull requests`, `Issues` all **read and write** (read alone fails
     with `Write access to repository not granted` because Renovate pushes branches), restricted
     to this repo.
3. Store it once: `gh secret set RENOVATE_TOKEN` (from the repo root).

A GitHub App install is _not_ needed — this is the self-hosted action setup.

## First onboarding

1. `.github/renovate-config.json` + `.github/workflows/renovate.yml` already exist on `main`.
2. Set the `RENOVATE_TOKEN` secret (above).
3. Run once manually: GitHub → Actions → **Renovate** → _Run workflow_, or wait for the cron.
   The first run opens PRs for any outdated tags. If every image is already current there are
   simply no PRs yet — the first ones appear when a newer tag is published. (No "onboarding"
   PR, because the global config already exists on the default branch.)

## Day-to-day flow

```
# 1. On GitHub: review + merge the Renovate PR
# 2. On the server running the stack:
git pull
just update-all        # recreate changed containers
```

Minor/patch PRs are safe to apply whenever (pinned tags, images pulled on demand). Major-bump
PRs deserve reading the release notes first.

## Troubleshooting

- **No PRs?** Check the Renovate run under Actions — its log states exactly what it saw
  (e.g. `Dependency extraction complete ... depCount`).
- **`Write access to repository not granted`** at push time: token needs `Contents: read and
write` (fine-grained) or `repo` (classic), allowed on this repository.
- **Token expired/wrong**: `gh secret set RENOVATE_TOKEN` again, then re-run via
  `workflow_dispatch`.
- **Validate config locally before pushing**:

  ```bash
  docker run --rm -v "$PWD":/repo ghcr.io/renovatebot/renovate:latest \
      renovate-config-validator /repo/.github/renovate-config.json
  ```
