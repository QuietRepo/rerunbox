#!/usr/bin/env bash
# RerunBox uninstaller.
#
#   sudo bash uninstall.sh            remove the services and program files,
#                                     KEEP your config, stream key and state
#   sudo bash uninstall.sh --purge    also remove config, secrets, state and the
#                                     service account
set -euo pipefail

PREFIX="${RB_PREFIX:-/opt/rerunbox}"
CONF_DIR="${RB_CONF_DIR:-/etc/rerunbox}"
UNIT_DIR="${RB_UNIT_DIR:-/etc/systemd/system}"
SUDOERS_DIR="${RB_SUDOERS_DIR:-/etc/sudoers.d}"
BIN_LINK="${RB_BIN_LINK:-/usr/local/bin/rerunbox}"
SKIP_SYSTEMCTL="${RB_SKIP_SYSTEMCTL:-0}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

[ "$(id -u)" -eq 0 ] || { echo "run as root: sudo bash uninstall.sh" >&2; exit 1; }
sctl() { if [ "$SKIP_SYSTEMCTL" = 1 ]; then :; else systemctl "$@"; fi; }

# Read the service user and state dir before anything is removed.
SERVICE_USER=rerunbox; STATE_DIR=/var/lib/rerunbox
# shellcheck disable=SC1091
[ -r "$CONF_DIR/rerunbox.conf" ] && . "$CONF_DIR/rerunbox.conf"

echo "Stopping and disabling services ..."
for u in rerunbox-restart.timer rerunbox-feeder.service rerunbox-relay.service rerunbox-webhook.service; do
    sctl disable --now "$u" 2>/dev/null || true
done

rm -f "$UNIT_DIR"/rerunbox-*.service "$UNIT_DIR"/rerunbox-restart.timer
rm -rf "$UNIT_DIR/rerunbox-feeder.service.d"
rm -f "$SUDOERS_DIR/rerunbox" "$BIN_LINK"
rm -rf "$PREFIX"
sctl daemon-reload

if [ "$PURGE" = 1 ]; then
    echo "Purging config, state and service account ..."
    rm -rf "$CONF_DIR" "$STATE_DIR"
    id "$SERVICE_USER" >/dev/null 2>&1 && userdel "$SERVICE_USER" || true
else
    echo "Kept $CONF_DIR (config + stream key) and $STATE_DIR. Use --purge to remove them."
fi
echo "RerunBox removed."
