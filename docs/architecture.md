# Architecture — How the DUMB stack scripts work

Platform-agnostic explanation of what these scripts do and why. For OS-specific install
steps see [`unraid.md`](unraid.md) or [`linux.md`](linux.md).

---

## Foundation & Consumer model

```
DUMB-2026 (foundation)
  ├─ NzbDAV + rclone mount         → host: <REMOTE_BIND>/nzbdav/
  ├─ Decypharr DFS mount           → host: <REMOTE_BIND>/decypharr/realdebrid/
  ├─ Internal *Arrs                (Sonarr HD/4K, Radarr HD/4K — manage -remote libraries)
  ├─ Postgres (internal)
  └─ rclone VFS cache              → host: <RCLONE_CACHE_DIR>/

prowlarr           (enabler — started if down; provides indexer feeds to DUMB's internal *Arrs)
plex               (reads symlinks via its own /mnt/debrid bind — a mount consumer,
                    but stopped/started by a separate monitor, not the Heartbeat)

CONSUMERS = empty by default
  DUMB's internal *Arrs restart automatically with the container.
  External *Arrs (e.g. binhex-sonarr/radarr) managing LOCAL libraries
  have no relationship to DUMB's mounts — they are not touched by these scripts.
```

DUMB exposes mounts to the host via a **shared propagation bind**:
container `/mnt/debrid` ↔ host `<REMOTE_BIND>`.

`*Arr` containers bind the same host path as `/mnt/debrid`, so `*Arrs` write symlinks using
the **container-side path** (`/mnt/debrid/decypharr/realdebrid/__all__/...`). That's
why the Sentinel matches symlink targets against `$CONTAINER_REMOTE_PREFIX`, not the
host path.

---

## The four scripts

### 1. Mount Heartbeat
Runs every 5 minutes. Validates both mounts, recovers by restarting DUMB-2026 if either
is dead, stops consumers before recovery and restarts them once both mounts pass. Primes
the rclone dir-cache incrementally with a small time budget per run. If recovery fails
`MAX_FAILURES` times in a row, escalates to a hard reset (wipe rclone VFS cache,
container restart).

### 2. Plex Mount Monitor
Runs every 2 minutes — faster than the Heartbeat. Plex caches stale FUSE handles after a
mount drops and **cannot recover on its own**; the only fix is restarting the container
once the mount is back. Either RD (Decypharr) or NzbDAV going down stops Plex; both back
up restarts it. Separate from the Heartbeat — Plex recovery and mount priming run at different cadences and should not share code.

### 3. Symlink Sentinel
Audits `-remote` media folders for broken symlinks pointing at the debrid mounts. Uses a
**one-readdir-per-mount** ground-truth index (`decypharr/__all__` packs + NzbDAV
categories) instead of stat-ing every symlink, so the scan is FUSE-cheap. Broken links
trigger the matching `*Arr` to rescan + a Plex section refresh. Safety: dry-run default,
circuit breaker on broken-count, rolling 24h deletion cap, mount-maturity gate.

### 4. Shutdown Janitor
Runs at OS/array shutdown. Stops `DUMB-2026` first with a long grace timeout (so the
in-container postgres flushes cleanly), unmounts the shared debrid bind, then stops all
remaining containers. Prevents shutdown stalls on stale FUSE mountpoints.

---

## Path reference

The Unraid and Linux variants use different host paths by default. Both scripts behave
identically once paths resolve.

| Resource | Unraid (default) | Linux (default — override in `config.env`) |
|---|---|---|
| NzbDAV mount | `/mnt/user/data/remote/nzbdav/` | `${REMOTE_BIND}/nzbdav/` |
| Decypharr DFS mount | `/mnt/user/data/remote/decypharr/realdebrid/` | `${REMOTE_BIND}/decypharr/realdebrid/` |
| rclone VFS cache | `/mnt/cache_ssd/rclone-cache/cache/` | `${RCLONE_CACHE_DIR}` |
| Symlink-backed media | `/mnt/user/data/media/*-remote/` | `${MEDIA_ROOT}/*-remote/` |
| State + logs | `/mnt/user/appdata/other/scripts/dumb-2026/` | `${STATE_DIR}`, `${LOG_DIR}` |
| Container-side prefix (in symlinks) | `/mnt/debrid` | `${CONTAINER_REMOTE_PREFIX}` |

Plex library section IDs (used by the Sentinel) are not paths — they're integers from
`/library/sections`. Get yours with:

```
curl -s "$PLEX_URL/library/sections?X-Plex-Token=$PLEX_TOKEN" | \
  grep -oE 'key="[0-9]+" type="[a-z]+" title="[^"]+"'
```

---

## Why Plex isn't in the Heartbeat's CONSUMERS list

Plex needs **container-restart-on-recovery** to drop stale FUSE handles. The Heartbeat
restarts `DUMB-2026` and brings *Arrs back, but Plex requires its own monitoring loop on
a faster cadence (2 min vs 5 min). - Heartbeat: foundation health and priming.
- Plex Monitor: user-visible playback recovery.
- Both run independently. If Heartbeat is mid-recovery, the Plex Monitor sees mounts down, stops Plex, then starts it when mounts return.

---

## Out of scope

- Manage a host-side `rclone` binary. rclone lives inside DUMB-2026; recovery is
  container-level.
- Touch external `*Arr` containers that manage non-`-remote` libraries.
- Delete files unprompted. The Sentinel only deletes **broken symlinks** matching the
  debrid prefixes, gated by dry-run / circuit breaker / 24h cap.
- Modify rclone or DUMB configuration. Everything is read-only from the script's
  perspective except mount state and symlinks.
