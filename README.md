# SunsetCam

## Description
A [Su Lab](http://sulab.org) project to automatically take a time lapse video of the San
Diego sunset (and sunrise) from our lab space at [Scripps Research](http://scripps.edu).

The original incarnation drove a Nikon DSLR over USB with `gphoto2` and posted the
finished timelapse to [@ScrippsCam on Twitter](https://twitter.com/ScrippsCam). This
modernized version runs on a Raspberry Pi 3B with a Camera Module 3 Wide and posts to
Bluesky.

## Architecture

- `scheduler.sh` — daily cron entrypoint. Uses R + `suncalc` to compute today's sunset
  time and queues a `SunsetCam.sh` run via `at`. It used to queue a sunrise run too;
  that is commented out as of 2026-09-21 since nothing was ever done with the sunrise
  videos — uncomment the sunrise block to bring it back.
- `SunsetCam.sh` — captures frames with `rpicam-still`, optionally deflickers, assembles
  an mp4 with `ffmpeg`, and posts to Bluesky.
- `getBestShutter.sh` — empirical shutter calibration: walks shutter speeds in 2/3-stop
  steps, counting unique colors in the sky (top half) per `imagemagick identify`. It then
  rejects candidates that blow more than `CLIP_MAX_BP` of the sky to white, and among those
  within `TIE_BREAK_PCT` of the peak color count takes the **longest** shutter. See
  *Exposure tuning dials* below.
- `skyClip.py` — measures what fraction of the sky a frame blows to white, in basis points.
  Supplies the clipping term `identify %k` lacks.
- `nextShutter.py` — closed-loop exposure ramp. Meters each captured frame and picks the next
  shutter so on-screen brightness declines at a target rate, instead of following a fixed
  time curve.
- `calc_brightness_pil_histogram.py` — PIL-based luminance check used by the
  auto-exposure feedback loop.
- `editorialComment.sh` — pulls a few frames from the finished mp4 and asks the local
  Claude Code CLI for a one-line editorial caption. Best-effort: on any failure the post
  goes out without a caption.
- `postPending.sh` — spools the intended post and delivers it with retries, so a wifi
  outage over the posting window doesn't lose the day's post. See *Post delivery* below.
- `uploadToBluesky.sh` / `uploadToBluesky.py` — post the finished mp4 to Bluesky using
  the `atproto` SDK; credentials read from `.env`.

## Dependencies

| Dependency | Type | Used by |
| --- | --- | --- |
| `rpicam-apps` | system | `rpicam-still` for frame capture |
| `imagemagick` | system | `identify` for unique-color counting in `getBestShutter.sh` |
| `ffmpeg` | system | mp4 assembly |
| `at` / `atd` | system | `scheduler.sh` queues timed jobs |
| `python3` | system | per-frame shutter ramp calculation; Bluesky upload |
| `r-base` | system | `Rscript` for sunrise/sunset time computation |
| `atproto` | Python | Bluesky SDK |
| `httpx` | Python | HTTP calls to the Bluesky video service |
| `python-dotenv` | Python | reads Bluesky credentials from `.env` |
| `suncalc` | R | astronomical sunrise/sunset times |
| `timelapse-deflicker.pl` | optional | inter-frame deflickering (see step 6 below) |

## Setup (Raspberry Pi OS Bookworm, Pi 3B + Camera Module 3 Wide)

1. **Install system packages**
   ```
   sudo apt-get update
   sudo apt-get install -y rpicam-apps imagemagick ffmpeg at \
                           python3-pip r-base
   ```

2. **Verify the camera works**
   ```
   rpicam-still -n -t 100 -o /tmp/test.jpg
   ```

3. **Install R packages and Python libraries**
   ```
   sudo R -e "install.packages('suncalc', repos='https://cloud.r-project.org')"
   pip install --break-system-packages atproto httpx python-dotenv
   ```

4. **Clone and configure**
   ```
   git clone https://github.com/andrewsu/SunsetCam.git
   cd SunsetCam
   cp config_sample.txt config.txt           # set ROOT and LOG_FILE
   cp .env.sample .env                       # add Bluesky credentials
   mkdir -p img tmp final
   ```

5. **Get Bluesky credentials**
   - At https://bsky.app go to **Settings → App Passwords** and create one.
   - Put your handle and the app password into `.env`:
     ```
     BLUESKY_HANDLE=yourhandle.bsky.social
     BLUESKY_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
     ```
   - Smoke test:
     ```
     ./uploadToBluesky.sh -m "test from SunsetCam" -f /path/to/test.mp4
     ```

6. **(Optional) Drop in timelapse-deflicker**
   Grab `timelapse-deflicker.pl` from
   https://github.com/cyberang3l/timelapse-deflicker, place it in the repo root, and
   `chmod +x`. Skip with `-d 0` if you don't want it.

7. **Schedule via cron**
   ```
   crontab -e
   ```
   Add:
   ```
   0 1 * * * /home/asu/SunsetCam/scheduler.sh
   */15 * * * * /home/asu/SunsetCam/postPending.sh >> /home/asu/SunsetCam/log 2>&1
   ```
   The second line is the catch-up sweep — see below.

## Post delivery

This camera is on wifi that drops 20-38 times a day, sometimes for 30+ minutes. An
outage over the posting window used to lose the day's post outright: the mp4 was
already finished in `final/`, but the uploader died on a DNS failure and `SunsetCam.sh`
moved on to cleanup. Posting is therefore split from capture:

1. `SunsetCam.sh` writes a spool entry to `pending/<video>.post` describing the post
   (video path, message, date, mention, tags) and hands it to `postPending.sh`.
2. `postPending.sh` waits for the link to actually work (DNS resolution plus a live
   request to `bsky.social/xrpc/_health` — the interface being up isn't enough), then
   generates the caption and posts. On failure it retries on a front-loaded backoff
   (0, 1, 2, 5, 10, 15 min) within the budget it was given.
3. Anything still undelivered when the budget runs out stays spooled. The `*/15` cron
   sweep retries it whenever the link comes back, up to `MAX_AGE_HOURS` (12) after the
   spool was created, then moves it to `pending/expired/`.

A successful post deletes the spool entry. Two further guards stop duplicates: `flock`
keeps the in-run attempt and the cron sweep from racing, and `uploadToBluesky.py
--skip-if-posted` checks the live feed for the post's date line before uploading, which
covers the case where `send_post` succeeded but the reply was lost with the link.

Useful knobs: `POST_RETRY_BUDGET_SEC` in `SunsetCam.sh` (how long to keep trying inside
the run, default 2400s) and `MAX_AGE_HOURS` in `postPending.sh`.

To deliver a stuck post by hand: `./postPending.sh --budget 600`

## Manual run

```
./SunsetCam.sh -i 5 -n 480 -e 1 -d 1 -t 1 -c 17 -a 0 -m "A sunset timelapse from Scripps"
```

Flags (preserved from the original gphoto2 era for backward compatibility):
| flag | meaning |
| --- | --- |
| `-i` | seconds between shots |
| `-n` | total number of shots |
| `-e` | run empirical exposure calibration first (`getBestShutter.sh`) |
| `-d` | run timelapse-deflicker after capture |
| `-t` | post finished mp4 (now to Bluesky, formerly Twitter) |
| `-c` | exposure compensation index 0..30 (1/3 EV per step, 15 = 0 EV) |
| `-a` | enable the closed-loop exposure ramp (`nextShutter.py`) |
| `-b` | scp the frames to the archive host |
| `-m` | post text |

## Exposure controls

Exposure is set in **three sequential stages**, and only one physical variable ever changes:
**shutter time**. Gain is pinned at `1.0` and never moves, so every dial below ultimately just
scales or reshapes the shutter.

```
getBestShutter.sh            -c <n>                nextShutter.py
   scan -> baseline    x  2^((c-15)/3)     ->    per-frame ramp
      (LEVEL)               (LEVEL)                  (SHAPE)
```

The property that makes this tractable: **stages 1-2 set the absolute level, stage 3 sets only
the shape of the fade, and the two are independent.** The baseline cancels out of the ramp's
trigger condition, so changing calibration slides the whole exposure curve vertically without
moving when the ramp starts (verified by replay on the 2026-08-10 and 08-11 runs).

Each dial is a constant at the top of its script, documented in place with the measurements
behind its current value.

### Stage 1 — calibration, before the run (`getBestShutter.sh`, only when `-e 1`)

Sweeps 22 candidates from 4,000,000us down to 250us in ~2/3-stop steps, metering the **top half
only** (the sky), then selects in three passes: reject over-clipping candidates, find the peak
unique-colour count among the survivors, then take the longest shutter within a window of that
peak.

| dial | default | effect |
| --- | --- | --- |
| `CLIP_MAX_BP` | `2500` (25%) | **Pass 1** — max fraction of sky allowed to blow to white. The in-frame sun disc alone clips ~8.5% and that floor rises toward the equinox, so raising this is usually safer than lowering it. Note the tie-break can push the pick toward this boundary when `%k` is flat, which makes it behave partly as an exposure target rather than a pure reject filter. |
| `TIE_BREAK_PCT` | `8` | **Pass 3** — how far below the peak colour count a candidate may sit and still be eligible; the **longest** eligible shutter wins. Widen for a brighter run and longer dusk at the cost of more clipped sky; `0` reverts to plain peak-`%k`. |
| `CLIP_LEVEL` | `250` | gamma-encoded luma at which a pixel counts as pure white. |
| `DEFAULT_SHUTTER_US` | `10000` | used instead of a scan when `-e 0` (this is what the sunrise run does). |

### Stage 2 — one-shot exposure compensation (`-c`, `SunsetCam.sh`)

`shutter = baseline x 2^((c - 15) / 3)` — 1/3 EV per step, `0` = −5 EV, `15` = 0 EV, `30` = +5 EV.
Applied *before* the ramp, so it scales the entire run. **Sunset currently runs `-c 15` (0 EV), so
this knob is inert there**; it is a second, fully independent lever on the same quantity the
Stage 1 dials control. Being a constant offset, it shifts every night equally — useful for a
deliberate global change, not for condition-dependent problems.

### Stage 3 — closed-loop ramp, during the run (`nextShutter.py`, only when `-a 1`)

Holds the baseline flat through the pre-sunset, then aims on-screen sky brightness at a target
that *declines* at a fixed rate, letting the measured sky pick each shutter:

```
target(t) = B0 * 2^(-DECLINE_EV_MIN * t)
shutter   = clamp(target / measured_sky, baseline, MAX_SHUTTER)
```

The shutter is a **ratchet** (opens only) and rate-limited, which is what makes flicker
structurally impossible.

**Known defect: the ramp can brighten the picture mid-video.** The docstring claim that
on-screen brightness "can never brighten" does not hold. `B0` is captured on **frame 1**
and the target decays from there at `RAMP_DECLINE_EV_MIN`, but the gate blocks any lift
until frame 240. The measured natural fall over that gated stretch is 0.06-0.27 EV/min,
so on a fast-falling night the scene is up to 3.4 stops *below* target by the time the
gate opens; the ramp then lifts at its 0.48 EV/min rate limit to catch up, and the viewer
sees the picture brighten ~10-12s into a 31.2s video (sunset is at 14.4s). Measured over
Sep 4-18: mean worst-case rebound +0.78 stops, and +2.65 on 2026-09-18. Verified rather
than inferred -- at every rebound peak the measured sky level matches the target curve to
within 1-5%.

Lowering `RAMP_GATE_FRAC` shrinks the deficit and so shrinks the rebound, at the cost of
protecting less of the metered pre-sunset. Simulated on all 15 nights, with sunset
brightness, near-black tail and ceiling behaviour unchanged throughout:

| `RAMP_GATE_FRAC` | gate frame | pre-sunset held | rebound mean | rebound worst |
| --- | --- | --- | --- | --- |
| `0.3075` (current) | 240 | sunset−30 → −10 | +0.78 | +2.65 |
| `0.231` | 180 | → −15 | +0.45 | +1.88 |
| `0.1926` | 150 | → −17.5 | +0.34 | +1.11 |
| `0.154` | 120 | → −20 | +0.27 | +0.84 |

Two fixes were measured and **rejected**: re-anchoring `B0` at the gate zeroes the rebound
but underexposes the sunset by up to 3 stops on exactly the worst nights, and a monotone
no-brighten clamp is strictly worse than shrinking the gate. Note the ratchet cannot
prevent brightening caused by the *sky* brightening -- only the shutter is ratcheted.

| dial | default | effect |
| --- | --- | --- |
| `RAMP_GATE_FRAC` | `0.3075` | fraction of the run held flat at the calibrated baseline before any lift, keeping the bright pre-sunset exposed as metered. Currently lands on frame 240 = 19.9 min in = ~sunset−9.6. **It is a fraction of the run, so changing `-n` moves the gate in absolute time — re-derive it if the run length changes.** Measured 2026-09-21 over Sep 4–18: this **is** now the binding constraint — the ramp lifts on the first frame it is allowed to on 13 of 15 nights, and the deficit accumulated while gated is what the ramp then sprints to close (see the rebound note below). |
| `RAMP_DECLINE_EV_MIN` | `0.10` | target on-screen decline rate (EV/min). **The main shape dial** — lower gives a brighter, longer dusk but more risk the scene stops visibly dimming. Note this is a rate from *run start*, so it multiplies out over the run: 0.18 permitted a 9-stop fall across 50 min and left the ramp inert (see SunsetCam.sh). |
| `RAMP_MAX_SHUTTER` | `120000` | absolute ceiling (us). The one term that does *not* scale with the baseline. ~~Measured 2026-08-25: not the binding constraint.~~ **That reading is stale** — it was taken on the old `-n 600` runs. Since `-n 780` went in the ramp reaches this ceiling on **15 of 15** nights (Sep 4–18), typically around frame 650 (~26s into the 31.2s video), after which the dusk fades naturally. Raising it to 250000 only drops that to 13/15 and changes nothing else measurable, so it binds but does no harm. |
| `RAMP_MAX_EV_PER_FRAME` | `0.04` | per-frame rate limit. With `-i 5` this caps lift at 0.48 EV/min. It must stay above the decline target or the rate limit, not the target, becomes what gates the ramp. |
| `RAMP_SMOOTH_FRAMES` | `5` | frames of causal smoothing on the sky measurement, so moving cloud doesn't drive the loop. |

### Fixed capture settings

These affect brightness and look but are not tuned per run.

| setting | value | note |
| --- | --- | --- |
| `--gain` | `1.0` | pinned at base ISO — **shutter is the only exposure variable** |
| `AWB_GAINS` | `2.34,1.67` | locked white balance; preserves warm sunset tones |
| `DENOISE` | `cdn_hq` | helps the noisy dusk frames |
| `SETTLE_MS` | `1000` | focus-settle time; shorter values produced soft frames |
| `JPEG_QUALITY` | `100` | avoid stacking JPEG artifacts before the h264 encode |

### Live configuration

| | sunset | sunrise (disabled) |
| --- | --- | --- |
| calibration | `-e 1` (full scan) | `-e 0` (fixed `DEFAULT_SHUTTER_US`) |
| ramp | `-a 1` (closed loop) | `-a 0` (flat) |
| compensation | `-c 15` (0 EV) | `-c 13` (−2/3 EV) |
| frames / interval | `-n 780 -i 5` (~65 min, sunset−30 → +35) | `-n 240 -i 10` |
| leveling | `-l 0` | `-l 0` |

The sunrise run is no longer scheduled (see `scheduler.sh`); its column is kept because the
flags still work if you re-enable it. It uses **none** of the Stage 1 or Stage 3 machinery —
those dials only affect sunset.

### Which dial for which symptom

| symptom | dial |
| --- | --- |
| sky blown out / too bright | `CLIP_MAX_BP` |
| whole run too dark | `TIE_BREAK_PCT` (condition-dependent) or `-c` (unconditional) |
| dusk fades to black too early | `RAMP_DECLINE_EV_MIN` |
| exposure lifts during the pre-sunset | `RAMP_GATE_FRAC` |

## Credits
Inspiration from Laura Hughes and Karthik Gangavarapu. Most coding done by Andrew Su.
Modernized for Raspberry Pi 3B + Camera Module 3 Wide and Bluesky posting in 2026.
