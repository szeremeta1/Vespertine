# SPDX-License-Identifier: GPL-3.0-or-later
# The Vinyl recording (Visualizer · Vinyl) as a constant-frame-rate movie with the record's label turning evenly.
#
# The recording is ~56 fps with jittered timestamps, and the app itself sometimes skips a frame, so on the trailer's
# 60 fps clock the label turns in uneven steps (holds and jumps). Only the label (the cover, r < 256 px at 2x) turns;
# everything else in the window is still or audio-driven. The label's angle in each real frame is measured
# (polar cross-correlation against the first frame), fitted against time (it turns at a constant 33 1/3 rpm), and
# each output tick takes the nearest real frame by angle and turns its label by the small remaining angle
# (cubic spline, label disc only). Nothing else in the frame is changed or blended.
#
# usage: vinyl-even.py <in.mov> <out.mov> <fps> <phase> <seconds> [--test [--diag]]
#   e.g. vinyl-even.py raw/C06.mov raw/vinyl.mov 60 0.6569 8   (0.3138 at 120 fps; see Assets.swift for the cue)
#   phase: where the stage samples within each output frame (its local times are (k + phase) / fps)
import sys, subprocess, json, numpy as np
from scipy.ndimage import map_coordinates

src, out, fps, phase, dur = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
test = "--test" in sys.argv
W, H = 2880, 1800
CX, CY = 1289.5, 900.5          # label centre in pixel-index coordinates (645, 450.5 pt at 2x)
R_IN, R_OUT = 262.0, 268.0       # label disc (256 px radius) + a feather over the plain dark ring outside it
B = 288                          # half-size of the box processed around the centre

pts = np.array(sorted(float(x) for x in subprocess.run(
    ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time", "-of", "csv=p=0", src],
    capture_output=True, text=True).stdout.split() if x != "N/A"))
pts = pts[pts <= dur + 0.2]
n = len(pts)

def decode(fmt, vf, bpp, shape):
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", src, "-t", f"{dur + 0.2}", "-vf", vf, "-fps_mode", "passthrough",
                          "-f", "rawvideo", "-pix_fmt", fmt, "-"], stdout=subprocess.PIPE)
    size = int(np.prod(shape)) * bpp
    while True:
        b = p.stdout.read(size)
        if len(b) < size: break
        yield np.frombuffer(b, np.uint16 if bpp == 2 else np.uint8).reshape(shape)

# 1. The label's absolute angle in every real frame.
N = 4096
th = np.linspace(0, 2 * np.pi, N, endpoint=False)
rr = np.arange(40, 250, 1.0)
x0, y0 = int(CX + 0.5) - B, int(CY + 0.5) - B      # crop origin: pixel index CX-B+0.5 → crop centre index B-0.5
cx_c, cy_c = CX - x0, CY - y0
PX = cx_c + rr[:, None] * np.cos(th)[None, :]; PY = cy_c + rr[:, None] * np.sin(th)[None, :]
gray = decode("gray", f"crop={2*B}:{2*B}:{x0}:{y0},format=gray", 1, (2 * B, 2 * B))
F = []
for g in gray:
    p = map_coordinates(g.astype(float), [PY, PX], order=1)
    F.append(np.fft.fft(p - p.mean(1, keepdims=True), axis=1))
assert len(F) == n, (len(F), n)
def rel(a, b):  # angle (deg) that turns frame a's label into frame b's, in (-180, 180]
    c = np.fft.ifft((F[b] * np.conj(F[a])).sum(0)).real
    k = int(c.argmax()); y1, y2, y3 = c[k - 1], c[k], c[(k + 1) % N]
    s = k + 0.5 * (y1 - y3) / (y1 - 2 * y2 + y3)
    return (s if s <= N / 2 else s - N) * 360 / N
step = np.array([rel(i - 1, i) for i in range(1, n)])
# absolute angle: measured against frame 0 directly where possible (no drift), unwrapped with the per-frame steps
acc = np.concatenate([[0], np.cumsum(step)])
ang = np.array([rel(0, i) for i in range(n)])
ang = ang + 360 * np.round((acc - ang) / 360)
omega, a0 = np.polyfit(pts, ang, 1)
resid = ang - (omega * pts + a0)
print(f"real frames {n}, label turns {omega:.3f} deg/s ({omega / 6:.3f} rpm); per-frame steps median {np.median(step):.3f} deg;"
      f" angle vs fitted clock: sd {resid.std():.3f} deg, max {np.abs(resid).max():.3f} deg", flush=True)

# The rotation is in screen coordinates (y down); its sign is checked on real frame pairs (--test).
yy, xx = np.mgrid[0:2 * B, 0:2 * B].astype(float)
dx, dy = xx - cx_c, yy - cy_c
r = np.hypot(dx, dy)
wgt = np.clip((R_OUT - r) / (R_OUT - R_IN), 0, 1) * np.clip((r - 17) / 4, 0, 1)   # the spindle (r < 17 px) doesn't turn
wgt = (wgt * wgt * (3 - 2 * wgt))[..., None]
def turn(box, deg):
    a = np.deg2rad(deg)
    # output pixel at angle θ takes the source at θ - a (the label moves by +a in the measured polar direction)
    sx = cx_c + dx * np.cos(a) + dy * np.sin(a)
    sy = cy_c - dx * np.sin(a) + dy * np.cos(a)
    out = np.empty_like(box)
    for c in range(3):
        out[..., c] = map_coordinates(box[..., c], [sy, sx], order=3, mode="nearest", prefilter=True)
    return box * (1 - wgt) + np.clip(out, 0, 65535) * wgt

frames = decode("rgb48le", "scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb48le",
                2, (H, W, 3))

if test:
    # Turn real frame i-1's label by the measured step and compare with real frame i, inside the label.
    m = (r < 250)
    prev = None; errs = []; still = []; acc_err = 0
    from PIL import Image
    for i, f in enumerate(frames):
        box = f[y0:y0 + 2 * B, x0:x0 + 2 * B].astype(float)
        if prev is not None and i < 120:
            pred = turn(prev, step[i - 1])
            e = np.abs(pred - box) / 257
            acc_err = acc_err + e
            errs.append(e[m].mean()); still.append(np.abs(prev - box)[m].mean() / 257)
            if i == 10 and "--diag" in sys.argv:   # predicted | real | |difference| x8, at 1:1
                row = np.concatenate([pred / 257, box / 257, np.clip(e * 8, 0, 255)], 1)
                Image.fromarray(np.clip(row, 0, 255).astype(np.uint8)).save(out + ".pair.png")
        prev = box
        if i >= 120: break
    if "--diag" in sys.argv:
        Image.fromarray(np.clip(acc_err / len(errs) * 16, 0, 255).astype(np.uint8)).save(out + ".meanerr.png")
    print(json.dumps({"label_mean_abs_err_8bit_turned": round(float(np.mean(errs)), 3), "worst": round(float(np.max(errs)), 3),
                      "label_mean_abs_diff_8bit_unturned": round(float(np.mean(still)), 3)}))
    sys.exit(0)

# 2. Output: tick k shows the content at time (k + phase) / fps.
K = int(round(dur * fps))
enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", f"{W}x{H}", "-r", f"{int(fps)}", "-i", "-",
                        "-vf", "scale=out_color_matrix=bt709:out_range=tv:in_range=pc:flags=accurate_rnd+full_chroma_int,format=yuv444p10le",
                        "-c:v", "prores_ks", "-profile:v", "4444", "-vendor", "apl0", "-color_primaries", "bt709", "-color_trc", "bt709",
                        "-colorspace", "bt709", "-color_range", "tv", "-video_track_timescale", f"{int(fps) * 100}", out], stdin=subprocess.PIPE)
buf = {}
it = enumerate(frames)
log = []
for k in range(K):
    t = (k + phase) / fps
    target = omega * t + a0
    j = int(np.argmin(np.abs(ang - target)))
    while j not in buf:
        i, f = next(it); buf[i] = f
    for old in [x for x in buf if x < j - 1]: del buf[old]
    f = buf[j].copy()
    d = target - ang[j]
    if abs(d) > 0.02:
        box = f[y0:y0 + 2 * B, x0:x0 + 2 * B].astype(float)
        f[y0:y0 + 2 * B, x0:x0 + 2 * B] = np.round(turn(box, d)).astype(np.uint16)
    enc.stdin.write(f.tobytes())
    log.append((k, t, j, float(pts[j]), float(d)))
enc.stdin.close(); enc.wait()
np.save(out + ".log.npy", np.array(log))
d = np.array([x[4] for x in log])
print(f"wrote {out}: {K} frames at {fps:g} fps; residual turn per tick |d| median {np.median(np.abs(d)):.3f} max {np.abs(d).max():.3f} deg;"
      f" real frames used {len(set(x[2] for x in log))}")
