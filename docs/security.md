---
title: Security
nav_order: 8
---

# Security: CrowdSec IP blocking + Cloudflare Access auth

CrowdSec runs in the **traefik stack** (edge — it's the layer that sees all public traffic).
Traefik's access log feeds the detection engine; a Traefik middleware plugin enforces the
decisions per router.

## Components

- `crowdsec` container (`crowdsecurity/crowdsec:v1.8.1`) — analysis engine + LAPI on the
  `internal` network at `crowdsec:8080`. It reads Traefik's JSON access log via
  `$CONFIG_DIR/traefik/crowdsec-acquis.yaml` (tracked in the repo at `data/traefik/`).
- Traefik plugin `bouncer` — the **`crowdsec@file`** middleware defined in
  `$CONFIG_DIR/traefik/dynamic.yml` (tracked at `data/traefik/`), in stream mode. It is attached
  to the **https entrypoint** (see `data/traefik/traefik.template.yml`), so it guards every
  router that terminates TLS — current and future — with no per-router labels. (The dashboard
  router additionally keeps its own `dashboardAcl` + basic-auth in front.) The LAPI key
  comes from `CROWDSEC_BOUNCER_API_KEY` via Traefik's Go templating (`env`, see `dynamic.yml`):
  Traefik renders dynamic config files as Go templates and does **not** substitute shell-style
  `${VAR}`, which would be sent to LAPI verbatim and fail authentication silently.

## Enable and verify

1. `CROWDSEC_BOUNCER_API_KEY` must be set in `stacks/traefik/.env` before first up —
   generation in [Quickstart](quickstart).
2. No per-router setup: the middleware sits on the https entrypoint, so every app router is
   protected automatically.
3. First Traefik start downloads/builds the plugin (needs outbound internet). CrowdSec seeds
   its config on first boot and confirms the bouncer:

   ```bash
   docker exec crowdsec cscli bouncers list     # expect the traefik bouncer to authed entries
   ```

4. Test that blocking actually works:

   ```bash
   docker exec crowdsec cscli decisions add --ip <your-public-ip> -d 10m   # expect 403
   docker exec crowdsec cscli decisions delete --ip <your-public-ip>       # unban
   docker exec crowdsec cscli alert list
   ```

## Behavior defaults

- **Bypasses**: client IPs in RFC1918/CGNAT ranges (`clientTrustedIPs`) are never checked — LAN
  and VPN users are exempt. The proxy chain is trusted (`forwardedHeadersTrustedIPs`) so the real
  client IP is read from `X-Forwarded-For` behind cloudflared.
- **Fail-open**: `updateMaxFailure: -1` — if LAPI is unreachable the edge lets traffic through
  rather than blocking everything. Startup is fail-open too (`streamStartupBlock: false`):
  with the middleware edge-wide, the "wait for CrowdSec before serving" default would stall all
  external traffic whenever Traefik restarts while CrowdSec is down. The trade-off is a small
  window at Traefik boot — until the first stream sync completes, typically seconds — during
  which banned IPs are not yet rejected.
- **Mode**: `stream`; the banned-IP cache refreshes every 60s from CrowdSec.

The CrowdSec engine registers with the community blocklist and derives decisions from Traefik
logs via the `crowdsecurity/traefik` and `crowdsecurity/http-cve` collections.

## Authentication with Cloudflare Access

CrowdSec decides **which IPs** are allowed; Cloudflare Access decides **which identities**. It
works at the edge, *before* cloudflared — the Zero Trust dashboard →
**Access → Applications** → **Add an application** → **Self-hosted** — so a request that doesn't
pass its policy never reaches the tunnel, let alone Traefik. Set the **Application domain** to
the hostname you want to protect (e.g. `radarr.<DOMAIN>`), create a **Policy** (any of: your
logged-in Cloudflare / SSO identity, an email domain, or a
[service token](https://developers.cloudflare.com/cloudflare-one/identity/service-tokens/) for
machine clients), choose a **Session duration**, and save. Visitors get the Access login page;
everything else in the zone stays public.

Caveats and how it fits the stack:

- **Do not put Access in front of Jellyfin if *external* TV/media apps must stream.** Jellyfin's
  TV and mobile clients (LG/Samsung, Android TV, Apple TV, Roku, ...) authenticate with a device
  **token**, not a browser, and cannot complete Cloudflare Access's interactive login — they fail
  to connect. LAN/Tailnet clients bypass Access anyway, so this only affects access from outside
  the house; still, a public `jellyfin.<DOMAIN>` must stay in front of Access if any external app
  should work. Leave it unprotected rather than breaking clients — Jellyfin's own accounts still
  guard it, and the web UI is unaffected. (A service token is the workaround for
  machine-to-machine clients that can send headers, not for the TV apps, which can't.)
- It is an extra layer over each app's own auth (Jellyfin accounts, the Traefik dashboard's
  basic-auth) — belt-and-suspenders, not a replacement. Rejected traffic never reaches the
  tunnel container, so Traefik and the apps only ever see approved requests.
- It composes with CrowdSec at different layers: Access filters unauthenticated humans at the
  edge while CrowdSec still blocks scanner IPs inside Traefik. Enable both; neither interferes
  with the other's bypasses (LAN/VPN users pass Access too if the `traefik.<DOMAIN>` dashboard
  and media sit behind it).
- LAN/Tailnet access goes straight to Traefik and never traverses the edge, so Access only
  applies to the public hostnames (same as the [geolock](ingress#geolock-optional-eg-usa-only)).
