<div align="center">

# kickstArrt

**A self-hosted media stack that runs itself.** Jellyfin + the \*arrs + a debrid gateway, fronted
by Cloudflare, guarded by CrowdSec, terminated by Traefik — all defined in one repo and brought
up with a single command.

[![CI](https://img.shields.io/github/actions/workflow/status/erdemoney/kickstarrt/ci.yml?logo=githubactions&logoColor=white&label=CI)](https://github.com/erdemoney/kickstarrt/actions)
[![Docs](https://img.shields.io/badge/docs-wiki-blue?logo=readthedocs&logoColor=white)](https://erdemoney.github.io/kickstarrt/)
[![Stack](https://img.shields.io/badge/stack-Docker%20Compose-2496ED?logo=docker&logoColor=white)](https://docs.docker.com/compose/)
[![TLS](https://img.shields.io/badge/tls-Let%27s%20Encrypt-2E8B57?logo=letsencrypt&logoColor=white)](https://letsencrypt.org)
[![WAF](https://img.shields.io/badge/waf-CrowdSec-brightgreen)](https://www.crowdsec.net)
[![Tooling](https://img.shields.io/badge/tooling-just-66459B)](https://just.systems)

</div>

---

kickstArrt wires together everything a media library needs — **instant, debrid-based streaming
that keeps nothing on disk**, automatic TLS, and edge security — as code. The whole stack runs
on one Docker host, and the same checkout deploys to a dedicated box, a VM, or a NAS appliance.

## Architecture

```
             Internet
                │
                ▼
  Cloudflare edge ─── CDN bypass for media · WAF geolock · Access auth
                │
                ▼
      cloudflared (tunnel)
                │
                ▼
  Traefik ────────► CrowdSec   edge WAF / IP blocking
                │
     ┌──────────┴──────────┐
     ▼                     ▼
LAN / Tailnet       Docker "internal" network
(→ Traefik :443)   ┌─────────────────────────┐
                   │ jellyfin     seerr      │
                   │ radarr       sonarr     │
                   │ prowlarr     bazarr     │
                   │ profilarr    decypharr  │
                   └─────────────────────────┘
```

**The media loop:** Prowlarr finds releases → Sonarr/Radarr grab them → Decypharr resolves the
torrent against your debrid provider into instant FUSE files → the \*arrs symlink them into the
library → Jellyfin streams to any client. Zero local storage, immediately playable.

## Services

| Service     | Role |
| ----------- | ---- |
| `traefik`   | TLS edge & reverse proxy — routes every hostname, issues the wildcard Let's Encrypt cert |
| `crowdsec`  | WAF / IP reputation — blocks scanners at the edge before they reach an app |
| `cloudflared` | Cloudflare tunnel — public hostnames reach the box with no open ports |
| `jellyfin`  | Media server & streaming to web, TV, and mobile clients |
| `seerr`     | User request manager — "want this movie" in one click |
| `radarr` / `sonarr` | Movies and TV automation — grabbing, renaming, library sync |
| `prowlarr`  | Indexer manager, synced to the \*arrs |
| `bazarr`    | Subtitle search & management |
| `profilarr` | Quality-profile sync (trash-guides) |
| `decypharr` | Debrid gateway — resolves grabs to instant FUSE streams |

## Key features

- **Nothing stored locally** — imports are symlinks into the debrid mount: instant, near-zero
  disk usage
- **Automatic TLS** — Traefik issues a `*.DOMAIN` Let's Encrypt wildcard via Cloudflare DNS-01;
  every app UI ships on HTTPS over the internet and on LAN/Tailnet alike
- **Edge security** — CrowdSec WAF inside Traefik, Cloudflare tunnel for ingress, and optional
  Cloudflare Access identity fronting per-hostname
- **Automated upkeep** — Renovate opens dependency PRs and CI validates every change (compose +
  pre-commit + a full secret-history scan)
- **One command to deploy** — `just init` fills the secrets, `just up` creates networks and
  config dirs and starts the stack; back it all up with the built-in restic recipes

## Quick start

> **Note:** this repo is meant to be **forked** — fork it (keep the fork **private**), then
> clone your fork. Your deployment secrets never touch the repo; they live in git-ignored
> `.env` files that `just init` creates.

```bash
git clone git@github.com:<you>/kickstarrt.git
cd kickstarrt
just init      # walks every secret; Enter accepts sensible defaults
just up        # networks → config dirs → the whole stack
```

Requires [Docker](https://docs.docker.com/engine/install/) (check the
[post-install steps](https://docs.docker.com/engine/install/linux-postinstall/) to run it
non-root) and [just](https://just.systems/man/en/chapter_4.html) — `cargo install just`, a distro
package, or the [release binaries](https://github.com/casey/just/releases).
The full walkthrough — Cloudflare zone, tunnel, DNS secrets, staging CA, first bring-up — is in
the [Quickstart](https://erdemoney.github.io/kickstarrt/quickstart).

## Docs

- [**Quickstart**](https://erdemoney.github.io/kickstarrt/quickstart) — prerequisites, fork, first bring-up
- [**Services**](https://erdemoney.github.io/kickstarrt/services) · [**The \*arrs**](https://erdemoney.github.io/kickstarrt/arrs) · [**Decypharr**](https://erdemoney.github.io/kickstarrt/decypharr) · [**Indexers**](https://erdemoney.github.io/kickstarrt/indexers)
- [**Ingress**](https://erdemoney.github.io/kickstarrt/ingress) — tunnel, TLS, geolock, media caching
- [**Security**](https://erdemoney.github.io/kickstarrt/security) — CrowdSec + Cloudflare Access
- [**Maintenance**](https://erdemoney.github.io/kickstarrt/maintenance) — backups, restic, restores
- [**Updates & CI**](https://erdemoney.github.io/kickstarrt/updates) — Renovate, validation, releases