# Unraid setup guide — DUMB stack

Setup steps for running the scripts in [`scripts/unraid/`](../scripts/unraid/) via the
**User Scripts** plugin on Unraid. See [`architecture.md`](architecture.md) for the
foundation/consumer model and what each script does.

---

## 1. Pre-flight

Confirm both mounts are healthy before deploying. From an Unraid terminal:

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

---

## 2. Fill in secrets

Edit `scripts/unraid/Symlink Cleanup (DUMB)` and replace the placeholders:

| Placeholder | Where to find it |
|---|---|
| `<UNRAID_HOST_OR_IP>` | Hostname or IP where your DUMB-exposed services are reachable |
| `<PLEX_PORT>` | Plex mapped port in Unraid Docker settings |
| `<YOUR_PLEX_TOKEN>` | Plex → any item → ⋯ → Get Info → View XML → URL contains `X-Plex-Token=` |
| `<SONARR_HD_PORT>` / `<SONARR_4K_PORT>` | DUMB Sonarr HD / 4K mapped ports |
| `<RADARR_HD_PORT>` / `<RADARR_4K_PORT>` | DUMB Radarr HD / 4K mapped ports |
| `<YOUR_*_API_KEY>` | Matching DUMB internal *Arr UI → Settings → General → API Key |

Keep your real, credentialed local copies under a gitignored path
(e.g. `scripts/unraid/_local-private/`).

---

## 3. Deploy via the User Scripts plugin

Paste each `(DUMB)` script into a new User Script entry with the schedule below.

| Script | Schedule |
|---|---|
| `Mount Script (DUMB)` | Custom cron: `*/5 * * * *` |
| `Plex Mount Monitor (DUMB)` | Custom cron: `*/2 * * * *` |
| `Symlink Cleanup (DUMB)` | Custom cron: `0 4 * * *` |
| `Array Stop Script (DUMB)` | **At Stopping of Array** |

---

## 4. Verify

Run each script manually ("Run Script") before relying on the schedule.

1. **Heartbeat (happy path)** — run while `DUMB-2026` is healthy. Both probes should
   pass, priming should run, no `docker restart` should fire.

2. **Heartbeat (recovery)** — `docker stop DUMB-2026`, then run Heartbeat. Expect:
   consumers stopped → `docker restart DUMB-2026` → consumers restarted. Confirm
   `binhex-plex` was NOT touched.

3. **Sentinel (dry run)** — with `DRY_RUN_GLOBAL="Y"`, create a test broken symlink:

   ```bash
   mkdir -p /mnt/user/data/media/tv-remote/_Test
   ln -s /mnt/debrid/nzbdav/nonexistent.mkv /mnt/user/data/media/tv-remote/_Test/test.mkv
   ```

   Run the Sentinel. Check `sentinel_audit.log` for a `MOCK` entry. Then clean up:

   ```bash
   rm -rf /mnt/user/data/media/tv-remote/_Test
   ```

   Flip `DRY_RUN_GLOBAL="N"` only after the audit log confirms correct behavior.

4. **Janitor** — stop the array from the Unraid WebUI. Check
   `/mnt/user/appdata/other/scripts/dumb-2026/shutdown.log`. Array should stop cleanly
   without "Retry unmounting disk share(s)" errors.

---

## Adding a new library to the Sentinel

In `scripts/unraid/Symlink Cleanup (DUMB)`:

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

   Depth guide: for `Movies/<Movie (Year)>/file.mkv` use `min=2 max=3`. For
   `TV/<Show>/<Season>/file.mkv` use `min=3 max=4`.

Only add `-remote` folders (DUMB-managed symlinks). Never add local-only folders
(`tv/`, `movies-hd/`, `movies-uhd/`, `movies-indian/`) — those are managed by independent
*Arrs and don't contain symlinks pointing at the debrid mounts.

---

## Hard reset

Set `HARD_RESET="Y"` in `scripts/unraid/Mount Script (DUMB)` and run once via User
Scripts. This will:

1. Stop all consumers.
2. Stop `DUMB-2026`.
3. Wipe `/mnt/cache_ssd/rclone-cache/cache/*`.
4. Start `DUMB-2026`.
5. Exit (consumers remain stopped until the next 5-minute heartbeat run).

Reset `HARD_RESET` back to `"N"` immediately after.

---

## Original (non-DUMB) scripts

The `Mount Script`, `Symlink Cleanup`, and `Array Stop Script` files (without `(DUMB)`)
in `scripts/unraid/` target a different architecture: host rclone binary, separate
NzbDAV and Decypharr containers, ZFS pools. They're retained for reference. Do not run
them on a DUMB-stack server.

For community discussion: [Unraid Support Thread](https://forums.unraid.net/topic/198498-rclone-scripts-to-mount-nzbdav-to-create-a-large-plex-library-with-fast-launch-times-and-efficient-arr-usage/).
