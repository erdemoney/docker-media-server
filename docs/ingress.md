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

### There is no Let's Encrypt account to create

This trips people up: Let's Encrypt has **no signup page, no dashboard, and no email
verification**. The account is created programmatically over ACME the first time Traefik starts —
it generates a keypair, registers it, accepts the subscriber agreement on your behalf, and stores
all of it in `$CONFIG_DIR/traefik/acme.json`. You never visit their website.

So `ACME_EMAIL` needs no prior setup anywhere, and `just init` defaults it to
`admin@<your domain>` — press Enter and you're done. Three things worth knowing about it:

- **Traefik requires the field** (it's `Required: Yes` in Traefik's ACME reference), even though
  Let's Encrypt treats the contact address as optional. Leave it blank and the resolver is
  misconfigured — `just dirs` warns you.
- **It does not have to receive mail.** Let's Encrypt
  [ended expiration notification emails on 4 June 2025](https://letsencrypt.org/2025/06/26/expiration-notification-service-has-ended),
  deleted the addresses it had stored, and no longer keeps ACME-supplied addresses against
  issuance data. Renewal is automatic here anyway; if you want independent alerting use a
  third-party monitor (they suggest Red Sift Certificates Lite, free up to 250 certs) rather
  than expecting mail from them.
- **But it cannot be a fake domain.** Their API validates the contact domain and rejects
  reserved ones outright:

  ```
  400 urn:ietf:params:acme:error:invalidEmail:
      invalid contact domain. Contact emails @example.com are forbidden
  ```

  Bare ICANN TLDs are refused for the same reason. That's why the default is `admin@` your own
  domain — a domain you demonstrably control, so it always passes, whether or not a mailbox
  exists behind it.

### What you *do* have to set up

All of it is Cloudflare-side, and all of it is already in [Quickstart](quickstart):

1. The domain is on Cloudflare (an active zone) — Traefik proves ownership by writing DNS records.
2. `CF_DNS_API_TOKEN` can edit that zone's DNS (the **Edit zone DNS** template).
3. Nothing else. Because the wildcard forces the **DNS-01** challenge — HTTP-01 cannot issue
   wildcards — the certificate never depends on inbound port 80/443 reachability. Certs issue
   correctly before the tunnel or any DNS record for an app exists.

### Use the staging CA while experimenting

Let's Encrypt's rate limits "last up to one week and cannot be overridden", so don't iterate on a
broken setup against production. In `data/traefik/traefik.template.yml`, point the resolver at
staging, then `just up`:

```yaml
caServer: https://acme-staging-v02.api.letsencrypt.org/directory
```

Staging issues untrusted certs (browsers will warn — that's expected). When you switch back to
production, delete the storage first so the staging account and certs aren't reused:

```bash
just down && rm -f data/traefik/acme.json && just up   # dirs re-creates it 0600
```

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
