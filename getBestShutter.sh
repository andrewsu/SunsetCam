#!/bin/bash

###
### getBestShutter.sh
###
### given current aperture value, find best shutter speed (as estimated by number of unique
### colors computed by imagemagick identify
###
### AS 20190110

### READ CONFIGURATION FILE
CONFIG_FILE="config.txt"
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source $CONFIG_FILE

lastNumColors=0

# iterate through shutterspeed settings, starting with longest exposure, decreasing by 2/3 stop each time
for ((i=36;i>=0;i=i-2)); do
    gphoto2 --set-config shutterspeed=$i
    gphoto2 --capture-image-and-download --force-overwrite --filename $ROOT/tmp/test.jpg

    # because we're looking at sunset, let's create a new with with just the top half of the photo
    HEIGHT=`identify -format %h $ROOT/tmp/test.jpg`
    WIDTH=`identify -format %w $ROOT/tmp/test.jpg`
    TOP=`expr $HEIGHT / 2`
    convert -crop ${WIDTH}x${TOP}+0+0 $ROOT/tmp/test.jpg $ROOT/tmp/test_top.jpg

    # use imagemagick to get number of unique colors -- see https://imagemagick.org/script/escape.php
    numColors=`identify -format %k $ROOT/tmp/test_top.jpg`
    echo "Shutter speed setting $i has $numColors unique colors"
    rm $ROOT/tmp/test.jpg $ROOT/tmp/test_top.jpg

    # test if the number of unique colors has decreased; if so, stop and use last setting
    if (( $numColors < $lastNumColors )); then
        break
    fi
    lastNumColors=$numColors
    lastIdx=$i
done

echo "setting shutterspeed: $lastIdx ($lastNumColors)"
gphoto2 --set-config shutterspeed=$lastIdx

