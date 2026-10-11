# Unraid setup guide — DUMB stack

Setup steps for running the scripts in [`scripts/unraid/`](../scripts/unraid/) via the
**User Scripts** plugin on Unraid. See [`architecture.md`](architecture.md) for the
foundation/consumer model and what each script does.

> **v2.0 (October 2026):** the scripts are NzbDAV/InfiniDysk-only. Decypharr and
> Real-Debrid are no longer checked. If you still run Decypharr, stay on the v1 scripts
> in git history.

---

## 1. Pre-flight

Run these in an Unraid terminal. Each should succeed before you deploy.

```bash
# State dir (also holds dumb.conf)
mkdir -p /mnt/user/appdata/other/scripts/dumb-2026/

# NzbDAV mount: must be a fuse.rclone mount and must list
grep ' /mnt/user/data/remote/nzbdav ' /proc/mounts
ls /mnt/user/data/remote/nzbdav/completed-symlinks

# InfiniDysk database (the Sentinel reads it read-only)
sqlite3 -readonly /mnt/user/appdata/DUMB-2026/data/nzbdav/db.sqlite "SELECT COUNT(*) FROM DavItems;"

# Symlink target format: expect /mnt/debrid/nzbdav/.ids/<a>/<b>/<c>/<d>/<e>/<uuid>
find /mnt/user/data/media/movies-hd-remote -maxdepth 2 -type l | head -3 | xargs -I{} readlink {}
```

---

## 2. Create `dumb.conf`

All host-specific values and secrets live in one file that every script sources. The
scripts themselves have no placeholders, so you can paste the repo copies unchanged.

```bash
cp scripts/unraid/dumb.conf.example /mnt/user/appdata/other/scripts/dumb-2026/dumb.conf
chmod 600 /mnt/user/appdata/other/scripts/dumb-2026/dumb.conf
```

Fill in:

| Setting | Where to find it |
|---|---|
| `PLEX_TOKEN` | Plex → any item → ⋯ → Get Info → View XML → URL contains `X-Plex-Token=` |
| `SONARR_HD_API` … `RADARR_4K_API` | Each DUMB-internal *Arr → Settings → General → API Key |
| `DUMB_API_USERNAME` / `DUMB_API_PASSWORD` | Optional. Your DUMB frontend login. Enables per-process restarts in the Heartbeat. |

The URLs default to `127.0.0.1` with DUMB's mapped ports. Change them only if your port
mappings differ. To keep the file elsewhere, set `DUMB_CONF=/path/to/file` in front of
each script.

---

## 3. Deploy via the User Scripts plugin

Paste each `(DUMB)` script into a User Script entry with the schedule below.

| Script | Schedule |
|---|---|
| `Mount Script (DUMB)` | Custom cron: `*/5 * * * *` |
| `Plex Mount Monitor (DUMB)` | Custom cron: `*/2 * * * *` |
| `Symlink Cleanup (DUMB)` | Custom cron: `0 6 * * *` |
| `Array Stop Script (DUMB)` | **At Stopping of Array** |

Upgrading from v1: delete the stale `SENTINEL_HOLD.txt` in the state dir after reviewing
it. The old `plex_mount_state` and `prime_state.db` formats are read and replaced
automatically.

---

## 4. Verify

Run each script manually ("Run Script") before enabling its schedule.

1. **Heartbeat (happy path).** Run with the mount healthy. Expect
   `Passed: NzbDAV is UP` and no restart.

2. **Plex Monitor.** Run with the mount healthy. Expect `Mount healthy` and Plex
   untouched.

3. **Sentinel (dry run).** Leave `DRY_RUN_GLOBAL` at `Y` and run it. The summary shows
   how many links are broken, and `sentinel_audit.log` lists each one as `MOCK` with a
   reason (`missing-id:<uuid>` or `legacy-target-gone`). To test detection, plant a link
   to an id that doesn't exist:

   ```bash
   mkdir -p "/mnt/user/data/media/tv-remote/_Test/Season 01"
   ln -s /mnt/debrid/nzbdav/.ids/0/0/0/0/0/00000000-0000-0000-0000-000000000000 \
     "/mnt/user/data/media/tv-remote/_Test/Season 01/test.mkv"
   ```

   Run the Sentinel and confirm a `MOCK` entry for it. Then clean up:

   ```bash
   rm -rf /mnt/user/data/media/tv-remote/_Test
   ```

   Set `DRY_RUN_GLOBAL="N"` in `dumb.conf` only after the audit log looks right.

4. **Janitor.** Stop the array from the Unraid WebUI. Check
   `/mnt/user/appdata/other/scripts/dumb-2026/shutdown.log`. The array should stop
   without "Retry unmounting disk share(s)" errors.

---

## Adding a new library to the Sentinel

1. If it uses a new DUMB-internal *Arr instance, add its URL/API pair to `dumb.conf`:
   ```bash
   RADARR_ANIME_URL="http://127.0.0.1:<port>"
   RADARR_ANIME_API="<api key>"
   ```
   Use DUMB's internal mapped ports, not the independent binhex *Arr ports.

2. Override `LIBRARIES` in `dumb.conf` (it replaces the script's default list, so copy
   the existing four entries too):
   ```bash
   LIBRARIES=(
       "/mnt/user/data/media/tv-remote|TV Shows|SONARR_HD|LIVE|PLEX|4|3|4"
       ...
       "/mnt/user/data/media/<folder>|<Display Name>|RADARR_ANIME|LIVE|PLEX|<plex-key>|2|3"
   )
   ```

   Depth guide: for `Movies/<Movie (Year)>/file.mkv` use `min=2 max=3`. For
   `TV/<Show>/<Season>/file.mkv` use `min=3 max=4`.

Only add `-remote` folders (DUMB-managed symlinks). Never add local-only folders
(`tv/`, `movies-hd/`, `movies-uhd/`, `movies-indian/`). Independent *Arrs manage those,
and they contain no NzbDAV symlinks.

Targeted *Arr rescans and searches need `jq` on the host. Without it, the Sentinel sends
one library-wide `RescanMovie`/`RescanSeries` per run instead and skips the search.

---

## Appdata backup coordination

The DUMB scripts detect a running appdata backup and skip that run (logging `[PAUSED] appdata backup in progress`). This prevents the scripts from restarting `DUMB-2026` or `binhex-plex` mid-backup, which corrupts the tar archive.

Two detection layers:
1. **Sentinel file** `/tmp/dumb-scripts.pause` — set by a pre-run hook, cleared by a post-run hook.
2. **Process fallback** — `pgrep` for the backup process (covers the case where hooks aren't yet configured).

### Setting up the hooks

In the **Commander-Apps appdata.backup** plugin (Settings → Appdata Backup → Advanced →
Custom pre/post scripts), add:

**Pre-run script** (runs before containers are stopped):
```bash
#!/bin/bash
touch /tmp/dumb-scripts.pause
sleep 10   # allow any in-flight script run to finish before the backup stops containers
```

**Post-run script** (runs after containers are restarted):
```bash
#!/bin/bash
rm -f /tmp/dumb-scripts.pause
```

> **Why the `sleep 10` in pre-run?** The guard fires at the top of each script run. If a
> Heartbeat run passed the guard a few seconds before the pre-run hook executes, it will
> continue — including any `docker restart` it issues. The 10-second sleep covers the gap:
> the next cron tick (5 min later) will see the sentinel and skip cleanly.

### Stale-lock safety

The sentinel auto-expires after 2 hours (`BACKUP_PAUSE_MAX_AGE_MIN=120`). If the backup
crashes and the post-run hook never fires, all scripts resume automatically after two hours.

To change the timeout, set `BACKUP_PAUSE_MAX_AGE_MIN` in the User Scripts plugin's
environment, or set it in `dumb.conf`.

### Verifying the pgrep fallback pattern

The default pattern matches both the modern `appdata.backup` and legacy `ca.backup2`
Commander-Apps plugins. Confirm it matches your installation:

```bash
# Run this while a backup is active
pgrep -af backup
```

If the output doesn't contain `appdata.backup` or `ca.backup2`, set
`BACKUP_PROC_PATTERN` to a pattern that does in `dumb.conf`.

---

## Hard reset

Run `Mount Script (DUMB)` once with `HARD_RESET=Y`. Either set it in `dumb.conf` or
prefix the script body with `HARD_RESET=Y`. This will:

1. Stop `DUMB-2026`.
2. Wipe `/mnt/cache_ssd/rclone-cache/cache/*`.
3. Start `DUMB-2026`.

Remove `HARD_RESET=Y` immediately after. The automatic hard reset (after `MAX_FAILURES`
failed recoveries) stops and starts the container but never wipes the cache.

---

## Original (non-DUMB) scripts

The `Mount Script`, `Symlink Cleanup`, and `Array Stop Script` files (without `(DUMB)`)
in `scripts/unraid/` target a different architecture: host rclone binary, separate
NzbDAV and Decypharr containers, ZFS pools. Do not run them on a DUMB-stack server.

For community discussion: [Unraid Support Thread](https://forums.unraid.net/topic/198498-rclone-scripts-to-mount-nzbdav-to-create-a-large-plex-library-with-fast-launch-times-and-efficient-arr-usage/).
