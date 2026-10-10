# Rclone Mounting & Library Maintenance for NzbDAV + DUMB

Bash scripts for running the **[DUMB](https://dumbarr.com) all-in-one stack**
(`DUMB-2026`) — NzbDAV + Decypharr + rclone, with internal `*Arrs` and Plex on top — and
keeping the symlink-backed library healthy.

Designed to be deployable on either **Unraid** (via the User Scripts plugin) or any
modern **Linux/Docker host** (Ubuntu, Debian, Fedora, etc.) via systemd timers. The
Unraid scripts are at v2.0 (NzbDAV-only). The Linux port is still v1 (NzbDAV +
Decypharr) and hasn't been updated yet.

---

## Pick your platform

| Platform | Scripts | Scheduler | Setup guide |
|---|---|---|---|
| **Unraid** | [`scripts/unraid/`](scripts/unraid/) | User Scripts plugin | **[docs/unraid.md](docs/unraid.md)** |
| **Linux / Ubuntu / Docker** (v1) | [`scripts/linux/`](scripts/linux/) | systemd timers (+ cron fallback) | **[docs/linux.md](docs/linux.md)** |

For the foundation/consumer model, mount semantics, and the rationale behind each script,
read **[docs/architecture.md](docs/architecture.md)** first.

---

## What's in the toolkit

Four scripts that together keep the DUMB stack healthy. The Unraid scripts (v2.0) are
NzbDAV/InfiniDysk-only; Decypharr/Real-Debrid is no longer used.

1. **Mount Heartbeat** — every 5 min. Checks the NzbDAV rclone mount and InfiniDysk's
   WebDAV backend. Recovers with the least disruptive action that works: restart just
   rclone through the DUMB API, then InfiniDysk, then the whole container, then a hard
   reset.
2. **Plex Mount Monitor** — every 2 min. Stops Plex after two consecutive failed mount
   checks and brings it back once the mount recovers. Plex caches stale FUSE handles and
   can't recover on its own.
3. **Symlink Sentinel** — daily. Finds library symlinks whose InfiniDysk item no longer
   exists by comparing link targets against InfiniDysk's own database (read-only, zero
   FUSE traffic). Deletes them, asks the owning `*Arr` to rescan and re-search that one
   title, and asks Plex to scan that folder. Dry-run default, circuit breaker, rolling
   24-hour deletion cap.
4. **Shutdown Janitor** — at OS / array shutdown. Stops `DUMB-2026` with a long grace
   timeout (so the internal postgres flushes), stops the remaining containers, then
   releases stale FUSE mounts under the shared bind.

All host-specific settings and secrets live in one `dumb.conf`
([example](scripts/unraid/dumb.conf.example)), so the scripts paste into User Scripts
unchanged.

See [docs/architecture.md](docs/architecture.md) for how they fit together.

---

## Repo layout

```
scripts/
├── unraid/   — Unraid (User Scripts plugin); originals + (DUMB) variants + dumb.conf.example
└── linux/    — Linux/systemd port of the v1 (DUMB) variants, plus systemd units + installer
docs/
├── architecture.md     — foundation/consumer model, paths, design choices
├── unraid.md           — Unraid setup guide
├── linux.md            — Linux/Docker setup guide
└── notifications.md    — pluggable notify backends (logger / ntfy / apprise / discord)
```

---

## Community

- **DUMB** project: <https://dumbarr.com>
- Unraid support thread: <https://forums.unraid.net/topic/198498-rclone-scripts-to-mount-nzbdav-to-create-a-large-plex-library-with-fast-launch-times-and-efficient-arr-usage/>

---

**Use at your own risk.** The Sentinel deletes broken symlinks; the Heartbeat stops and
restarts Docker containers. Always start with `DRY_RUN_GLOBAL=Y` and verify behavior on
your system before flipping to live deletions. See the setup guide for your platform for
the verify-before-deploy checklist.
