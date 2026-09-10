# Initial setup guide

Bringing up the media stack after a fresh clone/deploy on the NAS: bootstrap, app configs,
linking all the \*arrs together with API keys over Docker-internal DNS, Torrentio, and Decypharr.

## 0. Bootstrap the stack

Everything runs from the repo mount on the NAS (`/mnt/storage/docker/stacks`). On the dev box
edits are made here, committed, and `git pull`ed on the NAS.

1. Copy every stack's env example to a real `.env` and fill it in:

```
for s in traefik cloudflared media-server homarr; do
  cp files/stacks/$s/.env.example stacks/$s/.env   # (non-NAS) adjust as needed
done
```

Key variables (see `stacks/*/.env.example`):

- `DOMAIN=fromnowhere.net` — wildcard `*.fromnowhere.net` must resolve into the Cloudflare
  tunnel (cloudflared). Each app gets its own subdomain via `SUB_DOMAIN_*`.
- `CF_DNS_API_TOKEN` (traefik) — Cloudflare API token, used for DNS-01 ACME wildcard certs. TLS
  is enforced at the Traefik edge; internal traffic is plain HTTP inside Docker.
- `TRAEFIK_DASHBOARD_CREDENTIALS` — `htpasswd -nb user pass` output; dashboard lives at
  `https://traefik.fromnowhere.net`.
- `CLOUDFLARE_TUNNEL_TOKEN` (cloudflared).
- `SECRET_ENCRYPTION_KEY` (homarr) — generate with `openssl rand -base64 32`.
- `SERVICES_DIR=/mnt/storage/docker/data`, `DATA_DIR=/mnt/storage/media`, `ENV_PUID/ENV_PGID`
  (should match the NAS user owning the datasets).

### Where the Traefik secrets come from

#### `CF_DNS_API_TOKEN` — Cloudflare, DNS-01 ACME (wildcard TLS certs)

1. Log in at dash.cloudflare.com → **My Profile** (top right) → **API Tokens** → **Create Token**.
2. Use the **Edit zone DNS** template (or custom with Zone → DNS → **Edit** on `fromnowhere.net`).
3. The token only needs DNS edit on that one zone — nothing else (Traefik uses it to create
   `_acme-challenge` TXT records for `*.fromnowhere.net`).
4. Copy the **`<40-char token>`** into `CF_DNS_API_TOKEN` in `stacks/traefik/.env`.

Verify before first `up`: `curl -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \ -H "Authorization: Bearer <token>"` should return `"status": "active"`. If ACME then fails with "no TXT record" or "propagation", check the token has `Zone:DNS:Edit` for the right zone and the API isn't rate-limited.

#### `TRAEFIK_DASHBOARD_CREDENTIALS` — htpasswd basic-auth blob for `traefik.fromnowhere.net`

This is **not** a token — it's a username:password string pre-hashed by `htpasswd`. Generate:

```bash
# on the NAS (docker is there):
docker run --rm httpd:2.4-alpine htpasswd -nbB user 'ChangeMe-strong-password'
```

- `-n` prints the hash instead of writing a file; `-b` takes the password from the command line;
  `-B` uses bcrypt (recommended). No docker? `htpasswd -nbB user pass` if the `apache2-utils`
  package exists, or `openssl passwd -apr1 'pass'` works too (Traefik accepts both).
- The output looks like `user:$2y$05$...` — paste it **whole** into
  `TRAEFIK_DASHBOARD_CREDENTIALS`.
- `.env` gotcha: because the hash contains `$`, quote the whole value in single quotes so compose
  doesn't try to interpolate it:

```
TRAEFIK_DASHBOARD_CREDENTIALS='user:$2y$05$abcdefghijklmnopqrstuvwxyz0123456789'
```

The dashboard middleware is already wired (`traefik-auth`, applied to the `traefik-secure`
router); just supply the value. If you ever lose it, regenerate and recreate the traefik container.

#### `CROWDSEC_BOUNCER_API_KEY` — a local random key, nothing to buy or register

There's no dashboard for this one. It's an arbitrary random string that CrowdSec's bouncer
(`BOUNCER_KEY_TRAEFIK`) and the Traefik WAF middleware both use to authenticate to CrowdSec's
LAPI. Generate once with `openssl rand -hex 32` (64 hex chars) and paste into
`stacks/traefik/.env`. Recreate the `crowdsec` and `traefik` containers after changing it
(`just update-all`).

> Everything else in the traefik stack is either Path-defined (`$SERVICES_DIR`), or comes from the
> cloudflared stack (`CLOUDFLARE_TUNNEL_TOKEN` — create a tunnel in dash.cloudflare.com → Zero
> Trust → Networks → Tunnels and copy its token).

2. Pre-create + chown config dirs, create shared networks, bring everything up:

```
just dirs
just networks
just up
just ps
```

App UIs are at `https://<subdomain>.fromnowhere.net` — `jellyfin`, `seerr`, `radarr`, `sonarr`,
`prowlarr`, `profilarr`, `bazarr`, `decypharr`, `homarr`, `traefik`.

## 1. Internal DNS names and API keys

All services share the `internal` Docker network, so every container can reach the others by
**service name** — always use these, never `localhost` or the public subdomain. Public URLs are
for browsers only.

| Service   | Internal URL            | Port | API key lives at                                |
| --------- | ----------------------- | ---- | ----------------------------------------------- |
| jellyfin  | `http://jellyfin:8096`  | 8096 | Jellyfin → Dashboard → API Keys (generate one)  |
| seerr     | `http://seerr:5055`     | 5055 | (outbound only)                                 |
| radarr    | `http://radarr:7878`    | 7878 | Settings → General → API Key                    |
| sonarr    | `http://sonarr:8989`    | 8989 | Settings → General → API Key                    |
| prowlarr  | `http://prowlarr:9696`  | 9696 | Settings → General → API Key                    |
| profilarr | `http://profilarr:6868` | 6868 | profilarr → Settings → Radarr/Sonarr connection |
| bazarr    | `http://bazarr:6767`    | 6767 | (outbound only)                                 |
| decypharr | `http://decypharr:8282` | 8282 | Settings → API token (shown after first setup)  |
| sabnzbd   | `http://sabnzbd:8080`   | 8080 | SABnzbd → General → API key (if using Usenet)   |

Rule of thumb: when any UI asks for another app's **URL + API key**, paste the `http://<service>:<port>`
from the table and the key from the target app. Do not use the HTTPS subdomains — that hairpins
traffic out to Cloudflare, breaks CORS, and adds latency.

Sanity check from Nagios-less land: `docker exec <arr-container> curl -fsS http://sonarr:8989/ping`.

## 2. Link the \*arrs

### Prowlarr → Sonarr/Radarr (indexer sync)

1. Prowlarr → Settings → **Apps** → **Add Application** → **Sonarr**.
   - URL: `http://sonarr:8989`, API key from Sonarr's Settings → General.
   - Edit the Sync Profile: movies/TV categories, and **uncheck "Enable search"** wait/trim:
     leave the defaults, just check "Enable" and the correct categories.
2. Same for **Radarr** → `http://radarr:7878` + its API key.
3. Test both, then any indexer you add in Prowlarr (incl. Torrentio below) is pushed to both apps
   automatically, tagged `(Prowlarr)`.

### Sonarr/Radarr → download clients

In both apps: Settings → Download Clients.

- **Decypharr (torrents / debrid)** — add as a **qBittorrent** client:
  - Host: `decypharr`, Port: `8282`
  - Username: the **arr's own URL** — `http://sonarr:8989` (or radarr's) — Decypharr identifies
    the caller by this.
  - Password: that **arr's own API key** (Settings → General).
  - Category: `sonarr` / `radarr`; Priority `0`.
- **SABnzbd (Usenet, optional)** — add as **Sabnzbd** client: Host `sabnzbd`, port `8080`, API key
  from SABnzbd's own config.

Use priorities to prefer one source over the other. Test each client.

### Bazarr → Sonarr/Radarr (subtitles)

1. Settings → **Sonarr** → enable, URL `http://sonarr:8989`, API key.
2. Settings → **Radarr** → same with `http://radarr:7878`.
3. Create a language profile (Languages → manage), then assign it in Sonarr/Radarr
   library views via **Mass Edit** — Bazarr only fetches subtitles for titles added **after** a
   profile is assigned, so this is the step everyone forgets.
4. **Subtitle providers** (the fiddly part):
   - **OpenSubtitles.com** — primary. The old `.org` API is shut down; stock Bazarr now uses the
     `.com` API. Create an account, generate an **API key** on your profile page, and enter
     username + API key in the provider settings. Free tier is rate-limited (about 20
     downloads/day); VIP removes the cap.
   - **Podnapisi.net** — free fallback. Now requires a (free) account; grab the API key from your
     Podnapisi profile settings.
   - **Whisper (optional)** — AI-generated fallback for anything that clears nobody's minimum
     score. Needs a separate whisper ASR service; skip unless you want zero-miss coverage.
   - Rank providers by preference and raise each language's **minimum score** if subs arrive out of
     sync or from machine translation. Subtitle folder: **Alongside media file**.

### Profilarr → Sonarr/Radarr (quality profiles)

1. In profilarr add the Sonarr/Radarr instances: URL `http://sonarr:8989` / `http://radarr:7878`
   and each API key.
2. Import TRaSH guides / create profiles; profilarr applies them to the apps.

### Seerr → Jellyfin + Radarr + Sonarr (requests)

1. Seerr → Settings → **Jellyfin**: server name, URL `http://jellyfin:8096`, and an **API key
   generated on the Jellyfin server** (Dashboard → API Keys). Create the Jellyfin admin account on
   first login and log into Jellyfin once.
2. Seerr → **Radarr** and **Sonarr** -> enable, add `http://radarr:7878` / `http://sonarr:8989` +
   API keys, pick the quality profile and root folder for each.
3. Users can now request via Seerr, which pushes to Radarr/Sonarr.

## 3. Torrentio as a Prowlarr indexer

Torrentio is a movie/TV **torrent aggregator** (ezTV, rarbg, 1337x, TPB, nyaa, ...). Prowlarr
supports it as a custom Cardigann indexer, so results flow through the normal Prowlarr → Sonarr/
Radarr sync and grabs go to Decypharr for debrid streaming.

1. Create the custom-definitions dir inside Prowlarr's config and drop in the definition:

```
mkdir -p /mnt/storage/docker/data/prowlarr/Definitions/Custom
# fetch https://raw.githubusercontent.com/dreulavelle/Prowlarr-Indexers/main/Custom/torrentio.yml
#   and save it there as torrentio.yml
```

2. Restart Prowlarr so it picks up the new definition: `just restart media-server` (or recreate
   just the prowlarr service).
3. Prowlarr → **Indexers** → `+` → search **Torrentio** → add it.
   - Scroll to the indexer options and paste your **Real-Debrid (or supported-debrid) API key** in
     the key field — the whole point is debrid-cached torrents.
   - `default_opts` holds the provider list + `qualityfilter=scr,cam`; tweak the providers or sort
     if you want.
   - Save, enable, and confirm a green test. Enable it for movies/TV sync in the Sync Profile.
4. It now syncs to Sonarr/Radarr like any indexer. In Prowlarr search use
   `{imdbid:tt123456}` / `{imdbid:tt1234567}{season:00}{episode:00}` for precise hits.

## 4. Decypharr (debrid gateway)

Decypharr mounts your debrid provider as a FUSE filesystem (`/mnt/:/mnt:rshared`,
`/dev/fuse`, `SYS_ADMIN`, `apparmor:unconfined` in the compose) and exposes a qBittorrent and
SABnzbd-compatible API so Sonarr/Radarr see "instant" debrid files.

1. First visit to `https://decypharr.fromnowhere.net` runs the **setup wizard**:
   - **Authentication**: create admin username/password. The **API token is shown once** after
     setup completes — save it (that's the value used in the arr download-client Password field).
   - **Debrid providers**: add at least one (Real-Debrid, AllDebrid, Debrid-Link, Torbox,
     Premiumize) with its API key.
   - **Usenet (optional)**: add NNTP server details only if downloading from Usenet.
   - **Mount configuration**: pick **DFS**, mount path `/mnt/decypharr` (this is what the arrs will
     import from), and a cache dir.
   - Config is written to `/mnt/storage/docker/data/decypharr/configs/config.json`.
2. FUSE mounts made inside the container propagate to the NAS host at `/mnt/decypharr` thanks to
   the `:rshared` bind. If the arr containers don't yet mount that path, add a bind so Sonarr and
   Radarr can see it and import:

```
# both services, same host path as Decypharr uses
- /mnt/decypharr:/mnt/decypharr
```

3. Add Decypharr as a download client in Sonarr/Radarr (see §2 above — qBittorrent type,
   host `decypharr`, port `8282`, username = the arr's own URL, password = the arr's API key,
   category `sonarr`/`radarr`, priority `0`).
4. Decypharr → Settings → **Arrs**: it auto-detects the apps that hit it. Give it each arr's
   host (`http://sonarr:8989` etc., not the public URL) and API key outbound.
5. If the arr's import path differs from Decypharr's mount path, set a **path mapping** on the
   download client:
   - Remote path: `/mnt/decypharr` → Local path: whatever the arr sees, e.g. `/media/tv`.
6. **Repair worker / queue cleanup**: enable in Settings → Arrs (blacklist + research defaults are
   sensible) so failed grabs don't clog the queue.

Usenet-only users can skip the debrid gateway and just point the Sabnzbd client at `sabnzbd:8080`.

## 5. Remaining bring-up to-dos

- **CrowdSec (edge WAF / IP blocking)**: runs in the traefik stack. Before `just up`, generate a
  bouncer key and put it in `stacks/traefik/.env`:

```
openssl rand -hex 32            # paste into CROWDSEC_BOUNCER_API_KEY=
```

The same key becomes the CrowdSec bouncer (`BOUNCER_KEY_TRAEFIK`) and the Traefik middleware
LAPI key. On first boot CrowdSec seeds `…/data/crowdsec/config` and starts reading Traefik's
access log (`crowdsec-acquis.yaml`). It's enabled on the **Jellyfin** router via
`crowdsec@file`; add that label to any other router to protect it too. Verify with:

```
docker exec crowdsec cscli decisions add --ip <your-public-ip> -d 10m   # expect 403
docker exec crowdsec cscli alert list    # and remove: cscli decisions delete --ip <ip>
```

First Traefik start after adding the plugin downloads it from the plugin registry (needs
outbound internet). LAN/VPN IPs bypass the bouncer (`clientTrustedIPs`); `updateMaxFailure: -1`
keeps the edge fail-open if LAPI is unreachable.

- **Jellyfin library**: the compose currently only mounts `/config` — if you want Jellyfin to serve
  libraries, add media binds (`/mnt/storage/media/movies` etc.) to the jellyfin service, then add
  the media libraries in the Jellyfin UI.
- **Radarr/Sonarr root folders**: point them at your media dataset paths inside the containers
  (must match any bind mounts you add).
- **Homarr dashboard**: add widgets backed by the apps at their **internal** URLs
  (`http://sonarr:8989`, ...). It runs on the same network, so internal names work.
- **GPU**: verify the NVIDIA sys-fs/GPU is actually attached: `docker exec jellyfin nvidia-smi`.
  After any TrueNAS update the driver sysext must be re-enrolled (see `truenas.md`).
- **Traefik dashboard** login via the `TRAEFIK_DASHBOARD_CREDENTIALS` htpasswd blob; ACME uses the
  Cloudflare token and the wildcard `*.fromnowhere.net` cert — confirm a `Certificate` appears in
  Traefik's ACME panel after first up.
- **Certificates/wildcard**: initial let's Encrypt issuance needs the DNS token working and the
  wildcard record; Traefik resolves it automatically.

## Reference

- Decypharr docs: https://decypharr.com/guides (wizard, arr integration, mounts, troubleshooting)
- Torrentio indexer definition: https://github.com/dreulavelle/Prowlarr-Indexers
- Servarr wiki (Prowlarr quick start): https://wiki.servarr.com/prowlarr/quick-start-guide
