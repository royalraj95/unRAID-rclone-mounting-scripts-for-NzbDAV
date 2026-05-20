#!/usr/bin/env bash
# ======================================================================================
# LIB: common.sh — shared config loader, logging, and helpers
# Sourced by every script in scripts/linux/.
# ======================================================================================

# --- Load config -----------------------------------------------------------------------
# Default location matches systemd EnvironmentFile= in the units.
: "${CONFIG_FILE:=/etc/dumb-scripts/config.env}"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$CONFIG_FILE"; set +a
fi

# --- Defaults (every var has a sane fallback) ------------------------------------------
: "${DUMB_CONTAINER:=DUMB-2026}"
: "${PLEX_CONTAINER:=binhex-plex}"
: "${ENABLERS:=}"
: "${CONSUMERS:=}"

: "${REMOTE_BIND:=/srv/dumb/remote}"
: "${MEDIA_ROOT:=/srv/dumb/media}"
: "${NZB_MOUNT:=${REMOTE_BIND}/nzbdav}"
: "${DEC_MOUNT:=${REMOTE_BIND}/decypharr/realdebrid}"
: "${RCLONE_CACHE_DIR:=/var/cache/rclone/cache}"
: "${STATE_DIR:=/var/lib/dumb-scripts}"
: "${LOG_DIR:=/var/log/dumb-scripts}"
: "${RECOVERY_COOLDOWN_SEC:=900}"

: "${CONTAINER_REMOTE_PREFIX:=/mnt/debrid}"

mkdir -p "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true

# --- Logging ---------------------------------------------------------------------------
# log_step "msg"            — info to stdout + journal
# log_step "msg" "$LOG_FILE" — also tee to a per-script log file
log_step() {
    local msg="$1"
    local target="${2:-}"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $msg"
    if [ -n "$target" ]; then
        echo "$line" | tee -a "$target"
    else
        echo "$line"
    fi
    logger -t dumb-scripts -- "$msg" 2>/dev/null || true
}

# --- Helpers ---------------------------------------------------------------------------
# True if $1 exists and has at least one entry inside.
is_mounted() {
    find "$1" -maxdepth 1 -mindepth 1 -print -quit 2>/dev/null | grep -q .
}

# "true" / "false" / "" — same as docker inspect's State.Running.
container_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null
}

# Human-readable duration from a UNIX timestamp argument.
calculate_duration() {
    local diff=$(($(date +%s) - $1))
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    local mins=$(( (diff % 3600) / 60 ))
    if [ "$days" -gt 0 ]; then
        echo "${days}d ${hours}h ${mins}m"
    elif [ "$hours" -gt 0 ]; then
        echo "${hours}h ${mins}m"
    else
        echo "${mins}m"
    fi
}
