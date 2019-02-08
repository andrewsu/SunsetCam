#!/bin/bash

###
### uploadToTwitter.sh
###
### Andrew Su 2018-12-21
###

### USAGE: ./uploadToTwitter.sh <file to upload>

### READ CONFIGURATION FILE
CONFIG_FILE="config.txt"  
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1 
fi  
source $CONFIG_FILE

# Initialize parameters
message=""

# read in command-line options
while getopts ":m:f:" opt; do
  case $opt in
    m) message="$OPTARG"
    ;;
    f) file="$OPTARG"
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
    ;;
  esac
done


echo "`date`: Uploading to twitter" >> $LOG_FILE

MEDIA_FILE=$file
echo "FILE: $MEDIA_FILE"

# make sure MEDIA_FILE exists
if [ ! -f $MEDIA_FILE ]; then
     echo "Media file not found! Exiting..."
     exit 1 
fi  

# get file size
FILE_SIZE=$(stat -c%s "$MEDIA_FILE")
echo "$MEDIA_FILE // $FILE_SIZE"

# INIT
INIT_RESPONSE=`/usr/local/bin/twurl -H upload.twitter.com "/1.1/media/upload.json" -d "command=INIT&media_type=video/mp4&total_bytes=$FILE_SIZE" `
echo "INIT_RESPONSE: $INIT_RESPONSE"
MEDIA_ID=`echo $INIT_RESPONSE | jq -r '.media_id_string'`
echo "MEDIA_ID: $MEDIA_ID"

# APPEND
cmd="/usr/local/bin/twurl -H upload.twitter.com '/1.1/media/upload.json' -d \"command=APPEND&media_id=${MEDIA_ID}&segment_index=0\" --file ${MEDIA_FILE} --file-field 'media'"
echo "Uploading... $cmd"
eval $cmd


# FINALIZE
cmd="/usr/local/bin/twurl -H upload.twitter.com '/1.1/media/upload.json' -d \"command=FINALIZE&media_id=${MEDIA_ID}\""
echo "Finalizing: $cmd"
eval $cmd

# POST
cmd="/usr/local/bin/twurl -d \"status=$message&media_ids=${MEDIA_ID}\" /1.1/statuses/update.json"
echo "Posting: $cmd"
eval $cmd

