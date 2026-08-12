#!/bin/bash

###
### getBestShutter.sh
###
### Find the best shutter speed for current lighting (as estimated by number of unique
### colors in the TOP HALF of the frame -- the sky -- computed by imagemagick identify).
### Metering the sky (not the colour-rich foreground foliage, which would otherwise dominate
### the count and drive the sky to blow out) protects the sky; the foreground is allowed to
### fall to silhouette. Scans the full exposure range from a long exposure down to a short one
### in ~2/3-stop steps, then selects in three stages:
###
###   1. reject any candidate blowing more than CLIP_MAX_BP of the sky to white,
###   2. find the peak unique-colour count among the survivors (a well-exposed region has more
###      tonal variety than a blown or crushed one),
###   3. among candidates within TIE_BREAK_PCT of that peak, take the LONGEST shutter.
###
### Stage 3 exists because %k's peak is flat-topped and sits at the dark end of it, which
### under-exposed the whole run on 2026-08-10 (see TIE_BREAK_PCT below).
###
### Outputs the chosen shutter speed (microseconds) to $ROOT/tmp/shutter
###
### AS 20190110
### Modernized 2026-04-25 — rpicam-still (Camera Module 3 Wide via CSI)
###

### READ CONFIGURATION FILE
PARENT_LOG_FILE=$LOG_FILE   # if invoked from SunsetCam.sh, inherit its per-run log
CONFIG_FILE="$(dirname "$0")/config.txt"
if [ ! -f "$CONFIG_FILE" ]; then
     echo "Configuration file not found! Exiting..."
     exit 1
fi
source "$CONFIG_FILE"
[ -n "$PARENT_LOG_FILE" ] && LOG_FILE=$PARENT_LOG_FILE

mkdir -p $ROOT/tmp

echo "running getBestShutter.sh" >> $LOG_FILE

CAMERA_PID=""
trap '[ -n "$CAMERA_PID" ] && kill "$CAMERA_PID" 2>/dev/null; exit 1' INT TERM HUP

bestNumColors=-1
bestShutter=10000
peakShutter=""

# Every candidate that cleared the clipping cap, in scan order (longest shutter first).
allowedShutters=()
allowedColors=()
allowedClipKnown=()

# Highlight cap. `identify %k` counts tonal variety but has no notion of clipping, and on a
# low-contrast marine-layer sky the criterion inverts: shortening the exposure quantises the
# narrow tonal range into FEWER distinct levels than clipping costs, so %k actively rewards
# over-exposure. On 2026-08-09 the peak was 21616 colours at 6618us vs 21535 at 4188us -- 0.4%
# apart, i.e. noise -- and it took the brighter end, blowing 33% of the sky to pure white. Four
# of the nine sunsets in 2026-08-01..09 were blown that way (Aug 1 47.8%, Aug 3 44.5%, Aug 8
# 35.6%, Aug 9 32.9%), while every well-exposed night sat at 0.1-8.5%.
#
# So: reject any candidate blowing more than CLIP_MAX_BP of the sky, then take the most-colours
# shutter among the survivors. 2500bp = 25% is set from that week's spread -- above the borderline
# Aug 2 (18.9%, which keeps blue and cloud structure) and well below the blown nights, with ~3x
# headroom over the ~8.5% the in-frame sun disc clips on its own even when correctly exposed.
# That headroom matters because the sun is migrating further into frame toward the equinox, which
# raises the floor; if a good night ever gets rejected, raise this rather than lowering it.
CLIP_MAX_BP=2500   # basis points (10000 = 100%) of the sky allowed at or above CLIP_LEVEL
CLIP_LEVEL=250     # gamma-encoded luma at which a pixel reads as pure white

# Long-biased tie-break. The cap above stops %k over-exposing, but %k still picks the *bottom*
# of its own flat peak, which under-exposes the run. On 2026-08-10 (clear, sun setting into
# cloud) the scan peaked at 25318 colours @1677us with 4188us only 7.5% behind at 23427 -- and
# 1677us blew just 0.93% of the sky against the 25% cap, leaving ~24 points of headroom unused.
# The result was ~1.3 stops under-exposed: a dim sunset and 4.8s of the 24s video near-black.
# Picking 4188us instead would have matched a night judged good (frame-1 sky 0.20 vs 0.22) while
# clipping LESS than that night did (5.95% vs 8.48%).
#
# So among candidates within TIE_BREAK_PCT of the peak count, prefer the longest. Direction is
# deliberate: the mirror-image rule ("shortest within a few percent") was considered on
# 2026-08-09 and rejected because it would have picked 1061us on Aug 7, 0.67 stops darker than
# the 1677us that looked right. Clipping is what bounds over-exposure here, not %k.
#
# 8 is set from the Aug 10 spread: wide enough to reach 4188us (-7.5%) but not the visibly
# over-exposed 6618us (-11.1%, 16.1% blown). Widen it for a brighter, longer dusk at the cost of
# more clipped sky; narrow it toward 0 to fall back to plain peak-%k behaviour. Because it is a
# relative window it does nothing when the peak is genuinely sharp -- on a hazy night where %k
# goes flat and degenerate, the cap remains the real constraint.
TIE_BREAK_PCT=8    # % below the peak colour count still eligible; the longest of those wins

# Least-blown candidate seen, used only if NOTHING clears the cap (a very bright, very flat sky).
fallbackShutter=""
fallbackClip=-1

# Iterate shutter speeds (microseconds) from longest -> shortest in ~2/3-stop steps.
# 100/158 ≈ 1 / 2^(2/3) ≈ 0.6300 (i.e. one 2/3-stop reduction in exposure per iteration).
shutter=4000000   # 4 seconds (very dim twilight)
min_shutter=250   # 1/4000 s (bright daylight)

# Scan the WHOLE range and keep the shutter with the most unique colors. (Previously this
# broke at the first drop in colour count, which false-triggered at the 4s maximum when the
# longest shutters were all blown white -- near-white frames have few, noisy colour counts.)
while [ $shutter -ge $min_shutter ]; do
    rpicam-still -n -t 100 --width 1920 --height 1080 --shutter $shutter --gain 1.0 --awb daylight --autofocus-mode manual --lens-position 0 -o $ROOT/tmp/test.jpg >> $LOG_FILE 2>&1 &
    CAMERA_PID=$!
    wait $CAMERA_PID
    CAMERA_PID=""

    # count unique colours in the TOP HALF only (sky region) of the 1920x1080 capture, so the
    # exposure is metered for the sky rather than the colour-rich foreground foliage.
    # The [WxH+X+Y] suffix crops on read -- see https://imagemagick.org/script/escape.php
    numColors=$(identify -format %k "$ROOT/tmp/test.jpg[1920x540+0+0]" 2>/dev/null)
    numColors=${numColors:-0}

    # How much of the sky this exposure blows to white, in basis points. An empty result means the
    # measurement itself failed (no PIL, unreadable frame); that is treated as unknown and lets the
    # candidate through, so a broken helper degrades to the old colour-count-only behaviour rather
    # than vetoing every shutter and leaving us to pick a wild one.
    clipBp=$(python3 $ROOT/skyClip.py "$ROOT/tmp/test.jpg" $CLIP_LEVEL 2>>$LOG_FILE)
    rm -f $ROOT/tmp/test.jpg

    if [ -n "$clipBp" ] && [ "$clipBp" -gt "$CLIP_MAX_BP" ]; then
        echo "Shutter ${shutter}us has $numColors unique colors (sky/top-half), ${clipBp}bp blown -- REJECTED (cap ${CLIP_MAX_BP}bp)" >> $LOG_FILE
        if [ -z "$fallbackShutter" ] || [ "$clipBp" -lt "$fallbackClip" ]; then
            fallbackShutter=$shutter
            fallbackClip=$clipBp
        fi
    else
        echo "Shutter ${shutter}us has $numColors unique colors (sky/top-half), ${clipBp:-?}bp blown" >> $LOG_FILE
        # Record every candidate within the cap. Selection needs the peak count, which is not
        # known until the scan finishes, so the choice is made below rather than here.
        # clipKnown distinguishes "measured, and under the cap" from "unmeasurable, allowed
        # through by the fail-open above" -- only the former may be promoted by the long-biased
        # tie-break, which relies on clipping to bound how far it can reach.
        allowedShutters+=("$shutter")
        allowedColors+=("$numColors")
        if [ -n "$clipBp" ]; then allowedClipKnown+=(1); else allowedClipKnown+=(0); fi
        if (( numColors > bestNumColors )); then
            bestNumColors=$numColors
            peakShutter=$shutter
        fi
    fi
    shutter=$(($shutter * 100 / 158))
done

if [ "$bestNumColors" -le 0 ]; then
    if [ -n "$fallbackShutter" ]; then
        # Captures worked, but every exposure clipped past the cap. Take the least-blown one --
        # it is the closest to correct the scan found, and it is still bounded by the scan range.
        bestShutter=$fallbackShutter
        echo "$(date): getBestShutter.sh: no shutter met the ${CLIP_MAX_BP}bp clipping cap" >> $LOG_FILE
        echo "best shutter: ${bestShutter}us (${fallbackClip}bp blown, clipping-cap fallback)" >> $LOG_FILE
    else
        echo "$(date): getBestShutter.sh: all captures failed (camera locked?), aborting" >> $LOG_FILE
        exit 1
    fi
else
    # Long-biased tie-break: of the candidates within TIE_BREAK_PCT of the peak colour count,
    # take the longest shutter. The scan runs longest -> shortest, so the first qualifying entry
    # is the longest one. Requiring > 0 colours keeps a failed `identify` (0) from winning the
    # window when the peak is tiny enough that the threshold rounds to 0.
    threshold=$(( bestNumColors * (100 - TIE_BREAK_PCT) / 100 ))
    bestShutter=$peakShutter
    chosenColors=$bestNumColors
    for i in "${!allowedShutters[@]}"; do
        if (( allowedClipKnown[i] == 1 && allowedColors[i] >= threshold && allowedColors[i] > 0 )); then
            bestShutter=${allowedShutters[i]}
            chosenColors=${allowedColors[i]}
            break
        fi
    done

    if [ "$bestShutter" != "$peakShutter" ]; then
        echo "best shutter: ${bestShutter}us ($chosenColors unique colors) -- longest within ${TIE_BREAK_PCT}% of the ${bestNumColors}-colour peak at ${peakShutter}us" >> $LOG_FILE
    else
        echo "best shutter: ${bestShutter}us ($bestNumColors unique colors)" >> $LOG_FILE
    fi
fi
echo $bestShutter > $ROOT/tmp/shutter
