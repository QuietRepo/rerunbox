#!/usr/bin/env bash
# RerunBox installer.
#
#   sudo bash install.sh              interactive
#   sudo -E bash install.sh --yes     non-interactive; settings come from the
#                                     environment, e.g.
#       LIBRARY_DIR=/srv/videos RTMP_URL=rtmp://... sudo -E bash install.sh --yes
#
# Re-running is safe: existing settings become the defaults, the old config is
# backed up, and your stream key is kept unless you enter a new one.
#
# Options:
#   --yes           do not prompt; use environment variables / existing config
#   --no-packages   do not apt-get install dependencies
#   --force         carry on even if the GPU test encode fails
#   --start         start streaming when the install finishes
#   --user NAME     service account name (default: rerunbox)
#   -h, --help
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Locations (the overrides exist so the installer can be tested in a sandbox).
PREFIX="${RB_PREFIX:-/opt/rerunbox}"
CONF_DIR="${RB_CONF_DIR:-/etc/rerunbox}"
UNIT_DIR="${RB_UNIT_DIR:-/etc/systemd/system}"
SUDOERS_DIR="${RB_SUDOERS_DIR:-/etc/sudoers.d}"
BIN_LINK="${RB_BIN_LINK:-/usr/local/bin/rerunbox}"
SKIP_SYSTEMCTL="${RB_SKIP_SYSTEMCTL:-0}"
CONF="$CONF_DIR/rerunbox.conf"
SECRETS="$CONF_DIR/secrets.env"

ASSUME_YES=0; NO_PACKAGES=0; FORCE=0; START_NOW=0; USER_ARG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-packages) NO_PACKAGES=1 ;;
        --force) FORCE=1 ;;
        --start) START_NOW=1 ;;
        --user) USER_ARG="${2:?--user needs a name}"; shift ;;
        -h|--help) sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

sctl() { if [ "$SKIP_SYSTEMCTL" = 1 ]; then note "(skipped) systemctl $*"; else systemctl "$@"; fi; }

[ "$(id -u)" -eq 0 ] || die "run as root:  sudo bash install.sh"
[ "$(uname -s)" = Linux ] || die "RerunBox only runs on Linux"
if [ "$SKIP_SYSTEMCTL" != 1 ] && [ ! -d /run/systemd/system ]; then
    die "systemd is required (no systemd detected)"
fi
[ -t 0 ] || ASSUME_YES=1   # no terminal to prompt on

# --- Settings: environment > existing config > defaults --------------------

KEYS=(LIBRARY_DIR AD_DIR AD_INTERVAL EXTENSIONS OVERLAY_PNG OVERLAY_POS ENCODER
      VAAPI_DEVICE QP MAX_FPS KEYFRAME_SECONDS AUDIO_BITRATE BITRATE_WARN_KBPS
      RESTART_INTERVAL_HOURS WEBHOOK_BIND WEBHOOK_PORT SERVICE_USER STATE_DIR
      RTMP_URL WEBHOOK_TOKEN DISCORD_WEBHOOK_URL)

declare -A FROM_ENV=()
for k in "${KEYS[@]}"; do
    [ -n "${!k:-}" ] && FROM_ENV[$k]="${!k}"
done
[ -n "$USER_ARG" ] && FROM_ENV[SERVICE_USER]="$USER_ARG"

set -a
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"
# shellcheck disable=SC1090
[ -r "$SECRETS" ] && . "$SECRETS"
set +a
for k in "${!FROM_ENV[@]}"; do printf -v "$k" '%s' "${FROM_ENV[$k]}"; done

: "${LIBRARY_DIR:=}"; : "${AD_DIR:=}"; : "${AD_INTERVAL:=2}"
: "${EXTENSIONS:=mkv mp4 mov m4v webm ts avi}"
: "${OVERLAY_PNG:=}"; : "${OVERLAY_POS:=x=W-w-40:y=40}"
: "${ENCODER:=vaapi}"; : "${VAAPI_DEVICE:=/dev/dri/renderD128}"
: "${QP:=28}"; : "${MAX_FPS:=30}"; : "${KEYFRAME_SECONDS:=2}"
: "${AUDIO_BITRATE:=160k}"; : "${BITRATE_WARN_KBPS:=8500}"
: "${RESTART_INTERVAL_HOURS:=12}"
: "${WEBHOOK_BIND:=127.0.0.1}"; : "${WEBHOOK_PORT:=8787}"
: "${SERVICE_USER:=rerunbox}"; : "${STATE_DIR:=/var/lib/rerunbox}"
: "${RTMP_URL:=}"; : "${WEBHOOK_TOKEN:=}"; : "${DISCORD_WEBHOOK_URL:=}"

# ask VAR "Question" [secret]
ask() {
    local var="$1" q="$2" secret="${3:-}" cur ans
    cur="${!var}"
    [ "$ASSUME_YES" = 1 ] && return 0
    if [ -n "$secret" ]; then
        read -r -s -p "$q$([ -n "$cur" ] && echo ' [press Enter to keep the current one]'): " ans; echo
    else
        read -r -p "$q$([ -n "$cur" ] && echo " [$cur]"): " ans
    fi
    [ -n "$ans" ] && printf -v "$var" '%s' "$ans"
    return 0
}

# Values are written into shell-sourced files, so refuse anything that could
# break out of a double-quoted string.
check_safe() {
    local var="$1" val="${!1}"
    case "$val" in
        *'"'*|*'$'*|*'`'*|*'\'*|*$'\n'*)
            die "$var contains a character that is not allowed (double quote, \$, backtick, backslash or newline)" ;;
    esac
}

echo "RerunBox installer"
echo "Press Enter to accept the value in [brackets]."
echo

ask LIBRARY_DIR "Folder of videos to loop"
while [ ! -d "$LIBRARY_DIR" ]; do
    [ "$ASSUME_YES" = 1 ] && die "LIBRARY_DIR '$LIBRARY_DIR' is not an existing folder"
    warn "'$LIBRARY_DIR' is not an existing folder"
    LIBRARY_DIR=""; ask LIBRARY_DIR "Folder of videos to loop"
done
LIBRARY_DIR="$(cd "$LIBRARY_DIR" && pwd)"

ask AD_DIR "Optional folder of ad-break clips (blank for none)"
[ -z "$AD_DIR" ] || [ -d "$AD_DIR" ] || die "AD_DIR '$AD_DIR' is not an existing folder"
[ -z "$AD_DIR" ] || AD_DIR="$(cd "$AD_DIR" && pwd)"
[ -z "$AD_DIR" ] || ask AD_INTERVAL "Play the ad break after every N clips"

ask OVERLAY_PNG "Optional overlay PNG, e.g. a REPLAY badge (blank for none)"
[ -z "$OVERLAY_PNG" ] || [ -f "$OVERLAY_PNG" ] || die "OVERLAY_PNG '$OVERLAY_PNG' does not exist"
[ -z "$OVERLAY_PNG" ] || OVERLAY_PNG="$(readlink -f "$OVERLAY_PNG")"

while :; do
    ask RTMP_URL "Stream destination: full RTMP URL including your stream key" secret
    case "$RTMP_URL" in rtmp://*|rtmps://*) break ;; esac
    [ "$ASSUME_YES" = 1 ] && die "RTMP_URL must start with rtmp:// or rtmps://"
    warn "that does not look like an rtmp:// or rtmps:// URL"; RTMP_URL=""
done

ask QP "Quality (QP, lower = better quality and MORE bitrate; start at 28)"
ask MAX_FPS "Maximum frame rate (faster sources are reduced to this)"
ask RESTART_INTERVAL_HOURS "Restart the pipeline every N hours (0 = never)"
ask WEBHOOK_BIND "Webhook listen address (127.0.0.1 = this machine only)"
ask WEBHOOK_PORT "Webhook port"
ask DISCORD_WEBHOOK_URL "Optional Discord webhook URL for restart notices (blank for none)" secret

for k in "${KEYS[@]}"; do
    check_safe "$k"
done
case "$ENCODER" in vaapi|libx264) ;; *) die "ENCODER must be vaapi" ;; esac
[[ "$QP" =~ ^[0-9]+$ ]] && [ "$QP" -ge 1 ] && [ "$QP" -le 51 ] || die "QP must be 1-51"
[[ "$MAX_FPS" =~ ^[0-9]+$ ]] && [ "$MAX_FPS" -ge 1 ] || die "MAX_FPS must be a positive number"
[[ "$RESTART_INTERVAL_HOURS" =~ ^[0-9]+$ ]] || die "restart interval must be a whole number of hours"
[[ "$WEBHOOK_PORT" =~ ^[0-9]+$ ]] || die "webhook port must be a number"
[[ "$SERVICE_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid service user name '$SERVICE_USER'"

# --- Dependencies ---------------------------------------------------------------

say "Dependencies"
if [ "$NO_PACKAGES" = 0 ] && command -v apt-get >/dev/null; then
    va_pkg=intel-media-va-driver
    apt-cache show intel-media-va-driver-non-free >/dev/null 2>&1 && va_pkg=intel-media-va-driver-non-free
    note "installing ffmpeg, vainfo, $va_pkg, curl, python3, sudo ..."
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg vainfo "$va_pkg" curl python3 sudo
else
    missing=()
    for c in ffmpeg ffprobe curl python3 sudo; do command -v "$c" >/dev/null || missing+=("$c"); done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "missing: ${missing[*]}. Install them (plus the Intel media VA driver) and re-run with --no-packages"
    fi
    command -v vainfo >/dev/null || warn "vainfo is not installed; 'rerunbox doctor' will skip its driver check"
    note "all required commands present"
fi
command -v visudo >/dev/null || die "visudo not found (install sudo)"

# --- Service account ------------------------------------------------------------

say "Service account '$SERVICE_USER'"
if ! id "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --home-dir "$STATE_DIR" --shell /usr/sbin/nologin --user-group "$SERVICE_USER"
    note "created"
else
    note "already exists"
fi
for g in render video; do
    if getent group "$g" >/dev/null; then usermod -aG "$g" "$SERVICE_USER"; fi
done
install -d -m 0755 -o "$SERVICE_USER" -g "$SERVICE_USER" "$STATE_DIR"

# --- GPU check ------------------------------------------------------------------

say "Checking hardware H.264 encoding as '$SERVICE_USER'"
if [ "$ENCODER" = vaapi ]; then
    if sudo -u "$SERVICE_USER" ffmpeg -hide_banner -loglevel error -nostdin \
        -f lavfi -i testsrc2=size=1280x720:rate=30 -t 1 -vaapi_device "$VAAPI_DEVICE" \
        -vf format=nv12,hwupload -c:v h264_vaapi -rc_mode CQP -qp "$QP" -f null - 2>/tmp/.rerunbox-gpu.$$; then
        note "OK: the GPU encoded a test clip"
    else
        warn "the hardware test encode FAILED:"
        sed 's/^/        /' /tmp/.rerunbox-gpu.$$ >&2 || true
        note "Common causes: no Intel GPU, missing intel-media-va-driver, or $VAAPI_DEVICE not present."
        rm -f /tmp/.rerunbox-gpu.$$
        [ "$FORCE" = 1 ] || die "stopping. Fix the GPU setup, or re-run with --force to install anyway."
    fi
    rm -f /tmp/.rerunbox-gpu.$$
fi

say "Checking that '$SERVICE_USER' can read your media"
for d in "$LIBRARY_DIR" "$AD_DIR"; do
    [ -n "$d" ] || continue
    if sudo -u "$SERVICE_USER" test -r "$d" -a -x "$d" 2>/dev/null; then
        note "OK: $d"
    else
        warn "'$SERVICE_USER' cannot read $d. Fix permissions (for example: chmod -R a+rX), or for a network share add uid/gid or file_mode options to its mount. 'rerunbox doctor' re-checks this."
    fi
done

# --- Files ----------------------------------------------------------------------

say "Installing files to $PREFIX"
rm -rf "${PREFIX:?}/bin" "${PREFIX:?}/lib"
install -d -m 0755 "$PREFIX" "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/config"
for f in "$SRC"/bin/*; do install -m 0755 "$f" "$PREFIX/bin/"; done
for f in "$SRC"/lib/*;  do install -m 0644 "$f" "$PREFIX/lib/"; done
install -m 0644 "$SRC"/config/* "$PREFIX/config/"
install -m 0644 "$SRC/VERSION" "$PREFIX/VERSION"
ln -sfn "$PREFIX/bin/rerunbox" "$BIN_LINK"

say "Writing configuration to $CONF_DIR"
install -d -m 0755 "$CONF_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
[ -f "$CONF" ] && cp -p "$CONF" "$CONF.bak-$ts"
[ -f "$SECRETS" ] && cp -p "$SECRETS" "$SECRETS.bak-$ts"

if [ -z "$WEBHOOK_TOKEN" ]; then
    if command -v openssl >/dev/null; then WEBHOOK_TOKEN="$(openssl rand -hex 24)"
    else WEBHOOK_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"; fi
    note "generated a webhook token (show it with: sudo rerunbox token)"
fi

cat > "$CONF" <<EOF
# RerunBox configuration. Written by install.sh; see $PREFIX/config/rerunbox.conf.example
# for what every setting does. Apply changes with:  rerunbox restart
LIBRARY_DIR="$LIBRARY_DIR"
AD_DIR="$AD_DIR"
AD_INTERVAL="$AD_INTERVAL"
EXTENSIONS="$EXTENSIONS"
OVERLAY_PNG="$OVERLAY_PNG"
OVERLAY_POS="$OVERLAY_POS"
ENCODER="$ENCODER"
VAAPI_DEVICE="$VAAPI_DEVICE"
QP="$QP"
MAX_FPS="$MAX_FPS"
KEYFRAME_SECONDS="$KEYFRAME_SECONDS"
AUDIO_BITRATE="$AUDIO_BITRATE"
BITRATE_WARN_KBPS="$BITRATE_WARN_KBPS"
RESTART_INTERVAL_HOURS="$RESTART_INTERVAL_HOURS"
WEBHOOK_BIND="$WEBHOOK_BIND"
WEBHOOK_PORT="$WEBHOOK_PORT"
SERVICE_USER="$SERVICE_USER"
STATE_DIR="$STATE_DIR"
EOF
chmod 0644 "$CONF"

umask 077
cat > "$SECRETS" <<EOF
# RerunBox secrets. Keep private; never commit.
RTMP_URL="$RTMP_URL"
WEBHOOK_TOKEN="$WEBHOOK_TOKEN"
DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL"
EOF
umask 022
chown "root:$SERVICE_USER" "$SECRETS"
chmod 0640 "$SECRETS"

# --- systemd --------------------------------------------------------------------

say "Installing systemd units"
for u in rerunbox-relay.service rerunbox-feeder.service rerunbox-webhook.service rerunbox-restart.service; do
    sed -e "s|@USER@|$SERVICE_USER|g" -e "s|@PREFIX@|$PREFIX|g" "$SRC/systemd/$u" > "$UNIT_DIR/$u"
    chmod 0644 "$UNIT_DIR/$u"
done

# Make the feeder wait for the mount that holds the media (NAS, external disk).
mounts=()
for d in "$LIBRARY_DIR" "$AD_DIR"; do
    [ -n "$d" ] || continue
    case "$d" in *[[:space:]]*) warn "'$d' contains whitespace; skipping RequiresMountsFor for it" ;; *) mounts+=("$d") ;; esac
done
install -d -m 0755 "$UNIT_DIR/rerunbox-feeder.service.d"
if [ "${#mounts[@]}" -gt 0 ]; then
    printf '[Unit]\nRequiresMountsFor=%s\n' "${mounts[*]}" > "$UNIT_DIR/rerunbox-feeder.service.d/media.conf"
else
    rm -f "$UNIT_DIR/rerunbox-feeder.service.d/media.conf"
fi

if [ "$RESTART_INTERVAL_HOURS" -gt 0 ]; then
    sed -e "s|@HOURS@|$RESTART_INTERVAL_HOURS|g" "$SRC/systemd/rerunbox-restart.timer" > "$UNIT_DIR/rerunbox-restart.timer"
    chmod 0644 "$UNIT_DIR/rerunbox-restart.timer"
else
    sctl disable --now rerunbox-restart.timer 2>/dev/null || true
    rm -f "$UNIT_DIR/rerunbox-restart.timer"
fi

say "Allowing '$SERVICE_USER' to start/stop its own services (sudoers)"
systemctl_path="$(command -v systemctl || echo /usr/bin/systemctl)"
tmp_sudoers="$(mktemp)"
sed -e "s|@USER@|$SERVICE_USER|g" -e "s|@SYSTEMCTL@|$systemctl_path|g" "$SRC/systemd/rerunbox.sudoers" > "$tmp_sudoers"
if visudo -cf "$tmp_sudoers" >/dev/null; then
    install -d -m 0750 "$SUDOERS_DIR"
    install -m 0440 "$tmp_sudoers" "$SUDOERS_DIR/rerunbox"
    note "installed $SUDOERS_DIR/rerunbox"
else
    rm -f "$tmp_sudoers"
    die "generated sudoers file failed validation; nothing was installed"
fi
rm -f "$tmp_sudoers"

sctl daemon-reload
sctl enable rerunbox-relay.service rerunbox-feeder.service rerunbox-webhook.service
[ "$RESTART_INTERVAL_HOURS" -gt 0 ] && sctl enable --now rerunbox-restart.timer
sctl restart rerunbox-webhook.service || warn "webhook did not start; check: journalctl -u rerunbox-webhook"

if [ "$START_NOW" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    echo
    read -r -p "Start streaming now? Test your encode settings first if unsure. [y/N] " ans
    case "$ans" in y|Y|yes|YES) START_NOW=1 ;; esac
fi
if [ "$START_NOW" = 1 ]; then
    say "Starting the loop"
    sctl start rerunbox-relay.service
    sctl start rerunbox-feeder.service
fi

cat <<EOF

RerunBox $(tr -d '[:space:]' < "$SRC/VERSION") is installed.

Before you go live:
  rerunbox doctor          check the system, config and GPU
  rerunbox preflight       test every file in your library with the real encoder
  rerunbox test-encode     measure speed and bitrate on a sample (use your busiest clip)
  rerunbox start           begin streaming          (rerunbox status / logs / stop)

Config:   $CONF
Secrets:  $SECRETS   (stream key + webhook token)
Webhook:  http://$WEBHOOK_BIND:$WEBHOOK_PORT   token: sudo rerunbox token

Read docs/bitrate-tuning.md: Intel's encoder cannot cap bitrate, so check yours.
EOF
