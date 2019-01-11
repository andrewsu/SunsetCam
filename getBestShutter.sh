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
for ((i=36;i>=0;i=i-2)); do
    gphoto2 --set-config shutterspeed=$i
    gphoto2 --capture-image-and-download --force-overwrite --filename $ROOT/tmp/test.jpg
    numColors=`identify -format %k $ROOT/tmp/test.jpg`
    echo "$i: $numColors"
    rm $ROOT/tmp/test.jpg 
    if (( $numColors < $lastNumColors )); then
        break
    fi
    lastNumColors=$numColors
    lastIdx=$i
done

echo "setting shutterspeed: $lastIdx ($lastNumColors)"
gphoto2 --set-config shutterspeed=$lastIdx

