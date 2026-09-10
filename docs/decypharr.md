---
title: Decypharr
nav_order: 6
---

# Decypharr (debrid gateway)

Decypharr mounts your debrid provider as a FUSE filesystem and exposes a qBittorrent- and
SABnzbd-compatible API, so Sonarr/Radarr see "instant" debrid/Usenet files instead of a download
queue. It runs from the media-server stack (`cy01/blackhole:v2.5`) with the fuse mount plumbing
in the compose (`/mnt/:/mnt:rshared`, `/dev/fuse`, `SYS_ADMIN`, `apparmor:unconfined`).

## First-run setup wizard

Visit `https://decypharr.<DOMAIN>` once:

- **Authentication** — create admin username/password. The **API token is shown once** after
  setup completes: save it (it is the "password" in the arr download-client config below).
- **Debrid providers** — add at least one (Real-Debrid, AllDebrid, Debrid-Link, Torbox,
  Premiumize) with its API key. Torbox also provides Usenet (see [Services](services)).
- **Usenet (optional)** — add NNTP server details only if downloading from Usenet.
- **Mount configuration** — pick **DFS**, mount path `/mnt/decypharr` (what the \*arrs will import
  from), and a cache dir.

Config is written to `$SERVICES_DIR/decypharr/configs/config.json`.

## Visibility of the mount

FUSE mounts made inside the container propagate to the host at `/mnt/decypharr` (the `:rshared`
bind). If the arr containers don't yet mount that path, add a shared bind to Sonarr and Radarr so
they can import:

```yaml
# both services, same host path as Decypharr uses
- /mnt/decypharr:/mnt/decypharr
```

## Integration with Sonarr/Radarr

1. **Download client** (see also [The \*arrs](arrs)) — add Decypharr as a **qBittorrent** client:
   - Host `decypharr`, port `8282`
   - Username: the **arr's own URL** (`http://sonarr:8989` / `http://radarr:7878`)
   - Password: the **arr's own API key**
   - Category `sonarr` / `radarr`, priority `0`
2. **Outbound** — Decypharr → Settings → **Arrs**: it auto-detects apps that hit it; give each
   arr's host (`http://sonarr:8989`, not the public URL) and API key.
3. **Path mapping** — if the arr's import path differs from Decypharr's mount path, set one on
   the download client: Remote path `/mnt/decypharr` → Local path (what the arr sees), e.g.
   `/media/tv`.
4. **Repair worker / queue cleanup** — enable in Settings → Arrs (the blacklist + research
   defaults are sensible) so failed grabs don't clog the queue.

Usenet-only setups can skip the debrid gateway and point the Sabnzbd client straight at
`sabnzbd:8080`.

## Reference

- Decypharr docs: <https://decypharr.com/guides> (wizard, arr integration, mounts, troubleshooting)
