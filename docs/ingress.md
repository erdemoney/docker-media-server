---
title: Ingress
nav_order: 7
---

# Ingress: Traefik + Cloudflare tunnel

Public traffic path: Cloudflare edge → cloudflared tunnel (on `external`) → Traefik `:443` →
service on `internal`. Traefik routes purely by its own `Host()` labels; the tunnel is a
transparent pipe.

## Security gate: finish setup before going public

Adding a tunnel hostname opens that app to the whole internet **instantly** — and until its
first-run setup is done the app has **no login**, so anyone who finds the subdomain can create
the admin account or reconfigure the app for you. Because of that the order is fixed:

1. **Set up every app over LAN first** — [LAN access](lan-access) gives you working URLs with
   no exposure, and it's where the full [The \*arrs](arrs) walkthrough happens.
2. **Minimum before exposing each app: its setup is finished** — admin account exists and auth is
   on: Jellyfin (admin created on first login), Sonarr/Radarr/Prowlarr/Bazarr/Profilarr (Settings →
   General → Authentication), Seerr (admin on first login), Decypharr (wizard completed).
3. **Only then expose it** — add the public hostnames below.

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

- The **Traefik router** already accepts the subdomain (compose label
  `traefik.http.routers.<svc>.rule=Host(${SUB_DOMAIN_<SVC>}.${DOMAIN})`, with `tls=true`),
  and the DNS record for that hostname is proxied (orange-cloud) in the zone's DNS tab.
- **TLS mode** is **Full (strict)** (SSL/TLS → Edge Certificates), so the edge → Traefik leg
  uses the real cert.

Removing a hostname from Public Hostnames removes it from the internet; LAN/Tailnet access goes
directly to Traefik on `:443` and is unaffected.

## Certificates (automatic)

HTTPS is one-time setup, then handled for you. Traefik's ACME provider creates the
`_acme-challenge` TXT record via the Cloudflare API (`CLOUDFLARE_DNS_TOKEN`, from
[Quickstart](quickstart)) and issues a **Let's Encrypt wildcard cert for `*.DOMAIN`** — one cert
covering every hostname that terminates at Traefik, whether via tunnel, LAN, or Tailnet. Because
it's the **DNS-01** challenge, certs issue before the tunnel or any app hostname exists; no
inbound ports are required. Renewals and per-app HTTPS are automatic (`tls=true` on every router).
Confirm issuance in the Traefik dashboard's ACME panel (`https://traefik.<DOMAIN>`).

There is **no Let's Encrypt account to create** — no signup, dashboard, or email verification.
Traefik registers one over ACME on first start and stores it in `$CONFIG_DIR/traefik/acme.json`;
`ACME_EMAIL` (default `admin@<DOMAIN>` in `just init`) just needs to be a real, controlled domain
— the API rejects reserved ones (`@example.com`) — but it needn't receive mail.

While experimenting, use the **staging CA** — Let's Encrypt rate limits "last up to one week and
cannot be overridden". In `data/traefik/traefik.template.yml`:

```yaml
caServer: https://acme-staging-v02.api.letsencrypt.org/directory
```

then `just up`. Staging certs are untrusted (browsers warn — that's expected); switching back to
production means dropping the account storage first so the staging account/certs aren't reused:

```bash
just down && rm -f data/traefik/acme.json && just up   # dirs re-creates it 0600
```

### Editing Traefik's config

Traefik's static config is **rendered, not copied**: the repo tracks
`data/traefik/traefik.template.yml`, and `just up` renders it to
`$CONFIG_DIR/traefik/traefik.yml` (untracked) with your `ACME_EMAIL` filled in. **Edit the
template, never the rendered file** — `just up` overwrites the output every run. `dynamic.yml`
and `crowdsec-acquis.yaml` need no rendering and are mounted as tracked files (`dynamic.yml`
resolves its one secret at runtime with Traefik's Go templating).

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
