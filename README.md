# Rclone Mounting & Library Maintenance for NzbDAV + DUMB

Bash scripts for running the **[DUMB](https://dumbarr.com) all-in-one stack**
(`DUMB-2026`) — NzbDAV + Decypharr + rclone, with internal `*Arrs` and Plex on top — and
keeping the symlink-backed library healthy.

Designed to be deployable on either **Unraid** (via the User Scripts plugin) or any
modern **Linux/Docker host** (Ubuntu, Debian, Fedora, etc.) via systemd timers. The
scripts themselves are identical in behavior; only the platform plumbing differs.

---

## Pick your platform

| Platform | Scripts | Scheduler | Setup guide |
|---|---|---|---|
| **Unraid** | [`scripts/unraid/`](scripts/unraid/) | User Scripts plugin | **[docs/unraid.md](docs/unraid.md)** |
| **Linux / Ubuntu / Docker** | [`scripts/linux/`](scripts/linux/) | systemd timers (+ cron fallback) | **[docs/linux.md](docs/linux.md)** |

For the foundation/consumer model, mount semantics, and the rationale behind each script,
read **[docs/architecture.md](docs/architecture.md)** first.

---

## What's in the toolkit

Four scripts that together keep the DUMB stack healthy:

1. **Mount Heartbeat** — every 5 min. Validates NzbDAV and Decypharr mounts; stops
   consumers and restarts `DUMB-2026` to recover; primes the rclone dir-cache
   incrementally; escalates to a hard reset (wipe VFS cache + container recycle) on
   repeated failure.
2. **Plex Mount Monitor** — every 2 min. Stops Plex when either mount goes down,
   restarts Plex once both recover. Plex caches stale FUSE handles and can't recover on
   its own.
3. **Symlink Sentinel** — daily. Audits `-remote` libraries for broken symlinks pointing
   at the debrid mounts. Triggers the matching `*Arr` rescan + a Plex section refresh.
   Dry-run default, circuit breaker, rolling 24-hour deletion cap.
4. **Shutdown Janitor** — at OS / array shutdown. Stops `DUMB-2026` with a long grace
   timeout (so the internal postgres flushes), releases the shared debrid bind, then
   stops the remaining containers.

See [docs/architecture.md](docs/architecture.md) for how they fit together.

---

## Repo layout

```
scripts/
├── unraid/   — Unraid (User Scripts plugin); originals + (DUMB) variants
└── linux/    — Linux/systemd port of the (DUMB) variants, plus systemd units + installer
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
