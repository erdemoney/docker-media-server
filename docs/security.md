---
title: Security
nav_order: 7
---

# Security: CrowdSec IP blocking

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

CrowdSec decides **which IPs** are allowed. Identity-level auth for public hostnames — Cloudflare
Access, which decides **which identities** — is covered in
[Ingress → Authentication with Cloudflare Access](ingress#authentication-with-cloudflare-access).
