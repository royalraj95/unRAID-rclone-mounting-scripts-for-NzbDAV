# Linux / Docker setup guide — DUMB stack

Setup steps for running the scripts in [`scripts/linux/`](../scripts/linux/) on a generic
Linux host (Ubuntu, Debian, Fedora, etc.) using **systemd timers** as the scheduler. See
[`architecture.md`](architecture.md) for what each script does.

---

## Prerequisites

- Docker Engine and the [DUMB](https://dumbarr.com) container (`DUMB-2026`) already
  running on the host.
- systemd-based init (any mainstream modern distro). If you don't have systemd, see the
  **cron fallback** section at the bottom.
- The DUMB container's `/mnt/debrid` exposed to the host as a **shared propagation
  bind** (default `/srv/dumb/remote` in this guide — override via `config.env`).
- `curl`, `findutils`, `coreutils`, `awk`, `bash` (≥4). All standard.
- Optional: `apprise` if you want the Apprise notification backend.

---

## Default paths (override in `config.env`)

| Resource | Default |
|---|---|
| Scripts | `/opt/dumb-scripts/` |
| Config | `/etc/dumb-scripts/config.env` |
| State | `/var/lib/dumb-scripts/` |
| Logs | `/var/log/dumb-scripts/` *and* the systemd journal (`journalctl -t dumb-scripts`) |
| Host bind of debrid mounts | `/srv/dumb/remote/` |
| Media library root | `/srv/dumb/media/` |
| Rclone VFS cache | `/var/cache/rclone/cache/` |

If your DUMB container exposes its bind somewhere else (e.g. `/mnt/data/remote`), set
`REMOTE_BIND` in `config.env` accordingly.

---

## Install

```bash
git clone https://github.com/royalraj95/unRAID-rclone-mounting-scripts-for-NzbDAV.git
cd unRAID-rclone-mounting-scripts-for-NzbDAV/scripts/linux

sudo ./systemd/install.sh
```

The installer:

1. Copies the four scripts + `lib/` → `/opt/dumb-scripts/`.
2. Creates `/etc/dumb-scripts/config.env` from `config.env.example` (only if missing).
3. Installs the seven systemd unit files → `/etc/systemd/system/`.
4. `systemctl daemon-reload`.
5. Enables and starts the three repeating timers.
6. Enables the shutdown janitor service (it only runs at shutdown).

---

## Configure

```bash
sudoedit /etc/dumb-scripts/config.env
```

At minimum, set:

- **Foundation** — `DUMB_CONTAINER`, `PLEX_CONTAINER`, `ENABLERS`, `CONSUMERS`.
- **Paths** — `REMOTE_BIND`, `MEDIA_ROOT`, `RCLONE_CACHE_DIR` if non-default.
- **Plex** — `PLEX_URL`, `PLEX_TOKEN`. Get the token from Plex → any item → ⋯ → Get Info
  → View XML → URL contains `X-Plex-Token=`.
- **DUMB internal *Arrs** — `SONARR_HD_URL` + `SONARR_HD_API` and the others you use.
  Each *Arr UI → Settings → General → API Key.
- **Sentinel safety** — leave `DRY_RUN_GLOBAL=Y` for the first runs.
- **Notifications** — `NOTIFY_BACKEND` (see [`notifications.md`](notifications.md)).

After editing, restart the timers to pick up the new config:

```bash
sudo systemctl restart \
  nzbdav-heartbeat.timer \
  nzbdav-plex-monitor.timer \
  nzbdav-symlink-cleanup.timer
```

(The shutdown janitor only fires at shutdown so it doesn't need restarting.)

---

## Verify

Same four checks as the Unraid guide, with systemctl/journalctl idioms.

### 1. Heartbeat (happy path)

```bash
sudo systemctl start nzbdav-heartbeat.service
journalctl -u nzbdav-heartbeat.service -e
```

Expect: both `Passed: NzbDAV is UP` + `Passed: Decypharr is UP`, priming line, no
`docker restart`.

### 2. Heartbeat (recovery)

```bash
docker stop DUMB-2026
sudo systemctl start nzbdav-heartbeat.service
journalctl -u nzbdav-heartbeat.service -e
```

Expect: consumers stopped → `FIX: Restarting DUMB-2026` → consumers restarted. Plex
container should **not** be touched (the Plex Monitor handles it separately).

### 3. Sentinel (dry run)

With `DRY_RUN_GLOBAL=Y`, create a fake broken symlink:

```bash
mkdir -p "$MEDIA_ROOT/tv-remote/_Test"
ln -s "$CONTAINER_REMOTE_PREFIX/nzbdav/nonexistent.mkv" "$MEDIA_ROOT/tv-remote/_Test/test.mkv"
sudo systemctl start nzbdav-symlink-cleanup.service
tail "$LOG_DIR/sentinel_audit.log"
rm -rf "$MEDIA_ROOT/tv-remote/_Test"
```

You should see a `MOCK` entry. Flip `DRY_RUN_GLOBAL=N` only after the audit log
confirms correct behavior — then `systemctl restart nzbdav-symlink-cleanup.timer`.

> **Behavior note:** the Linux Sentinel sends a `notify` alert when the circuit breaker
> trips (`TOTAL_BROKEN_GLOBAL > MAX_BROKEN_BEFORE_HALT`). The Unraid version logs this
> but does not notify. This is an intentional improvement — it makes the "Sentinel
> Locked" state visible via your configured notification backend.

### 4. Janitor (shutdown)

Easiest: reboot the host. Watch `/var/log/dumb-scripts/shutdown.log` next boot.

To test without rebooting:

```bash
sudo systemctl stop nzbdav-shutdown-janitor.service
tail /var/log/dumb-scripts/shutdown.log
```

Stopping the service triggers `ExecStop=`, which runs the janitor. (Restart the service
afterwards: `sudo systemctl start nzbdav-shutdown-janitor.service`.)

---

## Observability

```bash
# All scripts log to journal under tag dumb-scripts:
journalctl -t dumb-scripts -f

# Per-unit logs:
journalctl -u nzbdav-heartbeat.service -e
journalctl -u nzbdav-plex-monitor.service -e
journalctl -u nzbdav-symlink-cleanup.service -e
journalctl -u nzbdav-shutdown-janitor.service -e

# Timer schedule:
systemctl list-timers 'nzbdav-*'

# Per-script log files (in addition to journal):
ls /var/log/dumb-scripts/
```

---

## Adding a new library to the Sentinel

The `LIBRARIES=(...)` array lives inside `scripts/linux/symlink-cleanup.sh` (Bash arrays
don't survive `EnvironmentFile=`). Either edit the script directly under
`/opt/dumb-scripts/symlink-cleanup.sh` and add lines like:

```
"$MEDIA_ROOT/movies-indian-remote|Movies Indian|RADARR_4K|LIVE|PLEX|3|2|3"
```

Or, for cleaner upgrades, set `LIBRARIES_FILE=/etc/dumb-scripts/libraries.txt` in
`config.env` and put one entry per line in that file:

```
# /etc/dumb-scripts/libraries.txt
/srv/dumb/media/tv-remote|TV Shows|SONARR_HD|LIVE|PLEX|4|3|4
/srv/dumb/media/tv-remote-4k|TV Shows 4K|SONARR_4K|LIVE|PLEX|10|3|4
```

Format: `Path|Name|Arr_Key|Mode|Notify_Type|Plex_Section_ID|Min_Depth|Max_Depth`.
Find Plex section IDs with:

```bash
curl -s "$PLEX_URL/library/sections?X-Plex-Token=$PLEX_TOKEN" | \
  grep -oE 'key="[0-9]+" type="[a-z]+" title="[^"]+"'
```

Only add `-remote` folders (DUMB-managed symlinks). Local-only library folders never
need scanning.

---

## Hard reset

In `/etc/dumb-scripts/config.env`, set `HARD_RESET=Y` and trigger one run:

```bash
sudo systemctl start nzbdav-heartbeat.service
```

The Heartbeat will stop consumers, stop `DUMB-2026`, wipe `$RCLONE_CACHE_DIR/*`, restart
`DUMB-2026`, then exit. Set `HARD_RESET=N` immediately after; the next scheduled run
will resume normal monitoring.

---

## Cron fallback

If you can't or don't want to use systemd, the same scripts work under cron. After
copying them to `/opt/dumb-scripts/` and editing `config.env`:

```cron
# /etc/cron.d/dumb-scripts
SHELL=/usr/bin/bash
CONFIG_FILE=/etc/dumb-scripts/config.env

*/5 * * * * root /opt/dumb-scripts/mount-heartbeat.sh    >> /var/log/dumb-scripts/heartbeat.cron.log 2>&1
*/2 * * * * root /opt/dumb-scripts/plex-mount-monitor.sh >> /var/log/dumb-scripts/plex-monitor.cron.log 2>&1
0 4 * * *   root /opt/dumb-scripts/symlink-cleanup.sh    >> /var/log/dumb-scripts/sentinel.cron.log 2>&1
```

The shutdown janitor still needs a systemd unit (or an equivalent rc.d / init shutdown
hook) — cron has no shutdown semantics. If you're on a non-systemd init, run
`shutdown-janitor.sh` manually before `systemctl poweroff` / `init 0`, or wire it into
your init system's shutdown hook.

---

## Troubleshooting

**`journalctl -t dumb-scripts` is empty** — `logger` isn't installed (rare). Install
`bsdutils` (Debian/Ubuntu) or `util-linux`. The scripts still log to `/var/log/dumb-scripts/`.

**SELinux/AppArmor blocking the bind mount** — On Fedora/RHEL/Rocky/Alma, the FUSE
mount inside the DUMB container needs to be visible on the host. Verify your DUMB
container has the propagation bind set (`/srv/dumb/remote:/mnt/debrid:rshared` or
equivalent in Docker Compose). On AppArmor systems (Ubuntu), check `dmesg | grep DENIED`.

**`fusermount` errors during shutdown** — Harmless. The janitor's `umount -l` + lazy
`fusermount -uz` are intentionally tolerant; if the bind is already gone, the script
just logs `SKIPPED`.

**Docker rootless** — `docker inspect` and friends need the same Docker socket the
script user can read. Either run the units as the rootless user (drop `User=` /
`Group=` overrides in a `*.service.d/override.conf` drop-in) or, easier, run rootful
Docker on a host dedicated to the DUMB stack.

**Plex restarts in a loop** — That means mounts are flapping. Watch
`journalctl -u nzbdav-plex-monitor.service -f` and `journalctl -u nzbdav-heartbeat.service -f`
side by side. Likely the Decypharr DFS mount isn't ready before the Heartbeat probes —
increase `UPTIME_MATURITY_REQUIRED` and/or `PATIENCE_MULT` indirectly via `/proc/loadavg`
load.

---

## Uninstall

```bash
sudo /path/to/cloned/scripts/linux/systemd/uninstall.sh
```

Removes the systemd units and `/opt/dumb-scripts/`. Leaves `config.env`, logs, and state
behind — delete those manually if desired.
