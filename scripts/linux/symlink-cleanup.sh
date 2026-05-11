#!/usr/bin/env bash
# ======================================================================================
# SCRIPT: Symlink Sentinel (DUMB / Linux) — v1.0-DUMB-LINUX
# DESCRIPTION: Detects broken symlinks pointing at DUMB-2026's debrid mounts,
#              calculates library health, and triggers DUMB's internal *Arrs + Plex refresh.
#
# NOTE ON PATHS: Symlinks created by DUMB's internal *Arrs use the CONTAINER-SIDE path
# ($CONTAINER_REMOTE_PREFIX = /mnt/debrid by default) because the *Arr containers bind
# $REMOTE_BIND as $CONTAINER_REMOTE_PREFIX, the same as DUMB does. The mount-prefix vars
# below must match the target path written INTO the symlink, NOT the host-side path.
# ======================================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/notify.sh
. "$SCRIPT_DIR/lib/notify.sh"

# --- 1. MEDIA SERVER + *ARR CONFIG (all from config.env) -------------------------------
: "${PLEX_URL:=}"
: "${PLEX_TOKEN:=}"
: "${EMBY_URL:=}"
: "${EMBY_API:=}"

: "${SONARR_HD_URL:=}"; : "${SONARR_HD_API:=}"
: "${SONARR_4K_URL:=}"; : "${SONARR_4K_API:=}"
: "${RADARR_HD_URL:=}"; : "${RADARR_HD_API:=}"
: "${RADARR_4K_URL:=}"; : "${RADARR_4K_API:=}"
: "${LIDARR_URL:=}"; : "${LIDARR_API:=}"
: "${SPORTARR_URL:=}"; : "${SPORTARR_API:=}"

# --- 2. SAFETY & PACE ------------------------------------------------------------------
: "${DRY_RUN_GLOBAL:=Y}"
: "${MAX_BROKEN_BEFORE_HALT:=150}"
: "${ROLLING_24H_LIMIT:=200}"
: "${UPTIME_MATURITY_REQUIRED:=3600}"
: "${DELETES_PER_RUN:=5}"
: "${MIN_PACKS_SANITY:=100}"

# --- 3. LIBRARY MAPPING ----------------------------------------------------------------
# Format: "Path|Name|Arr_Key|Mode|Notify_Type|Media_ID|Min_Depth|Max_Depth"
# Bash arrays can't be passed via systemd EnvironmentFile=, so keep the array here.
# Override by setting LIBRARIES_FILE=/path/to/libraries.txt (one entry per line) in
# config.env to load externally.
if [ -n "${LIBRARIES_FILE:-}" ] && [ -f "$LIBRARIES_FILE" ]; then
    mapfile -t LIBRARIES < <(grep -vE '^\s*(#|$)' "$LIBRARIES_FILE")
else
    LIBRARIES=(
        "$MEDIA_ROOT/tv-remote|TV Shows|SONARR_HD|LIVE|PLEX|4|3|4"
        "$MEDIA_ROOT/tv-remote-4k|TV Shows 4K|SONARR_4K|LIVE|PLEX|10|3|4"
        "$MEDIA_ROOT/movies-hd-remote|Movies HD|RADARR_HD|LIVE|PLEX|2|2|3"
        "$MEDIA_ROOT/movies-uhd-remote|Movies 4K|RADARR_4K|LIVE|PLEX|1|2|3"
    )
fi

# --- 4. PATHS --------------------------------------------------------------------------
STATE_DB="$STATE_DIR/sentinel_state.db"
AUDIT_LOG="$LOG_DIR/sentinel_audit.log"
HOLD_FILE="$STATE_DIR/SENTINEL_HOLD.txt"
PRIME_STATE="$STATE_DIR/prime_state.db"

# Symlink target prefix (container-side) — must match what DUMB's *Arrs write into symlinks.
NZB_LINK_PREFIX="$CONTAINER_REMOTE_PREFIX/nzbdav"
DEC_LINK_PREFIX="$CONTAINER_REMOTE_PREFIX/decypharr"

# --- 5. MAIN SCRIPT --------------------------------------------------------------------

log_it() { log_step "$1" "$AUDIT_LOG"; }

touch "$STATE_DB" "$AUDIT_LOG"

echo "------------------------------------------------------------"
echo " SENTINEL CONFIGURATION"
echo "------------------------------------------------------------"
echo " Deletes Per Run:   $DELETES_PER_RUN"
echo " Circuit Breaker:   $MAX_BROKEN_BEFORE_HALT"
echo " Rolling 24h Limit: $ROLLING_24H_LIMIT"
echo " Dry Run:           $DRY_RUN_GLOBAL"
echo " NZB prefix:        $NZB_LINK_PREFIX"
echo " DEC prefix:        $DEC_LINK_PREFIX"
echo "------------------------------------------------------------"

# 1. Maturity Check
if [ -f "$PRIME_STATE" ]; then
    NZB_START_TS=$(grep "NZB_START_TS" "$PRIME_STATE" | cut -d= -f2 | tr -d '"')
    if [ -n "$NZB_START_TS" ]; then
        UPTIME=$(( $(date +%s) - NZB_START_TS ))
        if [ "$UPTIME" -lt "$UPTIME_MATURITY_REQUIRED" ]; then
            log_it "STABILITY: Mount is fresh ($((UPTIME/60)) mins). Postponing."
            exit 0
        fi
    fi
fi

# 2. PRE-SCAN: Build ground-truth indexes for both mounts (no per-file stats)
PACK_LIST=$(mktemp)
NZB_LIST=$(mktemp)

# Decypharr: one readdir of __all__ — pack DIRECTORY names (torrent-level granularity).
DEC_ALL_PATH="${DEC_MOUNT}/__all__"
log_it "PRE-SCAN: Indexing decypharr packs from $DEC_ALL_PATH..."
find "$DEC_ALL_PATH" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -u > "$PACK_LIST"
DEC_PACK_COUNT=$(wc -l < "$PACK_LIST")

if (( DEC_PACK_COUNT < MIN_PACKS_SANITY )); then
    log_it "ABORT: Only $DEC_PACK_COUNT packs returned — decypharr index may be stale or mount is down. Exiting safely."
    rm -f "$PACK_LIST" "$NZB_LIST"
    exit 1
fi

# NzbDAV: ONE readdir of completed-symlinks — category dir names only (-maxdepth 1).
NZB_CS_PATH="${NZB_MOUNT}/completed-symlinks"
log_it "PRE-SCAN: Indexing NzbDAV categories from $NZB_CS_PATH..."
find "$NZB_CS_PATH" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -u > "$NZB_LIST"
NZB_CAT_COUNT=$(wc -l < "$NZB_LIST")

log_it "PRE-SCAN: $DEC_PACK_COUNT decypharr packs + $NZB_CAT_COUNT NzbDAV categories indexed. Starting scan..."

# 3. SCAN
TOTAL_BROKEN_GLOBAL=0
CANDIDATES=()

for ENTRY in "${LIBRARIES[@]}"; do
    IFS='|' read -r LIB_PATH LIB_NAME LIB_KEY LIB_MODE LIB_NOTIFY LIB_ID LIB_MIN LIB_MAX <<< "$ENTRY"
    if [ -d "$LIB_PATH" ]; then
        log_it ">> SCANNING: $LIB_NAME [$LIB_MODE]"

        DEPTH_ARGS=""
        [ -n "$LIB_MIN" ] && DEPTH_ARGS="$DEPTH_ARGS -mindepth $LIB_MIN"
        [ -n "$LIB_MAX" ] && DEPTH_ARGS="$DEPTH_ARGS -maxdepth $LIB_MAX"

        LIB_BROKEN_COUNT=0
        while IFS= read -r broken_link; do
            CANDIDATES+=("$broken_link|$LIB_NAME|$LIB_KEY|$LIB_MODE|$LIB_NOTIFY|$LIB_ID")
            ((LIB_BROKEN_COUNT++))
            [ "$LIB_BROKEN_COUNT" -ge "$MAX_BROKEN_BEFORE_HALT" ] && break
        done < <(
            # $DEPTH_ARGS is intentionally unquoted so bash word-splits it into separate flags.
            # shellcheck disable=SC2086
            find "$LIB_PATH" $DEPTH_ARGS -type l \
                \( -lname "${NZB_LINK_PREFIX}*" -o -lname "${DEC_LINK_PREFIX}*" \) \
                -printf '%p\t%l\n' 2>/dev/null | \
            awk -v pack_file="$PACK_LIST" \
                -v nzb_file="$NZB_LIST" \
                -v dec_marker="realdebrid/__all__/" \
                -v nzb_marker="nzbdav/completed-symlinks/" '
                BEGIN {
                    while ((getline p < pack_file) > 0) dec_avail[p] = 1
                    close(pack_file)
                    while ((getline f < nzb_file) > 0) nzb_avail[f] = 1
                    close(nzb_file)
                }
                {
                    n = split($0, parts, "\t")
                    link = parts[1]; target = parts[2]

                    pos = index(target, dec_marker)
                    if (pos > 0) {
                        rest = substr(target, pos + length(dec_marker))
                        slash = index(rest, "/")
                        pack = (slash > 0) ? substr(rest, 1, slash - 1) : rest
                        if (pack != "" && !(pack in dec_avail)) print link
                        next
                    }

                    pos = index(target, nzb_marker)
                    if (pos > 0 && length(nzb_avail) > 0) {
                        rest = substr(target, pos + length(nzb_marker))
                        slash = index(rest, "/")
                        category = (slash > 0) ? substr(rest, 1, slash - 1) : rest
                        if (category != "" && !(category in nzb_avail)) print link
                    }
                }
            '
        )
        log_it "  Broken: $LIB_BROKEN_COUNT"

        TOTAL_BROKEN_GLOBAL=$((TOTAL_BROKEN_GLOBAL + LIB_BROKEN_COUNT))
    fi
done

# 4. CIRCUIT BREAKER
if [ "$DRY_RUN_GLOBAL" = "N" ] && [ "$TOTAL_BROKEN_GLOBAL" -gt "$MAX_BROKEN_BEFORE_HALT" ]; then
    log_it "CRITICAL: Broken links ($TOTAL_BROKEN_GLOBAL) exceeds threshold ($MAX_BROKEN_BEFORE_HALT)."
    echo "$TOTAL_BROKEN_GLOBAL broken links found. Sentinel Locked." > "$HOLD_FILE"
    notify "Sentinel Locked" "$TOTAL_BROKEN_GLOBAL broken links exceed threshold ($MAX_BROKEN_BEFORE_HALT). See $HOLD_FILE." "alert"
    exit 1
fi

# 5. ROLLING 24H TALLY
NOW=$(date +%s)
VALID_ENTRIES=$(grep -E '^[0-9]+$' "$STATE_DB" | awk -v limit="$((NOW - 86400))" '$1 > limit')
echo "$VALID_ENTRIES" > "$STATE_DB"
ROLLING_COUNT=$(echo "$VALID_ENTRIES" | wc -w)

processed_this_run=0
declare -A LIB_SUMMARY

# 6. EXECUTION
for ENTRY in "${CANDIDATES[@]}"; do
    [ "$processed_this_run" -ge "$DELETES_PER_RUN" ] || [ "$ROLLING_COUNT" -ge "$ROLLING_24H_LIMIT" ] && break

    IFS='|' read -r LINK LIB_NAME LIB_KEY LIB_MODE LIB_NOTIFY LIB_ID <<< "$ENTRY"

    if [ "$LIB_MODE" = "LIVE" ] && [ "$DRY_RUN_GLOBAL" = "N" ]; then
        if rm -f "$LINK"; then
            CMD_NAME="RescanSeries"
            [[ "${LIB_KEY}" == *"RADARR"* ]] && CMD_NAME="RefreshMovie"
            URL_VAR="${LIB_KEY}_URL"; API_VAR="${LIB_KEY}_API"
            if [ -n "${!URL_VAR:-}" ] && [ -n "${!API_VAR:-}" ]; then
                curl -s -X POST "${!URL_VAR}/api/v3/command" \
                    -H "X-Api-Key: ${!API_VAR}" \
                    -H "Content-Type: application/json" \
                    -d "{\"name\": \"$CMD_NAME\"}" > /dev/null
            fi

            if [ "$LIB_NOTIFY" = "PLEX" ] && [ -n "$LIB_ID" ] && [ -n "$PLEX_TOKEN" ]; then
                curl -s -G "${PLEX_URL}/library/sections/${LIB_ID}/refresh" \
                    -d "X-Plex-Token=${PLEX_TOKEN}" > /dev/null
            elif [ "$LIB_NOTIFY" = "EMBY" ] && [ -n "$EMBY_URL" ]; then
                curl -s -X POST "${EMBY_URL}/Library/Refresh?api_key=${EMBY_API}" > /dev/null
            fi

            echo "$NOW" >> "$STATE_DB"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETED [$LIB_NAME]: $LINK" >> "$AUDIT_LOG"
            LIB_SUMMARY["$LIB_NAME"]=$(( ${LIB_SUMMARY["$LIB_NAME"]:-0} + 1 ))
            ((processed_this_run++))
            ((ROLLING_COUNT++))
        fi
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] MOCK    [$LIB_NAME]: $LINK" >> "$AUDIT_LOG"
        LIB_SUMMARY["$LIB_NAME"]=$(( ${LIB_SUMMARY["$LIB_NAME"]:-0} + 1 ))
        ((processed_this_run++))
        ((ROLLING_COUNT++))
    fi
done

# 7. OUTPUT SUMMARY
echo "------------------------------------------------------------"
for LIB in "${!LIB_SUMMARY[@]}"; do
    log_it "[$LIB] Processed: ${LIB_SUMMARY[$LIB]}"
done

log_it "SENTINEL SUMMARY: Processed: $processed_this_run | 24h Tally: $ROLLING_COUNT | Total broken found: $TOTAL_BROKEN_GLOBAL | DEC packs: $DEC_PACK_COUNT | NZB categories: $NZB_CAT_COUNT"
log_it "Detailed paths recorded in $AUDIT_LOG"
echo "------------------------------------------------------------"
rm -f "$PACK_LIST" "$NZB_LIST"
exit 0
