#!/bin/bash

### READ CONFIGURATION FILE
CONFIG_FILE="config.txt"  
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1 
fi  
source $CONFIG_FILE

### GET SUNSET TIME

# Option #1: use R
sunset=`Rscript $ROOT/getSunsetTime.r`
echo "sunset: $sunset" >> $LOG_FILE

# Option #2: use web services
#todaydate=`date +%F`
#sunset=`curl -s "https://api.sunrise-sunset.org/json?lat=32.896244&lng=-117.242651&date=$todaydate&formatted=0" | jq -r '.results.sunset'`


### the above commands should be used to tun this script at a certain time using 'at'

executionTime=`date -d "$sunset -25 min" +"%Y%m%d%H%M"`
echo "`date`: Logging command to execute at: $executionTime" >> $LOG_FILE


### schedule photo capture

#echo "echo '`date`: Executing photo capture' >> /home/pi/SunsetCam/log" | at -t $executionTime
echo "bash /home/pi/SunsetCam/SunsetCam.sh -e 1 -d 1 -c 18 >> $LOG_FILE" | at -t $executionTime


### GET SUNRISE TIME

# Option #1: use R
sunrise=`Rscript $ROOT/getSunriseTime.r`
echo "sunrise: $sunrise" >> $LOG_FILE

### the above commands should be used to tun this script at a certain time using 'at'

executionTime=`date -d "$sunrise -20 min" +"%Y%m%d%H%M"`
echo "`date`: Logging command to execute at: $executionTime" >> $LOG_FILE


### schedule photo capture

#echo "echo '`date`: Executing photo capture' >> /home/pi/SunsetCam/log" | at -t $executionTime
echo "bash /home/pi/SunsetCam/SunsetCam.sh -i 10 -n 240 -c 9 -e 1 -d 1 >> $LOG_FILE" | at -t $executionTime

