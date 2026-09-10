---
title: Ingress
nav_order: 7
---

# Ingress: Traefik + Cloudflare tunnel

Public traffic path: Cloudflare edge → cloudflared tunnel (on `external`) → Traefik `:443` →
service on `internal`. Traefik routes purely by its own `Host()` labels; the tunnel is a
transparent pipe.

## Adding a public hostname (GUI)

This cloudflared tunnel is **remotely-managed (token-only)** — public hostnames are configured in
the Cloudflare dashboard, not in files.

1. [Zero Trust dashboard](https://one.dash.cloudflare.com) → **Networks → Tunnels** → open this
   server's tunnel.
2. **Public Hostname** tab → **Add a public hostname**.
3. **Subdomain** (e.g. `jellyfin`) and **Domain** (`DOMAIN`) — this is the public URL.
4. **Type: HTTPS**, **URL: `traefik:443`** — the tunnel container and Traefik are both on the
   `external` network, and every public hostname terminates at Traefik.
5. Save.

For a hostname to actually work, two things must line up:

- The **Traefik router** already accepts the subdomain
  (`traefik.http.routers.<svc>.rule=Host(`${SUB_DOMAIN_<SVC>}.${DOMAIN}`)` with `tls=true`),
  and the DNS record for that hostname is proxied (orange-cloud) in the zone's DNS tab.
- **TLS mode** is **Full (strict)** (SSL/TLS → Edge Certificates), so the edge → Traefik leg
  uses the real cert.

Removing a hostname from Public Hostnames removes it from the internet; LAN/Tailnet access goes
directly to Traefik on `:443` and is unaffected.

## Certificates (automatic)

HTTPS is set up once and then handled for you. Traefik's ACME provider creates the
`_acme-challenge` TXT record through the Cloudflare API (`CF_DNS_API_TOKEN`) and issues a
**Let's Encrypt wildcard certificate for `*.DOMAIN`** — one cert that covers every hostname
terminating at Traefik, whether it arrived via the tunnel, LAN, or Tailnet (all three end at
Traefik on `:443`). Renewals are automatic. Confirm issuance in the Traefik dashboard's ACME
panel (`https://traefik.<DOMAIN>`); no per-app TLS setup is needed because every router label
sets `tls=true`.

## Media through the tunnel (no CDN caching)

Cloudflare's content restriction (historically "Section 2.8") only applies to the **CDN
service** — caching and serving content at the edge. Proxying media through a tunnel is fine as
long as the edge does **not cache** the video.

1. Cloudflare dashboard for the zone → **Caching → Cache Rules** → **Create rule**.
2. When: **Hostname** equals `jellyfin.<DOMAIN>` (add `/Videos/*` for path-level matching if
   preferred).
3. Then: **Cache eligibility** → **Bypass cache**.
4. Save; repeat for any other media hostnames.

Verify media responses are not cached:

```bash
curl -sI https://jellyfin.<DOMAIN>/web/ | grep -iE 'cf-cache-status|age|cache-control'
```

Expect `cf-cache-status: DYNAMIC` (or `BYPASS`) and no meaningful `Age` on media URLs.

## Geolock (optional, e.g. USA only)

Do this in Cloudflare, not Traefik: Cloudflare sees the real visitor IP at the edge; Traefik only
sees the cloudflared container, so a Traefik-side geoblock would be unreliable without trusting
`X-Forwarded-For` (which reopens spoofing).

1. Zone dashboard → **Security → WAF → Custom rules** → **Create rule**.
2. Field **Country**, operator **is not**, value **United States**; action **Block**.
3. Save — blocks every public hostname on the zone from outside the US.

Notes: country comes from the edge IP (VPNs bypass it); LAN/Tailnet traffic never traverses
Cloudflare, so this does not affect internal access. (This same pattern is also where you'd
enforce any other zone-wide WAF rules.)

## Traefik dashboard

The API dashboard is exposed at `https://traefik.<DOMAIN>` behind basic auth
(`TRAEFIK_DASHBOARD_CREDENTIALS`, see [Quickstart](quickstart)) plus a private-source-range ACL.
For any \*arr-scale question ("is the cert issued?", "which routers exist?") the dashboard is the
fastest place to look.
