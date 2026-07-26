#!/bin/bash

###
### editorialComment.sh
###
### Pull a few representative frames from a sunset/sunrise timelapse mp4 and ask
### the local Claude Code CLI (`claude -p`) to write a one-line, casual editorial
### caption suitable for social media (e.g. "those clouds are A+" or "overcast
### today -- they can't all be amazing").
###
### Prints the caption to stdout as a single line. On ANY failure (CLI missing or
### unauthenticated, timeout, no frames, junk output) it prints nothing to stdout
### and exits non-zero, so callers can fall back to posting without a caption.
###
### Andrew Su 2026-07-26
###
### USAGE: ./editorialComment.sh -f <video.mp4> [-n <frames, default 4>]

set -o pipefail

file=""
nframes=4
while getopts ":f:n:" opt; do
  case $opt in
    f) file="$OPTARG" ;;
    n) nframes="$OPTARG" ;;
    \?) echo "editorialComment: invalid option -$OPTARG" >&2 ;;
  esac
done

[ -n "$file" ] && [ -f "$file" ] || { echo "editorialComment: video not found: $file" >&2; exit 1; }

# Locate the claude CLI. It's an npm-global install that is NOT on the PATH of a
# non-interactive `at`/cron job, so fall back to the known install path.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null)}"
[ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.npm-global/bin/claude"
[ -x "$CLAUDE_BIN" ] || { echo "editorialComment: claude CLI not found" >&2; exit 1; }

# The claude CLI reads its auth from $CLAUDE_CODE_OAUTH_TOKEN. A non-interactive
# at/cron job doesn't inherit it, so load it from .env (same file the Bluesky
# creds live in) if it isn't already in the environment.
if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    ENV_FILE="$(dirname "$0")/.env"
    if [ -f "$ENV_FILE" ]; then
        tok="$(grep -E '^[[:space:]]*CLAUDE_CODE_OAUTH_TOKEN=' "$ENV_FILE" | tail -n1 | cut -d= -f2- | tr -d '\r')"
        tok="${tok%\"}"; tok="${tok#\"}"; tok="${tok%\'}"; tok="${tok#\'}"
        [ -n "$tok" ] && export CLAUDE_CODE_OAUTH_TOKEN="$tok"
    fi
fi

# Scratch dir for the extracted frames (cleaned up on exit).
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/editorial.XXXXXX")" || exit 1
trap 'rm -rf "$tmpdir"' EXIT

# Video duration (seconds); assume a short clip if ffprobe can't tell us.
dur="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$file" 2>/dev/null)"
case "$dur" in ''|*[!0-9.]*) dur=20 ;; esac

# Sample fractions across the run, weighted toward the second half where the
# sunset colour lives: pre-sunset -> sunset -> dusk.
fracs="0.25 0.50 0.70 0.88"
frames=()
i=0
for f in $fracs; do
    i=$((i+1))
    [ "$i" -le "$nframes" ] || break
    out="$tmpdir/frame_$(printf '%02d' "$i").jpg"
    ts="$(python3 -c "print(round(max(0.0, $dur*$f), 3))")"
    ffmpeg -nostdin -y -ss "$ts" -i "$file" -frames:v 1 -q:v 2 "$out" >/dev/null 2>&1
    [ -s "$out" ] && frames+=("$out")
done

[ "${#frames[@]}" -ge 1 ] || { echo "editorialComment: no frames extracted" >&2; exit 1; }

paths="$(printf '%s\n' "${frames[@]}")"

read -r -d '' prompt <<EOF
You are the witty social-media voice of a west-facing sunset timelapse camera at Scripps Research in La Jolla, California. Below are still frames pulled from today's timelapse, in chronological order (roughly golden hour -> sunset -> dusk):

$paths

Read each image, then reply with ONE short, casual caption (about 6 to 14 words) reacting to today's sky, colours, or clouds. Match the mood to what you actually see: gush over a vivid one, gently roast a flat or overcast one, hype great clouds. Write it like a real person, not a brochure. Output ONLY the caption, on a single line -- no hashtags, no emoji, no surrounding quotes, no preamble or explanation.
EOF

# Run headless, allowing only the Read tool (so it can view the frames without a
# permission prompt), bounded by a timeout. stderr -> file for logging.
out="$(cd "$tmpdir" && timeout 180 "$CLAUDE_BIN" -p "$prompt" --allowed-tools Read 2>"$tmpdir/claude.err")"
rc=$?
if [ $rc -ne 0 ]; then
    echo "editorialComment: claude exited $rc: $(tail -n1 "$tmpdir/claude.err" 2>/dev/null)" >&2
    exit 1
fi

# First non-empty line, trimmed, with any wrapping quotes stripped.
caption="$(printf '%s' "$out" | grep -m1 -v '^[[:space:]]*$' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^["'\'']//' -e 's/["'\'']$//')"

[ -n "$caption" ] || { echo "editorialComment: empty caption" >&2; exit 1; }

# Guardrails: reject over-long output or anything that looks like a CLI/auth error
# leaking to stdout rather than a real caption.
if [ "${#caption}" -gt 200 ]; then
    echo "editorialComment: caption too long (${#caption} chars)" >&2
    exit 1
fi
if printf '%s' "$caption" | grep -qiE 'api error|authenticat|oauth|usage limit|invalid api key'; then
    echo "editorialComment: output looks like a CLI error, not a caption: $caption" >&2
    exit 1
fi

printf '%s\n' "$caption"
