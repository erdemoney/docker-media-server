---
title: Quickstart
nav_order: 2
---

# Quickstart

Bring the stack up on a fresh Docker host, from a git checkout of this repo (clone it into
whatever directory will run the stack — e.g. `~/docker/kickstarrt`). Edit on a dev box, commit,
and `git pull` on the server.

`just` and Docker are prerequisites. Need Docker? Follow the official
[Docker Engine install guide](https://docs.docker.com/engine/install/) for your distro — it
covers the `docker compose` plugin too — then the
[post-installation steps](https://docs.docker.com/engine/install/linux-postinstall/) to run
`docker` as a non-root user (`usermod -aG docker` and a re-login). `just up`
handles the ordering for you — it creates the
shared networks and the per-service config dirs (both idempotent), then brings every stack up.
Why the networks and dirs matter is covered in [The \*arrs](arrs).

## Fork first

This repo is meant to be **forked**. Fork it to your own GitHub account, then clone your fork —
that gives you a personal copy to customize while still being able to pull upstream improvements.
**Make the fork `Private`** (Settings → change visibility) — it
deploys this stack from your fork, and a misstep that commits a secret to a public fork leaks it
to the world:

```bash
git clone git@github.com:<you>/kickstarrt.git ~/docker/kickstarrt
cd ~/docker/kickstarrt
git remote add upstream git@github.com:erdemoney/kickstarrt.git   # optional
```

## 1. Copy and fill the env files

Run `just init` — it creates each stack's `.env` and walks you through **every** variable:

- `CONFIG_DIR` isn't asked: it's automatically set to a full path to this repo's `data/` dir,
  where app configs, `acme.json`, and Traefik's rendered config live (and what the restic
  backup covers). It isn't user-configurable — the `just` recipes expect the repo-defined place
- `DOMAIN` is prompted once and synced to every stack that defines it (traefik, media-server)
- Subdomains default to the example values — Enter to keep, type to change;
  `ENV_PUID`/`ENV_PGID` instead propose the uid/gid of the user running `just` (Enter to
  use), so container files match your user — they fall back to `1000` if you run as root
- `ACME_EMAIL` defaults to `admin@<DOMAIN>` — Enter accepts it. There is **no Let's Encrypt
  account to register** (Traefik creates one over ACME on first start) and the address needn't
  receive mail, but it can't be a fake domain like `example.com` — their API rejects those.
  See [Ingress](ingress#there-is-no-lets-encrypt-account-to-create)
- `CROWDSEC_BOUNCER_API_KEY` is generated automatically (random 32-byte key)
- Prompts for a username/password and writes `TRAEFIK_DASHBOARD_CREDENTIALS`
- Explains each Cloudflare secret, then **confirms before opening the page in your
  browser** (and just shows the URL on a headless box), then prompts you to paste
  `CLOUDFLARE_DNS_TOKEN` and `CLOUDFLARE_TUNNEL_TOKEN` — leave empty to do them later
- You can skip anything; empty answers fall back to the current/default value
- Finishes by asking whether to set up **restic repo backups to Cloudflare R2** — answer
  `y` to be prompted for the R2 account ID, bucket, API token, and encryption password
  (see [Maintenance](maintenance)), or skip (Enter) and fill `.env.restic` later

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
| `CLOUDFLARE_DNS_TOKEN`              | traefik        | DNS-01 ACME for wildcard certs (see below)                       |
| `TRAEFIK_DASHBOARD_CREDENTIALS` | traefik        | dashboard basic-auth blob (see below)                            |
| `CROWDSEC_BOUNCER_API_KEY`      | traefik        | CrowdSec ↔ Traefik shared key (see below)                       |
| `CLOUDFLARE_TUNNEL_TOKEN`       | cloudflared    | remotely-managed tunnel token                                    |

## 2. Where the secrets come from

### `CLOUDFLARE_DNS_TOKEN` — Cloudflare (wildcard TLS)

This token *is* the entire Let's Encrypt prerequisite — DNS-01 is how Traefik proves it owns
`*.DOMAIN`. Nothing has to be set up at Let's Encrypt itself; see
[Ingress → Certificates](ingress#certificates-automatic).

1. dash.cloudflare.com → **My Profile** → **API Tokens** → **Create Token**.
2. Use the **Edit zone DNS** template (or custom: Zone → DNS → **Edit** on `DOMAIN`).
3. **Zone Resources** → **Include** → **Specific zone** → your `DOMAIN` (least privilege; not
   "All zones"). **Client IP Address Filtering** is optional — **Is in / Include** allow-lists the
   stated IPs (token usable only from them), while **Is not in / Exclude** *exempts* them (token
   still works from every other IP). The token is used **from the server's outbound IP**, and
   "Use my IP" inserts **your** public IP — the egress of whatever you're browsing from, not the
   server's. So unless the server exits through a **static** IP you allow-list, leave filtering
   off: a filter that doesn't match the server breaks every ACME renewal, and an *exclude* rule
   only shadows your own browsing IP. **TTL** is optional (notBefore/notAfter dates; default: no
   expiry) — if you set an end date, remember nothing in this stack rotates the token, so an
   expired one kills renewals until you replace it in `stacks/traefik/.env`.
4. Traefik uses it to create and delete `_acme-challenge` TXT records for `*.DOMAIN` — nothing
   else; those records are short-lived (~120s TTL) and fully automatic.

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

> **The stack is LAN-only until you add tunnel hostnames — use that window.** Nothing here is
> public yet and nothing becomes public until you expose it in [Ingress](ingress), and that's
> intentional: an app that's live on the internet *before* its setup is done is an app with no
> login, claimable by anyone. Do all setup through [LAN access](lan-access), then expose apps as
> the **last** step — see the
> [security gate](ingress#security-gate--finish-setup-before-going-public) in Ingress.

## 4. What to check right after boot

- Traefik downloaded the CrowdSec plugin on first start (needs outbound internet); a
  `Certificate` appears in the ACME panel for `*.DOMAIN`.
- CrowdSec seeded its config under `$CONFIG_DIR/crowdsec/config` — see [Security](security).
- Jellyfin's admin account is created on first login (feed its key to Seerr later).

Reach the stack first — [LAN access](lan-access) resolves every app's URL on a LAN/VPN client
and verifies the cert — then run `just wiring` on the server (it probes the internal network and
prints every URL + API key you need to paste) and continue to [The \*arrs](arrs) for the full
walkthrough. All first-run setup happens over LAN, before anything is public.
