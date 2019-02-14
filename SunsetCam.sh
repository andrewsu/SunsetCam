#!/bin/bash

###
### SunsetCam.sh
###
### Automate the creation of a time lapse gif using gphoto2
### 
### Andrew Su 2018-12-21
###

### USAGE: ./SunsetCam.sh [-i <interval -- time between shots>] [-n <total number of shots to take>]
###              [-e <1/0> -- perform initial empirical exposure test] [-d <1/0> -- perform deflicker in post]
###              [-t <1/0> -- upload movie to twitter] [-c <exposure compensation value from table below>]
###              [-a <1/0> -- auto-adjust exposure mode] [-b <1/0> -- copy photos to backup server]

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
autoexposure=0
backup=1

lumwindow=3	# calculate drop based on median of most recent $lumwindow images
lumthresh=0.08	# adjust exposure if % difference in lum from start is > $lumthresh
lumramp=5	# adjust exposure at most once every $lumramp images

# read in command-line options
while getopts ":i:n:e:d:t:c:a:b:" opt; do
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
    a) autoexposure="$OPTARG"
    ;;
    b) backup="$OPTARG"
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
printf "Argument interval is %s\n" "$interval"
printf "Argument num is %s\n" "$num"
printf "Argument cmd is %s\n" "$cmd"
if [ $autoexposure = 0 ]; then
    echo "`date`: Executing photo capture" >> $LOG_FILE
    cmd="gphoto2 --capture-image-and-download --filename \"$ROOT/img/$today/%Y%m%d%H%M%S.jpg\" -I $interval -F $num --force-overwrite"
    STARTTIME=`date "+%F %T"` # average 2 seconds for capture time
    eval $cmd
    ENDTIME=`date "+%T %Z"`
else
    echo "`date`: Executing photo capture (autoexposure mode)" >> $LOG_FILE

    luminancefile=$ROOT/img/$today/luminance.txt
    nochangecount=0   # the number of images taken since the exposure was last changed
    SECONDS=0
    STARTTIME=`date "+%F %T"`
    for i in `seq 1 $num`; do
        echo "Capturing photo $i / $num"
        cmd="gphoto2 --capture-image-and-download --filename \"$ROOT/img/$today/%Y%m%d%H%M%S.jpg\" --force-overwrite"
        eval $cmd

        # calculate and record luminance
        outputfile=`ls $ROOT/img/$today/*.jpg | tail -1`
        $ROOT/calculate_luminance.py $outputfile >> $luminancefile

        nochangecount=$(($nochangecount+1))

        if [ $i = 1 ]; then
            # on the first iteration, set the initial luminance to $lumstart
            lumstart=`head -1 $luminancefile | awk '{print $2}'`
            echo "LUMSTART: $lumstart"
        else

            # check if the there have been enough images taken at this exposure
            if [ $nochangecount -gt $lumramp ]; then
                # calculate % drop in luminance based on median of last 3 images
                lumcurrent=`tail -$lumwindow $luminancefile | awk '{print $2}' | sort -n | head -$((($lumwindow+1)/2)) | tail -1`
                echo "LUMCURRENT ($nochangecount | $lumramp): $lumcurrent"
                lumdiff=`echo "($lumcurrent - $lumstart)/$lumstart" | bc -l`
                echo "LUMDIFF: $lumdiff"
            fi
         
        fi

        sleep $(($interval*$i-$SECONDS)) 
    done
    ENDTIME=`date "+%T %Z"`
fi

# copy to archive
if [ $backup = 1 ]; then
    scp -r $ROOT/img/$today asu@sulab.scripps.edu:SunsetCamArchive
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
echo "`date`: Creating mp4 ($ROOT/final/$today.mp4)" >> $LOG_FILE
ffmpeg -y -pattern_type glob -i "$IMAGEDIR/*.jpg" -c:v libx264 -pix_fmt yuv420p -vf "scale=w=1280:h=720:force_original_aspect_ratio=decrease" $ROOT/final/$today.mp4

# upload movie to twitter
if [ $twitter = 1 ]; then
    echo "`date`: uploading to twitter" >> $LOG_FILE
    $ROOT/uploadToTwitter.sh -m "${STARTTIME} - ${ENDTIME}" -f $ROOT/final/$today.mp4
fi
