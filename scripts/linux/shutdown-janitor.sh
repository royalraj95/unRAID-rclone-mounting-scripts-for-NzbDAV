#!/usr/bin/env bash
# ======================================================================================
# SCRIPT: The Janitor (Shutdown Orchestrator) — DUMB / Linux
# VERSION: v1.0-DUMB-LINUX
# DESCRIPTION: Stops DUMB-2026 gracefully (postgres flushes inside the 90s grace
#              window), unmounts the shared debrid bind, then stops all remaining
#              containers. Runs as ExecStop= of nzbdav-shutdown-janitor.service so
#              it fires during systemd shutdown.
# ======================================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/notify.sh
. "$SCRIPT_DIR/lib/notify.sh"

: "${PG_FLUSH_TIME:=90}"

LOG_FILE="$LOG_DIR/shutdown.log"
LOCK_DIR="$STATE_DIR"

# Optional local bind bridges to unmount before container teardown.
# Set JANITOR_BINDS in config.env as semicolon-separated "source>dest" pairs.
# Semicolon is required (not newline) for systemd EnvironmentFile= compatibility.
# Example: JANITOR_BINDS="/mnt/sync>/var/lib/plex/transcode;/mnt/bar>/var/lib/other"
declare -A BINDS=()
if [ -n "${JANITOR_BINDS:-}" ]; then
    IFS=';' read -ra _pairs <<< "$JANITOR_BINDS"
    for _pair in "${_pairs[@]}"; do
        IFS='>' read -r src dst <<< "$_pair"
        src="${src# }"; src="${src% }"   # trim surrounding spaces
        dst="${dst# }"; dst="${dst% }"
        [ -n "$src" ] && [ -n "$dst" ] && BINDS["$src"]="$dst"
    done
    unset _pairs _pair src dst
fi

log() { log_step "$1" "$LOG_FILE"; }

echo "--- COMMENCING CLEAN SHUTDOWN (v1.0-DUMB-LINUX) ---" | tee -a "$LOG_FILE"

# --- STAGE 1: PRE-SHUTDOWN RAM SYNC ---
log "FORCING RAM FLUSH: Writing active buffers to disk..."
sync
log "SUCCESS: RAM buffers committed to storage."

# --- STAGE 2: STOP DUMB-2026 FIRST ---
# Postgres lives inside DUMB-2026. A long stop timeout lets the container's entrypoint
# flush the DB cleanly before Docker sends SIGKILL.
if [ "$(container_running "$DUMB_CONTAINER")" == "true" ]; then
    log "Signaling $DUMB_CONTAINER to shut down (${PG_FLUSH_TIME}s grace for postgres flush)..."
    docker stop -t "$PG_FLUSH_TIME" "$DUMB_CONTAINER" > /dev/null 2>&1
    log "SUCCESS: $DUMB_CONTAINER stopped."
else
    log "INFO: $DUMB_CONTAINER was already stopped."
fi

# --- STAGE 3: BIND BRIDGES ---
if [ ${#BINDS[@]} -gt 0 ]; then
    log "Unmounting local bind bridges..."
    for dest in "${BINDS[@]}"; do
        if mountpoint -q "$dest"; then
            if umount -l "$dest" > /dev/null 2>&1; then
                log "SUCCESS: Unmounted bind bridge: $dest"
            else
                log "WARNING: Failed to unmount $dest (Device busy)"
            fi
        fi
    done
else
    log "INFO: No bind bridges configured. Skipping."
fi

# --- STAGE 4: STOP ALL REMAINING CONTAINERS ---
REMAINING=$(docker ps -q)
if [ -n "$REMAINING" ]; then
    log "Stopping all remaining Docker containers..."
    # shellcheck disable=SC2086
    docker stop $REMAINING > /dev/null 2>&1
    log "SUCCESS: All remaining Docker containers stopped."
else
    log "INFO: No other containers running."
fi

# --- STAGE 5: UNMOUNT SHARED DEBRID BIND ---
log "Releasing shared debrid bind at $REMOTE_BIND..."
if mountpoint -q "$REMOTE_BIND" 2>/dev/null; then
    umount -l "$REMOTE_BIND" > /dev/null 2>&1
    fusermount -uz "$REMOTE_BIND" > /dev/null 2>&1
    log "SUCCESS: Released $REMOTE_BIND."
else
    log "INFO: $REMOTE_BIND is not mounted. Skipping."
fi

# --- STAGE 6: CLEANUP & NOTIFY ---
log "Purging script lock files..."
rm -f "$LOCK_DIR"/janitor_*.lock "$LOCK_DIR"/heartbeat_*.lock
log "SUCCESS: Lock files purged. Environment clear for shutdown."

# Best-effort: network may already be down at this point; HTTP backends (ntfy/discord/apprise)
# will fail gracefully and fall back to syslog. Only the "logger" backend is guaranteed here.
notify "Shutdown Prepared" "DUMB stack stopped, debrid bind released, all containers clear." "normal"

echo "--- JANITOR WORK COMPLETE ---" | tee -a "$LOG_FILE"
exit 0
