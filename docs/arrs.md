---
title: The *arrs
nav_order: 4
---

# The \*arrs: networking and app wiring

> **Before you start:** reach the stack first. [LAN access](lan-access) gets every app's URL
> resolving on a LAN/VPN client and verifies the cert — none of the wiring below (or any
> first-run setup) can happen before you can open the apps. All of it is done from those LAN URLs
> while nothing is public; exposing the stack is the **last** step ([Ingress](ingress)).

## Docker networking (shared networks)

The compose files declare two **`external: true`** shared networks so the stacks can talk to each
other without the `docker compose` project name in the way:

- `internal` — the default network every service here joins: app-to-app traffic only.
- `external` — the edge network where `cloudflared` and `traefik` sit (see [Ingress](ingress)).

Networks are created once with `just networks` (idempotent; `just up` calls it). Nothing inside
Docker binds an IP you need to care about — the names are what matter. Every service sets a
`container_name` matching its name, so containers are reachable at `http://<service>:<port>`,
and a newly added container is already reachable from every existing app.

## Internal DNS names and API keys

All services share the `internal` Docker network, so every container reaches the others by
**service name**. Always use these internal URLs — never `localhost`, never the public subdomain
(public URLs hairpin out to Cloudflare, break CORS, and add latency; they are for browsers only).

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

Rule of thumb: when any UI asks for another app's **URL + API key**, use the
`http://<service>:<port>` from the table and the key from the target app.

> Run `just wiring` on the server first — it probes every pairing's reachability
> and prints each URL + API key (read from `$CONFIG_DIR` on disk) for every
> section below, including the Decypharr client spec.

Sanity check any link from inside the network:
`docker exec <service> curl -fsS http://sonarr:8989/ping`.

## Prowlarr → Sonarr/Radarr (indexer sync)

1. Prowlarr → Settings → **Apps** → **Add Application** → **Sonarr**.
   - URL `http://sonarr:8989`, API key from Sonarr → Settings → General.
   - Leave the sync profile defaults; just check "Enable" and the correct categories.
2. Same for **Radarr** → `http://radarr:7878` + its API key.
3. Test both. Every indexer added in Prowlarr (including Torrentio, see [Indexers](indexers))
   is then pushed to both apps automatically (tagged `(Prowlarr)`).

## Sonarr/Radarr → download clients

In both apps: Settings → Download Clients. If both protocols are configured in Decypharr, add
**two** clients pointing at Decypharr — one **qBittorrent** for debrid, one **SABnzbd** for
Usenet (Decypharr exposes both APIs):

- **qBittorrent** — name `Decypharr (debrid)`
  - Host `decypharr`, port `8282`
  - Username: the **arr's own URL** — `http://sonarr:8989` (or radarr's); Decypharr identifies
    the caller by this.
  - Password: that **arr's own API key** (Settings → General).
  - Category `sonarr` / `radarr`; priority `0`.
- **SABnzbd** — name `Decypharr (usenet)` (only if you configured Usenet in Decypharr)
  - Host `decypharr`, port `8282`, **URL base `/sabnzbd`**
  - Same username/password as above.
  - Category `sonarr` / `radarr`; priority `0`.

Give them different priorities to prefer one protocol over the other — the arr sends a release
to the highest-priority client that can handle it. Test each client. Decypharr is detailed in
[Decypharr](decypharr).

## Bazarr → Sonarr/Radarr (subtitles)

Bazarr only fetches subtitles for titles added **after** a language profile is assigned — so the
profile step is easy to forget.

1. Settings → **Sonarr** → enable, URL `http://sonarr:8989`, API key.
2. Settings → **Radarr** → enable, URL `http://radarr:7878`, API key.
3. Create a language profile (Languages → manage), then assign it in the Sonarr/Radarr library
   views via **Mass Edit**.
4. **Subtitle providers** (the fiddly part):
   - **OpenSubtitles.com** — primary. The old `.org` API is shut down; stock Bazarr uses the
     `.com` API. Create an account, generate an **API key** on your profile page, enter username
     - API key. Free tier is rate-limited (~20 downloads/day); VIP removes the cap.
   - **subdl.com** — free fallback; grab an API key from your account panel (free tier allows
     ~2,000 searches/day) and enter it as api key.
   - **Whisper (optional)** — AI-generated fallback when nothing clears a minimum score; needs a
     separate whisper ASR service.
5. Rank providers by preference and raise each language's **minimum score** if subs arrive out
   of sync or machine-translated. Subtitle folder: **Alongside media file**.

## Profilarr → Sonarr/Radarr (quality profiles)

1. In profilarr add the Sonarr/Radarr instances: URL `http://sonarr:8989` / `http://radarr:7878`
   and each API key.
2. Import TRaSH guides / create profiles; profilarr applies them to the apps.

## Seerr → Jellyfin + Radarr + Sonarr (requests)

1. Seerr → Settings → **Jellyfin**: server name, URL `http://jellyfin:8096`, and an **API key
   generated on the Jellyfin server** (Dashboard → API Keys). Create the Jellyfin admin account
   on first login and log in once.
2. Seerr → **Radarr** and **Sonarr**: enable, add `http://radarr:7878` / `http://sonarr:8989` +
   API keys, pick the quality profile and root folder for each.
3. Users can now request via Seerr, which pushes to Radarr/Sonarr.

## Root folders and mounts

Sonarr/Radarr root folders must point at paths inside their own containers. In this stack the
library lives on Decypharr's FUSE mount (`/mnt/decypharr`), which is already reachable from every
service that touches media files — `sonarr`, `radarr`, `bazarr` (subtitles land next to the
video), and `jellyfin` (playback):

```yaml
- /mnt/debrid:/mnt:rslave
```

`:rslave` on the parent is what makes the mount *appear* inside those containers whenever
Decypharr creates it, with no startup ordering required. The bound parent is a dedicated host
directory (`/mnt/debrid`) mapped in as `/mnt`, so the containers see only the FUSE tree, not the
host's real `/mnt` (see [Decypharr](decypharr) for why it's the parent and not the mountpoint).
Nothing to add by hand — just point each app's root folder, and Jellyfin's libraries, at subpaths
of `/mnt/decypharr`.

## Imports are symlinks, not hardlinks

There's no local download to hardlink here: Decypharr hands the \*arrs a **symlink** pointing into
its FUSE mount, and importing renames that link into the root folder — the payload never lands on
disk, it streams from the debrid provider at playback. (FUSE debrid mounts can't hardlink anyway:
`link()` isn't implemented.) Two constraints follow:

- **Keep Decypharr's download folder and the \*arr root folders on the same mount** (both under
  `/mnt/decypharr`). Same filesystem means the import is a rename of a tiny symlink — instant. If
  they straddle filesystems the \*arrs fall back to copying, and copying a symlink *dereferences*
  it: the entire file gets pulled from debrid onto local disk.
- **Every consumer must resolve the symlink target at the same path.** What's stored in the
  library is an absolute path into the mount, so `sonarr`, `radarr`, `bazarr`, and `jellyfin` all
  bind `/mnt/decypharr` at the identical path (see [Decypharr](decypharr)). Change it in one place
  and that app sees a library full of dangling links.
