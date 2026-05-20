#!/usr/bin/env bash
# ======================================================================================
# Uninstaller for the DUMB Linux scripts + systemd units.
# Leaves /etc/dumb-scripts/config.env and /var/{lib,log}/dumb-scripts/ in place.
# ======================================================================================

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "error: must run as root (use sudo)" >&2
    exit 1
fi

SYSTEMD_DIR="/etc/systemd/system"
INSTALL_DIR="/opt/dumb-scripts"

echo "==> Stopping & disabling units"
for u in \
    nzbdav-heartbeat.timer \
    nzbdav-plex-monitor.timer \
    nzbdav-symlink-cleanup.timer \
    nzbdav-shutdown-janitor.service; do
    systemctl disable --now "$u" 2>/dev/null || true
done

echo "==> Removing systemd unit files"
rm -f "$SYSTEMD_DIR"/nzbdav-heartbeat.service \
      "$SYSTEMD_DIR"/nzbdav-heartbeat.timer \
      "$SYSTEMD_DIR"/nzbdav-plex-monitor.service \
      "$SYSTEMD_DIR"/nzbdav-plex-monitor.timer \
      "$SYSTEMD_DIR"/nzbdav-symlink-cleanup.service \
      "$SYSTEMD_DIR"/nzbdav-symlink-cleanup.timer \
      "$SYSTEMD_DIR"/nzbdav-shutdown-janitor.service

systemctl daemon-reload

echo "==> Removing $INSTALL_DIR"
rm -rf "$INSTALL_DIR"

cat <<EOF

Uninstall complete.
Preserved (delete manually if desired):
  /etc/dumb-scripts/             (config)
  /var/lib/dumb-scripts/         (state)
  /var/log/dumb-scripts/         (logs)
EOF
