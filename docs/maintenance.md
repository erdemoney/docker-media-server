---
title: Maintenance
nav_order: 11
---

# Maintenance and post-deploy checks

## Ops recipes (`justfile`)

| Command                         | What it does                                                                      |
| ------------------------------- | --------------------------------------------------------------------------------- |
| `just up`                       | create networks + config dirs, then bring up every stack                          |
| `just down`                     | tear every stack down                                                             |
| `just update-all`               | pull fresh images + recreate changed containers                                   |
| `just update <stack>`           | pull + recreate one stack, e.g. `just update traefik`                             |
| `just up-svc <stack> <svc>`     | recreate one service, e.g. `just up-svc media-server jellyfin`                    |
| `just update-svc <stack> <svc>` | pull + recreate one service                                                       |
| `just check-updates`            | compare pinned tags against registries; exits 1 if anything is newer              |
| `just images` / `just df`       | local images / disk usage                                                         |
| `just ps`                       | list running containers                                                           |
| `just logs <stack>`             | tail logs for a stack                                                             |
| `just restart <stack>`          | restart a stack                                                                   |
| `just validate`                 | `docker compose config -q` on every stack                                         |
| `just dirs`                     | pre-create + chown service config dirs (idempotent; called by `just up`)          |
| `just bootstrap-torrentio`      | install the Torrentio indexer definition into prowlarr (see [Indexers](indexers)) |
| `just networks`                 | create the shared `internal`/`external` networks                                  |

Formatting and linting are handled by **pre-commit** directly (`pre-commit install` once, then
hooks run automatically on every commit — same scope as CI: syntax + secret scanning). Gitleaks
is auto-downloaded by pre-commit on first run (no manual install needed).

The update flow the repo is built around: Renovate opens a PR → merge → `git pull` +
`just update-all` (see [Updates](updates)); `just check-updates` gives the same picture from the
CLI.

## Backups

Take your storage's native snapshot/backup mechanism to the following:

- **frequent on the config directory** (everything under `$SERVICES_DIR`, includes `acme.json`);
  it changes and matters.
- **daily/weekly on the media library.** Keep the schedules separate — don't mix config
  snapshots with bulk media.

Nothing in compose is precious — any container is one `just up` from a clean slate. The config
directory is the only state you can't rebuild; if you snapshot exactly one thing, snapshot that.

## Post-deploy checks

These are the outstanding items from first bring-up — do them once, then forget:

- **Jellyfin media access** — the compose mounts only `/config`. To serve libraries (and let the
  *arrs import into them), add the media binds to the `jellyfin` *and\* `sonarr`/`radarr` services
  (e.g. `${DATA_DIR}:/media` or per-subfolder mounts), then point root folders at those paths and
  add the libraries in the Jellyfin UI.
- **Root folders** in Radarr/Sonarr must match the bind mounts you actually give the containers.
- **Homarr dashboard** — add widgets backed by the apps at their **internal** URLs
  (`http://sonarr:8989`, ...); Homarr is on the same network, so service names resolve.
- **ACME/TLS** — confirm `*.DOMAIN` cert appears in Traefik's ACME panel after first up (needs a
  working `CF_DNS_API_TOKEN`).
- **CrowdSec** — confirm the bouncer authed: `docker exec crowdsec cscli bouncers list`
  (see [Security](security)).

## GPU (NVIDIA)

If the compose gives Jellyfin a GPU, verify it's actually attached:

```bash
docker exec jellyfin nvidia-smi
```

Hardware specifics (driver injection, host updates) are host-dependent.

## Troubleshooting

| Symptom                                      | Fix                                                                            |
| -------------------------------------------- | ------------------------------------------------------------------------------ |
| Renovate opened no PRs                       | see [Updates](updates) troubleshooting                                         |
| New indexer/app link fails                   | check the URL+port against the [internal DNS table](arrs); revisit the API key |
| Bouncer not blocking                         | recreate crowdsec + traefik after a key change; `cscli bouncers list`          |
| Traefik won't start after this repo's change | first start downloads plugins — check outbound internet; `just validate` first |
| Something in one container only              | `just update-svc <stack> <svc>` after a tag bump, don't `down` the stack       |
