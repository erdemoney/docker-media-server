---
title: Decypharr
nav_order: 6
---

# Decypharr (debrid gateway)

Decypharr mounts your debrid provider as a FUSE filesystem and exposes qBittorrent- and
SABnzbd-compatible APIs, so Sonarr/Radarr see "instant" debrid files instead of a download
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

Config is written to `$CONFIG_DIR/decypharr/configs/config.json`.

## Visibility of the mount

FUSE mounts made inside the container propagate to the host at `/mnt/decypharr` (the `:rshared`
bind). If the arr containers don't yet mount that path, add a shared bind to Sonarr and Radarr so
they can import:

```yaml
# both services, same host path as Decypharr uses
- /mnt/decypharr:/mnt/decypharr
```

## Integration with Sonarr/Radarr

1. **Download clients** (see also [The \*arrs](arrs)) — with both protocols configured, add
   Decypharr **twice** in each arr:
   - **qBittorrent** (`Decypharr (debrid)`) — debrid downloads.
   - **SABnzbd** (`Decypharr (usenet)`) — only if you're using Usenet; set **URL base
     `/sabnzbd`**.
   - Both share the same values: host `decypharr`, port `8282`, username = the **arr's own URL**
     (`http://sonarr:8989` / `http://radarr:7878`), password = the **arr's own API key**,
     category `sonarr` / `radarr`. Set different priorities to prefer one protocol over the
     other.
2. **Outbound** — Decypharr → Settings → **Arrs**: it auto-detects apps that hit it; give each
   arr's host (`http://sonarr:8989`, not the public URL) and API key.
3. **Path mapping** — if the arr's import path differs from Decypharr's mount path, set one on
   the download client: Remote path `/mnt/decypharr` → Local path (what the arr sees), e.g.
   `/media/tv`.
4. **Repair worker / queue cleanup** — enable in Settings → Arrs (the blacklist + research
   defaults are sensible) so failed grabs don't clog the queue.

## Reference

- Decypharr docs: <https://decypharr.com/guides> (wizard, arr integration, mounts, troubleshooting)
