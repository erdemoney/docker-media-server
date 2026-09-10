---
title: Services
nav_order: 9
---

# Recommended services

Subscription/indexer picks that pair with the stack. Wiring ran through
[Indexers](indexers) and [Decypharr](decypharr).

## Torbox — debrid + Usenet

- **Plan**: **Pro, ~$10/mo** — recommended for Usenet.
- **What it is**: a debrid provider (like Real-Debrid, but with its own Usenet support) that plugs
  straight into **Decypharr**. Torrents grabbed from Prowlarr get resolved to cached streams, and
  the Pro plan gives Decypharr's Usenet engine a backend too.
- **Setup**: create an account, grab an API key from the dashboard, add Torbox as a debrid
  provider in Decypharr's wizard / config (`provider: "torbox"`).
- **Pricing**: check <https://torbox.app> — Pro is the sweet spot if you want Usenet without a
  separate provider.

## AltHub — Usenet indexer

- **Price**: **$20 lifetime** (VIP).
- **What it is**: a Newznab-compatible Usenet indexer; one-time payment, no recurring cost.
- **Setup**: buy, then add the API key + Newznab URL from your AltHub profile in Prowlarr →
  Indexers → **Newznab**. It syncs to Sonarr/Radarr like any other indexer.

## Honorable mentions

- **Real-Debrid** — the classic debrid provider, well supported by Decypharr; largest cache
  community.
- **rrn / nzbgeek and friends** — extra Usenet indexers, mostly per-year; AltHub's lifetime deal
  usually beats them on cost.
- **trash-guides profiles** (imported via Profilarr) — not a subscription, but the biggest
  quality upgrade for free.

## Budget stack

All-in cost with the defaults: **~$10/mo** (Torbox Pro) + **$20 one-time** (AltHub). Everything
else in this stack is free and self-hosted.

> Pricing as of writing — confirm on vendor sites before subscribing.
