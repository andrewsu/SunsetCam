#!/usr/bin/env python3

"""
Closed-loop exposure ramp: given the frame just captured, print the shutter (us) for the next one.

The open-loop ramp this replaces lifted the shutter on a fixed time curve, so the net on-screen
brightness was (natural light fall) - (lift) with the two terms set by unrelated things: the fall
across the ramp window varied 0.8-2.8 stops night to night while the lift came from the metered
baseline. On 2026-08-07 (very clear, baseline 1677us) the two diverged and the video brightened
+2.7 stops through sunset, because the sky's light barely falls between sunset-10 and sunset+3.

Instead of guessing a curve, aim at a target *decline rate* and let the sky set the shutter:

    target(t) = B0 * 2^(-DECLINE_EV_PER_MIN * t)      B0 = sky level the baseline gave on frame 1
    shutter   = clamp(target / measured_sky, baseline, MAX_SHUTTER)

Two properties make this safe on hardware:

  * ratchet -- the shutter only ever opens, so a cloud brightening the sky cannot walk it back
    down and there is no oscillation.
  * rate limit -- at most MAX_EV_PER_FRAME per step, so a single bad measurement cannot produce
    a visible jump. Together these make flicker structurally impossible.

Where the light falls faster than the target rate the shutter simply stays put and the scene dims
naturally; it only opens where the light stalls (the sunset plateau). So the on-screen brightness
declines at >= DECLINE_EV_PER_MIN everywhere and can never brighten. GATE_FRAC holds it at the
metered baseline for the first part of the run, keeping the bright pre-sunset sky exposed as
metered rather than lifted.

Any failure (missing frame, unreadable JPEG, PIL missing) returns the current shutter unchanged --
the run degrades to a flat exposure rather than dying.
"""

import json
import os
import sys

# --- sRGB electro-optical transfer function -----------------------------------------------------
# The mean is taken over gamma-encoded luma and then linearized (rather than linearizing each
# pixel first) to match the offline reconstruction these constants were tuned against.


def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def sky_level(path, hint):
    """Mean linear luminance of the top half of a frame (the sky), 0..1.

    im.draft() asks libjpeg for a DCT-domain scaled decode, which reads ~1/64 of the pixels.
    On a Pi 3B that is ~0.5s vs ~8.5s for `identify -format %[fx:mean]`, which matters because
    the capture loop only has ~3.2s of slack between frames at -i 5.
    """
    from PIL import Image

    im = Image.open(path)
    im.draft("L", (hint, hint * 9 // 16))
    im = im.convert("L")
    w, h = im.size
    top = im.crop((0, 0, w, max(h // 2, 1)))          # meter the sky, as getBestShutter.sh does
    data = list(top.getdata())
    return srgb_to_linear(sum(data) / len(data) / 255.0)


def main():
    try:
        (frame_path, i, num, interval, baseline, shutter_used, state_path,
         gate_frac, decline_ev_min, max_shutter, max_ev_per_frame, smooth_frames) = sys.argv[1:13]
        i = int(i)                       # 1-based index of the frame just captured
        num = int(num)
        interval = float(interval)
        baseline = float(baseline)
        shutter_used = float(shutter_used)
        gate_frac = float(gate_frac)
        decline_ev_min = float(decline_ev_min)
        max_shutter = float(max_shutter)
        max_ev_per_frame = float(max_ev_per_frame)
        smooth_frames = int(smooth_frames)
    except (ValueError, IndexError) as exc:
        sys.stderr.write("nextShutter.py: bad arguments: %s\n" % exc)
        return 1

    state = {"hist": [], "cur": baseline, "b0": None}
    if os.path.exists(state_path):
        try:
            with open(state_path) as fh:
                state = json.load(fh)
        except (OSError, ValueError) as exc:
            sys.stderr.write("nextShutter.py: unreadable state, restarting it: %s\n" % exc)

    cur = float(state.get("cur", baseline))

    try:
        level = sky_level(frame_path, 240)
    except Exception as exc:                                  # never take the run down
        sys.stderr.write("nextShutter.py: metering failed (%s); holding %dus\n" % (exc, cur))
        print(int(cur))
        return 0

    # Scene luminance with our own exposure divided out, smoothed causally over the last
    # smooth_frames+1 frames so cloud movement doesn't drive the loop.
    hist = list(state.get("hist", []))
    hist.append(level / shutter_used if shutter_used > 0 else 0.0)
    hist = hist[-(smooth_frames + 1):]
    scene = sum(hist) / len(hist)

    b0 = state.get("b0")
    if b0 is None:
        b0 = scene * baseline                                 # on-screen level the baseline gives

    if scene > 0.0 and i >= int(gate_frac * (num - 1)):
        t_next = i * interval / 60.0                          # minutes from run start, next frame
        want = min(b0 * 2.0 ** (-decline_ev_min * t_next) / scene, max_shutter)
        if want > cur:
            cur = min(want, cur * 2.0 ** max_ev_per_frame)    # ratchet, rate-limited

    try:
        with open(state_path, "w") as fh:
            json.dump({"hist": hist, "cur": cur, "b0": b0}, fh)
    except OSError as exc:
        sys.stderr.write("nextShutter.py: could not save state: %s\n" % exc)

    print(int(cur))
    return 0


if __name__ == "__main__":
    sys.exit(main())
