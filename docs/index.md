---
title: Overview
nav_order: 1
---

# Docker media stack

A self-hosted media stack run through Docker, with a single GitHub repo as the source of truth
for compose files, configs that live in code, and all setup/ops documentation. The same
checkout runs on any Docker host (a dedicated box, a VM, a NAS appliance, ...) — the only hard
prerequisites are Docker, `just`, and a directory for the repo. Platform-specific notes for one
concrete deployment live in `truenas.md` at the repo root; everything here stays host-agnostic.

```text
Internet
   │
   ▼
Cloudflare edge ── cloudflared (tunnel) ──> Traefik ─────┐
   (CDN bypass for media, WAF geolock,        │          │
    public hostnames)                          │          ▼
                                          CrowdSec (WAF/IP blocking)
                                                     │
   Docker network `external`                        ▼
   ┌───────────────────────────┐   Traefik routes by Host()   ┌────────────────────────────┐
   │  HTTP edge (443)          │────────────────────────────▶ │  Docker network `internal` │
   └───────────────────────────┘                              │   jellyfin  seerr          │
                                                              │   radarr    sonarr         │
   LAN / Tailnet ────────────► Traefik :443 (direct)          │   prowlarr  bazarr         │
                                                              │   profilarr decypharr      │
                                                              └────────────────────────────┘
```

Media flow: Prowlarr finds releases (incl. the Torrentio debrid indexer) → Sonarr/Radarr grab
them → Decypharr resolves debrid/Usenet into instant files on a FUSE mount → \*arrs import into
the ZFS library → Jellyfin streams to clients; Seerr handles requests from users.

## Repository layout

```text
stacks/                  compose files (one folder per stack) + .env per stack
  traefik/               edge router, CrowdSec container, plugin + ACME
  cloudflared/           WAN ingress (remotely-managed tunnel)
  media-server/          jellyfin, seerr, radarr, sonarr, prowlarr,
                         profilarr, bazarr, decypharr
  homarr/                dashboard
data/                    runtime config that lives in code
  traefik/               traefik.yml, dynamic.yml, crowdsec-acquis.yaml
.github/                 Renovate pipeline (workflow + global config)
scripts/                 helper scripts
docs/                    this wiki (GitHub Pages)
justfile                 ops recipes (just up, just update-all, ...)
```

## Page map

| Page                       | What it covers                                                       |
| -------------------------- | -------------------------------------------------------------------- |
| [Quickstart](quickstart)   | env files, where every secret comes from, first `just up`            |
| [Docker networking](arrs)  | shared networks, internal DNS names, API-key wiring between all apps |
| [Indexers](indexers)       | Prowlarr, the Torrentio debrid indexer, AltHub                       |
| [Decypharr](decypharr)     | debrid gateway: wizard, arr integration, mounts                      |
| [Ingress](ingress)         | Traefik + Cloudflare tunnel: public hostnames, cache bypass, geolock |
| [Security](security)       | CrowdSec WAF and IP blocking                                         |
| [Services](services)       | recommended debrid/Usenet subscriptions                              |
| [Updates](updates)         | Renovate PR pipeline end to end                                      |
| [Maintenance](maintenance) | day-to-day ops, backups, post-deploy checks                          |

All absolute host paths in this wiki are written as the compose env vars they map to —
`$SERVICES_DIR` (app configs) and `$DATA_DIR` (the media library) are defined per stack in
`stacks/*/.env`.

## External references

- Decypharr docs: <https://decypharr.com/guides>
- Torrentio indexer definition: <https://github.com/dreulavelle/Prowlarr-Indexers>
- Servarr wiki (Prowlarr quick start): <https://wiki.servarr.com/prowlarr/quick-start-guide>
- CrowdSec documentation: <https://docs.crowdsec.net>
