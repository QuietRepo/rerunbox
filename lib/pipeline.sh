#!/usr/bin/env bash
# RerunBox ffmpeg pipeline builder. Sourced after lib/common.sh.
#
# This is the single source of truth for how a clip is encoded. The feeder
# (live playback), `rerunbox preflight` and `rerunbox test-encode` all call
# rb_build_cmd, so what you test is exactly what goes on air.
# shellcheck shell=bash

# Average frame rate of the first video stream as a decimal ("29.97"), or empty.
rb_probe_fps() {
    ffprobe -v error -select_streams v:0 -show_entries stream=avg_frame_rate \
        -of csv=p=0 "$1" </dev/null 2>/dev/null \
        | awk -F/ 'NF==2 && $2>0 {printf "%.2f", $1/$2}'
}

# Prints "1" if the file has at least one audio stream.
rb_probe_has_audio() {
    local out
    out="$(ffprobe -v error -select_streams a:0 -show_entries stream=index \
        -of csv=p=0 "$1" </dev/null 2>/dev/null)"
    [ -n "$out" ] && echo 1 || echo 0
}

# rb_build_cmd FILE MODE OUT FORMAT [EXTRA OUTPUT ARGS...]
#
#   MODE    "overlay" burns in OVERLAY_PNG (if configured); "plain" does not.
#   OUT     output target (the FIFO, "-" for null, or a file path)
#   FORMAT  ffmpeg muxer: mpegts, null, mp4 ...
#
# Environment knobs:
#   RB_REALTIME=1|0  pace at 1x (-re). Default 1. Tests set 0 to run flat out.
#   RB_START=SECS    seek this far into the source first.
#
# Sets the global array RB_CMD and the string RB_NOTE (a short human-readable
# description of what was detected, for the log line).
rb_build_cmd() {
    local f="$1" mode="$2" out="$3" fmt="$4"
    shift 4

    local src_fps out_fps fps_filter="" gop
    src_fps="$(rb_probe_fps "$f")"
    out_fps="$src_fps"
    RB_NOTE=""
    if [ -n "$src_fps" ]; then
        # Cap high-frame-rate sources (e.g. 60 fps) at MAX_FPS. Because the
        # hardware encoder is constant-quantiser, bitrate scales with frame
        # count, so a 60 fps clip would run at roughly 1.5-2x the bitrate of a
        # 30 fps one at the same QP. See docs/bitrate-tuning.md.
        if awk -v r="$src_fps" -v m="$MAX_FPS" 'BEGIN{exit !(r>m+1)}'; then
            fps_filter=",fps=${MAX_FPS}"
            out_fps="$MAX_FPS"
            RB_NOTE=" src=${src_fps}fps -> capped to ${MAX_FPS}"
        else
            RB_NOTE=" src=${src_fps}fps"
        fi
    fi
    gop="$(awk -v f="${out_fps:-$MAX_FPS}" -v s="$KEYFRAME_SECONDS" \
        'BEGIN{g=int(f*s+0.5); if(g<1)g=1; print g}')"

    # Encoder-specific pieces.
    local hw_init=() filter_tail venc=()
    case "$ENCODER" in
        vaapi)
            hw_init=(-vaapi_device "$VAAPI_DEVICE")
            filter_tail="format=nv12,hwupload"
            venc=(-c:v h264_vaapi -rc_mode CQP -qp "$QP" -profile:v high -bf 0 -g "$gop")
            ;;
        libx264)   # testing only: lets the test-suite run on machines without a GPU
            filter_tail="format=yuv420p"
            venc=(-c:v libx264 -preset ultrafast -crf 28 -profile:v high -bf 0 -g "$gop")
            ;;
    esac

    local use_overlay=0
    if [ "$mode" = "overlay" ] && [ -n "$OVERLAY_PNG" ]; then
        if [ -f "$OVERLAY_PNG" ]; then
            use_overlay=1
        else
            rb_warn "OVERLAY_PNG '$OVERLAY_PNG' is missing, playing without overlay"
        fi
    fi

    # Clips with no audio track would break the stream's continuity (the relay
    # expects video+audio in every clip), so feed them silence instead.
    local has_audio use_silence=0
    has_audio="$(rb_probe_has_audio "$f")"
    [ "$has_audio" = 1 ] || { use_silence=1; RB_NOTE+=" (no audio, adding silence)"; }

    RB_CMD=(ffmpeg -nostdin -hide_banner -loglevel warning -nostats -y)
    [ "${RB_REALTIME:-1}" = 1 ] && RB_CMD+=(-re)
    RB_CMD+=("${hw_init[@]}")
    [ -n "${RB_START:-}" ] && RB_CMD+=(-ss "$RB_START")
    RB_CMD+=(-i "$f")

    local next_input=1 overlay_idx silence_idx
    if [ "$use_overlay" = 1 ]; then
        overlay_idx=$next_input; next_input=$((next_input + 1))
        # -loop 1 is REQUIRED: a still image is a one-frame stream, and with
        # overlay=shortest=1 every clip would otherwise be cut to one frame.
        RB_CMD+=(-loop 1 -i "$OVERLAY_PNG")
    fi
    if [ "$use_silence" = 1 ]; then
        silence_idx=$next_input
        RB_CMD+=(-f lavfi -i "anullsrc=r=44100:cl=stereo")
    fi

    local vmap amap
    if [ "$use_overlay" = 1 ]; then
        RB_CMD+=(-filter_complex "[0:v]setpts=PTS-STARTPTS${fps_filter}[base];[${overlay_idx}:v]format=rgba[ov];[base][ov]overlay=${OVERLAY_POS}:shortest=1,${filter_tail}[v]")
        vmap="[v]"
    else
        RB_CMD+=(-vf "setpts=PTS-STARTPTS${fps_filter},${filter_tail}")
        vmap="0:v:0"
    fi
    if [ "$use_silence" = 1 ]; then amap="${silence_idx}:a"; else amap="0:a:0"; fi

    RB_CMD+=(-map "$vmap" -map "$amap" -af "asetpts=PTS-STARTPTS")
    RB_CMD+=("${venc[@]}")
    # cfr (no explicit -r) locks each clip to its own declared frame rate, which
    # prevents slow audio/video drift on long files whose nominal and actual
    # frame rates differ slightly.
    RB_CMD+=(-fps_mode cfr -c:a aac -ar 44100 -ac 2 -b:a "$AUDIO_BITRATE")
    [ "$use_silence" = 1 ] && RB_CMD+=(-shortest)
    RB_CMD+=("$@" -f "$fmt" "$out")
}
