#!/bin/bash

###
### getBestShutter.sh
###
### Find the best shutter speed for current lighting (as estimated by number of unique
### colors computed by imagemagick identify). Iterates from a long exposure down to a
### short one in ~2/3-stop steps; stops once unique-color count drops (i.e. peaked).
###
### Outputs the chosen shutter speed (microseconds) to $ROOT/tmp/shutter
###
### AS 20190110
### Modernized 2026-04-25 — rpicam-still (Camera Module 3 Wide via CSI)
###

### READ CONFIGURATION FILE
PARENT_LOG_FILE=$LOG_FILE   # if invoked from SunsetCam.sh, inherit its per-run log
CONFIG_FILE="config.txt"
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source $CONFIG_FILE
[ -n "$PARENT_LOG_FILE" ] && LOG_FILE=$PARENT_LOG_FILE

mkdir -p $ROOT/tmp

echo "running getBestShutter.sh" >> $LOG_FILE

lastNumColors=0
lastShutter=10000

# Iterate shutter speeds (microseconds) from longest -> shortest in ~2/3-stop steps.
# 100/158 ≈ 1 / 2^(2/3) ≈ 0.6300 (i.e. one 2/3-stop reduction in exposure per iteration).
shutter=4000000   # 4 seconds (very dim twilight)
min_shutter=250   # 1/4000 s (bright daylight)

while [ $shutter -ge $min_shutter ]; do
    rpicam-still -n -t 100 --width 1920 --height 1080 --shutter $shutter --gain 1.0 --awb daylight -o $ROOT/tmp/test.jpg >> $LOG_FILE 2>&1

    # use imagemagick to get number of unique colors -- see https://imagemagick.org/script/escape.php
    numColors=`identify -format %k $ROOT/tmp/test.jpg`
    echo "Shutter ${shutter}us has $numColors unique colors" >> $LOG_FILE
    rm -f $ROOT/tmp/test.jpg

    # if unique-color count has dropped, the previous setting was the peak
    if (( $numColors < $lastNumColors )); then
        break
    fi
    lastNumColors=$numColors
    lastShutter=$shutter
    shutter=$(($shutter * 100 / 158))
done

echo "best shutter: ${lastShutter}us ($lastNumColors unique colors)" >> $LOG_FILE
echo $lastShutter > $ROOT/tmp/shutter
