#!/bin/bash

###
### SunsetGIF.sh
###
### Automate the creation of a time lapse gif using gphoto2
### 
### Andrew Su 2018-12-21
###

### USAGE: ./SunsetGIF.sh [-i <interval -- time between shots>] [-n <total number of shots to take>]

### TODO
###   * take a pre-shot in program or priority mode to get exposure right
###   * periodically take exposure shots to test/adjust shutter/aperture?

echo "`date`: Executing photo capture" >> /home/pi/SunsetGIF/log

# Initialize parameters
num=120
interval=10

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
cmd='gphoto2 --set-config imagesize=2 --set-config imagequality=1 --set-config expprogram 1; gphoto2 --capture-image-and-download --filename "/home/pi/SunsetGIF/img/%Y%m%d%H%M%S.jpg" -I $interval -F $num'
printf "Argument interval is %s\n" "$interval"
printf "Argument num is %s\n" "$num"
printf "Argument cmd is %s\n" "$cmd"

# Execute command
eval $cmd

# Use imagemagik to do JPG -> GIF
echo 'Converting...'
today=`date +"%Y%m%d"`
convert -resize 50% -delay 5 -loop 0 /home/pi/SunsetGIF/img/$today*.jpg /home/pi/SunsetGIF/final/$today.gif

### example of posting to twitter
# twurl authorize --consumer-key KEY --consumer-secret SECRET
# twurl -H upload.twitter.com "/1.1/media/upload.json" -d "command=INIT&media_type=image/gif&total_bytes=4572889"
# twurl -H upload.twitter.com "/1.1/media/upload.json" -d "command=APPEND&media_id=1081416668553703424&segment_index=0" --file sunset3.gif --file-field "media"
# twurl -H upload.twitter.com "/1.1/media/upload.json" -d "command=FINALIZE&media_id=1081416668553703424"
# twurl -d 'status=Testing media&media_ids=1081416668553703424' /1.1/statuses/update.json


### example of creating mp4
# ffmpeg  -i DSC_*.JPG -c:v libx264 -pix_fmt yuv420p timelapse.mp4

### resize according to https://stackoverflow.com/questions/34391499/change-video-resolution-ffmpeg
# ffmpeg -y -i timelapse.mp4 -vf "[in]scale=iw*min(1280/iw\,720/ih):ih*min(1280/iw\,720/ih)[scaled]; [scaled]pad=1280:720:(1280-iw*min(1280/iw\,720/ih))/2:(720-ih*min(1280/iw\,720/ih))/2[padded]; [padded]setsar=1:1[out]" -c:v libx264 -c:a copy "timelapse_shrink.mp4"
