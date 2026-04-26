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
  steps and picks the one with the most unique colors (per `imagemagick identify`).
- `calc_brightness_pil_histogram.py` — PIL-based luminance check used by the
  auto-exposure feedback loop.
- `uploadToBluesky.sh` / `uploadToBluesky.py` — post the finished mp4 to Bluesky using
  the `atproto` SDK; credentials read from `.env`.

## Setup (Raspberry Pi OS Bookworm, Pi 3B + Camera Module 3 Wide)

1. **Install system packages**
   ```
   sudo apt-get update
   sudo apt-get install -y rpicam-apps imagemagick ffmpeg jq at \
                           python3-pip python3-pil r-base
   ```

2. **Verify the camera works**
   ```
   rpicam-still -n -t 100 -o /tmp/test.jpg
   ```

3. **Install R packages and Python libraries**
   ```
   sudo R -e "install.packages(c('RCurl','V8','suncalc'), repos='https://cloud.r-project.org')"
   pip install --break-system-packages atproto python-dotenv
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
   0 1 * * * cd /home/pi/SunsetCam && ./scheduler.sh
   ```

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
| `-a` | continuously adjust shutter based on luminance feedback |
| `-b` | scp the frames to the archive host |
| `-m` | post text |

## Credits
Inspiration from Laura Hughes and Karthik Gangavarapu. Most coding done by Andrew Su.
Modernized for Raspberry Pi 3B + Camera Module 3 Wide and Bluesky posting in 2026.
