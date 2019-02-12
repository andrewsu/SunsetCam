#!/bin/bash

###
### SunsetCam.sh
###
### Automate the creation of a time lapse gif using gphoto2
### 
### Andrew Su 2018-12-21
###

### USAGE: ./SunsetCam.sh [-i <interval -- time between shots>] [-n <total number of shots to take>]
###              [-e <1/0> -- perform empirical exposure test] [-d <1/0> -- perform deflicker]
###              [-t <1/0> -- upload movie to twitter] [-c <value from table below]

### possible exposure compensation values below
# /main/capturesettings/exposurecompensation
# Label: Exposure Compensation
# Type: RADIO
# Current: -2
# Choice: 0 -5
# Choice: 1 -4.666
# Choice: 2 -4.333
# Choice: 3 -4
# Choice: 4 -3.666
# Choice: 5 -3.333
# Choice: 6 -3
# Choice: 7 -2.666
# Choice: 8 -2.333
# Choice: 9 -2
# Choice: 10 -1.666
# Choice: 11 -1.333
# Choice: 12 -1
# Choice: 13 -0.666
# Choice: 14 -0.333
# Choice: 15 0
# Choice: 16 0.333
# Choice: 17 0.666
# Choice: 18 1
# Choice: 19 1.333
# Choice: 20 1.666
# Choice: 21 2
# Choice: 22 2.333
# Choice: 23 2.666
# Choice: 24 3
# Choice: 25 3.333
# Choice: 26 3.666
# Choice: 27 4
# Choice: 28 4.333
# Choice: 29 4.666
# Choice: 30 5

### TODO
###   * periodically take exposure shots to test/adjust shutter/aperture?

### READ CONFIGURATION FILE
CONFIG_FILE="config.txt"  
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1 
fi  
source $CONFIG_FILE

# Kill processes that lock gphoto2
pkill gvfs-gphoto2
pkill gvfsd-gphoto2


# Initialize parameters
num=480
interval=5
exposure=0
deflicker=1
twitter=1
compensation=15

# read in command-line options
while getopts ":i:n:e:d:t:c:" opt; do
  case $opt in
    i) interval="$OPTARG"
    ;;
    n) num="$OPTARG"
    ;;
    e) exposure="$OPTARG"
    ;;
    d) deflicker="$OPTARG"
    ;;
    t) twitter="$OPTARG"
    ;;
    c) compensation="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

# if requested, estimate exposure
if [ $exposure = 1 ]; then
    echo "`date`: calibrating exposure" >> $LOG_FILE
    $ROOT/getBestShutter.sh
fi

# set exposure compensation
echo "`date`: Setting exposure comp ($compensation)" >> $LOG_FILE
cmd="gphoto2 --set-config exposurecompensation=$compensation --set-config exposurecompensation2=0"
eval $cmd

# create output directory (if already exists, then create date.1, date.2, etc.)
today=`date +"%Y%m%d"`
if [ -d $ROOT/img/$today ]; then
    idx=1
    while [ -d $ROOT/img/$today.$idx ]; do
        idx=$(($idx+1))
    done
    today=$today.$idx
fi
echo "`date`: creating output directory ($ROOT/img/$today)" >> $LOG_FILE
mkdir $ROOT/img/$today

# Set configuration
cmd="gphoto2 --set-config imagesize=2 --set-config imagequality=1"
eval $cmd

# execute image capture
echo "`date`: Executing photo capture" >> $LOG_FILE
cmd="gphoto2 --capture-image-and-download --filename \"$ROOT/img/$today/%Y%m%d%H%M%S.jpg\" -I $interval -F $num --force-overwrite"
printf "Argument interval is %s\n" "$interval"
printf "Argument num is %s\n" "$num"
printf "Argument cmd is %s\n" "$cmd"
STARTTIME=`date "+%F %T"`
eval $cmd
ENDTIME=`date "+%T %Z"`

# copy to archive
scp -r $ROOT/img/$today asu@sulab.scripps.edu:SunsetCamArchive

# deflicker images
if [ $deflicker = 1 ]; then
    # deflicker using script from https://github.com/cyberang3l/timelapse-deflicker, as described 
    # at https://medium.com/twidi-and-his-camera/how-i-edited-5100-photos-for-my-last-timelapse-20f9ef6fe5db

    echo "`date`: deflickering images" >> $LOG_FILE
    cd $ROOT/img/$today
    $ROOT/timelapse-deflicker.pl -p 2 -w 50
    cd $ROOT
    IMAGEDIR="$ROOT/img/$today/Deflickered"
else 
    IMAGEDIR="$ROOT/img/$today"
fi

# create mp4 using ffmpeg
echo "`date`: Creating mp4 ($ROOT/final/$today.mp4)" >> $LOG_FILE
ffmpeg -y -pattern_type glob -i "$IMAGEDIR/*.jpg" -c:v libx264 -pix_fmt yuv420p -vf "scale=w=1280:h=720:force_original_aspect_ratio=decrease" $ROOT/final/$today.mp4

# upload movie to twitter
if [ $twitter = 1 ]; then
    echo "`date`: uploading to twitter" >> $LOG_FILE
    $ROOT/uploadToTwitter.sh -m "${STARTTIME} - ${ENDTIME}" -f $ROOT/final/$today.mp4
fi
