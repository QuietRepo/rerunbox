#!/usr/bin/env bash
# End-to-end smoke test: feeder -> FIFO -> relay -> file, with no GPU, no
# network and no systemd. It uses the libx264 test backend (ENCODER=libx264),
# so it proves the loop logic and the ffmpeg graph, NOT the Intel VAAPI path.
# Run it anywhere with ffmpeg, ffprobe and python3:   bash tests/smoke-test.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$T"' EXIT
PASS=0; FAIL=0
check() { if [ "$2" = "1" ]; then echo "  PASS  $1"; PASS=$((PASS + 1)); else echo "  FAIL  $1"; FAIL=$((FAIL + 1)); fi; }

mkdir -p "$T/lib" "$T/ads" "$T/state"
mk() { # mk NAME FPS SECONDS [noaudio]
    local audio=(-f lavfi -i "sine=frequency=440:sample_rate=48000" -c:a aac)
    [ "${4:-}" = noaudio ] && audio=(-an)
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=$2" "${audio[@]}" \
        -t "$3" -c:v libx264 -preset ultrafast -pix_fmt yuv420p "$T/$1"
}
mk lib/a_30fps.mp4 30 3
mk lib/b_60fps.mp4 60 3
mk lib/c_noaudio.mp4 25 3 noaudio
mk ads/ad.mp4 30 2
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=red@0.8:size=80x30,format=rgba" -frames:v 1 "$T/badge.png"

cat > "$T/rerunbox.conf" <<EOF
LIBRARY_DIR="$T/lib"
AD_DIR="$T/ads"
AD_INTERVAL="2"
OVERLAY_PNG="$T/badge.png"
ENCODER="libx264"
STATE_DIR="$T/state"
MAX_FPS="30"
EOF
printf 'RTMP_URL="%s"\n' "$T/out.flv" > "$T/secrets.env"
export RERUNBOX_CONF="$T/rerunbox.conf" RERUNBOX_SECRETS="$T/secrets.env"

echo "Config validation"
(
    # shellcheck source=../lib/common.sh
    . "$ROOT/lib/common.sh"; rb_load_config
    QP=99 rb_validate_config 2>/dev/null && exit 1 || exit 0
) ; check "rejects QP=99" "$([ $? -eq 0 ] && echo 1 || echo 0)"

echo "Pipeline"
"$ROOT/bin/rerunbox-relay" >"$T/relay.log" 2>&1 & RELAY=$!
sleep 1
"$ROOT/bin/rerunbox-feeder" >"$T/feeder.log" 2>&1 & FEEDER=$!
sleep 17          # 3 clips x 3 s + one 2 s ad break + margin, played at 1x
kill -TERM "$FEEDER"; wait "$FEEDER" 2>/dev/null
kill -TERM "$RELAY" 2>/dev/null; wait "$RELAY" 2>/dev/null

feed="$T/feeder.log"
grep -q "Feeding: a_30fps.mp4 \[overlay\]" "$feed"; check "plays library clips with overlay" "$([ $? -eq 0 ] && echo 1 || echo 0)"
grep -q "b_60fps.mp4.*capped to 30" "$feed";        check "caps 60 fps source to 30" "$([ $? -eq 0 ] && echo 1 || echo 0)"
grep -q "c_noaudio.mp4.*adding silence" "$feed";    check "adds silence to clip with no audio" "$([ $? -eq 0 ] && echo 1 || echo 0)"
grep -q "Ad break: 1 file" "$feed";                 check "ad break fires after 2 clips" "$([ $? -eq 0 ] && echo 1 || echo 0)"
grep -q "Feeding: ad.mp4 \[plain\]" "$feed";        check "ad is played without overlay" "$([ $? -eq 0 ] && echo 1 || echo 0)"
# (By now the loop has wrapped round, so which library clip is recorded depends
# on timing; what matters is that it is a library clip and never the ad.)
if [ -f "$T/state/feeder.state" ] && grep -q "$T/lib/" "$T/state/feeder.state" && ! grep -q "ad.mp4" "$T/state/feeder.state"; then
    check "state file records a library clip, never the ad" 1
else
    check "state file records a library clip, never the ad" 0
fi
grep -q "ffmpeg exited with status" "$feed" && ok_exit=0 || ok_exit=1
check "no ffmpeg failures logged" "$ok_exit"

if [ -s "$T/out.flv" ]; then
    dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$T/out.flv" 2>/dev/null)"
    # a(3)+b(3) + ad(2) + c(3) is about 11 s; a single-frame overlay bug would give ~0 s per clip
    check "relay output is continuous (duration ${dur:-0}s >= 9s)" "$(awk -v d="${dur:-0}" 'BEGIN{print (d>=9)?1:0}')"
    nv="$(ffprobe -v error -select_streams v -count_packets -show_entries stream=nb_read_packets -of csv=p=0 "$T/out.flv" 2>/dev/null)"
    check "video frames present (${nv:-0} packets)" "$(awk -v n="${nv:-0}" 'BEGIN{print (n>=250)?1:0}')"
    fps="$(ffprobe -v error -select_streams v -show_entries stream=avg_frame_rate -of csv=p=0 "$T/out.flv" 2>/dev/null | head -1)"
    check "output frame rate is 30 (got $fps)" "$([ "$fps" = "30/1" ] && echo 1 || echo 0)"
    na="$(ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$T/out.flv" 2>/dev/null | head -1)"
    check "output has AAC audio (got ${na:-none})" "$([ "$na" = "aac" ] && echo 1 || echo 0)"
else
    check "relay wrote output" 0
fi

echo "Resume"
printf '%s\n' "$T/lib/b_60fps.mp4" > "$T/state/feeder.state"
"$ROOT/bin/rerunbox-relay" >"$T/relay2.log" 2>&1 & RELAY=$!
sleep 1
"$ROOT/bin/rerunbox-feeder" >"$T/feeder2.log" 2>&1 & FEEDER=$!
sleep 3
kill -TERM "$FEEDER"; wait "$FEEDER" 2>/dev/null
kill -TERM "$RELAY" 2>/dev/null; wait "$RELAY" 2>/dev/null
grep -q "Resuming from last known file: b_60fps.mp4" "$T/feeder2.log"
check "resumes from the saved clip after restart" "$([ $? -eq 0 ] && echo 1 || echo 0)"
grep -q "Feeding: a_30fps.mp4" "$T/feeder2.log" && skipped=0 || skipped=1
check "does not replay earlier clips when resuming" "$skipped"

echo "CLI"
out="$("$ROOT/bin/rerunbox" version)"; check "version prints ($out)" "$([[ "$out" == RerunBox* ]] && echo 1 || echo 0)"
RERUNBOX_CONF="$T/rerunbox.conf" "$ROOT/bin/rerunbox" test-encode "$T/lib/a_30fps.mp4" 2 0 >"$T/te.log" 2>&1
grep -q "average bitrate" "$T/te.log"; check "test-encode reports a bitrate" "$([ $? -eq 0 ] && echo 1 || echo 0)"
"$ROOT/bin/rerunbox" preflight >"$T/pf.log" 2>&1
grep -q "4 of 4 file(s) passed" "$T/pf.log"; check "preflight passes all 4 files" "$([ $? -eq 0 ] && echo 1 || echo 0)"

echo "Webhook"
export WEBHOOK_TOKEN=testtoken WEBHOOK_BIND=127.0.0.1 WEBHOOK_PORT=18787 STATE_DIR="$T/state"
python3 "$ROOT/lib/webhook.py" & WH=$!
sleep 1
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "rejects missing token (403)" "$([ "$(code -X POST http://127.0.0.1:18787/start)" = 403 ] && echo 1 || echo 0)"
check "rejects wrong token (403)" "$([ "$(code -X POST -H 'X-Webhook-Token: nope' http://127.0.0.1:18787/start)" = 403 ] && echo 1 || echo 0)"
check "unknown route with token is 404" "$([ "$(code -X POST -H 'X-Webhook-Token: testtoken' http://127.0.0.1:18787/nope)" = 404 ] && echo 1 || echo 0)"
st="$(curl -s -H 'Authorization: Bearer testtoken' http://127.0.0.1:18787/status)"
check "GET /status returns JSON ($st)" "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(1 if "feeder" in d else 0)' "$st" 2>/dev/null || echo 0)"
printf 'x' > "$T/state/feeder.state"
curl -s -o /dev/null -X POST -H 'X-Webhook-Token: testtoken' http://127.0.0.1:18787/reset-position
check "reset-position deletes the state file" "$([ ! -e "$T/state/feeder.state" ] && echo 1 || echo 0)"
kill "$WH" 2>/dev/null
env -u WEBHOOK_TOKEN python3 "$ROOT/lib/webhook.py" >/dev/null 2>&1
check "webhook refuses to start without a token" "$([ $? -ne 0 ] && echo 1 || echo 0)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
