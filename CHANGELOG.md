# Changelog

## 0.1.0

First public release, extracted from a private looped-stream setup that has run
in production on an Intel i3-6100T.

- Feeder / FIFO / relay pipeline with Intel VAAPI hardware encoding
- Resume-from-position, ad breaks, PNG overlay, 60 to 30 fps cap, silence for audio-less clips
- Scheduled pipeline restart with optional Discord notice
- Token-protected webhook (`/start`, `/stop`, `/restart`, `/reset-position`, `/status`)
- `rerunbox` CLI with `doctor`, `preflight` and `test-encode`
- Interactive and non-interactive installer, uninstaller
- Changes from the private version:
  - one config file instead of values hard-coded in scripts
  - webhook binds to localhost by default
  - keyframe interval is derived from each clip's output frame rate
  - a failing clip no longer makes the feeder spin
