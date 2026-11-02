# Bitrate tuning (read this before going live)

## The problem

On Intel integrated graphics, the VAAPI H.264 encoder only supports
**constant-quantiser (CQP)** rate control in the setups RerunBox targets. You pick
a quality level (`QP`); the encoder then spends whatever number of bits it takes
to hold that quality in each scene.

- It **cannot cap bitrate.** Asking for VBR, CBR or a `-maxrate` fails outright
  (`Driver does not support VBR RC mode (supported modes: CQP)`), and an encoder
  that fails to open means nothing reaches your destination at all. Don't try.
- A calm scene and an intense one at the same `QP` can differ by 5x or more in bitrate.
- So the same `QP` that averages 1 Mbit/s on a quiet desktop recording can spike
  past 30 Mbit/s on fast gameplay.

If the peaks exceed what your destination accepts, you may not see a dropped
connection. Instead the platform's own transcoder can choke, and viewers get a
black screen with working audio while your ingest dashboard says everything is fine.

## What it looked like in practice

These numbers are from the author's library (a mix of 30 fps and 60 fps 1080p game
footage) on an i3-6100T. **Yours will differ**; they show the shape of the problem,
not values to copy.

| QP | Source | What was observed | Result |
|----|--------|-------------------|--------|
| 29 | calm content | ~1.1 to 1.5 Mbit/s average | fine, but well under a 6 Mbit/s target |
| 20 | mixed | ~28 Mbit/s sustained | Twitch went black (player error 1000, 0x0 video) |
| 24 | busy | avg ~7.6 Mbit/s with spikes past 10; later avg 8.9, max 34.7 | warning, then black screen on an intense clip |
| 28 | 30 fps, heavy | avg 6.1, max 13.0 | stable |
| 28 | **60 fps** | avg 9.2, max 21.0 | failed: 60 fps costs roughly 1.5 to 2x the bits |

Findings:

- Roughly **12 % bitrate change per QP step**, so a few steps is a big move.
- In that setup, failures sat at a *sustained average* above about 8.8 Mbit/s;
  runs that survived stayed at or below about 7.7 Mbit/s.
- Raising QP by only 4 was not enough margin twice in a row. Move in bigger
  steps than feels necessary, then re-test.
- **Frame rate is the cheapest lever.** CQP spends bits per frame, so reducing
  60 fps sources to 30 fps (`MAX_FPS=30`, the default) cuts the worst case
  without touching quality at 30 fps. RerunBox does this per clip.

## How to tune yours

1. **Know your destination's limit.** For example, Twitch has recommended roughly
   6 to 8.5 Mbit/s for 1080p; check your platform's current ingest guidance and
   set `BITRATE_WARN_KBPS` to its recommended maximum.
2. **Find your heaviest footage.** Fast action, lots of particle effects, film
   grain and screen-wide motion are the worst case. Calm material proves nothing.
3. **Measure it:**

   ```bash
   rerunbox test-encode /path/to/heavy-clip.mp4 30 600   # 30 s starting 10 min in
   ```

   It encodes a sample through the exact production pipeline and prints speed and
   average bitrate. Try several offsets in your busiest clips.
4. **Adjust `QP`** in `/etc/rerunbox/rerunbox.conf` (higher = smaller and softer) and repeat.
5. **Verify live.** Run the loop and watch your platform's ingest/health panel
   (for example Twitch Inspector's bitrate graph) *while a heavy clip plays*. Check
   the maximum as well as the average. A calm-moment check will pass right up
   until the clip that breaks it.
6. Keep `rerunbox test-encode` handy: re-test when you add new kinds of footage.

## Also check the encoder keeps up

`test-encode` reports speed as a multiple of real time. Anything under about 1.5x
means a heavy scene could make the encoder fall behind live pacing, which shows
up as viewer buffering. Hardware encoding is normally many times faster than
real time.

## If the stream goes black but the connection looks fine

1. Check the platform's bitrate graph for spikes above its recommended maximum.
2. Raise `QP` by 3 to 4, `rerunbox restart`, and watch a heavy clip.
3. Confirm 60 fps sources are being capped: `rerunbox logs | grep capped`.
4. Reconnecting alone (`rerunbox restart`) will not help if the cause is
   bitrate: it just re-sends the same oversized video.

## Why not just cap it?

Other encoders can. NVIDIA NVENC and software x264 both support real bitrate
limits. They aren't supported yet, and they're on the roadmap in large part
because of this limitation.
