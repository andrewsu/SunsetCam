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

# imgagemagick
`sudo apt-get install imagemagick`

# twurl
`sudo gem install twurl`

# clone repo
`git clone https://github.com/andrewsu/SunsetCam.git`

# set up cron job
using `crontab -e` create a job to run every morning at 1AM
`0 1 * * * /home/pi/SunsetCam/scheduler.sh`