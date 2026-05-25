#!/usr/bin/env bash
# ======================================================================================
# SCRIPT: Plex Mount Monitor (DUMB / Linux)
# VERSION: v1.0-DUMB-LINUX
# DESCRIPTION: Stops $PLEX_CONTAINER when DUMB's debrid mounts go down, and restarts it
#              once they recover. Linux/systemd port of the Unraid script.
#              Runs every 2 minutes via nzbdav-plex-monitor.timer.
#
# Plex caches stale FUSE handles after a mount drops — it cannot recover on its own
# and must be container-restarted to re-see the mounts. This script reacts faster
# (2 min) than the Heartbeat (5 min) without carrying its heavier priming workload.
#
# BOTH MOUNTS GATE PLEX: either RD (Decypharr) or NzbDAV going down stops Plex, since
# Plex libraries contain a mix of content from both mounts.
# ======================================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/notify.sh
. "$SCRIPT_DIR/lib/notify.sh"

RD_MOUNT_PATH="$DEC_MOUNT/__all__"
NZB_MOUNT_PATH="$NZB_MOUNT"
STATE_FILE="$STATE_DIR/plex_mount_state"
LOG_FILE="$LOG_DIR/plex_monitor.log"

log() { log_step "$1" "$LOG_FILE"; }

if backup_in_progress; then
    log "[PAUSED] appdata backup in progress — skipping run"
    exit 0
fi

RD_UP=false
NZB_UP=false
is_mounted "$RD_MOUNT_PATH" && RD_UP=true
is_mounted "$NZB_MOUNT_PATH" && NZB_UP=true

if $RD_UP && $NZB_UP; then
    CURRENT="up"
else
    CURRENT="down"
fi
PREVIOUS=$(cat "$STATE_FILE" 2>/dev/null || echo "up")

log "RD: $RD_UP | NZB: $NZB_UP | State: $CURRENT (was: $PREVIOUS)"

if [ "$CURRENT" = "down" ] && [ "$PREVIOUS" = "up" ]; then
    log "Mounts down — stopping Plex"
    docker stop "$PLEX_CONTAINER" >> "$LOG_FILE" 2>&1
    notify "Plex Stopped" "Debrid mounts went down. RD: $RD_UP | NZB: $NZB_UP. Plex stopped." "alert"

elif [ "$CURRENT" = "down" ] && [ "$PREVIOUS" = "down" ]; then
    log "Mounts still down — keeping Plex stopped"
    if [ "$(container_running "$PLEX_CONTAINER")" = "true" ]; then
        log "Plex running but mounts down — stopping"
        docker stop "$PLEX_CONTAINER" >> "$LOG_FILE" 2>&1
    fi

elif [ "$CURRENT" = "up" ] && [ "$PREVIOUS" = "down" ]; then
    log "Mounts recovered — starting Plex"
    docker start "$PLEX_CONTAINER" >> "$LOG_FILE" 2>&1
    notify "Plex Restored" "Debrid mounts recovered. RD: $RD_UP | NZB: $NZB_UP. Plex started." "normal"

else
    log "Mounts healthy — RD: $RD_UP | NZB: $NZB_UP"
fi

echo "$CURRENT" > "$STATE_FILE"
