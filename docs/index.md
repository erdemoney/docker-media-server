---
title: Overview
nav_order: 1
---

# kickstArrt

A self-hosted media stack run through Docker, with a single GitHub repo as the source of truth
for compose files, configs that live in code, and all setup/ops documentation. The same
checkout runs on any Docker host (a dedicated box, a VM, a NAS appliance, ...) — the only hard
prerequisites are Docker, `just`, and a directory for the repo. Everything here stays
host-agnostic.

```text
                        Internet
                           |
                           v
               Cloudflare edge (CDN bypass for media, WAF geolock)
                           |
                     cloudflared (tunnel)
                           |
                        Traefik ----> CrowdSec (WAF / IP blocking)
                           |
               ------------+------------
               |                         |
               v                         v
        LAN / Tailnet              Docker "internal" network
        (direct to Traefik)        +------------------------+
                                   | jellyfin    seerr      |
                                   | radarr      sonarr     |
                                   | prowlarr    bazarr     |
                                   | profilarr   decypharr  |
                                   +------------------------+
```

Media flow: Prowlarr finds releases (incl. the Torrentio debrid indexer) → Sonarr/Radarr grab
them → Decypharr resolves debrid/Usenet into instant files on a FUSE mount → \*arrs import into
the library on the debrid mount → Jellyfin streams to clients; Seerr handles requests from users.

**HTTPS comes out of the box.** Traefik's ACME provider creates the DNS-01 challenge through
Cloudflare (`CLOUDFLARE_DNS_TOKEN`) and issues a **Let's Encrypt wildcard certificate for
`*.DOMAIN`**, automatically renewed — so every service's UI is served over TLS, whether it's
reached from the public internet, LAN, or Tailnet. No per-app TLS configuration is involved.

## Hardware

A streaming-only setup like this doesn't need much. An **Intel N100 or N150 mini PC** (~$100–150
new) handles it comfortably: 4 low-power cores, hardware HEVC/AV1 decode for Jellyfin
transcoding, fanless, and sips ~6W idle. Pair it with 8–16 GB RAM and a small NVMe for the OS and
config — this stack streams from debrid and never stores a media library on the host.

The compose passes `/dev/dri` into Jellyfin so that iGPU is actually used. **If your host has no
`/dev/dri`** (a VM without GPU passthrough, or a CPU with no iGPU) the container will refuse to
start — delete the `devices:` block from the `jellyfin` service in
`stacks/media-server/compose.yaml` and it falls back to CPU transcoding.

## Operating system

**Debian** (stable) is the safe default — minimal, long support cycles, and every Docker guide
assumes it. If you're running Proxmox, spin up a Debian **LXC container** instead of a full VM;
it shares the host kernel (so Docker works natively) and uses a fraction of the RAM and disk a
VM would.

## Repository layout

```text
stacks/                  compose files (one folder per stack) + .env per stack
  traefik/               edge router, CrowdSec container, plugin + ACME
  cloudflared/           WAN ingress (remotely-managed tunnel)
  media-server/          jellyfin, seerr, radarr, sonarr, prowlarr,
                         profilarr, bazarr, decypharr
data/                    runtime config that lives in code
  traefik/               traefik.yml, dynamic.yml, crowdsec-acquis.yaml
.github/                 CI checks (workflow) + Renovate pipeline (workflow + global config)
docs/                    this wiki (GitHub Pages)
justfile                 ops recipes (just up, just update-all, ...)
```

## Page map

| Page                       | What it covers                                                       |
| -------------------------- | -------------------------------------------------------------------- |
| [Quickstart](quickstart)   | env files, where every secret comes from, first `just up`            |
| [The \*arrs](arrs)         | shared networks, internal DNS names, API-key wiring between all apps |
| [Indexers](indexers)       | Prowlarr, the Torrentio debrid indexer, AltHub                       |
| [Decypharr](decypharr)     | debrid gateway: wizard, arr integration, mounts                      |
| [Ingress](ingress)         | Traefik + Cloudflare tunnel: public hostnames, cache bypass, geolock |
| [Security](security)       | CrowdSec WAF and IP blocking                                         |
| [Services](services)       | recommended debrid/Usenet subscriptions                              |
| [Updates](updates)         | Renovate PR pipeline + CI checks end to end                          |
| [Maintenance](maintenance) | day-to-day ops, backups, post-deploy checks                          |

All absolute host paths in this wiki are written as the compose env vars they map to —
`$CONFIG_DIR` (app configs) is the repo's own `data/` dir, written into `stacks/traefik/.env`
and `stacks/media-server/.env` by `just init`. Media is served from the
debrid FUSE mount, so there is no local media directory to configure.

## Additional services

The core stack covers media acquisition, management, and streaming. A few extras pair well if you
want them — drop a compose file into `stacks/` and they'll join the same `internal` network
automatically once you add the folder to `stack_list` in the justfile (and to the stack loop
in `.github/workflows/ci.yml`):

- **Homarr** (`ghcr.io/homarr-labs/homarr`) — lightweight dashboard with widgets for each app.
  Point it at the internal service URLs (`http://sonarr:8989`, ...) and it just works.
- **qBittorrent** — if you prefer local torrents over debrid, add it as an alternative download
  client alongside Decypharr.
- **SABnzbd** — same idea for Usenet: add it as a **Sabnzbd** download client in the \*arrs
  (Decypharr already exposes a compatible API, but a local SABnzbd gives you real Usenet
  downloads to the filesystem).

## External references

- Decypharr docs: <https://decypharr.com/guides>
- Torrentio indexer definition: <https://github.com/dreulavelle/Prowlarr-Indexers>
- Servarr wiki (Prowlarr quick start): <https://wiki.servarr.com/prowlarr/quick-start-guide>
- CrowdSec documentation: <https://docs.crowdsec.net>
