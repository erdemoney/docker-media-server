---
title: Security
nav_order: 8
---

# Security: CrowdSec WAF / IP blocking

CrowdSec runs in the **traefik stack** (edge — it's the layer that sees all public traffic).
Traefik's access log feeds the detection engine; a Traefik middleware plugin enforces the
decisions per router.

## Components

- `crowdsec` container (`crowdsecurity/crowdsec:v1.8.1`) — analysis engine + LAPI on the
  `internal` network at `crowdsec:8080`. It reads Traefik's JSON access log via
  `data/traefik/crowdsec-acquis.yaml` (repo-relative path into the traefik stack).
- Traefik plugin `bouncer` — the **`crowdsec@file`** middleware defined in
  `data/traefik/dynamic.yml` (stream mode, key from `${CROWDSEC_BOUNCER_API_KEY}`).

## Enable and verify

1. `CROWDSEC_BOUNCER_API_KEY` must be set in `stacks/traefik/.env` before first up —
   generation in [Quickstart](quickstart).
2. The middleware is attached to the **Jellyfin** router
   (`traefik.http.routers.jellyfin.middlewares=crowdsec@file`). Protect any other router by
   adding that same label to it.
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
  rather than blocking everything.
- **Mode**: `stream`; the banned-IP cache refreshes every 60s from CrowdSec.

The CrowdSec engine registers with the community blocklist and derives decisions from Traefik
logs via the `crowdsecurity/traefik` and `crowdsecurity/http-cve` collections.
