# Rclone Mounting & Library Maintenance for NzbDAV

This repository provides a robust toolkit for managing Rclone mounts and library health on Unraid. It is specifically designed to handle the complexities of <a href="https://github.com/nzbdav-dev/nzbdav">NzbDAV</a> and <a href="https://github.com/sirrobot01/decypharr">Decypharr</a> ensuring your media stays connected and your system shuts down cleanly.

---

## What’s in the Box?

You get three core scripts. While the **Heartbeat** script is the engine, **Sentinel** and **The Janitor** are highly recommended to keep your library healthy and your server stable.

### 1. Rclone Heartbeat & Intelligent Priming (The Engine)
This is the "always-on" monitor. It keeps your NzbDAV and Decypharr mounts alive. If a mount drops, it stops your media apps (Sonarr, Radarr, etc.), fixes the connection, and restarts them once everything is stable.
* **Fast Scans:** Uses "Smart Priming" to scan only new library additions, keeping things snappy even with massive libraries.
* **Safety First:** Includes a "Nuclear Option" that force-resets the environment if recovery fails multiple times.

### 2. Symlink Sentinel (The Library Cleaner)
Think of this as your automated library auditor. It scans your media folders for broken symlinks caused by missing files on your cloud mounts.
* **Auto-Repair:** It talks to your *Arrs (Sonarr, Radarr, etc.) to trigger a refresh and cleanup of dead links.
* **Performance:** Uses custom depth settings (e.g. only looking 3 or 4 folders deep) so it doesn't waste time scanning thousands of irrelevant files.

### 3. The Janitor (The Shutdown Orchestrator)
Unraid often struggles to stop the array if Rclone mounts or ZFS pools are still "busy." The Janitor ensures a graceful exit.
* **Database Safety:** Flushes and stops your databases (like Postgres) properly before the array stops.
* **Clean Unmounts:** Lazily unmounts cloud paths and exports ZFS pools to prevent "unclean shutdown" errors.

---

## How It Works
The scripts use a **"Foundation & Consumer"** model. The **Heartbeat** script ensures the "Foundation" (NzbDAV/Rclone) is solid before allowing the "Consumers" (Sonarr, Radarr, Plex) to run. If the foundation cracks, the script stops the consumers to prevent them from "seeing" an empty library and making a mess of your database.

---

## Assumptions
* You are running **Unraid** with the **User Scripts** plugin installed.
* You have a working **Rclone** config file located at `/boot/config/plugins/rclone/.rclone.conf`.
* Your media is organised in a standard structure (e.g., `/tv/Show/Season/File`).

---

## Quick Setup Guide

1.  **Configure:** Open each script and check the **User Configuration** section at the top. Update your paths, API keys, and Rclone settings.
2.  **Test:** Set `DRY_RUN="Y"` in the scripts first to see what they would do without making actual changes.
3.  **Deploy via User Scripts Plugin:**
    * **Rclone Heartbeat:** Set to run on a custom cron schedule (e.g., `*/5 * * * *` for every 5 minutes).
    * **Symlink Sentinel:** Schedule to run via cron once a day or once an hour depending on your library activity.
    * **The Janitor:** Set this script to run **At Array Stop** to ensure clean shutdowns.

---

## Support
For more detailed information or community assistance, please visit the <a href="https://forums.unraid.net/topic/198498-rclone-scripts-to-mount-nzbdav-to-create-a-large-plex-library-with-fast-launch-times-and-efficient-arr-usage/">Unraid Support Thread</a>.

---

## Disclaimer
**Use at your own risk.** These scripts are provided "as-is" for personal use. I accept no responsibility for data loss, accidental deletions, or hardware damage. Always verify your configuration before letting the scripts manage live data.
