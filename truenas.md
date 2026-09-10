# TrueNAS dataset setup

Goal: two ZFS datasets that make hardlinks work across the whole media stack (download host →
library) and keep snapshot/restore scopes clean.

## Dataset layout

```
storage                          pool
├── docker  dataset (lz4)                      -> /mnt/storage/docker
│   ├── stacks/                                compose files + .env  (git is the real backup)
│   └── data/                                  app configs (radarr/, sonarr/, traefik/, ...)
└── media  dataset (lz4, recordsize=1M)        -> /mnt/storage/media
    ├── movies/
    ├── tv/
    └── downloads/
        ├── incomplete/                        throwaway working dir (may be own dataset if
        │                                      you want to exclude it from snapshots)
        └── usenet/                            completed downloads -- SAME dataset as movies/tv
```

- `SERVICES_DIR=/mnt/storage/docker/data` in every stack's `.env`
- `DATA_DIR=/mnt/storage/media` in `stacks/media-server/.env`
- One dataset for ALL configs = one snapshot/restore unit. No per-service datasets needed.
- Jellyfin transcodes run on a container `tmpfs` (RAM) — no dataset, nothing to snapshot or back up.

## Why this layout

- **Hardlinks** only work within one filesystem (one ZFS dataset). `movies/`, `tv/`, and the
  completed `downloads/usenet/` all live inside the single `media` dataset, so Radarr/Sonarr import
  via instant hardlink. What matters is filesystem identity, not Docker mount paths — bind-mounts of
  subdirectories inside the same dataset are all the same filesystem.
- **Snapshot scoping**: configs are tiny and critical (snapshot frequently), media is bulk
  (snapshot daily/weekly). Separate datasets -> separate schedules, retention, and selective
  replication.
- **One-shot restore**: `zfs snapshot -r storage/docker@...` captures compose files + all configs
  together — a full stack restore point.
- `recordsize=1M` on `media` matches large media files; `lz4` is cheap everywhere else.
- **Transcodes** are true throwaway: Jellyfin mounts a container `tmpfs` at `/transcodes` (RAM).
  Nothing is written to disk, there is no dataset to snapshot or back up, and it clears itself on
  container restart. RAM footprint is small (only the rolling transcode buffer, not the file). If
  you ever add an SSD/NVMe pool you could optionally move transcodes there instead — the current
  tmpfs approach is the zero-maintenance default.

## Creating the layout (fresh)

```
zfs create -o compression=lz4 storage/docker
zfs create -o compression=lz4 -o recordsize=1M storage/media
mkdir -p /mnt/storage/docker/{stacks,data}
mkdir -p /mnt/storage/media/{movies,tv,downloads/incomplete,downloads/usenet}
chown -R <PUID>:<PGID> /mnt/storage/docker/data /mnt/storage/media
```

## Migrating from the current (nested) layout

Yes — **flatten** the old datasets into plain directories with a filesystem copy, then destroy the
old datasets. Do NOT use `zfs send|recv` here: it preserves dataset boundaries, which is exactly
what you're trying to collapse. `rsync`/`cp` lands the data as plain dirs inside the new datasets.

1. **Get to a neutral state** — stop the stack (frees bind-mounts and stops writes). Note `down`,
   not `stop`: stopped-but-unremoved containers still hold their mounts:

```
docker compose -f /mnt/storage/docker/stacks/media-server/compose.yaml down
docker compose -f /mnt/storage/docker/stacks/traefik/compose.yaml down
docker compose -f /mnt/storage/docker/stacks/cloudflared/compose.yaml down
docker compose -f /mnt/storage/docker/stacks/homarr/compose.yaml down
```

If a `data -> data.old` rename from earlier is still pending, finish or abort it now that
nothing is using the mount (this step no longer needs `data.old` — see step 4).

2. **Inventory + snapshot** for rollback insurance:

```
zfs list -r -o name,used,mountpoint storage
zfs snapshot -r storage@pre-migration
```

3. **Create the target layout** (commands above).

4. **Flatten configs** (pick the correct source for your actual layout — e.g. `data.old` or the
   original `data` dataset):

```
rsync -aH --info=progress2 /mnt/storage/docker/data.old/ /mnt/storage/docker/data/
```

5. **Union media** into the single dataset — one rsync per source (sub)dataset into its target dir,
   or a single rsync if your media is one nested tree:

```
rsync -aH --info=progress2 <old>/movies/     /mnt/storage/media/movies/
rsync -aH --info=progress2 <old>/tv/         /mnt/storage/media/tv/
rsync -aH --info=progress2 <old>/downloads/  /mnt/storage/media/downloads/
```

(`-H` preserves existing hardlinks inside each source.)

6. **Verify before deleting anything** — compare sizes, then spot-check dirs/files:

```
du -sh <old-path>/movies /mnt/storage/media/movies
```

7. **Fix ownership, then destroy** the old datasets only after verification:

```
chown -R <PUID>:<PGID> /mnt/storage/docker/data /mnt/storage/media
zfs destroy <old-dataset> ...
```

Use `zfs destroy` — never `rm -rf` on a mounted dataset (leaves an empty dataset behind;
destroying a parent removes its children).

8. **Deploy**: update `stacks/media-server/.env` (`DATA_DIR=/mnt/storage/media`), `docker compose up -d`.

## Shared networks

The stacks use two pre-created Docker networks, declared `external: true` in every compose file
(intentional — non-external would create a project-isolated network per stack and break cross-stack
routing). They survive daemon restarts but are wiped if the apps VM is ever rebuilt, so create them
idempotently from the repo before first deploy:

```
cd /mnt/storage/docker/stacks && just networks
```

- `internal` — app-to-app traffic / routing between services and Traefik.
- `external` — Traefik ↔ cloudflared WAN ingress.

## Backups / replication

- Snapshots: frequent on `docker` (configs incl. `acme.json`), daily/weekly on `media`.
- Scope them: keep `docker` and `media` snapshot schedules separate (doesn't mix configs with bulk).
- `incomplete/` can be excluded from media snapshots if made its own throwaway dataset.
