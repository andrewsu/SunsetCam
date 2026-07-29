#!/bin/bash

###
### postPending.sh
###
### Retry + catch-up delivery for the nightly Bluesky post.
###
### Why: this Pi rides the edge of eduroam coverage (-80 to -92 dBm) and drops the
### link 20-38 times a day, sometimes for 30+ minutes. Twice in a row (2026-07-27,
### 2026-07-28) an outage sat right on top of the ~20:22 posting window and lost the
### whole day's post -- the video was already finished in final/, but
### uploadToBluesky.py died on a DNS failure and SunsetCam.sh moved on to cleanup.
###
### So SunsetCam.sh no longer posts directly. It spools a small descriptor of the
### intended post, then asks this script to deliver it within a retry budget.
### Whatever is still undelivered when the budget runs out stays in the spool for
### the cron sweep to pick up once the link is back:
###
###     */15 * * * * /home/asu/SunsetCam/postPending.sh >> /home/asu/SunsetCam/log 2>&1
###
### USAGE:
###   postPending.sh --enqueue -f <video.mp4> [-m <message>] [--date <d>]
###                  [--mention <handle>] [--tags <a,b>] [--comment <caption>]
###       Writes a spool entry and prints its path to stdout. Does not post.
###
###   postPending.sh [--budget <seconds>] [spoolfile ...]
###       Delivers the named spool entries, or every pending entry if none are
###       named (the cron sweep). Exits 0 when nothing is left pending.
###
### Andrew Su 2026-07-28
###

set -o pipefail

### READ CONFIGURATION FILE
CONFIG_FILE="$(dirname "$0")/config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
     echo "Configuration file not found! Exiting..." >&2
     exit 1
fi
source "$CONFIG_FILE"

SPOOL_DIR="$ROOT/pending"
LOCK_FILE="$SPOOL_DIR/.lock"
EXPIRED_DIR="$SPOOL_DIR/expired"

# How long a spooled post stays eligible. 12h lets a sunset that couldn't go out at
# ~20:25 still land by ~08:25 the next morning -- the post text carries its own date
# so a late one is never ambiguous -- but stops us dropping yesterday's sky into the
# feed two days on.
MAX_AGE_HOURS=${MAX_AGE_HOURS:-12}

# Seconds to wait before each successive delivery attempt, clamped by the budget.
# Front-loaded so a 60-second blip costs almost nothing, then stretched out to ride
# through the half-hour outages this link actually produces.
BACKOFF=(0 60 120 300 600 900 900 900)

# Retry budget when --budget isn't given. The cron sweep runs every 15 min, so a
# short budget is right there; SunsetCam.sh passes a much larger one for the
# in-run attempt.
DEFAULT_BUDGET=300

# Seconds to keep re-checking connectivity before giving up on an attempt.
NET_WAIT_SEC=90

# How many times to try generating the editorial caption before settling for a plain
# post. Each failure costs up to 180s (the CLI's own timeout).
MAX_CAPTION_TRIES=${MAX_CAPTION_TRIES:-2}

log() { echo "`date`: postPending: $*"; }

### Is the network actually usable? DNS is what fails here first (the uploader dies
### with "Temporary failure in name resolution"), so check resolution AND a real
### request rather than trusting the interface state.
network_up() {
    getent hosts bsky.social >/dev/null 2>&1 || return 1
    curl -fsS -m 20 -o /dev/null https://bsky.social/xrpc/_health 2>/dev/null
}

### Wait up to $1 seconds for the link to come back. Returns 1 if it never does.
wait_for_network() {
    local deadline=$(( $(date +%s) + $1 ))
    while :; do
        network_up && return 0
        [ "$(date +%s)" -ge "$deadline" ] && return 1
        sleep 10
    done
}

### --- enqueue -------------------------------------------------------------

enqueue() {
    local video="" message="" date_str="" mention="" tags="" comment=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|--file)    video="$2";    shift 2 ;;
            -m|--message) message="$2";  shift 2 ;;
            --date)       date_str="$2"; shift 2 ;;
            --mention)    mention="$2";  shift 2 ;;
            --tags)       tags="$2";     shift 2 ;;
            --comment)    comment="$2";  shift 2 ;;
            *) echo "postPending --enqueue: unknown option $1" >&2; return 1 ;;
        esac
    done

    [ -n "$video" ] || { echo "postPending --enqueue: -f <video> is required" >&2; return 1; }
    [ -f "$video" ] || { echo "postPending --enqueue: video not found: $video" >&2; return 1; }

    mkdir -p "$SPOOL_DIR" || return 1
    local base spool
    base="$(basename "$video" .mp4)"
    spool="$SPOOL_DIR/$base.post"

    # Values are single-line by construction (the caption is one line, the rest are
    # short literals), so a plain key=value file is enough and needs no quoting or
    # eval on the way back in.
    {
        printf 'video=%s\n'   "$video"
        printf 'message=%s\n' "$message"
        printf 'date=%s\n'    "$date_str"
        printf 'mention=%s\n' "$mention"
        printf 'tags=%s\n'    "$tags"
        printf 'comment=%s\n' "$comment"
        printf 'created=%s\n' "$(date +%s)"
    } > "$spool" || return 1

    echo "$spool"
}

### --- delivery ------------------------------------------------------------

# Populates the globals used by deliver(). No eval: the value is whatever follows
# the first '=' on the line, verbatim.
read_spool() {
    sp_video=""; sp_message=""; sp_date=""; sp_mention=""; sp_tags=""; sp_comment=""
    sp_created=""; sp_captiontries=0
    local line key val
    while IFS= read -r line; do
        key="${line%%=*}"
        val="${line#*=}"
        case "$key" in
            video)        sp_video="$val" ;;
            message)      sp_message="$val" ;;
            date)         sp_date="$val" ;;
            mention)      sp_mention="$val" ;;
            tags)         sp_tags="$val" ;;
            comment)      sp_comment="$val" ;;
            created)      sp_created="$val" ;;
            captiontries) sp_captiontries="$val" ;;
        esac
    done < "$1"
}

# Rewrite one key in place, so a caption generated on one attempt isn't paid for
# again on the next (and so the attempt count survives across sweeps).
save_field() {
    local spool="$1" key="$2" val="$3" tmp
    tmp="$(mktemp "${spool}.XXXXXX")" || return 1
    { grep -v "^${key}=" "$spool"; printf '%s=%s\n' "$key" "$val"; } > "$tmp" \
        && mv "$tmp" "$spool" || { rm -f "$tmp"; return 1; }
}

### Deliver one spool entry. Returns 0 if it is posted (or already was), 1 if it
### should stay pending for a later sweep.
deliver_once() {
    local spool="$1"
    read_spool "$spool"

    if [ ! -f "$sp_video" ]; then
        log "video gone, dropping $spool ($sp_video)"
        rm -f "$spool"
        return 0
    fi

    # The caption needs the network too, so it is generated here rather than at
    # enqueue time: a night that starts offline still gets a captioned post once
    # the link returns, instead of being permanently stuck with the plain fallback.
    # Capped at MAX_CAPTION_TRIES because a broken CLI (expired token, say) fails by
    # timing out after 180s, which would otherwise eat the retry budget every attempt.
    if [ -z "$sp_comment" ] && [ -x "$ROOT/editorialComment.sh" ] \
       && [ "$sp_captiontries" -lt "$MAX_CAPTION_TRIES" ]; then
        save_field "$spool" captiontries "$(( sp_captiontries + 1 ))"
        # stdout is the caption; stderr carries the reason on failure and flows
        # through to whatever log the caller redirected us to.
        sp_comment="$("$ROOT/editorialComment.sh" -f "$sp_video")"
        if [ -n "$sp_comment" ]; then
            log "editorial caption: $sp_comment"
            save_field "$spool" comment "$sp_comment"
        else
            log "no editorial caption (try $(( sp_captiontries + 1 ))/$MAX_CAPTION_TRIES); posting plain"
        fi
    fi

    "$ROOT/uploadToBluesky.sh" -m "$sp_message" --comment "$sp_comment" --date "$sp_date" \
        --mention "$sp_mention" --tags "$sp_tags" \
        --skip-if-posted "$sp_date" -f "$sp_video"
    local rc=$?

    if [ $rc -eq 0 ]; then
        rm -f "$spool"
        return 0
    fi
    return 1
}

### Deliver one spool entry, retrying on the BACKOFF schedule until the budget runs
### out. Leaves the entry in place if it never lands.
deliver() {
    local spool="$1" budget="$2"
    local started attempt delay now

    started=$(date +%s)

    # Expire before spending anything on it.
    read_spool "$spool"
    if [ -n "$sp_created" ]; then
        local age=$(( started - sp_created ))
        if [ "$age" -gt $(( MAX_AGE_HOURS * 3600 )) ]; then
            mkdir -p "$EXPIRED_DIR"
            mv "$spool" "$EXPIRED_DIR/" 2>/dev/null
            log "gave up on $(basename "$spool") after $(( age / 3600 ))h (limit ${MAX_AGE_HOURS}h); moved to $EXPIRED_DIR"
            return 1
        fi
    fi

    attempt=0
    while :; do
        delay=${BACKOFF[$attempt]:-${BACKOFF[-1]}}
        if [ "$delay" -gt 0 ]; then
            now=$(date +%s)
            if [ $(( now - started + delay )) -gt "$budget" ]; then
                log "retry budget (${budget}s) exhausted for $(basename "$spool"); left pending for the next sweep"
                return 1
            fi
            log "attempt $((attempt+1)) for $(basename "$spool") in ${delay}s"
            sleep "$delay"
        fi

        if wait_for_network "$NET_WAIT_SEC"; then
            if deliver_once "$spool"; then
                log "delivered $(basename "$spool")"
                return 0
            fi
            log "delivery attempt $((attempt+1)) failed for $(basename "$spool")"
        else
            log "no network after ${NET_WAIT_SEC}s; skipping attempt $((attempt+1)) for $(basename "$spool")"
        fi

        attempt=$((attempt+1))
        now=$(date +%s)
        [ $(( now - started )) -lt "$budget" ] || {
            log "retry budget (${budget}s) exhausted for $(basename "$spool"); left pending for the next sweep"
            return 1
        }
    done
}

### --- main ----------------------------------------------------------------

if [ "$1" = "--enqueue" ]; then
    shift
    enqueue "$@"
    exit $?
fi

budget=$DEFAULT_BUDGET
spools=()
while [ $# -gt 0 ]; do
    case "$1" in
        --budget) budget="$2"; shift 2 ;;
        *) spools+=("$1"); shift ;;
    esac
done

mkdir -p "$SPOOL_DIR"

# One deliverer at a time: the in-run attempt from SunsetCam.sh and the cron sweep
# would otherwise race on the same entry and could double-post it.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "another delivery is in progress; nothing to do"
    exit 0
fi

if [ ${#spools[@]} -eq 0 ]; then
    shopt -s nullglob
    spools=("$SPOOL_DIR"/*.post)
    shopt -u nullglob
fi

[ ${#spools[@]} -eq 0 ] && exit 0

rc=0
for spool in "${spools[@]}"; do
    [ -f "$spool" ] || continue
    deliver "$spool" "$budget" || rc=1
done
exit $rc
