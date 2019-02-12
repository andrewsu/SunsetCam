# R and Rscript
`sudo apt-get install r-base`
`sudo apt-get install libcurl4-openssl-dev`
`sudo apt-get install libv8-3.14-dev`

## suncalc R package
`install.packages('RCurl')`
`install.packages('V8')`
`install.packages('suncalc')`

# at
`sudo apt-get install at`

# gphoto2
`sudo apt-get install gphoto2 libgphoto2*`

## note about gphoto2
test gphoto2 installation by executing 'gphoto2 --capture-image-and-download'.  If you get an error related to not being able to claim the USB device, kill processes as described at this link:
	https://askubuntu.com/questions/993876/gphoto2-could-not-claim-the-usb-device

# graphicsmagick
NOTE: the command below worked on raspbian, but on ubuntu needed to follow instructions at https://gist.github.com/witooh/089eeac4165dfb5ccf3d
`sudo apt-get install graphicsmagick`

# pgmagick
not sure if we'll use the python library for graphicsmagick yet, but just in case, noting installation here... (a bit of a random assortment of libraries here -- will need to sort out exactly what's necessary...
`sudo apt-get install libgraphicsmagick++1-dev libboost-python-dev`
`sudo apt-get install libgraphicsmagick-q16-3`
`sudo apt-get install libgraphicsmagick++-q16-12`
`sudo apt-get install python-pgmagick`
`pip install pgmagick`

# ffmpeg
`sudo apt-get install ffmpeg`

# jq
`sudo apt-get install jq`

# twurl
`sudo gem install twurl`

# install and configure ntp so time is automatically set on boot
sudo apt install ntp
sudo systemctl enable ntp
sudo timedatectl set-ntp 1

# clone repo
`git clone https://github.com/andrewsu/SunsetCam.git`

# set up cron job
using `crontab -e` create a job *like this* to run every morning at 1AM
`0 1 * * * cd /home/pi/SunsetCam && ./scheduler.sh`

# force time to update on boot

add these lines to /etc/rc.local
```
/etc/init.d/ntp stop
/usr/sbin/ntpd -q -g
/etc/init.d/ntp start
```

# authorize the twitter account
```
CONFIG_FILE="config.txt" 
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi 
source $CONFIG_FILE
twurl authorize --consumer-key $TWITTER_API_KEY --consumer-secret $TWITTER_API_SECRET_KEY
```
follow instructions shown at prompt (go to twitter URL, authenticate, enter PIN)
