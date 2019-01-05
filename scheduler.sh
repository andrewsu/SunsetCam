#!/bin/bash

### GET SUNSET TIME

# Option #1: use R
sunset=`Rscript /home/pi/SunsetGIF/getSunsetTime.r`
echo "sunset: $sunset" >> /home/pi/SunsetGIF/log

# Option #2: use web services
#todaydate=`date +%F`
#sunset=`curl -s "https://api.sunrise-sunset.org/json?lat=32.896244&lng=-117.242651&date=$todaydate&formatted=0" | jq -r '.results.sunset'`


### the above commands should be used to tun this script at a certain time using 'at'

executionTime=`date -d "$sunset -10 min" +"%Y%m%d%H%M"`
echo "`date`: Logging command to execute at: $executionTime" >> /home/pi/SunsetGIF/log 


### schedule photo capture

#echo "echo '`date`: Executing photo capture' >> /home/pi/SunsetGIF/log" | at -t $executionTime
echo "bash /home/pi/SunsetGIF/SunsetGIF.sh >> /home/pi/SunsetGIF/log" | at -t $executionTime

