# SunsetCam

## Description
A [Su Lab](http://sulab.org) project to automatically take a time lapse video of the San
Diego sunset (and sunrise) from our lab space at [Scripps Research](http://scripps.edu).

The original incarnation drove a Nikon DSLR over USB with `gphoto2` and posted the
finished timelapse to [@ScrippsCam on Twitter](https://twitter.com/ScrippsCam). This
modernized version runs on a Raspberry Pi 3B with a Camera Module 3 Wide and posts to
Bluesky.

## Architecture

- `scheduler.sh` — daily cron entrypoint. Uses R + `suncalc` to compute today's sunrise
  and sunset times and queues two `SunsetCam.sh` runs via `at`.
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

## Exposure tuning dials

Sunset exposure is set in two stages: `getBestShutter.sh` picks the starting shutter before the
run, then `nextShutter.py` adjusts it per frame during the run. Each dial is a constant at the
top of its script, documented in place with the measurements behind its current value.

| dial | script | default | effect |
| --- | --- | --- | --- |
| `CLIP_MAX_BP` | `getBestShutter.sh` | `2500` (25%) | max sky allowed to blow to white. **Raise, never lower** — the in-frame sun disc alone clips ~8.5%, and that floor rises as the sun migrates in toward the equinox. |
| `TIE_BREAK_PCT` | `getBestShutter.sh` | `8` | how far below the peak color count a candidate may sit and still be eligible; the **longest** eligible shutter wins. Widen for a brighter run and longer dusk at the cost of more clipped sky; `0` reverts to plain peak-`%k`. |
| `CLIP_LEVEL` | `getBestShutter.sh` | `250` | gamma-encoded luma at which a pixel counts as pure white. |
| `RAMP_DECLINE_EV_MIN` | `SunsetCam.sh` | `0.18` | target on-screen decline rate (EV/min) the ramp aims at. Lower = brighter, longer dusk but more risk the scene stops visibly dimming. |
| `RAMP_GATE_FRAC` | `SunsetCam.sh` | `0.40` | fraction of the run held flat at the calibrated baseline before the ramp may act, keeping the bright pre-sunset exposed as metered. |
| `RAMP_MAX_SHUTTER` | `SunsetCam.sh` | `30000` | absolute ceiling (us). The one term that does not scale with the baseline, so it starts truncating the ramp for baselines above ~12000us. |
| `RAMP_MAX_EV_PER_FRAME` | `SunsetCam.sh` | `0.02` | per-frame rate limit. With `-i 5` this caps lift at 0.24 EV/min, so the ramp can slow the fade but never arrest it. |

Note the two stages interact only through the *level*, not the timing: the baseline cancels out
of the ramp's trigger condition, so changing `TIE_BREAK_PCT` scales the whole exposure curve
vertically without moving when the ramp starts (verified by replay on the 2026-08-10 run).

## Credits
Inspiration from Laura Hughes and Karthik Gangavarapu. Most coding done by Andrew Su.
Modernized for Raspberry Pi 3B + Camera Module 3 Wide and Bluesky posting in 2026.
