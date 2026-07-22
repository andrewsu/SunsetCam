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
###              [-a <1/0> -- gentle exposure ramp: ease the shutter up over the run (see RAMP_STOPS/RAMP_START_FRAC)]
###              [-b <1/0> -- copy photos to backup server]
###              [-l <degrees> -- rotate frames to level the horizon in the final video; + = clockwise]

### Exposure compensation index mapping (kept identical to original gphoto2 semantics)
###   each step  = 1/3 EV
###   index 0    = -5 EV   (darkest)
###   index 15   =  0 EV   (no compensation)
###   index 30   = +5 EV   (brightest)
### Internally: shutter_us = bestShutter_us * 2^((compensation - 15) / 3)

### READ CONFIGURATION FILE
CONFIG_FILE="$(dirname "$0")/config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source "$CONFIG_FILE"

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
level=0

# Gentle exposure ramp (-a 1): from the sky-metered baseline, ease the shutter UP over the run
# to partially offset the fading light -- so the pre-sunset sky stays protected (flat start),
# the sunset/dusk hold detail longer, and it STILL fades to black (the lift is far smaller than
# the ambient light loss). Deterministic (no per-frame metering), so there is no flicker.
#   RAMP_STOPS       = total EV lift by the end of the run
#   RAMP_START_FRAC  = fraction of the run to stay flat before the lift eases in (smoothstep)
RAMP_STOPS=1.5
RAMP_START_FRAC=0.35

# Default shutter (in microseconds) used when -e 0 (no calibration). 1/100s is a reasonable
# starting point for golden hour; the autoexposure loop will adjust from here.
DEFAULT_SHUTTER_US=10000

# Camera settle time (milliseconds) before each capture (rpicam-still -t). The voice-coil
# focus lens needs time to physically move to and settle at the manual lens position; the
# old value of 100ms was too short and produced soft frames. 1000ms is a safe margin and
# stays well under the capture interval.
SETTLE_MS=1000

# JPEG quality (rpicam-still -q, default 93). Capture near-lossless frames so we don't stack
# JPEG artifacts before the h264 encode.
JPEG_QUALITY=100

# Fixed white balance as explicit red,blue gains (rpicam-still --awbgains), which disables the
# AWB algorithm entirely. Measured from --awb daylight on this camera (~6159K). Locking the
# gains keeps colour consistent frame-to-frame AND preserves the warm sunset tones that auto
# WB would otherwise neutralise.
AWB_GAINS="2.34,1.67"

# Denoise mode (rpicam-still --denoise). cdn_hq = high-quality colour denoise, which helps the
# noisy low-light frames at the dusk end of the run. Applied to all frames for simplicity.
DENOISE=cdn_hq

# read in command-line options
while getopts ":i:n:e:d:t:c:a:b:m:l:" opt; do
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
    l) level="$OPTARG"
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
CAMERA_PID=""
trap '[ -n "$CAMERA_PID" ] && kill "$CAMERA_PID" 2>/dev/null; exit 1' INT TERM HUP
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
    $ROOT/getBestShutter.sh || { echo "`date`: getBestShutter.sh failed" >> $LOG_FILE; exit 1; }
    bestShutter=`cat $ROOT/tmp/shutter`
    if [ -z "$bestShutter" ]; then
        echo "`date`: shutter file empty, using default" >> $LOG_FILE
        bestShutter=$DEFAULT_SHUTTER_US
    fi
    echo "`date`: calibrated baseline shutter ${bestShutter}us" >> $LOG_FILE
else
    bestShutter=$DEFAULT_SHUTTER_US
    echo "`date`: skipping calibration; baseline shutter ${bestShutter}us" >> $LOG_FILE
fi

# apply exposure compensation: shutter_us = bestShutter_us * 2^((compensation - 15) / 3)
compDiff=$(($compensation - 15))
shutter=$(python3 -c "print(int($bestShutter * 2**($compDiff/3)))")
echo "`date`: shutter after compensation (${compDiff}/3 stops) = ${shutter}us" >> $LOG_FILE

# capture loop
echo "`date`: Executing photo capture (autoexposure=$autoexposure)" >> $LOG_FILE
start_shutter=$shutter
if [ $autoexposure = 1 ]; then
    end_shutter=$(python3 -c "print(int($start_shutter * 2 ** $RAMP_STOPS))")
    echo "`date`: gentle exposure ramp: ${start_shutter}us flat until ${RAMP_START_FRAC} of run, then eased up to ${end_shutter}us (+${RAMP_STOPS} stops) by the end" >> $LOG_FILE
fi
SECONDS=0
STARTTIME=`date "+%F %T"`

for i in `seq 1 $num`; do
    if [ $autoexposure = 1 ]; then
        # Gentle ramp: hold the sky-metered baseline until RAMP_START_FRAC of the run, then ease
        # the shutter up by up to RAMP_STOPS EV via a smoothstep (zero slope at the start = no
        # visible kink). The lift only partially offsets the fading light, so it still fades out.
        shutter=$(python3 -c "
s0=$start_shutter; i=$i; n=$num; stops=$RAMP_STOPS; f=$RAMP_START_FRAC
p = (i - 1) / max(n - 1, 1)
u = max((p - f) / max(1 - f, 1e-9), 0.0)   # 0 while flat, then 0->1 over [f,1]
s = u * u * (3 - 2 * u)                     # smoothstep
print(int(s0 * 2 ** (stops * s)))
")
    fi

    filename="$ROOT/img/$today/`date +%Y%m%d%H%M%S`.jpg"
    echo "Capturing photo $i / $num at shutter=${shutter}us -> $filename" >> $LOG_FILE
    rpicam-still -n -t $SETTLE_MS --width 1920 --height 1080 --shutter $shutter --gain 1.0 --awbgains $AWB_GAINS --denoise $DENOISE --autofocus-mode manual --lens-position 0 -q $JPEG_QUALITY -o "$filename" >> $LOG_FILE 2>&1 &
    CAMERA_PID=$!
    wait $CAMERA_PID
    CAMERA_PID=""

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

# Optional horizon-leveling rotation (-l <degrees>, + = clockwise). Rotate about the centre,
# then zoom just enough to crop back to a full-frame 1920x1080 with no black corners. The
# zoom factor cos(a)+(16/9)sin(a) is the exact fill amount for a 16:9 frame; x1.02 for margin.
# The filter string contains no spaces, so unquoted $VF expands to exactly "-vf <filter>".
VF=""
if [ "$level" != "0" ]; then
    zoom=$(python3 -c "import math; a=abs($level)*math.pi/180; print((math.cos(a)+(16.0/9.0)*math.sin(a))*1.02)")
    rot=$(python3 -c "import math; print($level*math.pi/180.0)")
    VF="-vf scale=iw*${zoom}:ih*${zoom},rotate=${rot}:fillcolor=black,crop=1920:1080"
    echo "`date`: leveling horizon by ${level} deg (zoom ${zoom})" >> $LOG_FILE
fi
# Encode at native 1920x1080 (no downscale) with a lower CRF for higher quality. Kept 8-bit
# yuv420p for broad player/Bluesky compatibility (10-bit would reduce sky banding but risks
# playback/transcode issues on the posted video).
ffmpeg -y -pattern_type glob -i "$IMAGEDIR/*.jpg" $VF -c:v libx264 -crf 18 -pix_fmt yuv420p $ROOT/final/$today.mp4 || { echo "`date`: ffmpeg failed" >> $LOG_FILE; exit 1; }

# upload movie to Bluesky
if [ $post = 1 ]; then
    echo "`date`: posting to Bluesky" >> $LOG_FILE
    $ROOT/uploadToBluesky.sh -m "$message (${STARTTIME} - ${ENDTIME})" -f $ROOT/final/$today.mp4 >> $LOG_FILE 2>&1
fi

# clean up
cd "$ROOT/img" || { echo "`date`: cd $ROOT/img failed, skipping cleanup" >> $LOG_FILE; exit 0; }
echo "`date`: cleaning up" >> $LOG_FILE
old_dirs=$(ls -t | tail -n +50)
[ -n "$old_dirs" ] && rm -vr $old_dirs >> $LOG_FILE
