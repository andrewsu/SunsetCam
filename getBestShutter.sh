#!/bin/bash

###
### getBestShutter.sh
###
### Find the best shutter speed for current lighting (as estimated by number of unique
### colors in the TOP HALF of the frame -- the sky -- computed by imagemagick identify).
### Metering the sky (not the colour-rich foreground foliage, which would otherwise dominate
### the count and drive the sky to blow out) protects the sky; the foreground is allowed to
### fall to silhouette. Scans the full exposure range from a long exposure down to a short one
### in ~2/3-stop steps and picks the shutter with the most unique colours (a well-exposed
### region has more tonal variety than a blown or crushed one).
###
### Outputs the chosen shutter speed (microseconds) to $ROOT/tmp/shutter
###
### AS 20190110
### Modernized 2026-04-25 — rpicam-still (Camera Module 3 Wide via CSI)
###

### READ CONFIGURATION FILE
PARENT_LOG_FILE=$LOG_FILE   # if invoked from SunsetCam.sh, inherit its per-run log
CONFIG_FILE="$(dirname "$0")/config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source "$CONFIG_FILE"
[ -n "$PARENT_LOG_FILE" ] && LOG_FILE=$PARENT_LOG_FILE

mkdir -p $ROOT/tmp

echo "running getBestShutter.sh" >> $LOG_FILE

CAMERA_PID=""
trap '[ -n "$CAMERA_PID" ] && kill "$CAMERA_PID" 2>/dev/null; exit 1' INT TERM HUP

bestNumColors=-1
bestShutter=10000

# Iterate shutter speeds (microseconds) from longest -> shortest in ~2/3-stop steps.
# 100/158 ≈ 1 / 2^(2/3) ≈ 0.6300 (i.e. one 2/3-stop reduction in exposure per iteration).
shutter=4000000   # 4 seconds (very dim twilight)
min_shutter=250   # 1/4000 s (bright daylight)

# Scan the WHOLE range and keep the shutter with the most unique colors. (Previously this
# broke at the first drop in colour count, which false-triggered at the 4s maximum when the
# longest shutters were all blown white -- near-white frames have few, noisy colour counts.)
while [ $shutter -ge $min_shutter ]; do
    rpicam-still -n -t 100 --width 1920 --height 1080 --shutter $shutter --gain 1.0 --awb daylight --autofocus-mode manual --lens-position 0 -o $ROOT/tmp/test.jpg >> $LOG_FILE 2>&1 &
    CAMERA_PID=$!
    wait $CAMERA_PID
    CAMERA_PID=""

    # count unique colours in the TOP HALF only (sky region) of the 1920x1080 capture, so the
    # exposure is metered for the sky rather than the colour-rich foreground foliage.
    # The [WxH+X+Y] suffix crops on read -- see https://imagemagick.org/script/escape.php
    numColors=$(identify -format %k "$ROOT/tmp/test.jpg[1920x540+0+0]" 2>/dev/null)
    numColors=${numColors:-0}
    echo "Shutter ${shutter}us has $numColors unique colors (sky/top-half)" >> $LOG_FILE
    rm -f $ROOT/tmp/test.jpg

    # keep the best-exposed (most unique colours) shutter seen so far
    if (( numColors > bestNumColors )); then
        bestNumColors=$numColors
        bestShutter=$shutter
    fi
    shutter=$(($shutter * 100 / 158))
done

if [ "$bestNumColors" -le 0 ]; then
    echo "$(date): getBestShutter.sh: all captures failed (camera locked?), aborting" >> $LOG_FILE
    exit 1
fi
echo "best shutter: ${bestShutter}us ($bestNumColors unique colors)" >> $LOG_FILE
echo $bestShutter > $ROOT/tmp/shutter
