# RerunBox

Turn a folder of videos into a 24/7 live stream, on a small headless Linux box.

RerunBox plays your videos in a loop, re-encodes them on the fly with the Intel
GPU, and pushes one continuous stream to any RTMP destination (Twitch, YouTube,
Restream, your own server). It remembers where it was after a restart, can drop
in ad-break clips, can burn in a "REPLAY" badge, and can be started, stopped and
reset from a Stream Deck or any script over HTTP.

It started as the private tool behind a rerun channel that runs when its owner
isn't live, and has been running in production for weeks on an old Dell OptiPlex.
This is the first public release (v0.1), so read [Status](#status) before you
trust it with a channel you care about.

```
 your videos ──► feeder ──► FIFO ──► relay ──► rtmp://your-destination
 (one folder)   re-encodes   named    stream-copy
                one clip at  pipe     (no re-encode)
                a time
```

Each clip is decoded and encoded by its own short-lived ffmpeg process with its
timestamps reset to zero, and the relay just forwards a continuous stream. That
design means mixed codecs, odd frame rates and clip boundaries cannot desync or
crash the outgoing stream.

## Features

- Loops a folder of videos forever, rescanning it every lap (add and remove files freely)
- Hardware H.264 encoding on Intel GPUs (VAAPI), so a low-power CPU can hold a 1080p30 stream
- Resumes from the clip it was on after a restart or reboot
- Optional ad-break folder, played after every N clips
- Optional PNG overlay on library clips
- Frame-rate cap (60 fps sources are reduced to 30) to keep bitrate predictable
- Clips with no audio track are given silence, so they can't break the stream
- Scheduled restart (default every 12 h) for platforms that drop very long streams,
  skipped automatically if you stopped the loop on purpose
- Token-protected HTTP webhook: start, stop, restart, reset position, status
- `rerunbox doctor`, `preflight` and `test-encode` to check everything *before* you go live
- Optional Discord notification on each scheduled restart
- Runs as an unprivileged service user under systemd

## Requirements

- A Linux machine with systemd. Developed on Ubuntu; Debian should work.
- An **Intel** CPU with integrated graphics, Skylake (6th gen) or newer, with
  `/dev/dri/renderD128` present. Intel only is supported in this version.
- `ffmpeg`, `vainfo`, the Intel media VA driver, `curl`, `python3` and `sudo`.
  On Debian/Ubuntu the installer installs these for you.
- An RTMP/RTMPS ingest URL including your stream key.
- Videos in a folder the machine can read (local disk or a network share).

A headless mini PC with an i3 is plenty. Encoding happens on the GPU, so the CPU
mostly idles.

### Tested on

The streaming pipeline has run 24/7 on this machine:

| | |
|---|---|
| Machine | Dell OptiPlex 3040, headless |
| CPU / GPU | Intel Core i3-6100T (Skylake, 2 cores / 4 threads), HD Graphics 530 |
| RAM | about 14 GiB usable |
| OS | Ubuntu 26.04.1 LTS, kernel 7.0.0-34-generic |
| ffmpeg | 8.0.1 (Ubuntu package `8.0.1-3ubuntu2`) |
| VA driver | Intel iHD 26.1.2 |
| Workload | 1080p30 H.264 to Twitch and YouTube via Restream, library read from a NAS over SMB |

On that machine the CPU sits mostly idle and the GPU's encoder engine is lightly
loaded. The automated test suite (software encoder only) also passes on ffmpeg 6.1.1.

Other hardware and distributions are untested. If you run it somewhere else, please
open an issue with your results from `rerunbox doctor`, whether it works or not.

## Install

```bash
git clone https://github.com/QuietRepo/rerunbox.git
cd rerunbox
sudo bash install.sh
```

The installer asks for your video folder, your RTMP URL and a few optional
settings, creates a `rerunbox` service account, checks that the GPU can really
encode, writes the config, installs and enables the systemd services, and stops
there so you can test before going live.

Non-interactive:

```bash
LIBRARY_DIR=/srv/videos RTMP_URL='rtmp://...' sudo -E bash install.sh --yes
```

Re-running the installer is safe: your existing settings become the defaults and
the old config is backed up next to the new one.

## Before you go live (important)

```bash
rerunbox doctor        # config, files, driver, GPU, services
rerunbox preflight     # run every file in your library through the real encoder
rerunbox test-encode /path/to/your/busiest/clip 30 600   # speed + bitrate sample
rerunbox start
rerunbox status
```

**Read [docs/bitrate-tuning.md](docs/bitrate-tuning.md).** Intel's VAAPI encoder
runs in constant-quantiser mode and *cannot cap bitrate*: busy footage produces
far more bits than calm footage at the same setting, and a destination that
doesn't like the result may go black while your connection looks perfectly
healthy. The default `QP=28` came from one library on one machine. Measure
yours, with your most intense clips.

## Day to day

```
rerunbox status        services, current clip, recent log
rerunbox start | stop | restart
rerunbox reset         forget the resume position, start from the first file
rerunbox logs -f       follow the feeder and relay logs
rerunbox config        show the effective configuration (secrets hidden)
rerunbox token         print the webhook token
```

Your settings live in `/etc/rerunbox/rerunbox.conf`; the stream key and webhook
token are in `/etc/rerunbox/secrets.env` (readable only by root and the service
account). After editing either, run `rerunbox restart`.
[`config/rerunbox.conf.example`](config/rerunbox.conf.example) documents every setting.

### Adding and removing videos

Drop files into the library folder. They are picked up at the start of the next
lap, with no restart needed. Files play in filename order, so prefix names with
numbers (`01-`, `02-`) if you care about the order. Run `rerunbox preflight`
after adding anything new.

### Network shares

If your library is on a NAS, mount it with options that survive hiccups
(for CIFS, `hard` rather than `soft`) and make sure the service account can read
it (`uid=`/`gid=`/`file_mode=` mount options, or world-readable permissions). The
installer makes the feeder wait for the mount holding your library at boot.

## The webhook

A small HTTP API on port 8787 (localhost only by default) lets a Stream Deck,
home-automation system or script control the loop:

```bash
curl -X POST -H "X-Webhook-Token: $TOKEN" http://HOST:8787/stop
curl -X POST -H "X-Webhook-Token: $TOKEN" http://HOST:8787/start
curl -X POST -H "X-Webhook-Token: $TOKEN" http://HOST:8787/reset-position
curl         -H "X-Webhook-Token: $TOKEN" http://HOST:8787/status
```

See [docs/webhook.md](docs/webhook.md), including how to hand over to a live
broadcast on the same stream key and how to expose it safely on a LAN.

## Status

RerunBox v0.1 was extracted from a private setup that has run for weeks on an
Intel i3-6100T under Ubuntu, streaming 1080p30 to Twitch and YouTube through
Restream. What that does and doesn't tell you:

- The encode pipeline, resume, ad breaks, overlay and restart logic are the same
  ones that ran in production there.
- The installer, the `rerunbox` command and the generalised config are new in
  this release. They are covered by an automated test (`tests/smoke-test.sh`,
  which runs the whole feeder → relay path using a software encoder) and were
  exercised in a sandbox, but not yet on a range of real machines. Expect rough edges
  and please open issues.
- Only Intel VAAPI has been run on real hardware. Other GPUs are not supported yet.
- Resume is per clip, not per second: after a restart the interrupted clip starts again.
- Your stream key can appear in the journal if ffmpeg prints the destination URL in
  an error. Treat the journal as sensitive and don't paste logs publicly unredacted.

Roadmap ideas: NVENC and software encoders (NVENC can cap bitrate properly),
several destinations without a restreaming service, shuffle mode, mid-clip resume.

## Please stream only what you have the right to

RerunBox rebroadcasts files. Use it for content you own or are licensed to
stream, and follow your platform's rules on rebroadcasts and reruns (several
require a "rerun" label or tag, and none of them can be set by this tool).

## Uninstall

```bash
sudo bash uninstall.sh            # remove services, keep your config and stream key
sudo bash uninstall.sh --purge    # remove everything, including the service account
```

## Development

```bash
bash tests/smoke-test.sh          # needs ffmpeg, ffprobe, python3, curl; no GPU
shellcheck -x install.sh uninstall.sh bin/* lib/*.sh
```

All three of the feeder, `preflight` and `test-encode` build their ffmpeg command
in `lib/pipeline.sh`, so what you test is what goes on air. When adding an
encoder, that is the one place to change.

## Licence

MIT. See [LICENSE](LICENSE).
