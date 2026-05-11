# Rclone Mounting & Library Maintenance for NzbDAV + DUMB

A robust toolkit for managing Rclone mounts and media library health on Unraid, designed for the **[DUMB](https://dumbarr.com) all-in-one stack** (`DUMB-2026`). The repo ships both the original scripts (for standalone NzbDAV + Decypharr containers with host-side rclone) and the DUMB-adapted variants used in this setup.

---

## What's in the Box

Three core scripts, each with an original and a DUMB-adapted version (`Scripts/* (DUMB)`):

### 1. Mount Script — Rclone Heartbeat & Intelligent Priming
The always-on monitor run every 5 minutes. Validates both NzbDAV and Decypharr mounts, stops `*Arr` consumers before touching the mount, recovers by restarting `DUMB-2026` (rclone lives inside the container), then restarts consumers once both mounts are confirmed alive. Includes a "Nuclear Option" hard-reset (wipes VFS cache, recycles container) if recovery fails `MAX_FAILURES` consecutive times. Primes the rclone dir-cache incrementally on each run.

### 2. Symlink Cleanup — Symlink Sentinel
Audits media library folders for broken symlinks pointing at the debrid mounts. Calls the matching `*Arr` to trigger a rescan, then refreshes the Plex library section. Rate-limited with a circuit breaker (`MAX_BROKEN_BEFORE_HALT`) and a rolling 24-hour deletion cap. Start with `DRY_RUN_GLOBAL="Y"`.

### 3. Plex Mount Monitor
Runs every 2 minutes. Stops `binhex-plex` when the RealDebrid (Decypharr) mount goes down, and restarts it once the mount recovers. Plex caches stale FUSE handles after a mount drops and must be container-restarted to re-see recovered mounts — this handles that automatically without disrupting playback unnecessarily. RD is the primary gate; NzbDAV state is logged for diagnostics only.

### 4. Array Stop Script — The Janitor
Runs **at array stop**. Stops `DUMB-2026` first with a 90-second grace period (giving postgres time to flush internally), unmounts the shared debrid bind (`/mnt/user/data/remote`), then stops all remaining containers.

---

## How It Works

The scripts use a **Foundation & Consumer model**:

```
DUMB-2026 (foundation)
  ├─ NzbDAV + rclone mount         → host: /mnt/user/data/remote/nzbdav/
  ├─ Decypharr DFS mount           → host: /mnt/user/data/remote/decypharr/realdebrid/
  ├─ Internal *Arrs                (Sonarr HD/4K, Radarr HD/4K — manage -remote libraries)
  ├─ Postgres (internal)
  └─ rclone VFS cache              → host: /mnt/cache_ssd/rclone-cache/cache/

binhex-prowlarr  (enabler — started if down; provides indexer feeds to DUMB's internal *Arrs)
binhex-plex      (reads symlinks via its own /mnt/debrid bind — technically a mount consumer
                  but NOT stopped during surgery; see below)

CONSUMERS = empty
  DUMB's internal *Arrs restart automatically with the container.
  binhex-sonarr, binhex-radarr-UHD, binhex-radarr-indian, bazarr-4k/hd/indian
  are an independent stack managing LOCAL libraries (tv/, movies-hd/, etc.) with
  no relationship to DUMB's mounts — they are never touched by these scripts.
```

**Why isn't Plex in the Heartbeat's CONSUMERS list?**
Plex needs special handling: it doesn't recover on its own after a mount drops (it caches stale FUSE handles and must be container-restarted). The `Plex Mount Monitor` script handles this at 2-minute cadence, which is faster than the Heartbeat's 5-minute cycle and keeps the concern cleanly separated. Plex is stopped precisely when mounts go down and restarted once they recover — no manual intervention needed.

DUMB exposes mounts to the host via a `shared` propagation bind: container `/mnt/debrid` ↔ host `/mnt/user/data/remote`. `*Arr` containers bind the same host path as `/mnt/debrid`, so symlinks written by `*Arrs` use the container-side path (`/mnt/debrid/decypharr/realdebrid/__all__/...`).

---

## Path Reference

| Resource | Host path |
|---|---|
| NzbDAV mount | `/mnt/user/data/remote/nzbdav/` |
| Decypharr DFS mount | `/mnt/user/data/remote/decypharr/realdebrid/` |
| rclone VFS cache | `/mnt/cache_ssd/rclone-cache/cache/` |
| Symlink-backed media | `/mnt/user/data/media/*-remote/` |
| Script state & logs | `/mnt/user/appdata/other/scripts/dumb-2026/` |

Plex library section IDs (used by Sentinel):

| Library | Plex key |
|---|---|
| TV Shows | 4 |
| TV Shows - 4K | 10 |
| Movies-HD | 2 |
| Movies-4k | 1 |
| Movies-Indian | 3 |

---

## Quick Setup Guide

### 1. Pre-flight (run on Unraid terminal)

Confirm both mounts are healthy before deploying:

```bash
# State dir
mkdir -p /mnt/user/appdata/other/scripts/dumb-2026/

# NzbDAV probe (should list subdirs)
ls /mnt/user/data/remote/nzbdav/completed-symlinks

# Decypharr probe (both should succeed)
ls /mnt/user/data/remote/decypharr/realdebrid/__all__
ls /mnt/user/data/remote/decypharr/realdebrid/version.txt

# Confirm symlink target format (should show /mnt/debrid/... paths)
find /mnt/user/data/media -maxdepth 4 -type l 2>/dev/null | head -3 | \
  xargs -I{} sh -c 'echo "{}"; readlink "{}"'
```

### 2. Fill in secrets (edit `Scripts/Symlink Cleanup (DUMB)`)

| Placeholder | Where to find it |
|---|---|
| `<UNRAID_HOST_OR_IP>` | Hostname or IP where your DUMB-exposed services are reachable |
| `<PLEX_PORT>` | Plex mapped port in Unraid Docker settings |
| `<YOUR_PLEX_TOKEN>` | Click any item in Plex → ⋯ → Get Info → View XML → URL contains `X-Plex-Token=` |
| `<SONARR_HD_PORT>` / `<SONARR_4K_PORT>` | DUMB Sonarr HD / 4K mapped ports |
| `<RADARR_HD_PORT>` / `<RADARR_4K_PORT>` | DUMB Radarr HD / 4K mapped ports |
| `<YOUR_*_API_KEY>` | Matching DUMB internal *Arr UI → Settings → General → API Key |

Keep your real, credentialed local copies in `Scripts/_local-private/` (gitignored).

### 3. Deploy via User Scripts plugin

Paste each `(DUMB)` script into a new User Script entry:

| Script | Schedule |
|---|---|
| `Mount Script (DUMB)` | Custom cron: `*/5 * * * *` |
| `Plex Mount Monitor (DUMB)` | Custom cron: `*/2 * * * *` |
| `Symlink Cleanup (DUMB)` | Custom cron: `0 4 * * *` |
| `Array Stop Script (DUMB)` | **At Stopping of Array** |

### 4. Verify

Run each script manually ("Run Script") before relying on the schedule:

1. **Heartbeat (happy path)** — run while `DUMB-2026` is healthy. Both probes should pass, priming should run, no `docker restart` should fire.

2. **Heartbeat (recovery)** — `docker stop DUMB-2026`, then run Heartbeat. Expect: consumers stopped → `docker restart DUMB-2026` → consumers restarted. Confirm `binhex-plex` was NOT touched.

3. **Sentinel (dry run)** — with `DRY_RUN_GLOBAL="Y"`, create a test broken symlink:
   ```bash
   mkdir -p /mnt/user/data/media/tv-remote/_Test
   ln -s /mnt/debrid/nzbdav/nonexistent.mkv /mnt/user/data/media/tv-remote/_Test/test.mkv
   ```
   Run the Sentinel. Check `sentinel_audit.log` for a `MOCK` entry. Then clean up:
   ```bash
   rm -rf /mnt/user/data/media/tv-remote/_Test
   ```
   Flip `DRY_RUN_GLOBAL="N"` only after the audit log confirms correct behaviour.

4. **Janitor** — stop the array from Unraid WebUI. Check `/mnt/user/appdata/other/scripts/dumb-2026/shutdown.log`. Array should stop cleanly without "Retry unmounting disk share(s)" errors.

---

## Adding a New Library to the Sentinel

In `Scripts/Symlink Cleanup (DUMB)`:

1. If routing to a new DUMB-internal *Arr instance, add its URL/API pair:
   ```bash
   RADARR_4K_URL="http://<UNRAID_HOST_OR_IP>:<RADARR_4K_PORT>"
   RADARR_4K_API="<YOUR_RADARR_4K_API_KEY>"
   ```
   Use your DUMB internal mapped ports — not the independent binhex *Arr ports.

2. Add a `LIBRARIES` entry:
   ```bash
   "/mnt/user/data/media/<folder>|<Display Name>|RADARR_4K|LIVE|PLEX|<plex-key>|<min-depth>|<max-depth>"
   ```

   Depth guide: for `Movies/<Movie (Year)>/file.mkv` use `min=2 max=3`. For `TV/<Show>/<Season>/file.mkv` use `min=3 max=4`.

   Get Plex section keys:
   ```bash
   curl -s "http://<UNRAID_HOST_OR_IP>:<PLEX_PORT>/library/sections?X-Plex-Token=<YOUR_PLEX_TOKEN>" | \
     grep -oE 'key="[0-9]+" type="[a-z]+" title="[^"]+"'
   ```

Only add `-remote` folders (DUMB-managed symlinks). Never add local-only folders (`tv/`, `movies-hd/`, `movies-uhd/`, `movies-indian/`) — those are managed by the independent binhex stack and don't contain symlinks pointing at the debrid mounts.

---

## Hard Reset

Set `HARD_RESET="Y"` in `Mount Script (DUMB)` and run once via User Scripts. This will:
1. Stop all consumers
2. Stop `DUMB-2026`
3. Wipe `/mnt/cache_ssd/rclone-cache/cache/*`
4. Start `DUMB-2026`
5. Exit (consumers remain stopped until the next 5-minute heartbeat run)

Reset `HARD_RESET` back to `"N"` immediately after.

---

## Original Scripts

The original `Scripts/Mount Script`, `Scripts/Array Stop Script`, and `Scripts/Symlink Cleanup` remain in the repo for reference. They target a different architecture (host rclone binary, separate `NzbDAV` and `Decypharr` containers, ZFS pools). Do not deploy the originals on this server.

For community discussion: [Unraid Support Thread](https://forums.unraid.net/topic/198498-rclone-scripts-to-mount-nzbdav-to-create-a-large-plex-library-with-fast-launch-times-and-efficient-arr-usage/)

---

**Use at your own risk.** Always test with dry-run modes before enabling live deletions. These scripts stop Docker containers and delete symlinks — verify the configuration matches your setup before deploying.
