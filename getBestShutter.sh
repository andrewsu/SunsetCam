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
### region has more tonal variety than a blown or crushed one) -- subject to a hard cap on how
### much of the sky it is allowed to blow to white (see CLIP_MAX_BP below).
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

# Highlight cap. `identify %k` counts tonal variety but has no notion of clipping, and on a
# low-contrast marine-layer sky the criterion inverts: shortening the exposure quantises the
# narrow tonal range into FEWER distinct levels than clipping costs, so %k actively rewards
# over-exposure. On 2026-08-09 the peak was 21616 colours at 6618us vs 21535 at 4188us -- 0.4%
# apart, i.e. noise -- and it took the brighter end, blowing 33% of the sky to pure white. Four
# of the nine sunsets in 2026-08-01..09 were blown that way (Aug 1 47.8%, Aug 3 44.5%, Aug 8
# 35.6%, Aug 9 32.9%), while every well-exposed night sat at 0.1-8.5%.
#
# So: reject any candidate blowing more than CLIP_MAX_BP of the sky, then take the most-colours
# shutter among the survivors. 2500bp = 25% is set from that week's spread -- above the borderline
# Aug 2 (18.9%, which keeps blue and cloud structure) and well below the blown nights, with ~3x
# headroom over the ~8.5% the in-frame sun disc clips on its own even when correctly exposed.
# That headroom matters because the sun is migrating further into frame toward the equinox, which
# raises the floor; if a good night ever gets rejected, raise this rather than lowering it.
CLIP_MAX_BP=2500   # basis points (10000 = 100%) of the sky allowed at or above CLIP_LEVEL
CLIP_LEVEL=250     # gamma-encoded luma at which a pixel reads as pure white

# Least-blown candidate seen, used only if NOTHING clears the cap (a very bright, very flat sky).
fallbackShutter=""
fallbackClip=-1

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

    # How much of the sky this exposure blows to white, in basis points. An empty result means the
    # measurement itself failed (no PIL, unreadable frame); that is treated as unknown and lets the
    # candidate through, so a broken helper degrades to the old colour-count-only behaviour rather
    # than vetoing every shutter and leaving us to pick a wild one.
    clipBp=$(python3 $ROOT/skyClip.py "$ROOT/tmp/test.jpg" $CLIP_LEVEL 2>>$LOG_FILE)
    rm -f $ROOT/tmp/test.jpg

    if [ -n "$clipBp" ] && [ "$clipBp" -gt "$CLIP_MAX_BP" ]; then
        echo "Shutter ${shutter}us has $numColors unique colors (sky/top-half), ${clipBp}bp blown -- REJECTED (cap ${CLIP_MAX_BP}bp)" >> $LOG_FILE
        if [ -z "$fallbackShutter" ] || [ "$clipBp" -lt "$fallbackClip" ]; then
            fallbackShutter=$shutter
            fallbackClip=$clipBp
        fi
    else
        echo "Shutter ${shutter}us has $numColors unique colors (sky/top-half), ${clipBp:-?}bp blown" >> $LOG_FILE
        # keep the best-exposed (most unique colours) shutter among those within the cap
        if (( numColors > bestNumColors )); then
            bestNumColors=$numColors
            bestShutter=$shutter
        fi
    fi
    shutter=$(($shutter * 100 / 158))
done

if [ "$bestNumColors" -le 0 ]; then
    if [ -n "$fallbackShutter" ]; then
        # Captures worked, but every exposure clipped past the cap. Take the least-blown one --
        # it is the closest to correct the scan found, and it is still bounded by the scan range.
        bestShutter=$fallbackShutter
        echo "$(date): getBestShutter.sh: no shutter met the ${CLIP_MAX_BP}bp clipping cap" >> $LOG_FILE
        echo "best shutter: ${bestShutter}us (${fallbackClip}bp blown, clipping-cap fallback)" >> $LOG_FILE
    else
        echo "$(date): getBestShutter.sh: all captures failed (camera locked?), aborting" >> $LOG_FILE
        exit 1
    fi
else
    echo "best shutter: ${bestShutter}us ($bestNumColors unique colors)" >> $LOG_FILE
fi
echo $bestShutter > $ROOT/tmp/shutter
