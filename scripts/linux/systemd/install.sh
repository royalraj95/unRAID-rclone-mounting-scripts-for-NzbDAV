#!/usr/bin/env bash
# ======================================================================================
# Installer for the DUMB Linux scripts + systemd units. Idempotent.
#
# Layout after install:
#   /opt/dumb-scripts/                 — all four scripts + lib/
#   /etc/dumb-scripts/config.env       — config (created from .example on first run)
#   /etc/systemd/system/nzbdav-*.{service,timer}
#   /var/lib/dumb-scripts/             — state (created on first run by the scripts)
#   /var/log/dumb-scripts/             — logs   (created on first run by the scripts)
# ======================================================================================

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (use sudo)" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/dumb-scripts"
CONFIG_DIR="/etc/dumb-scripts"
SYSTEMD_DIR="/etc/systemd/system"

echo "==> Installing scripts to $INSTALL_DIR"
install -m 0755 -d "$INSTALL_DIR" "$INSTALL_DIR/lib" "$CONFIG_DIR"
install -m 0755 "$SRC_DIR/mount-heartbeat.sh"     "$INSTALL_DIR/"
install -m 0755 "$SRC_DIR/plex-mount-monitor.sh"  "$INSTALL_DIR/"
install -m 0755 "$SRC_DIR/symlink-cleanup.sh"     "$INSTALL_DIR/"
install -m 0755 "$SRC_DIR/shutdown-janitor.sh"    "$INSTALL_DIR/"
install -m 0644 "$SRC_DIR/lib/common.sh"          "$INSTALL_DIR/lib/"
install -m 0644 "$SRC_DIR/lib/notify.sh"          "$INSTALL_DIR/lib/"

echo "==> Installing config example to $CONFIG_DIR"
install -m 0644 "$SRC_DIR/config.env.example" "$CONFIG_DIR/config.env.example"
if [ ! -f "$CONFIG_DIR/config.env" ]; then
    install -m 0600 "$SRC_DIR/config.env.example" "$CONFIG_DIR/config.env"
    echo "    created $CONFIG_DIR/config.env (edit before enabling timers)"
else
    echo "    $CONFIG_DIR/config.env already exists — leaving it alone"
fi

echo "==> Installing systemd units to $SYSTEMD_DIR"
install -m 0644 "$SRC_DIR/systemd/nzbdav-heartbeat.service"          "$SYSTEMD_DIR/"
install -m 0644 "$SRC_DIR/systemd/nzbdav-heartbeat.timer"            "$SYSTEMD_DIR/"
install -m 0644 "$SRC_DIR/systemd/nzbdav-plex-monitor.service"       "$SYSTEMD_DIR/"
install -m 0644 "$SRC_DIR/systemd/nzbdav-plex-monitor.timer"         "$SYSTEMD_DIR/"
install -m 0644 "$SRC_DIR/systemd/nzbdav-symlink-cleanup.service"    "$SYSTEMD_DIR/"
install -m 0644 "$SRC_DIR/systemd/nzbdav-symlink-cleanup.timer"      "$SYSTEMD_DIR/"
install -m 0644 "$SRC_DIR/systemd/nzbdav-shutdown-janitor.service"   "$SYSTEMD_DIR/"

systemctl daemon-reload

echo "==> Enabling timers + shutdown service"
systemctl enable --now \
    nzbdav-heartbeat.timer \
    nzbdav-plex-monitor.timer \
    nzbdav-symlink-cleanup.timer
systemctl enable nzbdav-shutdown-janitor.service

cat <<EOF

Install complete.

Next steps:
  1. Edit your config:    sudoedit /etc/dumb-scripts/config.env
  2. Validate one run:    sudo systemctl start nzbdav-heartbeat.service
                          sudo journalctl -u nzbdav-heartbeat.service -e
  3. Watch the timers:    systemctl list-timers 'nzbdav-*'
  4. Live logs:           journalctl -t dumb-scripts -f

Uninstall: sudo $SRC_DIR/systemd/uninstall.sh
EOF
