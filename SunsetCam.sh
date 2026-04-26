#!/bin/bash

###
### SunsetCam.sh
###
### Automate the creation of a time lapse video using rpicam-still
### (Raspberry Pi Camera Module 3 Wide on Bookworm).
###
### Andrew Su 2018-12-21
### Modernized 2026-04-25 — gphoto2 -> rpicam-still, Twitter -> Bluesky
###

### USAGE: ./SunsetCam.sh [-i <interval -- time between shots>] [-n <total number of shots to take>]
###              [-e <1/0> -- perform initial empirical exposure test] [-d <1/0> -- perform deflicker in post]
###              [-t <1/0> -- post movie to Bluesky] [-c <exposure compensation index, 0..30, 15=0EV>]
###              [-a <1/0> -- auto-adjust exposure mode] [-b <1/0> -- copy photos to backup server]

### Exposure compensation index mapping (kept identical to original gphoto2 semantics)
###   each step  = 1/3 EV
###   index 0    = -5 EV   (darkest)
###   index 15   =  0 EV   (no compensation)
###   index 30   = +5 EV   (brightest)
### Internally: shutter_us = bestShutter_us * 2^((compensation - 15) / 3)

### READ CONFIGURATION FILE
CONFIG_FILE="config.txt"
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source $CONFIG_FILE

# Initialize parameters
num=480
interval=5
exposure=0
deflicker=1
post=1
compensation=15
autoexposure=0
backup=1
message=""

lumwindow=5	# calculate drop based on median of most recent $lumwindow images
lumthresh=0.12	# adjust exposure if % difference in lum from start is > $lumthresh
lumramp=20	# adjust exposure at most once every $lumramp images

# Default shutter (in microseconds) used when -e 0 (no calibration). 1/100s is a reasonable
# starting point for golden hour; the autoexposure loop will adjust from here.
DEFAULT_SHUTTER_US=10000

# read in command-line options
while getopts ":i:n:e:d:t:c:a:b:m:" opt; do
  case $opt in
    i) interval="$OPTARG"
    ;;
    n) num="$OPTARG"
    ;;
    e) exposure="$OPTARG"
    ;;
    d) deflicker="$OPTARG"
    ;;
    t) post="$OPTARG"
    ;;
    c) compensation="$OPTARG"
    ;;
    a) autoexposure="$OPTARG"
    ;;
    b) backup="$OPTARG"
    ;;
    m) message="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

# create output directory (multiple runs per day get _2, _3, ... suffixes)
today=`date +"%Y%m%d"`
if [ -d $ROOT/img/$today ]; then
    idx=2
    while [ -d $ROOT/img/${today}_${idx} ]; do
        idx=$(($idx+1))
    done
    today=${today}_${idx}
fi
mkdir -p $ROOT/img/$today
LOG_FILE=$ROOT/img/$today/log
export LOG_FILE   # so child scripts (getBestShutter.sh, etc.) write to the same per-run log
echo "`date`: created output directory ($ROOT/img/$today)" >> $LOG_FILE

# report run parameters
echo "Argument interval is $interval" >> $LOG_FILE
echo "Argument num is $num" >> $LOG_FILE
echo "Argument exposure is $exposure" >> $LOG_FILE
echo "Argument deflicker is $deflicker" >> $LOG_FILE
echo "Argument post (Bluesky) is $post" >> $LOG_FILE
echo "Argument compensation is $compensation" >> $LOG_FILE
echo "Argument autoexposure is $autoexposure " >> $LOG_FILE
echo "Argument backup is $backup" >> $LOG_FILE
echo "Argument message is $message" >> $LOG_FILE

# determine baseline shutter (microseconds)
if [ $exposure = 1 ]; then
    $ROOT/getBestShutter.sh
    bestShutter=`cat $ROOT/tmp/shutter`
    echo "`date`: calibrated baseline shutter ${bestShutter}us" >> $LOG_FILE
else
    bestShutter=$DEFAULT_SHUTTER_US
    echo "`date`: skipping calibration; baseline shutter ${bestShutter}us" >> $LOG_FILE
fi

# apply exposure compensation: shutter_us = bestShutter_us * 2^((compensation - 15) / 3)
compDiff=$(($compensation - 15))
shutter=$(python3 -c "print(int($bestShutter * 2**($compDiff/3)))")
echo "`date`: shutter after compensation (${compDiff}/3 stops) = ${shutter}us" >> $LOG_FILE

# capture loop (used for both manual and autoexposure modes)
echo "`date`: Executing photo capture (autoexposure=$autoexposure)" >> $LOG_FILE
luminancefile=$ROOT/img/$today/luminance.txt
nochangecount=0
SECONDS=0
STARTTIME=`date "+%F %T"`

for i in `seq 1 $num`; do
    filename="$ROOT/img/$today/`date +%Y%m%d%H%M%S`.jpg"
    echo "Capturing photo $i / $num at shutter=${shutter}us -> $filename" >> $LOG_FILE
    rpicam-still -n -t 100 --width 1920 --height 1080 --shutter $shutter --gain 1.0 --awb daylight -o "$filename" >> $LOG_FILE 2>&1

    if [ $autoexposure = 1 ]; then
        # calculate and record luminance
        $ROOT/calc_brightness_pil_histogram.py "$filename" >> $luminancefile
        nochangecount=$(($nochangecount + 1))

        if [ $i = 1 ]; then
            lumstart=`head -1 $luminancefile | awk '{print $2}'`
            echo "LUMSTART: $lumstart" >> $LOG_FILE
        elif [ $nochangecount -gt $lumramp ]; then
            # median of last $lumwindow luminance values
            lumcurrent=`tail -$lumwindow $luminancefile | awk '{print $2}' | sort -n | head -$((($lumwindow+1)/2)) | tail -1`
            echo "LUMCURRENT ($nochangecount | $lumramp): $lumcurrent" >> $LOG_FILE
            lumdiff=`echo "($lumcurrent - $lumstart)/$lumstart" | bc -l`
            echo "LUMDIFF: $lumdiff" >> $LOG_FILE

            if (( $(echo "$lumdiff > $lumthresh" | bc -l) )); then
                # image got brighter than start -> shorten exposure by 1/3 stop
                newshutter=$(python3 -c "print(int($shutter / (2**(1/3))))")
                echo "SHUTTER: $shutter -> $newshutter (shorten, 1/3 stop)" >> $LOG_FILE
                shutter=$newshutter
                nochangecount=0
            elif (( $(echo "$lumdiff*-1 > $lumthresh" | bc -l) )); then
                # image got dimmer than start -> lengthen exposure by 1/3 stop
                newshutter=$(python3 -c "print(int($shutter * (2**(1/3))))")
                echo "SHUTTER: $shutter -> $newshutter (lengthen, 1/3 stop)" >> $LOG_FILE
                shutter=$newshutter
                nochangecount=0
            fi
        fi
    fi

    # sleep until next capture
    sleepduration=$(($interval*$i - $SECONDS))
    if [ $sleepduration -gt 0 ]; then
        sleep $sleepduration
    fi
done
ENDTIME=`date "+%T %Z"`

# copy to archive
if [ $backup = 1 ]; then
    scp -r $ROOT/img/$today asu@sulab.scripps.edu:SunsetCamArchive &
fi

# deflicker images
if [ $deflicker = 1 ]; then
    # deflicker using script from https://github.com/cyberang3l/timelapse-deflicker, as described
    # at https://medium.com/twidi-and-his-camera/how-i-edited-5100-photos-for-my-last-timelapse-20f9ef6fe5db

    echo "`date`: deflickering images" >> $LOG_FILE
    cd $ROOT/img/$today
    $ROOT/timelapse-deflicker.pl -p 2 -w 15
    cd $ROOT
    IMAGEDIR="$ROOT/img/$today/Deflickered"
else
    IMAGEDIR="$ROOT/img/$today"
fi

# create mp4 using ffmpeg
mkdir -p $ROOT/final
echo "`date`: Creating mp4 ($ROOT/final/$today.mp4)" >> $LOG_FILE
ffmpeg -y -pattern_type glob -i "$IMAGEDIR/*.jpg" -c:v libx264 -pix_fmt yuv420p -vf "scale=w=1280:h=720:force_original_aspect_ratio=decrease" $ROOT/final/$today.mp4

# upload movie to Bluesky
if [ $post = 1 ]; then
    echo "`date`: posting to Bluesky" >> $LOG_FILE
    $ROOT/uploadToBluesky.sh -m "$message (${STARTTIME} - ${ENDTIME})" -f $ROOT/final/$today.mp4 >> $LOG_FILE 2>&1
fi

# clean up
cd $ROOT/img
echo "`date`: cleaning up" >> $LOG_FILE
rm -vr `ls -t | tail -n +50` >> $LOG_FILE
