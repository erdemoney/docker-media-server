---
title: Maintenance
nav_order: 11
---

# Maintenance and post-deploy checks

## Ops recipes (`justfile`)

| Command                         | What it does                                                                      |
| ------------------------------- | --------------------------------------------------------------------------------- |
| `just init`                     | create `.env` files and fill the interactive secrets (idempotent)                 |
| `just up`                       | create networks, config dirs, `acme.json` + rendered `traefik.yml`, then bring up every stack |
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
| `just validate`                 | `docker compose config -q` on every stack (read-only — never writes a `.env`)     |
| `just pull`                     | pull fresh images for every stack without recreating anything                     |
| `just config <stack>`           | print the fully resolved compose config for one stack                             |
| `just dirs`                     | create config dirs, `acme.json` (0600) + render `traefik.yml` (called by `just up`) |
| `just bootstrap-torrentio`      | install the Torrentio indexer definition into prowlarr (see [Indexers](indexers)) |
| `just wiring`                   | probe the internal network + print every URL/API key the \*arrs need (see [The \*arrs](arrs)) |
| `just networks`                 | create the shared `internal`/`external` networks                                  |
| `just backup-init`              | create the restic repository in `RESTIC_REPOSITORY` (idempotent; see below)      |
| `just backup` / `backup-list` / `backup-check` / `backup-prune` / `backup-restore` | restic snapshots, integrity, retention, restore — see [Repo backups](#offsite-restic-backups-of-the-repo) |

Formatting and linting are handled by **pre-commit** directly (`pre-commit install` once, then
hooks run automatically on every commit). The hooks cover YAML/JSON syntax and formatting, large
files, merge markers, case conflicts, private keys and staged-secret scanning; CI runs the same
set plus a full-history secret scan. Gitleaks is auto-downloaded by pre-commit on first run.

The update flow the repo is built around: Renovate opens a PR → merge → `git pull` +
`just update-all` (see [Updates](updates)); `just check-updates` gives the same picture from the
CLI.

## Traefik's config is rendered, not copied

Traefik cannot read env vars or templates in its **static** config, but `ACME_EMAIL` has to be
per-deployment. So the repo tracks `data/traefik/traefik.yml.template` and `just dirs` renders it
to `$CONFIG_DIR/traefik/traefik.yml` (untracked) with the value from `stacks/traefik/.env`:

- **edit the template**, never the rendered file — `just up` overwrites the output every run;
- `dynamic.yml` and `crowdsec-acquis.yaml` need no rendering and are mounted as tracked files
  (`dynamic.yml` resolves its one secret with Traefik's Go templating at runtime instead).

## Backups

This is a pure-debrid stack — the host holds nothing but config, so the whole backup story is
one target: the **config directory** (everything under `$CONFIG_DIR` — `acme.json`, the Traefik
configs, and each app's own state like the \*arr databases). Snapshot it frequently with your
storage's native mechanism.

Nothing in compose is precious — any container is one `just up` from a clean slate. The config
directory is the only state you can't rebuild; if you snapshot exactly one thing, snapshot that.

### Offsite restic backups of the repo

The native snapshots above cover that config state; the other state that can't be rebuilt from the repo's
`main` is the **repo working tree itself** — `stacks/*/.env` hold every secret and `data/` holds
runtime config. Back it up too, encrypted and deduplicated, with [restic](https://restic.net),
run in a container by `just` (nothing to install). One-time setup:

```
just init          # answer yes to the R2 restic step (or copy .env.backup.example -> .env.backup by hand)
just backup-init   # create the restic repository (idempotent)
just backup        # snapshot the repo; schedule it daily via a systemd timer or cron
```

`.env.backup` is passed to the container with `docker run --env-file`. `just init` configures
it for the documented backend, **Cloudflare R2** — zero egress, no minimums, same account as
the rest of this stack. (Backblaze B2 is cheaper raw storage; every backend works, but you're
on your own if you deviate — see below.)

#### Cloudflare R2 (the documented path)

1. `dash.cloudflare.com` → **R2** → **Create bucket** (e.g. `media-server-restic`; location
   Automatic).
2. **R2** → **Manage R2 API Tokens** → **Create API token** → **Admin read & write**. Save the
   **Access Key ID** and **Secret Access Key**, and note your **Account ID** (top of the R2 page).
3. Run `just init` and answer **yes** to "Configure R2 restic backups now?" — it prompts for the
   Account ID, bucket, and token, then writes `.env.backup`:

   ```
   RESTIC_REPOSITORY=s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET>
   RESTIC_PASSWORD=...
   AWS_ACCESS_KEY_ID=...
   AWS_SECRET_ACCESS_KEY=...
   AWS_DEFAULT_REGION=auto
   ```

   `AWS_DEFAULT_REGION` must stay `auto` — it's R2's only region. To configure by hand instead
   of re-running init, copy `.env.backup.example` to `.env.backup` and fill the same values.

#### Other backends (on you)

Any backend restic reaches over the network works with these recipes unchanged — set
`RESTIC_REPOSITORY` and the matching credentials yourself. (A `local dir`, `sftp:` or
`rclone:` repository additionally needs its path, key or config mounted into the restic
container, which the recipes don't do.)

| Backend       | `RESTIC_REPOSITORY` example               |
| ------------- | ----------------------------------------- |
| Backblaze B2  | `b2:my-bucket:my-path` (cheapest storage) |
| local dir     | `/mnt/backups/restic`                     |
| SFTP          | `sftp:user@host:/srv/restic`              |
| S3-compatible | `s3:s3.amazonaws.com/my-bucket`           |
| Azure / GCS   | `azure:container:/path` / `gs:bucket:/path` |
| rclone        | `rclone:remote:path`                      |

Credential vars live in `.env.backup` too (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`B2_ACCOUNT_ID`, `B2_ACCOUNT_KEY`, `RCLONE_CONFIG`, ...) and are forwarded the same way.
Snapshots **exclude `.git` and `.env.backup`**, so the unencrypted
`RESTIC_PASSWORD` is never stored inside the backups; keep that password somewhere safe or you
cannot restore anything.

Other recipes:

| Command                     | What it does                                               |
| --------------------------- | ---------------------------------------------------------- |
| `just backup-list`          | list snapshots                                             |
| `just backup-check`         | verify repository integrity (for a full audit run `restic check --read-data` manually) |
| `just backup-prune`         | `forget --prune` honoring `RESTIC_KEEP_*` in `.env.backup` |
| `just backup-restore [<id>]`| dry-run preview, then restore into the repo working tree (default: latest) |
| `just backup-schedule [<cal>]`| install a systemd timer running `just backup` (default `daily`; sudo) |
| `just backup-unschedule`    | stop and remove the installed systemd timer (sudo)         |

Schedule the routine snapshots with a **systemd timer** — better than cron here: journald captures
the output, and `Persistent=true` catches up on a backup that was skipped while the host was off:

```bash
just backup-schedule              # runs daily
just backup-schedule "*-*-* 04:30:00"   # custom calendar, re-run to change
```

This writes `restic-backup.{service,timer}` under `/etc/systemd/system` via sudo (with a
confirmation prompt), resolves your actual `just` path into `ExecStart`, and enables the timer.
On a host **without** systemd (Alpine, OpenWrt, a NAS scheduler), it prints the equivalent cron
line and exits non-zero — or use cron directly:

```
0 4 * * * cd /srv/docker-media-server && /usr/local/bin/just backup
```

`systemctl list-timers restic-backup.timer` shows the next run; `just backup-unschedule` removes
the units.

`just backup-restore` is **non-destructive**: it dry-runs first, prints exactly what would be
restored/updated, and asks for confirmation before writing anything. Files present locally but
missing from the snapshot are kept (no `--delete`); restored files overwrite current ones in
place. It re-creates the repo working tree (`data/` + all `.env` files); `.env.backup` survives
restores. Drill a restore into a scratch clone periodically — an untested backup is a gamble.
Fragile-chain warning: `$CONFIG_DIR` is the repo's own `data/` dir, so restic already covers
everything this host can't rebuild — the \*arr databases included. What it does *not* protect
against is a thief taking the box: that needs the snapshots to live somewhere else, which is
what the R2 repository above is for.

> **`data/` is untracked app state.** Never `git clean` on the server — `-dfx` removes ignored
> files, i.e. the whole config state. `git pull`/`reset --hard` are safe (they only touch tracked
> files). And keep the working tree clean (no uncommitted changes) before `just backup-restore`,
> otherwise restored versions of the tracked `data/traefik/*.yml` show up as diffs.

## Post-deploy checks

These are the outstanding items from first bring-up — do them once, then forget:

- **Jellyfin libraries** — Decypharr's FUSE mount is already reachable from `jellyfin`, `sonarr`,
  `radarr`, and `bazarr` (`- /mnt/debrid:/mnt:rslave`), so all that's left is adding
  the libraries in the Jellyfin UI pointing at subpaths of it (see [The \*arrs](arrs)). If those
  paths look empty inside the containers, check mount propagation (see [Decypharr](decypharr)).
- **Root folders** in Radarr/Sonarr must point at paths the containers can actually reach.
- **Jellyfin transcoding** — point *Playback → Transcode path* at `/transcodes` (a tmpfs, so
  transcode scratch never hits disk) and enable VAAPI/QSV hardware acceleration; `/dev/dri` is
  already passed in (see [Hardware](index#hardware) if the host has no iGPU).
- **ACME/TLS** — confirm `*.DOMAIN` cert appears in Traefik's ACME panel after first up (needs a
  working `CF_DNS_API_TOKEN` **and** a non-empty `ACME_EMAIL`; `just dirs` warns if it's blank).
  `$CONFIG_DIR/traefik/acme.json` must be a 0600 *file* — `just dirs` guarantees that, because a
  directory there (what docker creates for a missing bind source) silently breaks cert storage.
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
