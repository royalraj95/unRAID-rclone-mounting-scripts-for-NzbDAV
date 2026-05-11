#!/usr/bin/env bash
# ======================================================================================
# SCRIPT: Rclone Heartbeat & Intelligent Priming (DUMB / Linux)
# VERSION: v1.0-DUMB-LINUX
# DESCRIPTION: Linux/systemd port of the Unraid "Mount Script (DUMB)".
#              Monitors NzbDAV and Decypharr mounts exposed by DUMB-2026 via the
#              shared propagation bind (/mnt/debrid inside container → $REMOTE_BIND
#              on host). Recovery restarts DUMB-2026. No host-side rclone management
#              — rclone lives inside the container.
#
# Config: /etc/dumb-scripts/config.env (override with CONFIG_FILE=...)
# Runs:   nzbdav-heartbeat.timer (every 5 minutes by default)
# ======================================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/notify.sh
. "$SCRIPT_DIR/lib/notify.sh"

SCRIPT_VERSION="v1.0-DUMB-LINUX"
: "${HARD_RESET:=N}"
: "${MAX_FAILURES:=5}"
: "${PRIME_MAX_TIME:=60}"
: "${EXCLUDE_DIRS:=}"
: "${EXCLUDE_EXTS:=.srt .ass .vtt}"

STATE_FILE="$STATE_DIR/prime_state.db"
LOG_FILE="$LOG_DIR/heartbeat.log"

log() { log_step "$1" "$LOG_FILE"; }

ALL_CONSUMERS="$CONSUMERS"

# --- SECTION 1: SUMMARY ----------------------------------------------------------------
log "VALIDATING: Script configuration and environment..."
echo "---------------------------------------------------"
echo "[CONFIG SUMMARY]"
echo "Script Version:      $SCRIPT_VERSION"
echo "Config File:         ${CONFIG_FILE:-<unset>}"
echo "State File:          $STATE_FILE"
echo "Hard Reset Toggle:   $HARD_RESET"
echo ""
echo "[MOUNT PATHS]"
echo "NzbDAV (host):       $NZB_MOUNT"
echo "Decypharr (host):    $DEC_MOUNT"
echo "Media Library:       $MEDIA_ROOT"
echo ""
echo "[DOCKER SETTINGS]"
echo "Foundation:          $DUMB_CONTAINER"
echo "Enabler Containers:  $ENABLERS"
echo "Consumer Containers: $CONSUMERS"
echo "---------------------------------------------------"

# --- SECTION 2: ENVIRONMENTAL READINESS ------------------------------------------------
PATIENCE_MULT=1
if [[ "$HARD_RESET" == "N" ]]; then
    log "VERIFYING: System environment and load..."
    CURRENT_LOAD=$(awk '{print $1}' /proc/loadavg | cut -d. -f1)
    if [ "$CURRENT_LOAD" -gt 80 ]; then
        log "PATIENCE: High load detected ($CURRENT_LOAD). Doubling timeouts."
        PATIENCE_MULT=2
    fi
fi

# --- SECTION 3: FOUNDATION CHECK -------------------------------------------------------
FOUNDATION_RESTARTED=false

if [ "$(container_running "$DUMB_CONTAINER")" != "true" ]; then
    log "[!] $DUMB_CONTAINER is down. Starting..."
    docker start "$DUMB_CONTAINER" > /dev/null 2>&1
    FOUNDATION_RESTARTED=true
fi

for container in $ENABLERS; do
    if [ "$(container_running "$container")" != "true" ]; then
        log "[!] $container is down. Starting..."
        docker start "$container" > /dev/null 2>&1
        FOUNDATION_RESTARTED=true
    fi
done

if [[ "$FOUNDATION_RESTARTED" == "true" ]]; then
    log "WAITING: Giving foundation containers 30s to initialize..."
    sleep 30
fi

# --- SECTION 4: INDEPENDENT MOUNT VALIDATION -------------------------------------------
# shellcheck disable=SC1090
[ -f "$STATE_FILE" ] && . "$STATE_FILE"
N_CUR_FAIL=${N_FAIL_COUNT:-0}
NZB_VALIDATION_SUBFOLDER="$NZB_MOUNT/completed-symlinks"
NZB_MOUNT_ALIVE=false
DEC_MOUNT_ALIVE=false

if [[ "$HARD_RESET" == "N" ]]; then
    # --- NzbDAV ---
    log "CHECKING: NzbDAV Mount integrity..."

    if [ "$(container_running "$DUMB_CONTAINER")" == "true" ]; then
        N_COUNT=0
        while [ $N_COUNT -lt 5 ]; do
            if timeout $((5 * PATIENCE_MULT))s ls "$NZB_VALIDATION_SUBFOLDER" > /dev/null 2>&1; then
                NZB_MOUNT_ALIVE=true
                log "Passed: NzbDAV is UP."
                break
            fi
            log "WAITING: NzbDAV mount stalling (Attempt $((N_COUNT + 1))/5)..."
            sleep $((6 * PATIENCE_MULT))
            ((N_COUNT++))
        done
    else
        log "[!] $DUMB_CONTAINER is dead. Bypassing NzbDAV patience window..."
    fi

    if [[ "$NZB_MOUNT_ALIVE" == "true" ]]; then
        [[ "${NZB_STATE:-}" != "UP" ]] && NZB_STATE="UP" && NZB_START_TS=$(date +%s)
        echo "N_FAIL_COUNT=0" > "$STATE_FILE"
        N_CUR_FAIL=0
    else
        log "[!] Failed: NzbDAV is DOWN."
        notify "Mount Down" "NzbDAV mount integrity check failed at $NZB_MOUNT" "alert"
        [[ "${NZB_STATE:-}" != "DOWN" ]] && NZB_STATE="DOWN" && NZB_START_TS=$(date +%s)
    fi

    # --- Decypharr (DFS via realdebrid subpath) ---
    if [[ -n "$DEC_MOUNT" ]]; then
        log "CHECKING: Decypharr Mount integrity..."

        if [ "$(container_running "$DUMB_CONTAINER")" == "true" ]; then
            D_COUNT=0
            while [ $D_COUNT -lt 5 ]; do
                if { timeout $((5 * PATIENCE_MULT))s ls -d "$DEC_MOUNT/__all__" > /dev/null 2>&1 && \
                     timeout $((5 * PATIENCE_MULT))s ls "$DEC_MOUNT/version.txt" > /dev/null 2>&1; }; then
                    DEC_MOUNT_ALIVE=true
                    log "Passed: Decypharr is UP."
                    break
                fi
                log "WAITING: Decypharr mount not ready (Attempt $((D_COUNT + 1))/5)..."
                sleep $((6 * PATIENCE_MULT))
                ((D_COUNT++))
            done
        else
            log "[!] $DUMB_CONTAINER is dead. Bypassing Decypharr patience window..."
        fi

        if [[ "$DEC_MOUNT_ALIVE" == "false" ]]; then
            log "[!] Failed: Decypharr is DOWN. Entering Recovery..."

            for container in $ALL_CONSUMERS; do
                if [ "$(container_running "$container")" == "true" ]; then
                    log "Stopping Consumer: $container..."
                    docker stop "$container" > /dev/null 2>&1
                fi
            done

            log "FIX: Restarting $DUMB_CONTAINER to recover Decypharr..."
            docker restart "$DUMB_CONTAINER" > /dev/null 2>&1
            DEC_START_TS=$(date +%s)

            D_POST_COUNT=0
            while [ $D_POST_COUNT -lt 5 ]; do
                sleep $((12 * PATIENCE_MULT))
                if { timeout $((5 * PATIENCE_MULT))s ls -d "$DEC_MOUNT/__all__" > /dev/null 2>&1 && \
                     timeout $((5 * PATIENCE_MULT))s ls "$DEC_MOUNT/version.txt" > /dev/null 2>&1; }; then
                    DEC_MOUNT_ALIVE=true
                    log "RECOVERY: Decypharr is UP after restart."
                    break
                fi
                log "WAITING: Decypharr stabilizing after restart (Attempt $((D_POST_COUNT + 1))/5)..."
                ((D_POST_COUNT++))
            done

            if [[ "$DEC_MOUNT_ALIVE" == "false" ]]; then
                log "[!] CRITICAL: Decypharr recovery failed."
                notify "Mount Down" "Decypharr recovery failed at $DEC_MOUNT." "alert"
            fi
        fi

        if [[ "$DEC_MOUNT_ALIVE" == "true" ]]; then
            if [[ "${DEC_STATE:-}" != "UP" ]]; then DEC_STATE="UP"; DEC_START_TS=$(date +%s); fi
        else
            if [[ "${DEC_STATE:-}" != "DOWN" ]]; then DEC_STATE="DOWN"; DEC_START_TS=$(date +%s); fi
        fi
    fi
fi

# --- SECTION 5: MOUNT RECOVERY LOOP ----------------------------------------------------
RECOVERY_FAILED=false
if [[ "$HARD_RESET" == "N" ]] && [[ "$NZB_MOUNT_ALIVE" == "false" ]]; then
    log "REBUILD: Attempting mount recovery via container restart..."

    for container in $ALL_CONSUMERS; do
        if [ "$(container_running "$container")" == "true" ]; then
            log "Stopping Consumer: $container..."
            docker stop "$container" > /dev/null 2>&1
        fi
    done

    log "FIX: Restarting $DUMB_CONTAINER..."
    docker restart "$DUMB_CONTAINER" > /dev/null 2>&1

    COUNT=0
    while [ $COUNT -lt 5 ]; do
        sleep $((12 * PATIENCE_MULT))
        if timeout $((5 * PATIENCE_MULT))s ls "$NZB_VALIDATION_SUBFOLDER" > /dev/null 2>&1; then
            log "SUCCESS: NzbDAV mount stabilized."
            notify "Mount Success" "NzbDAV mount has been successfully restored." "normal"
            NZB_STATE="UP"
            NZB_START_TS=$(date +%s)
            {
                echo "N_FAIL_COUNT=0"
                echo "NZB_STATE=\"$NZB_STATE\""
                echo "NZB_START_TS=\"$NZB_START_TS\""
                echo "DEC_STATE=\"${DEC_STATE:-}\""
                echo "DEC_START_TS=\"${DEC_START_TS:-}\""
                echo "TOTAL_LMP_PRIMED=${TOTAL_LMP_PRIMED:-0}"
            } > "$STATE_FILE"
            NZB_MOUNT_ALIVE=true
            RECOVERY_FAILED=false
            break
        fi
        log "WAITING: Mount stabilizing (Attempt $((COUNT + 1))/5)..."
        ((COUNT++))
    done

    if [[ "$NZB_MOUNT_ALIVE" == "false" ]]; then
        RECOVERY_FAILED=true
        N_CUR_FAIL=$((N_CUR_FAIL + 1))
        {
            echo "N_FAIL_COUNT=$N_CUR_FAIL"
            echo "NZB_STATE=\"${NZB_STATE:-}\""
            echo "NZB_START_TS=\"${NZB_START_TS:-}\""
            echo "DEC_STATE=\"${DEC_STATE:-}\""
            echo "DEC_START_TS=\"${DEC_START_TS:-}\""
            echo "TOTAL_LMP_PRIMED=${TOTAL_LMP_PRIMED:-0}"
        } > "$STATE_FILE"
    fi
fi

# --- SECTION 6: NUCLEAR JUNCTION -------------------------------------------------------
TRIGGER_HARD_RESET=false
if [[ "$HARD_RESET" == "Y" ]]; then
    log "MANUAL RESET: Executing requested purge..."
    TRIGGER_HARD_RESET=true
elif [[ "$RECOVERY_FAILED" == "true" ]] && [[ "$N_CUR_FAIL" -ge "$MAX_FAILURES" ]]; then
    log "[CRITICAL] Recovery failed and threshold ($MAX_FAILURES) reached."
    TRIGGER_HARD_RESET=true
fi

if [[ "$TRIGGER_HARD_RESET" == "true" ]]; then
    log "NUCLEAR OPTION: Stopping $DUMB_CONTAINER and resetting state..."
    notify "Forced Reset" "A forced reset has been triggered. Restarting $DUMB_CONTAINER." "alert"

    for container in $ALL_CONSUMERS; do
        if [ "$(container_running "$container")" == "true" ]; then
            log "Stopping Consumer: $container..."
            docker stop "$container" > /dev/null 2>&1
        fi
    done

    log "Stopping $DUMB_CONTAINER..."
    docker stop "$DUMB_CONTAINER" > /dev/null 2>&1

    # Cache wipe only when explicitly requested (HARD_RESET=Y). Auto-triggered nuclear
    # resets (MAX_FAILURES reached) restart the container but intentionally skip the
    # wipe to preserve warm cache across transient failures.
    if [[ "$HARD_RESET" == "Y" ]] && [[ -d "$RCLONE_CACHE_DIR" ]]; then
        log "Wiping rclone VFS cache at $RCLONE_CACHE_DIR..."
        rm -rf "${RCLONE_CACHE_DIR:?}"/*
        log "SUCCESS: Cache wiped."
    fi

    sleep 5
    log "Starting $DUMB_CONTAINER..."
    docker start "$DUMB_CONTAINER" > /dev/null 2>&1

    NZB_STATE="DOWN"; NZB_START_TS=$(date +%s)
    DEC_STATE="DOWN"; DEC_START_TS=$(date +%s)
    {
        echo "N_FAIL_COUNT=0"
        echo "NZB_STATE=\"$NZB_STATE\""
        echo "NZB_START_TS=\"$NZB_START_TS\""
        echo "DEC_STATE=\"$DEC_STATE\""
        echo "DEC_START_TS=\"$DEC_START_TS\""
        echo "TOTAL_LMP_PRIMED=0"
    } > "$STATE_FILE"
    log "SUCCESS: Nuclear Cleanup complete. Counter reset. EXITING."
    exit 0
fi

if [[ "$NZB_MOUNT_ALIVE" == "false" ]]; then
    log "[ABORT] Mount recovery failed. Threshold not yet reached ($N_CUR_FAIL/$MAX_FAILURES). Exiting."
    exit 1
fi

# --- SECTION 7: PRIMING & RESTORATION --------------------------------------------------
log "INITIATING: Intelligent Priming (Library Only)..."
# shellcheck disable=SC1090
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

START_TIME=$(date +%s)
LAST_RUN_TS=${LAST_PRIMED_TS:-0}
LMP_RUN_COUNT=0
CUR_TOTAL_LMP=${TOTAL_LMP_PRIMED:-0}

log "Checking $MEDIA_ROOT for new files..."
FIND_EXCLUDES=""
for d in $EXCLUDE_DIRS; do
    FIND_EXCLUDES="$FIND_EXCLUDES ! -path \"*/${d#/}/*\""
done
for e in $EXCLUDE_EXTS; do
    FIND_EXCLUDES="$FIND_EXCLUDES ! -name \"*$e\""
done

eval "nice -n 19 ionice -c 3 find \"$MEDIA_ROOT\" -type l $FIND_EXCLUDES -newermt \"@$LAST_RUN_TS\" -exec ls -d {} + > /dev/null 2>&1"

if [[ "${ALL_HISTORICAL_PRIMED:-}" != "TRUE" ]]; then
    log "Resuming historical prime for Media Path..."
    mapfile -t LMP_TARGETS < <(eval "nice -n 19 ionice -c 3 find \"$MEDIA_ROOT\" -type l $FIND_EXCLUDES -not -newermt \"@${HISTORICAL_MARKER:-$(date +%s)}\" -printf \"%T@ %p\n\" | sort -rn | cut -d' ' -f2-")

    if [ ${#LMP_TARGETS[@]} -gt 0 ]; then
        for file in "${LMP_TARGETS[@]}"; do
            nice -n 19 ionice -c 3 ls -d "$file" > /dev/null 2>&1
            ((LMP_RUN_COUNT++))
            NEW_LMP_MARKER=$(stat -c %Y "$file" 2>/dev/null)
            [ $(( $(date +%s) - START_TIME )) -ge "$PRIME_MAX_TIME" ] && break
        done
    else
        ALL_HISTORICAL_PRIMED="TRUE"
    fi
fi
CUR_TOTAL_LMP=$((CUR_TOTAL_LMP + LMP_RUN_COUNT))
log "$LMP_RUN_COUNT new files found ... $CUR_TOTAL_LMP total files in the library."

{
    echo "N_FAIL_COUNT=${N_CUR_FAIL:-0}"
    echo "LAST_PRIMED_TS=$(date +%s)"
    echo "HISTORICAL_MARKER=${NEW_LMP_MARKER:-${HISTORICAL_MARKER:-}}"
    echo "ALL_HISTORICAL_PRIMED=${ALL_HISTORICAL_PRIMED:-}"
    echo "NZB_STATE=\"${NZB_STATE:-}\""
    echo "NZB_START_TS=\"${NZB_START_TS:-}\""
    echo "DEC_STATE=\"${DEC_STATE:-}\""
    echo "DEC_START_TS=\"${DEC_START_TS:-}\""
    echo "TOTAL_LMP_PRIMED=$CUR_TOTAL_LMP"
} > "$STATE_FILE"

# --- SECTION 8: RESTORATION ------------------------------------------------------------
log "RESTORATION: Starting Consumers..."
if [[ "$NZB_MOUNT_ALIVE" == "true" ]] && [[ "$DEC_MOUNT_ALIVE" == "true" ]]; then
    for container in $ALL_CONSUMERS; do
        docker start "$container" > /dev/null 2>&1
    done
else
    log "[ABORT] Restoration skipped. One or more mounts are offline."
fi

# --- SECTION 9: FINAL SUMMARY ----------------------------------------------------------
log "FINALIZING: Generating environment report..."
# shellcheck disable=SC1090
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

CUR_LOAD=$(awk '{print $1}' /proc/loadavg)
RAM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_FREE=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
RAM_PERC=$(awk "BEGIN {printf \"%.1f\", ($RAM_FREE/$RAM_TOTAL)*100}")

NZB_TIME=$(calculate_duration "${NZB_START_TS:-$(date +%s)}")
DEC_TIME=$(calculate_duration "${DEC_START_TS:-$(date +%s)}")

echo ""
echo "Status Summary:"
echo "NzbDAV ${NZB_STATE:-?} (${NZB_TIME}) : Decypharr ${DEC_STATE:-?} (${DEC_TIME}) | Primed ${TOTAL_LMP_PRIMED:-0} | Load ${CUR_LOAD} | RAM FREE: ${RAM_PERC}%"
echo "--------------------------------------------------------------------------------------"
log "STATUS: All Systems Operational."
exit 0
