# TrueNAS SCALE — platform notes for this stack

> This doc is our **operator's reference**: everything TrueNAS/ZFS-specific that the generic wiki
> deliberately leaves out. It's a running note as much as a guide — re-read the sections that
> match what you're doing. Runs on **TrueNAS SCALE 25.10.7**, Docker via the built-in apps VM.

## Layout

Two datasets on pool `storage` (raidz2), mounted under `/mnt/storage`:

```
storage/docker -> /mnt/storage/docker
  stacks/        # this repo checkout -> /mnt/storage/docker/stacks
  data/          # $SERVICES_DIR, app runtime state per service
storage/media -> /mnt/storage/media   # $DATA_DIR, the library
  movies/
  tv/
  downloads/     # rockets + usenet + incomplete, SAME dataset as movies/tv -> hardlinks work
```

### Why

- **Configs rebuildable, media not.** `docker/` gets frequent snapshots (small, changes often);
  `media/` gets daily/weekly snapshots (bulk, rarely changes at the margins).
- **ONE dataset for movies+tv+downloads** is the whole trick for the \*arrs: when Sonarr imports a
  download it hard-links the file into the library instead of copying it. That only works within a
  single dataset (same pool). The instant you split downloads out, every import becomes a copy and
  your disk fills up twice as fast.
- **`recordsize=1M`** on the media dataset for large media files (the pool default 128K costs
  extra read amplification on sequential reads).

### Fresh create (only needs doing once)

```bash
zfs create storage/docker
zfs set compression=lz4 storage/docker

zfs create storage/media
zfs set recordsize=1M storage/media
zfs set atime=off storage/media

# optional scratch dir inside media -> gets its own dataset so snapshots can exclude it
zfs create storage/media/downloads_incomplete
```

Keep `movies/`, `tv/`, `downloads/` as plain directories under `storage/media` — they must stay
inside the one dataset. If you ever do separate datasets for them, hardlinks break.

### Migrating an existing library onto this layout

Must be a **copy/move that creates new files at the destination**, not a filesystem-level move:

- `mv` a file **across** datasets on the same pool is actually a copy+unlink, so a one-shot
  `mv storage/oldmedia/tv storage/media/` still ends up hard-linkable. What breaks it is
  **rclone/`cp --reflink`/zfs-send**: rclone reduces copies to reflinks, zfs-send preserves
  dataset structure, so files would not be real copies after a reflink-only move.
- If you migrated with rclone carelessly, re-import a folder (do an in-place copy of its files)
  or delete+re-add in the \*arrs rather than trusting links.

## Repo location

The repo lives at `/mnt/storage/docker/stacks` (dataset `storage/docker`), so compose files are
snapshotted with the configs. `just up` pre-creates each service's dir under
`/mnt/storage/docker/data` (`$SERVICES_DIR`) with the right ownership (via its `dirs`
dependency) and then brings everything up.

## Shared Docker networks

`internal` and `external` are recreated by `just networks` / `just up` (idempotent).

**Gotcha: TrueNAS apps-VM rebuilds wipe them.** Every TrueNAS update rebuilds the apps VM; the
shared `external:true` networks are recreated then, so they come back — but a clean re-install
of the apps system drops them. If containers start failing on DNS/network after reinstalling
apps, run `just networks` and `just up`, that's the whole fix.

## Backups / ZFS snapshots

Drop-in snapshots (fail-fast, sendable off-box):

```bash
zfs snapshot -r storage/docker@manual-$(date +%F)   # configs + compose (this is the one that matters)
zfs snapshot storage/media@manual-$(date +%F)       # library checkpoint

zfs list -t snapshot                                 # inspect
zfs destroy storage/docker@manual-$(date +%F)        # drop a bad one
```

Then schedule: **hourly/daily on `storage/docker`** (small, changes constantly — includes
`acme.json`), **daily/weekly on `storage/media`**. Keep the two schedules independent — never
mix config snapshots with bulk media. Prune on a retention window, not by hand.

If you gave `downloads_incomplete/` its own dataset, exclude it from the media snapshot schedule
(packaged via `-o ... ` or just snapshot `storage/media` children you care about; simplest is to
snapshot `storage/media` from inside the dataset so incomplete is included but cheap).

Off-box: `zfs send -R storage/docker@latest | ssh offsite zfs recv backup/docker` (encrypt,
compress, or use `syncoid`).

## GPU (NVIDIA)

Jellyfin is configured to use the NVIDIA GPU (P400). TrueNAS ships a **legacy driver sysext**
that must be re-enrolled **after every TrueNAS update or reboot** — it does not survive updates:

```bash
# fetch/re-add the raw sysext for the running release, e.g. from the driver repo:
#   https://truenas-drivers.zhouyou.info/25.10.7/nvidia.raw
just restart media-server   # or the jellyfin service
docker exec jellyfin nvidia-smi   # confirm GPU attached again
```

If `nvidia-smi` is missing inside Jellyfin after an update, the sysext is not enrolled —
re-add it and recreate the container (the compose for this stack is read-only to this too:
Jellyfin already requests the device; the host driver is the only moving part).

## Decypharr mount visibility

The Decypharr DFS mount created inside its container propagates to the **host** at
`/mnt/decypharr` (via the `:rshared` bind) — so you can inspect it from the TrueNAS shell, and
any container that binds that path sees the same files. If you want a file-debugging spot for
"does the arr see X", start there.
