---
title: Indexers
nav_order: 5
---

# Indexers: Prowlarr, Torrentio, and AltHub

Prowlarr is the single place indexers are configured; everything syncs to Sonarr/Radarr via
"Apps" (see [The \*arrs](arrs)).

## Recommended indexers

| Indexer                      | Type               | Cost               | Where it fits                           |
| ---------------------------- | ------------------ | ------------------ | --------------------------------------- |
| Torrentio (custom Cardigann) | torrent aggregator | needs a debrid key | debrid-cached streams through Decypharr |
| AltHub                       | Usenet             | $20 lifetime       | cheap Newznab companion to Usenet       |

Detailed recommendations live in [Services](services).

## Torrentio as a Prowlarr indexer

Torrentio is a movie/TV **torrent aggregator** (ezTV, rarbg, 1337x, TPB, nyaa, ...). Prowlarr
supports it as a custom Cardigann indexer, so results flow through the normal Prowlarr → Sonarr/
Radarr sync and grabs go to Decypharr for debrid streaming.

1. Drop the definition into Prowlarr's config and restart:

   ```bash
   mkdir -p "$SERVICES_DIR/prowlarr/Definitions/Custom"
   # fetch https://raw.githubusercontent.com/dreulavelle/Prowlarr-Indexers/main/Custom/torrentio.yml
   #   and save it there as torrentio.yml
   just restart media-server        # or recreate just the prowlarr service
   ```

2. Prowlarr → **Indexers** → `+` → search **Torrentio** → add it.
   - Paste your **Real-Debrid (or supported-debrid) API key** in the indexer key field — the
     whole point is debrid-cached torrents.
   - `default_opts` holds the provider list plus `qualityfilter=scr,cam`; tweak the providers or
     sort if you want.
   - Save, enable, and confirm a green test; enable for movies/TV in the Sync Profile.
3. It syncs to Sonarr/Radarr like any indexer. For precise hits in Prowlarr search use
   `{imdbid:tt123456}` / `{imdbid:tt1234567}{season:00}{episode:00}`.

## Adding a regular Usenet indexer (e.g. AltHub)

1. Buy / register (see [Services](services)), then take the **API key + Newznab URL** from the
   indexer's profile page.
2. Prowlarr → Indexers → **+** → **Newznab**: paste the URL and API key, enable, test, save.
3. It syncs to Sonarr/Radarr automatically via the Apps configured earlier.
