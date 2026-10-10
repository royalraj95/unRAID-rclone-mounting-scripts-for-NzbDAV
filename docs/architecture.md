# Architecture — How the DUMB stack scripts work

Platform-agnostic explanation of what these scripts do and why. For install steps see
[`unraid.md`](unraid.md) or [`linux.md`](linux.md).

> **v2.0 (Unraid scripts, October 2026):** NzbDAV/InfiniDysk only. Decypharr and
> Real-Debrid were disabled in DUMB. The v1 scripts gated everything on the Decypharr
> mount, so they kept Plex stopped and restarted the container on every run. The Linux
> port in `scripts/linux/` is still v1.

---

## Foundation & consumer model

```
DUMB-2026 (foundation)
  ├─ InfiniDysk (DUMB process "InfiniDysk"; the NzbDAV fork)
  │    WebDAV backend :8080 (host :8089), SQLite DB at <appdata>/data/nzbdav/db.sqlite
  ├─ rclone (DUMB process "rclone w/ InfiniDysk")
  │    mounts nzbdav: → /mnt/debrid/nzbdav → host <REMOTE_BIND>/nzbdav/
  ├─ Internal *Arrs  (Sonarr HD/4K, Radarr HD/4K — import into the -remote libraries)
  ├─ Postgres (internal)
  └─ rclone VFS cache → host <RCLONE_CACHE_DIR>/

prowlarr   (enabler — started if down; feeds indexers to DUMB's internal *Arrs)
plex       (reads the -remote symlinks; stopped/started by its own monitor)
```

DUMB exposes the mount to the host through a shared bind: container `/mnt/debrid` ↔
host `<REMOTE_BIND>`. The *Arrs write symlinks using the container-side path:

```
/mnt/user/data/media/movies-hd-remote/<Movie>/<file>.mkv
  → /mnt/debrid/nzbdav/.ids/f/d/e/1/9/fde1946f-3b99-42c7-8ebf-7a5f7dff3738
```

The trailing UUID is the item's primary key in InfiniDysk's database (`DavItems.Id`,
stored upper-case). The five directories are its first five hex characters
(`DavItems.IdPrefix`).

---

## What InfiniDysk already handles

InfiniDysk maintains its side of the library on its own, so the scripts don't:

| Setting | Effect |
|---|---|
| `repair.enable` | Health-checks every file. Unrecoverable files get removed and the owning *Arr is asked to re-grab. |
| `maintenance.remove-orphaned-schedule-enabled` | Removes InfiniDysk items that no symlink under `media.library-dir` points at. |

The scripts cover the gaps: the mount itself dying, Plex holding stale FUSE handles, and
library symlinks left behind after their InfiniDysk item is gone.

---

## The four scripts

### 1. Mount Heartbeat — every 5 minutes

Probes the mount without network I/O: it must be a mountpoint, and one readdir of
`completed-symlinks` must answer within a timeout. It also checks that InfiniDysk's
WebDAV backend answers HTTP at all. The rclone dir cache can keep answering readdir
after the backend dies.

On failure it climbs a ladder, one rung per consecutive failed recovery:

| Fail # | Action | Needs |
|---|---|---|
| 1 | Restart `rclone w/ InfiniDysk` via the DUMB API | DUMB API login in `dumb.conf` |
| 2 | Restart `InfiniDysk`, then rclone, via the DUMB API | DUMB API login |
| 3+ | `docker restart DUMB-2026` (at most once per `RECOVERY_COOLDOWN_SEC`) | — |
| `MAX_FAILURES` | Hard reset: `docker stop` + `docker start` | — |

Without API credentials, or if the API call fails, it goes straight to the container
restart. A dead backend with a live mount skips rung 1, because restarting rclone can't
revive InfiniDysk. After each action it waits up to `RECOVERY_WAIT_SEC` for the mount.
Cooldown skips don't count as failures.

v1 also "primed" the library by running `ls -d` on every symlink. That only reads the
link inode and never touches the mount, so v2 drops it.

### 2. Plex Mount Monitor — every 2 minutes

Plex caches stale FUSE handles after a mount drops and can't recover without a container
restart. The monitor stops Plex after `DOWN_THRESHOLD` (default 2) consecutive failed
probes. That debounce keeps one slow readdir from taking Plex offline. When the mount
returns it starts Plex. If someone started Plex by hand in the meantime, it restarts Plex
instead.

### 3. Symlink Sentinel — daily

Finds library symlinks whose InfiniDysk item no longer exists, without touching the
mount:

1. `find -type l -printf '%p\t%l\n'` over each `-remote` library. This reads link
   inodes only.
2. `sqlite3 -readonly db.sqlite "SELECT lower(Id) FROM DavItems"` — about 100k ids in
   well under a second. This runs after the scan, so an item imported mid-run can't look
   missing.
3. awk flags each `.ids/<uuid>` link whose UUID isn't in the export. Links into the
   retired Decypharr mount are flagged when their target is gone. Any other target is
   counted as "unknown" and left alone.

For each deleted link it asks the owning *Arr to rescan that one movie or series, and
optionally search for it. That needs `jq`; without it, the fallback is one library-wide
rescan. Plex scans just that folder.

Safety: dry-run by default; an id floor (`MIN_IDS`) and an id-drop guard
(`ID_DROP_MAX_PCT`) against a reset or restored database; a circuit breaker that writes
a hold file which actually blocks later runs; a per-run cap; and a rolling 24-hour cap.

### 4. Shutdown Janitor — at array stop

Stops `DUMB-2026` first with a 90-second grace period, so the in-container Postgres
flushes. Then it stops the remaining containers. Finally it lazily unmounts every FUSE
mount left under the shared bind, deepest first: once DUMB is gone, rclone's mountpoint
lingers as "Transport endpoint is not connected" and can stall array stop.

---

## Path reference

| Resource | Unraid default |
|---|---|
| NzbDAV mount (host) | `/mnt/user/data/remote/nzbdav/` |
| InfiniDysk database | `/mnt/user/appdata/DUMB-2026/data/nzbdav/db.sqlite` |
| rclone VFS cache | `/mnt/cache_ssd/rclone-cache/cache/` |
| Symlink-backed media (host) | `/mnt/user/data/media/*-remote/` |
| Same media as the *Arrs and Plex see it | `/data/media/*-remote/` |
| Symlink target prefix | `/mnt/debrid/nzbdav/.ids/` |
| Shared config | `/mnt/user/appdata/other/scripts/dumb-2026/dumb.conf` |
| State + logs | `/mnt/user/appdata/other/scripts/dumb-2026/` |

---

## Out of scope

- Managing a host-side `rclone` binary. rclone lives inside DUMB-2026.
- Touching external `*Arr` containers that manage non-`-remote` libraries.
- Modifying rclone, InfiniDysk or DUMB configuration, or writing to InfiniDysk's
  database.
- Deleting anything other than broken symlinks, and those only behind dry-run, the
  circuit breaker and the deletion caps.
