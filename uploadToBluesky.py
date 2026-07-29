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
from atproto import Client, client_utils
from atproto_client import models
from atproto_client.models.blob_ref import BlobRef


VIDEO_SERVICE = "https://video.bsky.app"
POLL_INTERVAL_SEC = 5
POLL_TIMEOUT_SEC = 30 * 60


def resolve_pds_host(did: str) -> str:
    """Resolve the user's PDS hostname from their DID document."""
    if did.startswith("did:plc:"):
        doc = httpx.get(f"https://plc.directory/{did}", timeout=30).json()
    elif did.startswith("did:web:"):
        host = did[len("did:web:"):].replace(":", "/")
        doc = httpx.get(f"https://{host}/.well-known/did.json", timeout=30).json()
    else:
        sys.exit(f"Unsupported DID method: {did}")
    for svc in doc.get("service", []):
        if svc.get("type") == "AtprotoPersonalDataServer":
            return urlparse(svc["serviceEndpoint"]).hostname
    sys.exit(f"No PDS service entry in DID document for {did}")


def upload_and_wait(client: Client, video_bytes: bytes, filename: str) -> "models.BlobRef":
    """Upload to Bluesky's video service and poll until processing completes.

    The SDK's send_video() uses plain uploadBlob, which skips video-service
    transcoding and produces "Video not found" on the rendered post. This
    follows the documented flow: getServiceAuth -> uploadVideo -> getJobStatus.
    """
    pds_host = resolve_pds_host(client.me.did)
    aud = f"did:web:{pds_host}"
    print(f"PDS host: {pds_host}")
    print(f"Service auth aud: {aud}")

    # The video service validates the service-auth token's lxm claim against
    # com.atproto.repo.uploadBlob (NOT app.bsky.video.uploadVideo, which now 401s
    # with "should be com.atproto.repo.uploadBlob").
    auth = client.com.atproto.server.get_service_auth(
        models.ComAtprotoServerGetServiceAuth.Params(
            aud=aud,
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
    print(f"uploadVideo HTTP {upload.status_code}: {upload.text}")
    try:
        body = upload.json()
    except Exception:
        body = {}

    # The video service returns 409 "already_exists" when this DID has already
    # uploaded a video with this filename (e.g. reposting the same file). The
    # response still carries the existing jobId, so we recover the blob via
    # getJobStatus instead of failing. This must be checked BEFORE raise_for_status
    # (which would otherwise abort on the 409).
    if upload.status_code == 409 and body.get("error") == "already_exists" and body.get("jobId"):
        job_id = body["jobId"]
        print(f"Video already processed, reusing job_id={job_id}")
    else:
        upload.raise_for_status()
        # Success returns {"jobStatus": {...}}.
        if "error" in body and "jobStatus" not in body:
            sys.exit(f"uploadVideo error: {body.get('error')} — {body.get('message')}")
        job_status = body.get("jobStatus") or {}
        job_id = job_status.get("jobId") or body.get("jobId")
        if not job_id:
            if job_status.get("error"):
                sys.exit(f"uploadVideo rejected: {job_status['error']}")
            sys.exit(f"uploadVideo returned no jobId: {body}")
        print(f"Video upload accepted, job_id={job_id}")

    # getJobStatus is served by video.bsky.app, not the user's PDS, so we
    # query it directly. The endpoint accepts unauthenticated GETs.
    deadline = time.monotonic() + POLL_TIMEOUT_SEC
    started = time.monotonic()
    while True:
        resp = httpx.get(
            f"{VIDEO_SERVICE}/xrpc/app.bsky.video.getJobStatus",
            params={"jobId": job_id},
            timeout=30,
        )
        resp.raise_for_status()
        status = resp.json().get("jobStatus") or {}
        state = status.get("state")
        if state == "JOB_STATE_COMPLETED":
            blob = status.get("blob")
            if not blob:
                sys.exit("Video processing completed but no blob was returned")
            print(f"Video processing complete after {int(time.monotonic() - started)}s")
            return BlobRef.model_validate(blob)
        if state == "JOB_STATE_FAILED":
            sys.exit(f"Video processing failed: {status.get('error')} {status.get('message')}")
        if time.monotonic() > deadline:
            sys.exit(f"Video processing did not finish within {POLL_TIMEOUT_SEC}s (last state: {state})")
        print(f"  state={state} progress={status.get('progress')}")
        time.sleep(POLL_INTERVAL_SEC)


def resolve_did(handle: str):
    """Resolve a Bluesky handle to its DID via the public API (no auth needed).

    Returns the DID string, or None if resolution fails — callers then fall back
    to rendering the handle as plain text instead of a linked mention.
    """
    try:
        resp = httpx.get(
            "https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle",
            params={"handle": handle},
            timeout=30,
        )
        resp.raise_for_status()
        return resp.json().get("did")
    except Exception as e:  # noqa: BLE001 - best-effort; degrade to plain text
        print(f"Could not resolve @{handle} to a DID: {e}")
        return None


def already_posted(handle: str, marker: str) -> bool:
    """True if a recent post by `handle` already contains `marker`.

    Guards the retry/catch-up path (postPending.sh): if send_post succeeded but the
    reply was lost to a dropped link, the entry stays spooled and gets retried, and
    without this check that retry would publish a duplicate. The marker used is the
    post's date line, which is unique per run.

    A failed check returns False on purpose -- if we can't reach the API we are about
    to fail the upload anyway, and refusing to post is worse than the race we're
    guarding against.
    """
    try:
        resp = httpx.get(
            "https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed",
            params={"actor": handle, "limit": 30},
            timeout=30,
        )
        resp.raise_for_status()
        for item in resp.json().get("feed", []):
            text = ((item.get("post") or {}).get("record") or {}).get("text") or ""
            if marker in text:
                return True
    except Exception as e:  # noqa: BLE001 - best-effort duplicate guard
        print(f"Could not check for an existing post: {e}")
    return False


def build_post_text(message: str, comment: str, date_str: str, mention: str, tags: str):
    """Assemble the post as atproto rich text with real tag/mention facets.

    Layout:
        <editorial comment>          (optional, from the Claude CLI)

        <message> — <date>          (framing line, e.g. "Sunset over Scripps Research — Sunday, July 26, 2026")
        #tag1 #tag2 @mention        (clickable hashtag + mention facets)
    """
    tb = client_utils.TextBuilder()
    written = False

    comment = (comment or "").strip()
    if comment:
        tb.text(comment)
        written = True

    frame_line = (message or "").strip()
    date_str = (date_str or "").strip()
    if date_str:
        frame_line = f"{frame_line} — {date_str}" if frame_line else date_str
    if frame_line:
        if written:
            tb.text("\n\n")
        tb.text(frame_line)
        written = True

    tag_list = [t.strip().lstrip("#") for t in (tags or "").split(",") if t.strip()]
    if tag_list or mention:
        if written:
            tb.text("\n")
        first = True
        for tag in tag_list:
            if not first:
                tb.text(" ")
            tb.tag(f"#{tag}", tag)
            first = False
        if mention:
            handle = mention.lstrip("@")
            if not first:
                tb.text(" ")
            did = resolve_did(handle)
            if did:
                tb.mention(f"@{handle}", did)
            else:
                tb.text(f"@{handle}")
            first = False

    return tb


def main():
    parser = argparse.ArgumentParser(description="Post a video to Bluesky.")
    parser.add_argument("-m", "--message", default="", help="Framing line (e.g. 'Sunset over Scripps Research')")
    parser.add_argument("-f", "--file", required=True, help="Path to mp4 video")
    parser.add_argument("--comment", default="", help="Editorial caption line (from the Claude CLI)")
    parser.add_argument("--date", default="", help="Human-readable date appended to the framing line")
    parser.add_argument("--mention", default="", help="Bluesky handle to @-mention (e.g. scripps.edu)")
    parser.add_argument("--tags", default="", help="Comma-separated hashtags without '#' (e.g. sunset,timelapse)")
    parser.add_argument("--skip-if-posted", default="", help="Exit 0 without posting if a recent post already contains this text (duplicate guard for retries)")
    parser.add_argument("--dry-run", action="store_true", help="Print the composed post and facets, then exit without posting")
    args = parser.parse_args()

    post = build_post_text(args.message, args.comment, args.date, args.mention, args.tags)

    if args.dry_run:
        print("--- post text ---")
        print(post.build_text())
        print("--- facets ---")
        for facet in post.build_facets():
            print(facet.model_dump_json())
        return

    load_dotenv(Path(__file__).resolve().parent / ".env")
    handle = os.environ.get("BLUESKY_HANDLE")
    app_password = os.environ.get("BLUESKY_APP_PASSWORD")
    if not handle or not app_password:
        sys.exit("Missing BLUESKY_HANDLE or BLUESKY_APP_PASSWORD in .env")

    video_path = Path(args.file)
    if not video_path.is_file():
        sys.exit(f"Video file not found: {video_path}")

    # Checked before the (slow, expensive) video upload, and via the public API so
    # it costs nothing but one GET.
    if args.skip_if_posted and already_posted(handle, args.skip_if_posted):
        print(f"Already posted (found {args.skip_if_posted!r} in a recent post); nothing to do")
        return

    client = Client()
    client.login(handle, app_password)

    video_bytes = video_path.read_bytes()
    blob = upload_and_wait(client, video_bytes, video_path.name)

    response = client.send_post(
        text=post,
        embed=models.AppBskyEmbedVideo.Main(video=blob, alt="SunsetCam timelapse"),
    )
    print(f"Posted to Bluesky: {response.uri}")


if __name__ == "__main__":
    main()
