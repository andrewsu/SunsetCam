#!/usr/bin/env python3

"""
Print how much of the sky a frame blows out, as basis points (0..10000) of the top half.

getBestShutter.sh picks the shutter with the most unique colours in the sky. That criterion has
no notion of clipping, and on a low-contrast marine-layer sky it inverts: shortening the exposure
quantises the narrow tonal range into FEWER distinct levels than clipping costs, so `%k` actively
rewards over-exposure. Measured on the 2026-08-09 scan the peak was 21616 colours at 6618us vs
21535 at 4188us -- 0.4% apart, i.e. noise -- and it took the brighter end, blowing 33% of the sky
to pure white. Four of the nine sunsets in 2026-08-01..09 were blown that way (up to 48%).

This gives getBestShutter.sh the missing term: the fraction of sky at or above CLIP_LEVEL, so it
can reject candidates that clip more than RAMP-independent CLIP_MAX_BP and take the best-exposed
shutter among the rest.

Uses the same im.draft() DCT-scaled decode as nextShutter.py: 0.58s per candidate on a Pi 3B, vs
5.0s for the equivalent ImageMagick `-threshold` pass, which over the scan's 22 candidates is 13s
of added calibration instead of 110s. Checked against a full-resolution count on the nine
2026-08-01..09 sunset frames -- draft vs full: 4754/4779, 1879/1892, 4496/4449, 600/601, 463/470,
6/8, 848/845, 3558/3563, 3280/3287 bp, i.e. within half a percentage point everywhere. The blown
regions are large and contiguous, so the 1/8-scale averaging does not soften the count.
"""

import sys

# Luma at or above which a pixel counts as blown. 250/255 on the gamma-encoded Rec601 luma, i.e.
# the same "pure white" the eye reads in the video, not a linear-light threshold.
CLIP_LEVEL = 250


def clipped_bp(path, level, hint=240):
    """Fraction of the top half at or above `level`, in basis points (0..10000)."""
    from PIL import Image

    im = Image.open(path)
    im.draft("L", (hint, hint * 9 // 16))
    im = im.convert("L")
    w, h = im.size
    top = im.crop((0, 0, w, max(h // 2, 1)))       # meter the sky, as getBestShutter.sh does
    hist = top.histogram()
    n = sum(hist)
    return int(round(sum(hist[level:]) * 10000.0 / n)) if n else 0


def main():
    if len(sys.argv) < 2:
        sys.stderr.write("usage: skyClip.py <frame.jpg> [clip_level]\n")
        return 1
    level = int(sys.argv[2]) if len(sys.argv) > 2 else CLIP_LEVEL

    # Print nothing on failure. The caller treats an unreadable measurement as "unknown" and lets
    # the candidate through, so a broken PIL degrades to the old colour-count-only behaviour
    # rather than vetoing every shutter and picking a wild one.
    try:
        print(clipped_bp(sys.argv[1], level))
    except Exception as exc:
        sys.stderr.write("skyClip.py: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
