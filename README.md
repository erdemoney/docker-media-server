# kickstArrt

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
into instant files via FUSE → \*arrs symlink them into the library → Jellyfin streams to clients.
Seerr handles user requests.

## Key features

- **Nothing stored locally** — imports are symlinks into the debrid mount: instant, zero disk usage
- **Automatic HTTPS** — Traefik issues a `*.DOMAIN` Let's Encrypt wildcard cert via Cloudflare
  DNS-01; every app UI ships on TLS, on the public internet and on LAN/Tailnet alike
- **Automated updates** — Renovate opens PRs, CI validates every change
- **Edge security** — CrowdSec WAF at Traefik, Cloudflare tunnel for WAN ingress
- **Single source of truth** — compose, configs, and docs in one repo; `just up` on any Docker host

## Quick start

```bash
git clone git@github.com:<you>/kickstarrt.git
cd kickstarrt
just init
# answers a few prompts for the secrets; remaining vars go in stacks/*/.env (see docs/quickstart.md)
just up
```

Requires Docker and [just](https://just.systems). Full setup guide and architecture details live
in the [wiki](https://erdemoney.github.io/kickstarrt/).
