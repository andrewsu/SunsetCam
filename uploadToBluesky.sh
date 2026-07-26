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
CONFIG_FILE="$(dirname "$0")/config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source "$CONFIG_FILE"

# All arguments are forwarded straight through to uploadToBluesky.py (which uses
# argparse and understands -m/-f plus the newer --comment/--date/--mention/--tags
# long options). We only peek at -f/--file here for the existence check + log line.
file=""
prev=""
for arg in "$@"; do
    case "$prev" in -f|--file) file="$arg" ;; esac
    prev="$arg"
done

echo "`date`: Uploading $file to Bluesky"

if [ -n "$file" ] && [ ! -f "$file" ]; then
     echo "Media file not found! Exiting..."
     exit 1
fi

$ROOT/uploadToBluesky.py "$@"
