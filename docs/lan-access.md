---
title: LAN access
nav_order: 3
---

# Set up the apps over LAN

The LAN-only stage: **before any public hostname exists, and before the \*arr wiring**, you reach
every app from a LAN client and do all first-run setup here — the stack behaves exactly as it will
over the internet (same `Host()` routing, same wildcard cert, browser-trustable) but nothing is
reachable from outside.

Reaching Traefik `:443` from a LAN client already works (cert issuance is DNS-01 — no inbound
ports — and LAN/VPN traffic hits Traefik directly). The only thing standing between you and
usable URLs is hostname resolution: `jellyfin.<DOMAIN>` & co. must resolve to the server's LAN IP
on the machine you're setting up from.

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
- **Router UI**: a regular A record per hostname for the ones you want to reach
  (`jellyfin.<DOMAIN> → 192.168.1.50`, `traefik.<DOMAIN> → 192.168.1.50`, ...).

**Fallback: a hosts-file entry** on the machine you're setting up from (no router access needed;
affects only that machine — all the OSes do this the same way, just different paths). `just hosts`
prints a ready-to-paste block for the exact subdomains in your `.env` files, mapped to the
server's primary LAN IP (hand it an address to generate for another machine:
`just hosts 10.0.0.5`):

```bash
just hosts
```

which prints something like (exact subdomains from your `.env`):

```
192.168.1.50   traefik.<DOMAIN> jellyfin.<DOMAIN> sonarr.<DOMAIN> radarr.<DOMAIN>
                prowlarr.<DOMAIN> bazarr.<DOMAIN> profilarr.<DOMAIN> seerr.<DOMAIN>
```

Hosts files match **exact hostnames only** — no wildcards, and Traefik routes by exact `Host()`. So
one entry per subdomain is required; keep the block whole or trim it to the apps you're actually
setting up.

Where to edit it (admin rights needed, then flush the DNS cache):

- **macOS / Linux**: `/etc/hosts`… then
  ```
  sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
  ```
  (Linux: no flush needed — or `systemctl restart systemd-resolved` /
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

From a LAN client that URL **is** the real stack — that's the point of this stage. Keep the local
DNS rule afterwards (it's permanent split-horizon DNS; `just backup`/cron traffic and Traefik's
dashboard then never depend on the tunnel). When the URLs work, move on to
[The \*arrs](arrs) walkthrough — every first-run setup (admin accounts, auth, API keys,
interconnections) happens from these LAN URLs, while nothing is public. Only when everything is
set up and secured do you expose it — that's the **last** step, in [Ingress](ingress).