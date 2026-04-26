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
import time
from pathlib import Path
from urllib.parse import urlparse

import httpx
from dotenv import load_dotenv
from atproto import Client
from atproto_client import models


VIDEO_SERVICE = "https://video.bsky.app"
POLL_INTERVAL_SEC = 5
POLL_TIMEOUT_SEC = 30 * 60


def upload_and_wait(client: Client, video_bytes: bytes, filename: str) -> "models.BlobRef":
    """Upload to Bluesky's video service and poll until processing completes.

    The SDK's send_video() uses plain uploadBlob, which skips video-service
    transcoding and produces "Video not found" on the rendered post. This
    follows the documented flow: getServiceAuth -> uploadVideo -> getJobStatus.
    """
    pds_host = urlparse(client._base_url).hostname

    auth = client.com.atproto.server.get_service_auth(
        models.ComAtprotoServerGetServiceAuth.Params(
            aud=f"did:web:{pds_host}",
            lxm="com.atproto.repo.uploadBlob",
            exp=int(time.time()) + 30 * 60,
        )
    )

    upload = httpx.post(
        f"{VIDEO_SERVICE}/xrpc/app.bsky.video.uploadVideo",
        params={"did": client.me.did, "name": filename},
        headers={
            "Authorization": f"Bearer {auth.token}",
            "Content-Type": "video/mp4",
        },
        content=video_bytes,
        timeout=300,
    )
    upload.raise_for_status()
    job_id = upload.json()["jobStatus"]["jobId"]
    print(f"Video upload accepted, job_id={job_id}")

    deadline = time.monotonic() + POLL_TIMEOUT_SEC
    while True:
        status = client.app.bsky.video.get_job_status(
            models.AppBskyVideoGetJobStatus.Params(job_id=job_id)
        ).job_status
        if status.state == "JOB_STATE_COMPLETED":
            if status.blob is None:
                sys.exit("Video processing completed but no blob was returned")
            print(f"Video processing complete after {int(POLL_TIMEOUT_SEC - (deadline - time.monotonic()))}s")
            return status.blob
        if status.state == "JOB_STATE_FAILED":
            sys.exit(f"Video processing failed: {status.error} {status.message}")
        if time.monotonic() > deadline:
            sys.exit(f"Video processing did not finish within {POLL_TIMEOUT_SEC}s (last state: {status.state})")
        print(f"  state={status.state} progress={status.progress}")
        time.sleep(POLL_INTERVAL_SEC)


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

    video_bytes = video_path.read_bytes()
    blob = upload_and_wait(client, video_bytes, video_path.name)

    response = client.send_post(
        text=args.message,
        embed=models.AppBskyEmbedVideo.Main(video=blob, alt="SunsetCam timelapse"),
    )
    print(f"Posted to Bluesky: {response.uri}")


if __name__ == "__main__":
    main()
