#!/usr/bin/env python3
"""Post a video file to Bluesky using the atproto Python SDK.

Credentials are loaded from a .env file in this script's directory:
    BLUESKY_HANDLE=yourhandle.bsky.social
    BLUESKY_APP_PASSWORD=xxxx-xxxx-xxxx-xxxx

Usage:
    uploadToBluesky.py -m "post text" -f /path/to/video.mp4
"""

import argparse
import os
import sys
from pathlib import Path

from dotenv import load_dotenv
from atproto import Client


def main():
    parser = argparse.ArgumentParser(description="Post a video to Bluesky.")
    parser.add_argument("-m", "--message", default="", help="Post text")
    parser.add_argument("-f", "--file", required=True, help="Path to mp4 video")
    args = parser.parse_args()

    load_dotenv(Path(__file__).resolve().parent / ".env")
    handle = os.environ.get("BLUESKY_HANDLE")
    app_password = os.environ.get("BLUESKY_APP_PASSWORD")
    if not handle or not app_password:
        sys.exit("Missing BLUESKY_HANDLE or BLUESKY_APP_PASSWORD in .env")

    video_path = Path(args.file)
    if not video_path.is_file():
        sys.exit(f"Video file not found: {video_path}")

    client = Client()
    client.login(handle, app_password)

    with open(video_path, "rb") as f:
        video_bytes = f.read()

    response = client.send_video(
        text=args.message,
        video=video_bytes,
        video_alt="SunsetCam timelapse",
    )
    print(f"Posted to Bluesky: {response.uri}")


if __name__ == "__main__":
    main()
