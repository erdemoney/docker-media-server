# Cloudflare + media streaming setup

Reference for running Jellyfin (and other self-hosted media) behind a cloudflared Tunnel
without running afoul of Cloudflare's terms of service.

## Why this works

Cloudflare's content restriction (historically "Section 2.8", since rewritten) only applies to
the **CDN service** — caching and serving content at the edge. It does not restrict proxying
media through a Tunnel when caching is bypassed.

The current terms (Service-Specific Terms, "Content Delivery Network (Free, Pro, or Business)")
say, in part:

> Cloudflare's content delivery network (the "CDN") Service can be used to cache and serve web
> pages and websites. Unless you are an Enterprise customer, Cloudflare offers specific Paid
> Services (e.g., the Developer Platform, Images, and Stream) that you must use in order to serve
> video and other large files via the CDN.

Put simply: video may not be **served/cached by the CDN** on a free plan, but it can be
**proxied through a Tunnel** so long as the edge does not cache it. The blog post announcing the
TOS change is here: <https://blog.cloudflare.com/updated-tos/>

## Steps

1. Go to the Cloudflare dashboard for the `fromnowhere.net` zone.

2. Open **Caching → Cache Rules**.

3. Click **Create rule**.

4. When: match **Hostname** equals `jellyfin.fromnowhere.net`
   (add a second condition for `/Videos/*` if you prefer path-level matching).

5. Then: set **Cache eligibility** to **Bypass cache**.

6. Save. (Repeat for any other media hostnames you expose.)

7. Confirm the Tunnel hostname for `jellyfin.fromnowhere.net` uses TLS mode
   **Full (strict)** so the path cloudflared → Traefik stays encrypted end to end.

## How to verify

Check that media responses are not being cached by the CDN:

```bash
curl -sI https://jellyfin.fromnowhere.net/web/ | grep -iE 'cf-cache-status|age|cache-control'
```

Expect `cf-cache-status: DYNAMIC` (or `BYPASS`) and no meaningful `Age` header on media URLs.

## Adding a Cloudflare Tunnel entrypoint for a service

This cloudflared tunnel is a **remotely-managed (token) tunnel** — see `TUNNEL_TOKEN` in
`stacks/cloudflared/compose.yml`. Public hostnames (i.e. which URLs the tunnel exposes and where
they route) are configured in the Cloudflare dashboard, not in files:

1. In the [Zero Trust dashboard](https://one.dash.cloudflare.com), go to
   **Networks → Tunnels** and open the tunnel this server runs.

2. Open the **Public Hostname** tab and click **Add a public hostname**.

3. Set **Subdomain** (e.g. `jellyfin`) and **Domain** (`fromnowhere.net`) — this is the public URL.

4. **Type: HTTPS**, **URL: `traefik:443`**. The tunnel container is on the `external` Docker
   network; Traefik (which is also on that network) is where every public hostname terminates.

5. Save. Traffic for that hostname becomes: Cloudflare edge → tunnel → `traefik:443` →
   (Traefik routes it by its own `Host()` rule) → the service container on the `internal` network.

Two things must line up for a hostname to actually work:

- The **Traefik router** must already accept the subdomain
  (`traefik.http.routers.<svc>.rule=Host(`${SUB_DOMAIN_<SVC>}.${DOMAIN}`)`) with `tls=true`, and
  the DNS record for that hostname must be proxied (orange-cloud) in the Cloudflare zone DNS tab.
- The **TLS mode** for the hostname should be **Full (strict)** in **SSL/TLS → Edge Certificates**
  / the tunnel settings, so the edge → Traefik leg uses the real cert.

Removing a hostname from the Public Hostname list removes it from the internet; it does not affect
LAN/Tailnet access, which goes directly to Traefik on `:443`.

## Geolock to the USA only

Do this in Cloudflare, not Traefik. Cloudflare sees the real visitor IP at the edge (before it
enters the tunnel); Traefik only sees the cloudflared container IP, so a Traefik-side geoblock
would be unreliable without trusting `X-Forwarded-For` (which reintroduces spoofing risk).

1. In the Cloudflare dashboard for the `fromnowhere.net` zone, go to
   **Security → WAF → Custom rules** (or **Firewall → IP Access Rules**).

2. Create a rule:

   - Field: **Country**, operator: **is not**, value: **United States**
   - Action: **Block**

3. Save. This blocks all public internet access to every hostname on the zone from outside the US.

Notes:

- Country is derived from the edge IP, so VPN users can bypass it.
- `fromnowhere.net` and its subdomains always resolve to Cloudflare, so DNS-level "openness" doesn't
  change; the block happens at the WAF before traffic reaches the tunnel.
- LAN/Tailnet access never traverses Cloudflare, so this rule does **not** affect internal use
  (including admin UIs) — they keep their own access control in Traefik.

## Also note

- This same approach works for e.g. seerr / any other large-files-served-via-tunnel hostname.
- The restriction is about the CDN serving (caching) media; plain TCP/HTTP relay through a
  Tunnel with cache bypass is not serving video "via the CDN."
- If you ever change your mind and want a non-Cloudflare public exposure path, Tailscale Funnel
  is the project's alternative — but note Funnel URLs are `*.ts.net` only and cannot use the
  `fromnowhere.net` hostnames.
