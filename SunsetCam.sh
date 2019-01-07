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


echo "`date`: Executing photo capture" >> $LOG_FILE

# Initialize parameters
num=240
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

# Set and print command
cmd='gphoto2 --set-config imagesize=2 --set-config imagequality=1; gphoto2 --capture-image-and-download --filename "$ROOT/img/%Y%m%d%H%M%S.jpg" -I $interval -F $num'
printf "Argument interval is %s\n" "$interval"
printf "Argument num is %s\n" "$num"
printf "Argument cmd is %s\n" "$cmd"

# Execute command
eval $cmd

# create mp4 using ffmpeg
today=`date +"%Y%m%d"`
ffmpeg -pattern_type glob -i "$ROOT/img/$today*.jpg" -c:v libx264 -pix_fmt yuv420p -vf "scale=w=1280:h=720:force_original_aspect_ratio=decrease" $ROOT/final/$today.mp4

# upload movie to twitter
$ROOT/uploadToTwitter.sh final/$today.mp4
