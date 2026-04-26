# Hardware

- Raspberry Pi 3B running Raspberry Pi OS Bookworm
- Raspberry Pi Camera Module 3 Wide attached via the CSI ribbon cable

# System packages

```
sudo apt-get update
sudo apt-get install -y rpicam-apps imagemagick ffmpeg jq at python3-pip python3-venv \
                        r-base libcurl4-openssl-dev
```

## Verify the camera

```
rpicam-still -n -t 100 -o /tmp/test.jpg
```

If this writes a JPEG, the camera + driver are working. If not, check `vcgencmd get_camera`
and the CSI cable seating before going further.

# R / suncalc (sunrise/sunset times)

```
sudo R -e "install.packages(c('RCurl','V8','suncalc'), repos='https://cloud.r-project.org')"
```

# Python dependencies (Bluesky posting + brightness analysis)

The brightness script (`calc_brightness_pil_histogram.py`) needs `Pillow`. The Bluesky
uploader needs `atproto` and `python-dotenv`.

```
sudo apt-get install -y python3-pil
pip install --break-system-packages atproto python-dotenv
```

(or use a virtualenv and adjust the shebang/path in `uploadToBluesky.py` accordingly)

# NTP — make sure the Pi has the right time on boot

```
sudo apt install ntp
sudo systemctl enable ntp
sudo timedatectl set-ntp 1
```

If you want to force a sync at boot, add to `/etc/rc.local`:
```
/etc/init.d/ntp stop
/usr/sbin/ntpd -q -g
/etc/init.d/ntp start
```

# Clone the repo

```
git clone https://github.com/andrewsu/SunsetCam.git
cd SunsetCam
cp config_sample.txt config.txt   # edit ROOT and LOG_FILE
cp .env.sample .env               # add your Bluesky credentials
```

# Bluesky credentials

1. Sign in at https://bsky.app and go to Settings → App Passwords
2. Create a new app password (looks like `xxxx-xxxx-xxxx-xxxx`)
3. Put your handle and the app password in `.env`:
   ```
   BLUESKY_HANDLE=yourhandle.bsky.social
   BLUESKY_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx
   ```

Test the uploader with a small mp4:
```
./uploadToBluesky.sh -m "test post" -f /path/to/some.mp4
```

# Deflicker (optional, recommended)

The capture script invokes `timelapse-deflicker.pl` from
https://github.com/cyberang3l/timelapse-deflicker — drop the script in the repo root and
make it executable, or pass `-d 0` to skip.

# Cron — run the scheduler each morning

```
crontab -e
```
Add:
```
0 1 * * * cd /home/pi/SunsetCam && ./scheduler.sh
```
The scheduler computes today's sunrise and sunset times and queues `SunsetCam.sh` runs
via `at`.
