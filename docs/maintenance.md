---
title: Maintenance
nav_order: 11
---

# Maintenance and post-deploy checks

## Ops recipes (`justfile`)

| Command                         | What it does                                                                      |
| ------------------------------- | --------------------------------------------------------------------------------- |
| `just init`                     | create `.env` files and fill the interactive secrets (idempotent)                 |
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
| `just wiring`                   | probe the internal network + print every URL/API key the \*arrs need (see [The \*arrs](arrs)) |
| `just networks`                 | create the shared `internal`/`external` networks                                  |
| `just backup-init`              | create the restic repository in `RESTIC_REPOSITORY` (idempotent; see below)      |
| `just backup` / `backup-list` / `backup-check` / `backup-prune` / `backup-restore` | restic snapshots, integrity, retention, restore — see [Repo backups](#repo-backups-with-restic) |

Formatting and linting are handled by **pre-commit** directly (`pre-commit install` once, then
hooks run automatically on every commit — same scope as CI: syntax + secret scanning). Gitleaks
is auto-downloaded by pre-commit on first run (no manual install needed).

The update flow the repo is built around: Renovate opens a PR → merge → `git pull` +
`just update-all` (see [Updates](updates)); `just check-updates` gives the same picture from the
CLI.

## Backups

Take your storage's native snapshot/backup mechanism to the following:

- **frequent on the config directory** (everything under `$CONFIG_DIR`, includes `acme.json`);
  it changes and matters.
- **daily/weekly on the media library.** Keep the schedules separate — don't mix config
  snapshots with bulk media.

Nothing in compose is precious — any container is one `just up` from a clean slate. The config
directory is the only state you can't rebuild; if you snapshot exactly one thing, snapshot that.

### Offsite restic backups of the repo

The native snapshots above cover the data; the other state that can't be rebuilt from the repo's
`main` is the **repo working tree itself** — `stacks/*/.env` hold every secret and `data/` holds
runtime config. Back it up too, encrypted and deduplicated, with [restic](https://restic.net),
run in a container by `just` (nothing to install). One-time setup:

```
just init          # answer yes to "restic backups" (or copy .env.backup.example -> .env.backup by hand)
just backup-init   # create the restic repository (idempotent)
just backup        # snapshot the repo; schedule it daily via a systemd timer or cron
```

`.env.backup` is passed to the container with `docker run --env-file`, so it only contains restic's
standard shell variables — **backend-agnostic**. Set `RESTIC_REPOSITORY` to whatever you use:

| Backend       | `RESTIC_REPOSITORY` example               |
| ------------- | ----------------------------------------- |
| local dir     | `/mnt/backups/restic`                     |
| SFTP          | `sftp:user@host:/srv/restic`              |
| S3-compatible | `s3:s3.amazonaws.com/my-bucket`           |
| Backblaze B2  | `b2:my-bucket:my-path`                    |
| Azure / GCS   | `azure:container:/path` / `gs:bucket:/path` |
| rclone        | `rclone:remote:path`                      |

Backends that need credentials get them added to `.env.backup` too (`AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY`, `B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`, `RCLONE_CONFIG`, ...) — they are
forwarded the same way. Snapshots **exclude `.git` and `.env.backup`**, so the unencrypted
`RESTIC_PASSWORD` is never stored inside the backups; keep that password somewhere safe or you
cannot restore anything.

Other recipes:

| Command                     | What it does                                               |
| --------------------------- | ---------------------------------------------------------- |
| `just backup-list`          | list snapshots                                             |
| `just backup-check`         | verify repository integrity (add `--read-data` for a full audit) |
| `just backup-prune`         | `forget --prune` honoring `RESTIC_KEEP_*` in `.env.backup` |
| `just backup-restore [<id>]`| restore into the repo working tree (default: latest)       |

A daily systemd timer (place both units in `/etc/systemd/system/`):

```ini
# restic-backup.timer
[Unit]
Description=Nightly restic backup of the media repo

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# restic-backup.service
[Unit]
Description=Nightly restic backup of the media repo

[Service]
Type=oneshot
WorkingDirectory=/srv/docker-media-server
ExecStart=/usr/local/bin/just backup
```

`just backup-restore` re-creates the repo working tree (`data/` + all `.env` files); `.env.backup`
survives restores. Drill a restore into a scratch clone periodically — an untested backup is a
gamble. Fragile-chain warning: this protects the repo, and native snapshots protect `$CONFIG_DIR`
+ media, but a thief taking the box still wants you to have *remote* copies of `$CONFIG_DIR` too —
if that's your threat model, point a second restic profile at it (see [The \*arrs](arrs)).

## Post-deploy checks

These are the outstanding items from first bring-up — do them once, then forget:

- **Jellyfin media access** — the compose mounts only `/config`. To serve libraries (and let the
  *arrs import into them), bind Decypharr's FUSE mount into `jellyfin` *and\* `sonarr`/`radarr`
  (`- /mnt/decypharr:/mnt/decypharr`), then point root folders at subpaths of it and add the
  libraries in the Jellyfin UI (see [The \*arrs](arrs)).
- **Root folders** in Radarr/Sonarr must point at paths the containers can actually reach.
- **ACME/TLS** — confirm `*.DOMAIN` cert appears in Traefik's ACME panel after first up (needs a
  working `CF_DNS_API_TOKEN`).
- **CrowdSec** — confirm the bouncer authed: `docker exec crowdsec cscli bouncers list`
  (see [Security](security)).

## Troubleshooting

| Symptom                                      | Fix                                                                            |
| -------------------------------------------- | ------------------------------------------------------------------------------ |
| Renovate opened no PRs                       | see [Updates](updates) troubleshooting                                         |
| New indexer/app link fails                   | check the URL+port against the [internal DNS table](arrs); revisit the API key |
| Bouncer not blocking                         | recreate crowdsec + traefik after a key change; `cscli bouncers list`          |
| Traefik won't start after this repo's change | first start downloads plugins — check outbound internet; `just validate` first |
| Something in one container only              | `just update-svc <stack> <svc>` after a tag bump, don't `down` the stack       |
