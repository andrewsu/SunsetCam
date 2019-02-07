#!/bin/bash

###
### SunsetCam.sh
###
### Automate the creation of a time lapse gif using gphoto2
### 
### Andrew Su 2018-12-21
###

### USAGE: ./SunsetCam.sh [-i <interval -- time between shots>] [-n <total number of shots to take>]

### TODO
###   * take a pre-shot in program or priority mode to get exposure right
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

echo "`date`: calibrating exposure" >> $LOG_FILE
$ROOT/getBestShutter.sh


echo "`date`: Executing photo capture" >> $LOG_FILE

# Initialize parameters
num=480
interval=5

# read in command-line options
while getopts ":i:n:" opt; do
  case $opt in
    i) interval="$OPTARG"
    ;;
    n) num="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done

# create output directory
today=`date +"%Y%m%d"`
mkdir $ROOT/img/today

# Set and print command
cmd="gphoto2 --set-config imagesize=2 --set-config imagequality=1; gphoto2 --capture-image-and-download --filename \"$ROOT/img/$today/%Y%m%d%H%M%S.jpg\" -I $interval -F $num"
printf "Argument interval is %s\n" "$interval"
printf "Argument num is %s\n" "$num"
printf "Argument cmd is %s\n" "$cmd"

# Execute command
eval $cmd

# create mp4 using ffmpeg
echo "`date`: Creating mp4" >> $LOG_FILE
ffmpeg -pattern_type glob -i "$ROOT/img/$today/$today*.jpg" -c:v libx264 -pix_fmt yuv420p -vf "scale=w=1280:h=720:force_original_aspect_ratio=decrease" $ROOT/final/$today.mp4

# upload movie to twitter
$ROOT/uploadToTwitter.sh $ROOT/final/$today.mp4
