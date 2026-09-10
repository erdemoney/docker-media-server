---
title: Quickstart
nav_order: 2
---

# Quickstart

Bring the stack up on a fresh Docker host, from a git checkout of this repo (clone it into
whatever directory will run the stack — e.g. `~/docker/media-server`). Edit on a dev box, commit,
and `git pull` on the server.

`just` and Docker are prerequisites. `just up` handles the ordering for you — it creates the
shared networks and the per-service config dirs (both idempotent), then brings every stack up.
Why the networks and dirs matter is covered in [The \*arrs](arrs).

## Fork first

This repo is meant to be **forked**. Fork it to your own GitHub account, then clone your fork —
that gives you a personal copy to customize (domain, secrets, service list) while still being able
to pull upstream improvements:

```bash
git clone git@github.com:<you>/docker-media-server.git ~/docker/media-server
cd ~/docker/media-server
git remote add upstream git@github.com:erdemoney/docker-media-server.git   # optional
```

## 1. Copy and fill the env files

Run `just init` — it creates each stack's `.env` and walks you through **every** variable:

- `CONFIG_DIR` is not asked: it is always the repo checkout's `data/` dir. App configs,
  `acme.json` and Traefik's rendered config live there, which is also what the restic
  backup covers — keeping them together is the whole point, so it isn't configurable
- `DOMAIN` is prompted once and synced to every stack that defines it (traefik, media-server)
- Subdomains default to the example values — Enter to keep, type to change;
  `ENV_PUID`/`ENV_PGID` instead propose the uid/gid of the user running `just` (Enter to
  use), so container files match your user — they fall back to `1000` if you run as root
- `ACME_EMAIL` is your Let's Encrypt account address — `just dirs` renders it into
  `traefik.yml`; leave it empty and no certificates will be issued
- `CROWDSEC_BOUNCER_API_KEY` is generated automatically (random 32-byte key)
- Prompts for a username/password and writes `TRAEFIK_DASHBOARD_CREDENTIALS`
- Explains each Cloudflare secret, then **confirms before opening the page in your
  browser** (and just shows the URL on a headless box), then prompts you to paste
  `CF_DNS_API_TOKEN` and `CLOUDFLARE_TUNNEL_TOKEN` — leave empty to do them later
- You can skip anything; empty answers fall back to the current/default value
- Finishes by asking whether to set up **restic repo backups to Cloudflare R2** — answer
  `y` to be prompted for the R2 account ID, bucket, API token, and encryption password
  (see [Maintenance](maintenance)), or skip (Enter) and fill `.env.backup` later

```bash
just init
```

Safe to re-run — it shows the current values and never overwrites without your say-so.

Set each variable (see `stacks/*/.env.example`):

| Variable                        | Where it lives | What it's for                                                    |
| ------------------------------- | -------------- | ---------------------------------------------------------------- |
| `DOMAIN`                        | traefik + media-server | apex domain; every `SUB_DOMAIN_*` entry extends it       |
| `SUB_DOMAIN_*`                  | per stack      | public subdomain per app, e.g. `jellyfin.<DOMAIN>`               |
| `CONFIG_DIR`                    | traefik + media-server | app config dir — derived, always the repo's `data/` dir  |
| `ACME_EMAIL`                    | traefik        | Let's Encrypt account address (rendered into `traefik.yml`)      |
| `ENV_PUID` / `ENV_PGID`         | media-server   | user/group owning the config dirs (init proposes the running user's ids) |
| `CF_DNS_API_TOKEN`              | traefik        | DNS-01 ACME for wildcard certs (see below)                       |
| `TRAEFIK_DASHBOARD_CREDENTIALS` | traefik        | dashboard basic-auth blob (see below)                            |
| `CROWDSEC_BOUNCER_API_KEY`      | traefik        | CrowdSec ↔ Traefik shared key (see below)                       |
| `CLOUDFLARE_TUNNEL_TOKEN`       | cloudflared    | remotely-managed tunnel token                                    |

## 2. Where the secrets come from

### `CF_DNS_API_TOKEN` — Cloudflare (wildcard TLS)

1. dash.cloudflare.com → **My Profile** → **API Tokens** → **Create Token**.
2. Use the **Edit zone DNS** template (or custom: Zone → DNS → **Edit** on `DOMAIN`).
3. Traefik uses it to create `_acme-challenge` TXT records for `*.DOMAIN` — nothing else.

Verify before first `up`:

```bash
curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer <token>"   # expect "status": "active"
```

### `TRAEFIK_DASHBOARD_CREDENTIALS` — htpasswd blob for `traefik.<DOMAIN>`

Not a token — a `user:hash` pair produced by `htpasswd`:

```bash
docker run --rm httpd:2.4-alpine htpasswd -nbB user 'ChangeMe-strong-password'
```

(No docker? `htpasswd -nbB` from `apache2-utils`, or `openssl passwd -apr1 'pass'` — Traefik
accepts both.)

`.env` gotcha: the `$2y$...` hash breaks compose interpolation, so **quote the whole value in
single quotes**:

```
TRAEFIK_DASHBOARD_CREDENTIALS='user:$2y$05$abcdefghijklmnopqrstuvwxyz0123456789'
```

Regenerate and recreate the traefik container if you ever lose it.

### `CROWDSEC_BOUNCER_API_KEY` — local random key

No dashboard to sign up for. Any random string works; both CrowdSec and Traefik use it to
authenticate over LAPI:

```bash
openssl rand -hex 32     # 64 hex chars
```

Paste into `stacks/traefik/.env`. It must be set **before** `just up`; after changing it,
recreate the `crowdsec` and `traefik` containers (`just update-all`). Details in
[Security](security).

### `CLOUDFLARE_TUNNEL_TOKEN` — Zero Trust tunnel

dash.cloudflare.com → **Zero Trust** → **Networks → Tunnels** → create a tunnel and copy its
token. How the tunnel's public hostnames route to Traefik is covered in [Ingress](ingress).

## 3. First boot

```bash
just up          # creates networks, config dirs, acme.json + traefik.yml, then brings up every stack
just ps          # confirm everything is running
```

App UIs live at `https://<subdomain>.<DOMAIN>`: `jellyfin`, `seerr`, `radarr`, `sonarr`,
`prowlarr`, `profilarr`, `bazarr`, `decypharr`, `traefik`.

## 4. What to check right after boot

- Traefik downloaded the CrowdSec plugin on first start (needs outbound internet); a
  `Certificate` appears in the ACME panel for `*.DOMAIN`.
- CrowdSec seeded its config under `$CONFIG_DIR/crowdsec/config` — see [Security](security).
- Jellyfin's admin account is created on first login (feed its key to Seerr later).

Then run `just wiring` on the server — it probes the internal network and prints
every URL + API key you need to paste, then continue to [The \*arrs](arrs) for
the full walkthrough.
