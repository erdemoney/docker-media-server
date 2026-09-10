# docker-media-server

Self-hosted media stack — Jellyfin, \*arrs, debrid gateway, Traefik, CrowdSec — orchestrated
with Docker Compose and driven by a single repo.

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

**Media flow:** Prowlarr finds releases → Sonarr/Radarr grab them → Decypharr resolves debrid
into instant files via FUSE → \*arrs hardlink into the library → Jellyfin streams to clients.
Seerr handles user requests.

## Key features

- **Hardlink-friendly layout** — imports are instant, zero extra disk usage
- **Automated updates** — Renovate opens PRs, CI validates every change
- **Edge security** — CrowdSec WAF at Traefik, Cloudflare tunnel for WAN ingress
- **Single source of truth** — compose, configs, and docs in one repo; `just up` on any Docker host

## Quick start

```bash
git clone git@github.com:<you>/docker-media-server.git
cd docker-media-server
for s in traefik cloudflared media-server homarr; do cp stacks/$s/.env.example stacks/$s/.env; done
# fill in .env files (see docs/quickstart.md for where every secret comes from)
just up
```

Requires Docker and [just](https://just.systems). Full setup guide and architecture details live
in the [wiki](https://erdemoney.github.io/docker-media-server/).
