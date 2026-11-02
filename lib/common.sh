#!/usr/bin/env bash
# RerunBox shared helpers. Sourced by the other scripts; never executed directly.
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables here are consumed by the scripts that source this file

RB_ROOT="${RB_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RB_CONF="${RERUNBOX_CONF:-/etc/rerunbox/rerunbox.conf}"
RB_SECRETS="${RERUNBOX_SECRETS:-/etc/rerunbox/secrets.env}"

RB_RELAY_UNIT="rerunbox-relay.service"
RB_FEEDER_UNIT="rerunbox-feeder.service"
RB_WEBHOOK_UNIT="rerunbox-webhook.service"
RB_TIMER_UNIT="rerunbox-restart.timer"

rb_log()  { printf '%s %s\n' "$(date '+%F %T')" "$*"; }
rb_warn() { printf '%s WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }
rb_die()  { printf '%s ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

rb_version() {
    if [ -r "$RB_ROOT/VERSION" ]; then tr -d '[:space:]' < "$RB_ROOT/VERSION"; else echo "unknown"; fi
}

# Load config (non-secret) and secrets (if readable), then apply defaults.
rb_load_config() {
    set -a
    # shellcheck disable=SC1090
    [ -r "$RB_CONF" ] && . "$RB_CONF"
    # shellcheck disable=SC1090
    [ -r "$RB_SECRETS" ] && . "$RB_SECRETS"
    set +a

    : "${SERVICE_USER:=rerunbox}"
    : "${STATE_DIR:=/var/lib/rerunbox}"
    : "${LIBRARY_DIR:=}"
    : "${AD_DIR:=}"
    : "${AD_INTERVAL:=2}"
    : "${EXTENSIONS:=mkv mp4 mov m4v webm ts avi}"
    : "${ENCODER:=vaapi}"
    : "${VAAPI_DEVICE:=/dev/dri/renderD128}"
    : "${QP:=28}"
    : "${MAX_FPS:=30}"
    : "${KEYFRAME_SECONDS:=2}"
    : "${AUDIO_BITRATE:=160k}"
    : "${OVERLAY_PNG:=}"
    : "${OVERLAY_POS:=x=W-w-40:y=40}"
    : "${BITRATE_WARN_KBPS:=8500}"
    : "${RESTART_INTERVAL_HOURS:=12}"
    : "${WEBHOOK_BIND:=127.0.0.1}"
    : "${WEBHOOK_PORT:=8787}"
    : "${RTMP_URL:=}"
    : "${WEBHOOK_TOKEN:=}"
    : "${DISCORD_WEBHOOK_URL:=}"

    FIFO="$STATE_DIR/stream.fifo"
    STATE_FILE="$STATE_DIR/feeder.state"
}

rb_is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

# Validate values that get interpolated into ffmpeg arguments. Returns non-zero
# and prints every problem found.
rb_validate_config() {
    local bad=0
    if ! rb_is_int "$QP" || [ "$QP" -lt 1 ] || [ "$QP" -gt 51 ]; then
        echo "QP must be an integer between 1 and 51 (got '$QP')" >&2; bad=1; fi
    if ! rb_is_int "$MAX_FPS" || [ "$MAX_FPS" -lt 1 ] || [ "$MAX_FPS" -gt 120 ]; then
        echo "MAX_FPS must be an integer between 1 and 120 (got '$MAX_FPS')" >&2; bad=1; fi
    if ! rb_is_int "$KEYFRAME_SECONDS" || [ "$KEYFRAME_SECONDS" -lt 1 ] || [ "$KEYFRAME_SECONDS" -gt 10 ]; then
        echo "KEYFRAME_SECONDS must be an integer between 1 and 10 (got '$KEYFRAME_SECONDS')" >&2; bad=1; fi
    if ! rb_is_int "$AD_INTERVAL" || [ "$AD_INTERVAL" -lt 1 ]; then
        echo "AD_INTERVAL must be an integer >= 1 (got '$AD_INTERVAL')" >&2; bad=1; fi
    if ! rb_is_int "$RESTART_INTERVAL_HOURS"; then
        echo "RESTART_INTERVAL_HOURS must be an integer, 0 disables (got '$RESTART_INTERVAL_HOURS')" >&2; bad=1; fi
    if ! rb_is_int "$WEBHOOK_PORT" || [ "$WEBHOOK_PORT" -lt 1 ] || [ "$WEBHOOK_PORT" -gt 65535 ]; then
        echo "WEBHOOK_PORT must be 1-65535 (got '$WEBHOOK_PORT')" >&2; bad=1; fi
    if ! [[ "$AUDIO_BITRATE" =~ ^[0-9]+k$ ]]; then
        echo "AUDIO_BITRATE must look like 160k (got '$AUDIO_BITRATE')" >&2; bad=1; fi
    case "$ENCODER" in
        vaapi|libx264) ;;
        *) echo "ENCODER must be 'vaapi' (got '$ENCODER')" >&2; bad=1 ;;
    esac
    return $bad
}

# Run a command as root, using sudo when we are not already root.
rb_sudo() {
    if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# Fill the global array MEDIA_FILES with the sorted media files in DIR.
# Hidden files (including macOS "._" shadows) and partial downloads are skipped
# because only the configured extensions match.
rb_list_media() {
    local dir="$1" ext f
    local -a args=()
    for ext in $EXTENSIONS; do
        [ "${#args[@]}" -gt 0 ] && args+=(-o)
        args+=(-iname "*.${ext}")
    done
    MEDIA_FILES=()
    [ -d "$dir" ] || return 0
    while IFS= read -r -d '' f; do
        MEDIA_FILES+=("$f")
    done < <(find "$dir" -maxdepth 1 -type f ! -name '.*' \( "${args[@]}" \) -print0 | LC_ALL=C sort -z)
}

# Stop the loop: feeder first, then relay (reverse of start order).
rb_loop_stop() {
    rb_sudo systemctl stop "$RB_FEEDER_UNIT" || return 1
    rb_sudo systemctl stop "$RB_RELAY_UNIT"
}

# Start the loop: relay first (it creates the FIFO), then feeder.
rb_loop_start() {
    rb_sudo systemctl start "$RB_RELAY_UNIT" || return 1
    rb_sudo systemctl start "$RB_FEEDER_UNIT"
}
