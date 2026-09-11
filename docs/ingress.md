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
first-run wizard is done the app has **no login**, so a stranger who finds the subdomain can
create the admin account or reconfigure the app for you. Sequence it deliberately:

1. `just up`, then set up **every** app from a LAN client **before** adding any hostname — the
   stack publishes nothing publicly until you do, so [**test before the tunnel**](#test-before-the-tunnel)
   and walk through the app setup calmly. Same URL, same cert the internet will get.
2. Minimum before exposing each app: its **admin account exists and auth is on** — Jellyfin
   (admin created on first login), Sonarr/Radarr/Prowlarr/Bazarr/Profilarr (Settings → General →
   Authentication), Seerr (admin on first login), Decypharr (wizard completed).
3. **Only then** add public hostnames below.

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

## Test before the tunnel

The wildcard cert issues before the tunnel exists (DNS-01 needs no inbound ports), and LAN/Tailnet
traffic already reaches Traefik `:443` directly — so the *only* thing standing between you and a
testable stack is that `jellyfin.<DOMAIN>` & co. resolve to the server's LAN IP on whatever client
you test from. Traefik routes purely by exact hostname, so once a request lands with the right
`Host:` header the whole pipeline (routing → TLS → app) is the real deal — same cert a visitor
will get, browser-trustable and all. No Cloudflare public setup involved yet.

**Recommended: a local DNS record.** One rule covers the whole LAN, permanently — it doubles as
split-horizon DNS so LAN clients resolve to the server instead of hairpinning out through the
tunnel. Consumer routers often only allow per-hostname records; a wildcard is better if your
resolver supports it:

- **Pi-hole / dnsmasq / AdGuard Home** (one line, wildcard):
  ```
  address=/<DOMAIN>/192.168.1.50
  ```
- **unbound** (OPNsense/pfSense):
  ```
  local-data: "*.<DOMAIN> A 192.168.1.50"
  ```
- **Router UI**: a regular A record per hostname for the ones you want to test
  (`jellyfin.<DOMAIN> → 192.168.1.50`, `traefik.<DOMAIN> → 192.168.1.50`, ...).

**Fallback: a hosts-file entry** on the machine you're testing from (no router access needed;
affects only that machine — all the OSes do this the same way, just different paths). Point every
subdomain that exists in `stacks/media-server/.env` at the server, e.g.:

```
192.168.1.50   traefik.<DOMAIN> jellyfin.<DOMAIN> sonarr.<DOMAIN> radarr.<DOMAIN>
                prowlarr.<DOMAIN> bazarr.<DOMAIN> profilarr.<DOMAIN> seerr.<DOMAIN>
```

Where to edit it (admin rights needed, then flush the DNS cache):

- **macOS / Linux**: `/etc/hosts`… then
  ```
  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
  ```
  (Linux: no flush needed — or `systemctl restart systemd-resolved` /**
  `sudo nscd -i hosts` if it's being stubborn).
- **Windows**: `C:\Windows\System32\drivers\etc\hosts` — open Notepad as **Administrator** to
  edit it, then
  ```
  ipconfig /flushdns
  ```

Check the entry is live before poking at Traefik:

```bash
nslookup jellyfin.<DOMAIN>     # Windows: use nslookup.exe; should answer 192.168.1.50
```

Then verify routing and the cert:

```bash
curl -sI https://jellyfin.<DOMAIN>/            # expect 200/302 + the app
echo | openssl s_client -connect 192.168.1.50:443 -servername jellyfin.<DOMAIN> 2>/dev/null \
  | openssl x509 -noout -text | grep -A1 "Subject Alternative Name"   # expect *.<DOMAIN>
```

Got a working URL? Skip the waiting: `just wiring` prints every internal URL and API key the apps
need. Once the tunnel hostnames are added (above), decide whether local DNS stays — keeping it is
safe and recommended; `just backup`/cron traffic, LAN access, and Traefik's dashboard then never
depend on the tunnel being up.

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
