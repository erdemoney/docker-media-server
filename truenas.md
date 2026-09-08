# TrueNAS dataset setup

Goal: a single ZFS dataset tree that makes hardlinks work across the whole media stack
(download host → library), so Radarr/Sonarr import via instant hardlink instead of copy+delete.

## Why one dataset

Hardlinks only work within a single filesystem. In ZFS each dataset is its own filesystem, so if
`movies/` and `downloads/` live in separate datasets, a download→library hardlink fails and the
arrs silently fall back to copying (slow, doubles I/O and space on completion).

What matters is filesystem identity, **not** the Docker mount paths — Docker bind-mounts of
subdirectories inside the same dataset are all still the same filesystem, which is exactly what the
compose file relies on. There is no need to mount the whole `media` dir in each container.

## Target layout

```
/mnt/storage/docker/data/media/             <- single dataset: media
├── movies/
├── tv/
└── downloads/
    ├── incomplete/                         <- SABnzbd working dir
    └── usenet/                             <- SABnzbd completed downloads
```

- `DATA_DIR=/mnt/storage/docker/data` in `stacks/media-server/.env`
- All paths below were created with `zfs create` for `/mnt/storage/docker/data` (or already exist),
  and `media` itself is created as its own dataset:

```
zfs create -o compression=lz4 -o recordsize=1M tank/storage/docker/data/media
mkdir -p /mnt/storage/docker/data/media/{movies,tv,downloads/incomplete,downloads/usenet}
chown -R <PUID>:<PGID> /mnt/storage/docker/data/media
```

SABnzbd and every arr must see the *same* paths for downloads and library (see the volume mounts in
`stacks/media-server/compose.yaml`).

## If you already have per-category datasets

If `movies` / `tv` / `downloads` were created as separate datasets, they are separate filesystems
and hardlinks will not cross them. Migrate to the single-dataset layout:

1. Snapshot everything first:

```
zfs snapshot -r tank/storage/docker/data@pre-migration
```

2. Rename the old datasets aside (keeps them intact as rollback insurance):

```
zfs rename tank/storage/docker/data/media/movies   tank/storage/docker/data/.movies-old
zfs rename tank/storage/docker/data/media/tv       tank/storage/docker/data/.tv-old
zfs rename tank/storage/docker/data/media/downloads tank/storage/docker/data/.downloads-old
```

   (`media` must exist as a dataset first — see the target layout above.)

3. Create plain directories in their place:

```
mkdir -p /mnt/storage/docker/data/media/{movies,tv,downloads/incomplete,downloads/usenet}
```

4. Copy the data into the plain dirs with `rsync` in-place semantics so hardlinks are preserved
   and files are removed from the old datasets as they go:

```
rsync -a --remove-source-files /mnt/storage/docker/data/.movies-old/     /mnt/storage/docker/data/media/movies/
rsync -a --remove-source-files /mnt/storage/docker/data/.tv-old/         /mnt/storage/docker/data/media/tv/
rsync -a --remove-source-files /mnt/storage/docker/data/.downloads-old/  /mnt/storage/docker/data/media/downloads/
```

   (Using `--inplace` is not needed here; plain `-a` is fine. Protect `/etc/localtime`, config dirs,
   and anything else that must remain on the old dataset.)

5. Verify nothing was lost before deleting the old datasets — compare sizes:

```
du -sh /mnt/storage/docker/data/media/movies /mnt/storage/docker/data/media/tv /mnt/storage/docker/data/media/downloads
```

6. After confirming data integrity and that the stack works (imports hardlink), destroy the old
   datasets:

```
zfs destroy tank/storage/docker/data/media/.movies-old
zfs destroy tank/storage/docker/data/media/.tv-old
zfs destroy tank/storage/docker/data/media/.downloads-old
```

7. Set properties and ownership on the new dataset/tree:

```
zfs set compression=lz4 recordsize=1M tank/storage/docker/data/media
chown -R <PUID>:<PGID> /mnt/storage/docker/data/media
```

## Alternative: zero-migration layout

If you'd rather not consolidate datasets, you can keep per-category datasets *provided* the
downloader's completed directory lives inside the same dataset as each library (so a hardlink is
still same-filesystem). This is more mounts in the compose file, not a change to the file's logic:

```
media-movies/          dataset
├── movies/
└── downloads/usenet/  <- SABnzbd completed dir (same dataset as movies)
media-tv/              dataset
├── tv/
└── downloads/usenet/  <- SABnzbd completed dir (same dataset as tv)
```

Every volume source must swap to these paths and SABnzbd writes its completed downloads into each
library's dataset. It works, but the single-dataset layout above is simpler and is the recommended
target.

## Sizing / recordsize notes

- `recordsize=1M` matches how large media files are stored and read; ZFS still random-accesses small
  blocks fine for typical metadata.
- `compression=lz4` is cheap and effective on media + metadata.
- Dataset snapshots (e.g. TrueNAS replication) will be far larger than the old per-category layout
  once you also snapshot nearby config dirs — keep `/mnt/storage/docker/data` snapshots scoped.