#!/bin/bash

###
### uploadToBluesky.sh
###
### Thin wrapper around uploadToBluesky.py — keeps the same -m/-f interface
### the original uploadToTwitter.sh exposed, so SunsetCam.sh can call it
### without other changes.
###
### Andrew Su 2018-12-21 (rewritten 2026-04-25 for Bluesky)
###

### USAGE: ./uploadToBluesky.sh -m "<post text>" -f <file to upload>

### READ CONFIGURATION FILE
CONFIG_FILE="config.txt"
if [ ! -f $CONFIG_FILE ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source $CONFIG_FILE

# Initialize parameters
message=""
file=""

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

echo "`date`: Uploading $file to Bluesky"

if [ ! -f "$file" ]; then
     echo "Media file not found! Exiting..."
     exit 1
fi

$ROOT/uploadToBluesky.py -m "$message" -f "$file"
