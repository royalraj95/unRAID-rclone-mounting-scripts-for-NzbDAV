#!/usr/bin/env bash
# ======================================================================================
# LIB: notify.sh — pluggable notification dispatcher
#
# Usage: notify "subject" "message" [priority]
#   priority is one of: normal, alert (Unraid convention) — translated per-backend.
#
# Backend selected via NOTIFY_BACKEND env var (set in config.env):
#   logger   (default) — writes to syslog/journal via `logger -t dumb-scripts`
#   ntfy     — POSTs to $NTFY_URL (https://ntfy.sh/<topic> or self-hosted)
#   apprise  — calls `apprise -t -b -- $APPRISE_URLS` (requires `apprise` binary)
#   discord  — POSTs to $DISCORD_WEBHOOK_URL
#
# Any backend failure falls back to the logger.
# ======================================================================================

notify() {
    local subject="$1"
    local message="$2"
    local priority="${3:-normal}"
    local backend="${NOTIFY_BACKEND:-logger}"

    case "$backend" in
        ntfy)
            if [ -n "${NTFY_URL:-}" ]; then
                # ntfy priority: 1 (min) .. 5 (urgent). Map alert->4, normal->3.
                local ntfy_priority=3
                [ "$priority" = "alert" ] && ntfy_priority=4
                if curl -fsS --max-time 10 \
                    -H "Title: $subject" \
                    -H "Priority: $ntfy_priority" \
                    -H "Tags: dumb-scripts" \
                    -d "$message" \
                    "$NTFY_URL" > /dev/null 2>&1; then
                    return 0
                fi
            fi
            ;;
        apprise)
            if command -v apprise > /dev/null 2>&1 && [ -n "${APPRISE_URLS:-}" ]; then
                # APPRISE_URLS may be comma- or newline-separated. Pass as single arg.
                if apprise -t "$subject" -b "$message" -- "$APPRISE_URLS" > /dev/null 2>&1; then
                    return 0
                fi
            fi
            ;;
        discord)
            if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
                # Escape backslashes and double-quotes for JSON.
                local safe_subject safe_message
                safe_subject=${subject//\\/\\\\}; safe_subject=${safe_subject//\"/\\\"}
                safe_message=${message//\\/\\\\}; safe_message=${safe_message//\"/\\\"}
                local payload="{\"content\":\"**[$priority] $safe_subject** — $safe_message\"}"
                if curl -fsS --max-time 10 \
                    -H "Content-Type: application/json" \
                    -d "$payload" \
                    "$DISCORD_WEBHOOK_URL" > /dev/null 2>&1; then
                    return 0
                fi
            fi
            ;;
    esac

    # Fallback (also the explicit "logger" backend).
    local syslog_priority="user.info"
    [ "$priority" = "alert" ] && syslog_priority="user.warning"
    logger -t dumb-scripts -p "$syslog_priority" -- "[$priority] $subject: $message" 2>/dev/null || \
        echo "[notify-fallback] [$priority] $subject: $message" >&2
}
