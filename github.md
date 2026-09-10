# GitHub / Renovate update pipeline

[Renovate](https://ghcr.io/renovatebot/renovate) runs self-hosted in a GitHub Actions
workflow and opens pull requests that bump the pinned image tags in `stacks/*/compose.yaml`.
You review/merge the PR, then pull and re-recreate on TrueNAS.

This is the "true automation" upgrade over the local `just check-updates` (which stays useful
for a quick CLI look). Bumps happen as reviewable PRs instead of by hand.

## How it works

- `.github/workflows/renovate.yml` runs daily at `06:00 UTC` (and on manual
  `workflow_dispatch`).
- `.github/renovate.json` is the **global** Renovate config (it lives under `.github/` so
  Renovate treats it as global config with self-hosted options — a root-level `renovate.json`
  would be treated as _repo_ config, which forbids global-only options like `repositories`).
  It restricts Renovate to the `docker-compose` manager, so it only looks at `image:` lines
  in the compose files. Config summary:
  - `config:recommended` — sane global defaults
  - `repositories` — `erdemoney/docker-media-server` (self-hosted Renovate needs the repo
    told explicitly; the Action does not auto-discover)
  - `gitAuthor` — commits are authored as `renovate[bot]` (avoids Mend's default
    unsigned-commit warning)
  - `schedule: ["* 6 * * *"]` — only act in the 06:00 UTC window
  - minor/patch bumps are **grouped into one PR**; major bumps each get their own PR
  - `automerge: false` everywhere — nothing is merged without you
  - no dependency dashboard (keeps the token simple; pending updates are visible via
    Renovate PRs or `just check-updates`)
- Renovate keeps our deliberate pin philosophy: it bumps exact tags (`:v3.4.1` -> `:v3.5.0`),
  never turns them into floating `:latest`.

## Prerequisites

- The repo is hosted on GitHub (it is: `github.com/erdemoney/docker-media-server`).
- A Personal Access Token with write access to this repo, stored as the
  `RENOVATE_TOKEN` Actions secret:
  1. Create a token at <https://github.com/settings/tokens>:
     - Classic: scope `repo` (simplest).
     - Fine-grained: `Contents`, `Pull requests`, `Issues` = read/write, restricted to this repo.
  2. Store it once: `gh secret set RENOVATE_TOKEN` (run in the repo root).

  (GitHub App install is _not_ needed — this is the self-hosted action setup, which only
  needs the PAT.)

## First-time onboarding

1. Add `.github/renovate.json` and `.github/workflows/renovate.yml` (already in this repo).
2. Set the `RENOVATE_TOKEN` secret (above).
3. Push everything: `git push origin main`.
4. Run once manually: GitHub -> Actions -> _Renovate_ -> _Run workflow_, or wait for the
   cron. The first run opens PRs for any outdated tags.

Because the global config already exists on the default branch, there's no "onboarding" PR —
Renovate goes straight to scanning. If every image is already current (see
`just check-updates`), there are simply no PRs yet — the first ones appear when a newer tag
is published.

## Day-to-day flow (on TrueNAS)

```
# 1. On GitHub: review + merge the Renovate PR
# 2. On the NAS:
git pull
just update-all        # recreate changed containers
```

Because tags are pinned and images are pulled on demand, a merged minor/patch PR is safe to
apply whenever. Major-bump PRs deserve release-note reading first.

## Accelerators / notes

- Newer tags today: `just check-updates` lists them and exits non-zero when any exist.
- Each container can also be recreated alone: `just update-svc media-server jellyfin`.
- Merging a PR from the CLI: `gh pr merge --merge <pr#>`. To merge + pull + update in one go
  from a laptop, run:
  ```
  gh pr checkout <pr#> && git push origin HEAD:main             # or just click Merge
  ssh trunas 'cd /mnt/storage/docker/stacks && git pull && just update-all'
  ```

## Troubleshooting

- No PRs? Check the _Renovate_ run under Actions — the log states exactly what Renovate saw
  (e.g. `Dependency extraction complete ... depCount`).
- Token expired/wrong? `gh secret set RENOVATE_TOKEN` again, then re-run via
  `workflow_dispatch`.
- Want to validate the config locally before pushing:
  ```
  docker run --rm -v "$PWD":/repo ghcr.io/renovatebot/renovate:latest \
      renovate-config-validator /repo/.github/renovate.json
  ```
