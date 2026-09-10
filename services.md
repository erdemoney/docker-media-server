# Recommended services

Subscription/indexer picks that pair with the stack (see `setup.md` for wiring them in).

## Torbox — debrid + Usenet

- **Plan**: **Pro, ~$10/mo** — recommended for Usenet.
- **What it is**: a debrid provider (like Real-Debrid but with its own Usenet support) that plugs
  straight into **Decypharr**. Torrents grabbed from Prowlarr get resolved to cached streams, and
  the Pro plan adds Usenet access so Decypharr's Usenet engine has a backend too.
- **Setup**: create an account, grab an API key from the dashboard, and add Torbox as a debrid
  provider in Decypharr's setup wizard / config (`provider: "torbox"`). See
  https://decypharr.com/guides/debrid/torbox.
- **Pricing**: check torbox.app for current prices — Pro is the sweet spot if you want Usenet
  without a separate provider.

## AltHub — Usenet indexer

- **Price**: **$20 lifetime** (VIP).
- **What it is**: a Newznab-compatible Usenet indexer. One-time payment, no recurring cost.
- **Setup**: after purchasing, take the API key + Newznab URL from the AltHub profile page and add
  it in Prowlarr → Indexers → **Newznab** (`generic` is enough: its URL handles the rest). Once
  added it syncs to Sonarr/Radarr like every other Prowlarr indexer.
- **Why**: cheap lifetime indexer as the Usenet companion to Torbox.

## Honorable mentions

- **Real-Debrid** — the classic debrid provider, well supported by Decypharr; largest cache community.
- **rrn / nzbgeek etc.** — extra Usenet indexers, most are per-year; AltHub's lifetime deal usually
  beats them all on cost.
- **trash-guides profiles** (imported via Profilarr) — not a subscription, but the biggest quality
  upgrade for free.

## Budget stack

All-in monthly cost with the defaults: **~$10/mo** (Torbox Pro) + **$20 one-time** (AltHub).
Everything else (Traefik, Jellyfin, Sonarr/Radarr/Prowlarr/Bazarr/Profilarr, Homarr) is free and
self-hosted on this stack.

> Pricing as of writing — confirm on vendor sites before subscribing.
