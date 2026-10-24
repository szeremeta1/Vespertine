#!/usr/bin/env python3
"""Trim a loopback capture so it starts where the channel-ID file starts.
The pack files begin with 1.0 s of digital silence, then the first voice at 1.000 s, so: find the first sample whose
level is above a threshold (default -40 dBFS), subtract 1.0 s, write the trimmed WAV (float32, same channels).
usage: trim_capture.py IN.wav OUT.wav [threshold_dB] [lead_seconds]    (needs numpy + ffmpeg/ffprobe on PATH)"""
import subprocess, sys, json
import numpy as np
src, dst = sys.argv[1], sys.argv[2]
thr = float(sys.argv[3]) if len(sys.argv) > 3 else -40.0
lead = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
pr = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=channels,sample_rate", "-of", "json", src], capture_output=True, text=True).stdout)["streams"][0]
n, rate = int(pr["channels"]), int(pr["sample_rate"])
raw = subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", src, "-f", "f32le", "-acodec", "pcm_f32le", "-"], capture_output=True, check=True).stdout
x = np.frombuffer(raw, "<f4").reshape(-1, n)
level = np.max(np.abs(x), axis=1)
idx = np.flatnonzero(level > 10 ** (thr / 20))
if idx.size == 0:
    print("NO SIGNAL above %.0f dBFS in %s: capture is silent, nothing to trim" % (thr, src)); sys.exit(3)
start = max(0.0, idx[0] / rate - lead)
print("first sound at %.3f s; trimming to start at %.3f s; capture length %.2f s, peak %.1f dBFS" % (idx[0] / rate, start, len(x) / rate, 20 * np.log10(level.max())))
subprocess.run(["ffmpeg", "-nostdin", "-y", "-v", "error", "-ss", "%.4f" % start, "-i", src, "-c:a", "pcm_f32le", dst], check=True)
