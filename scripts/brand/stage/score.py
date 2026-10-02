#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The trailer's music: an original score, synthesized from scratch (no samples, loops or presets), so it's
Vespertine's own and free to use anywhere the trailer goes.

Timed to the cut in Sources/TrailerStage/Timeline.swift: 130 BPM (two bars to each of the trailer's 65 BPM bars),
first downbeat at 3.657 s, the end card from bar 8, 36.633 s in all. A lounge progression in D-flat
(Dbmaj9, Bbm9, Gbmaj9, Ab13sus4) on a Rhodes-like FM piano, a warm pad, sub bass and soft half-time drums,
mastered to -14 LUFS with true peaks under -1 dBTP.

    python3 score.py out.wav                             the trailer's bed (48 kHz, 24-bit)
    python3 score.py --rate 384000 --bits 32 out.wav     the hi-res edition: synthesized at that rate, not upsampled,
                                                         so the hats, clicks and saturation really reach 192 kHz
(needs numpy, scipy, soundfile, pyloudnorm)
"""
import argparse

import numpy as np
import pyloudnorm
import soundfile
from scipy import ndimage, signal

OPTIONS = argparse.ArgumentParser(description="Synthesizes the trailer's score.")
OPTIONS.add_argument("out", nargs="?", default="vespertine-score.wav")
OPTIONS.add_argument("--rate", type=int, default=48_000, help="sample rate (the trailer uses 48000)")
OPTIONS.add_argument("--bits", type=int, choices=(16, 24, 32), default=24, help="PCM word length")
OPTIONS = OPTIONS.parse_args()
SR = OPTIONS.rate
BEAT = 60 / 130
MBAR = 4 * BEAT
FIRST_DOWNBEAT = 3.657            # Music.firstDownbeat: musical bar 2
T0 = FIRST_DOWNBEAT - 2 * MBAR    # musical bar 0 (a few ms before the file starts)
DURATION = 36.633                 # Music.duration
END_BAR = 16                      # the end card (trailer bar 8)
N = int(DURATION * SR)
RNG = np.random.default_rng(1729)


def at(bar, beat=0.0):
    """Time of `beat` (0-based, fractional) in musical bar `bar`."""
    return T0 + bar * MBAR + beat * BEAT


def midi(n):
    return 440.0 * 2 ** ((n - 69) / 12)


# One chord per musical bar. The intro sits on the subdominant and the suspended dominant, so the first downbeat
# lands on the tonic; bars 14-15 do the same into the end card.
DB, BBM, GB, AB = (
    (37, [53, 56, 60, 63]),       # Dbmaj9: F Ab C Eb over Db
    (34, [56, 60, 61, 65]),       # Bbm9: Ab C Db F over Bb
    (30, [58, 61, 65, 68]),       # Gbmaj9: Bb Db F Ab over Gb
    (32, [54, 58, 61, 65]),       # Ab13sus4: Gb Bb Db F over Ab
)
CHORDS = [GB, AB] + [DB, BBM, GB, AB] * 3 + [GB, AB] + [DB] * 4


def stereo(mono, pan=0.0):
    """Equal-power pan, -1 (left) … 1 (right)."""
    a = (pan + 1) * np.pi / 4
    return np.stack([mono * np.cos(a), mono * np.sin(a)])


def place(bus, sound, start):
    """Adds a (2, n) sound to the bus at `start` seconds, clipped to the file."""
    i = int(round(start * SR))
    j0 = max(0, -i)
    i = max(0, i)
    n = min(sound.shape[1] - j0, bus.shape[1] - i)
    if n > 0:
        bus[:, i:i + n] += sound[:, j0:j0 + n]


# MARK: - Instruments

def rhodes(note, length, velocity=0.6):
    """Two-operator FM electric piano: a bright attack that mellows, a tine click, and a gentle release."""
    f = midi(note)
    n = int((length + 1.2) * SR)
    t = np.arange(n) / SR
    index = (1.6 * velocity + 0.4) * np.exp(-t / 0.45) + 0.25
    tone = np.sin(2 * np.pi * f * t + index * np.sin(2 * np.pi * f * t))
    tine = 0.12 * velocity * np.sin(2 * np.pi * f * 14.0 * t) * np.exp(-t / 0.03)
    env = (1 - np.exp(-t / 0.002)) * np.exp(-t / (2.4 - 0.012 * (note - 48)))
    env *= np.where(t < length, 1.0, np.exp(-(t - length) / 0.22))
    return (tone + tine) * env * velocity


def pad(notes, length, cutoff=2600.0, attack=0.7, release=1.1):
    """Two detuned additive saws per note, darkened above `cutoff`, swelling in and out."""
    n = int((length + release) * SR)
    t = np.arange(n) / SR
    left, right = np.zeros(n), np.zeros(n)
    for note in notes:
        for side, cents in ((left, -7.0), (right, 7.0)):
            f = midi(note) * 2 ** (cents / 1200)
            phase = RNG.uniform(0, 2 * np.pi)
            wave = np.zeros(n)
            for k in range(1, 40):
                if k * f > 9000:
                    break
                wave += np.sin(2 * np.pi * k * f * t + phase * k) / k * np.exp(-(k * f) / cutoff)
            side += wave
    env = np.clip(t / attack, 0, 1) ** 2 * np.where(t < length, 1.0, np.clip(1 - (t - length) / release, 0, 1) ** 2)
    return np.stack([left, right]) * env / (len(notes) * 4)


def sub_bass(note, length):
    f = midi(note)
    n = int((length + 0.15) * SR)
    t = np.arange(n) / SR
    tone = np.sin(2 * np.pi * f * t) + 0.25 * np.sin(4 * np.pi * f * t) + 0.08 * np.sin(6 * np.pi * f * t)
    env = (1 - np.exp(-t / 0.008)) * np.where(t < length, np.exp(-t / 3.0), np.exp(-length / 3.0) * np.exp(-(t - length) / 0.04))
    return tone * env


def kick(velocity=1.0):
    t = np.arange(int(0.5 * SR)) / SR
    pitch = 46 + 74 * np.exp(-t / 0.035)
    body = np.sin(2 * np.pi * np.cumsum(pitch) / SR) * np.exp(-t / 0.32)
    click = signal.lfilter(*signal.butter(2, 3500 / (SR / 2), "high"), RNG.standard_normal(len(t))) * np.exp(-t / 0.004)
    return (body + 0.12 * click) * velocity


def clap(velocity=1.0):
    t = np.arange(int(0.6 * SR)) / SR
    noise = signal.lfilter(*signal.butter(2, [900 / (SR / 2), 5000 / (SR / 2)], "band"), RNG.standard_normal(len(t)))
    bursts = sum(np.exp(-np.clip(t - d, 0, None) / 0.006) * (t >= d) for d in (0.0, 0.011, 0.022))
    return noise * (0.6 * bursts + np.exp(-t / 0.16) * (t >= 0.022)) * velocity


def hat(velocity=0.5, open_=False):
    t = np.arange(int((0.35 if open_ else 0.08) * SR)) / SR
    noise = signal.lfilter(*signal.butter(4, 7000 / (SR / 2), "high"), RNG.standard_normal(len(t)))
    return noise * np.exp(-t / (0.12 if open_ else 0.022)) * velocity


def swell(length, low=300.0, high=7000.0, reverse=False):
    """Filtered noise rising into a cut (a riser, or a short reverse swell)."""
    n = int(length * SR)
    t = np.arange(n) / SR
    noise = RNG.standard_normal((2, n))
    out = np.zeros((2, n))
    block = 512
    for i in range(0, n, block):
        x = i / n
        f = low * (high / low) ** x
        b, a = signal.butter(2, [max(f / 1.6, 40) / (SR / 2), min(f * 1.6, SR / 2.1) / (SR / 2)], "band")
        out[:, i:i + block] = signal.lfilter(b, a, noise[:, i:i + block])
    env = (t / length) ** (3 if reverse else 2)
    return out * env


def impact(length=2.4):
    t = np.arange(int(length * SR)) / SR
    drop = np.sin(2 * np.pi * np.cumsum(38 + 40 * np.exp(-t / 0.25)) / SR) * np.exp(-t / 0.9)
    wash = signal.lfilter(*signal.butter(2, [3000 / (SR / 2), 12000 / (SR / 2)], "band"), RNG.standard_normal((2, len(t))))
    return np.stack([drop, drop]) * 0.7 + wash * np.exp(-t / 1.1) * 0.12


# MARK: - Arrangement

dry = np.zeros((2, N))       # bass, kick: no reverb
wet = np.zeros((2, N))       # everything else, through the reverb as well
duck = np.ones(N)            # sidechain from the kick, for the pad and bass
pads = np.zeros((2, N))
bass = np.zeros((2, N))

for bar, (root, notes) in enumerate(CHORDS):
    start = at(bar)
    if bar > END_BAR:
        break
    final = bar == END_BAR
    length = (DURATION - start - 0.5) if final else MBAR
    # Pad: darker in the intro, opening up as the groove arrives, widest for Spatial Audio (bars 10-11).
    cutoff = 900 + 1500 * bar / 2 if bar < 2 else (3400 if bar in (10, 11) else 2600)
    place(pads, pad(notes + [root + 24], length + 0.3, cutoff=cutoff, attack=1.4 if bar == 0 else 0.5,
                    release=2.5 if final else 0.9), start - 0.15)
    # Piano.
    if bar < 2:
        for k, note in enumerate(notes + [notes[1] + 12]):            # a rising arpeggio into the downbeat
            place(wet, stereo(rhodes(note, BEAT * 1.6, 0.42 + 0.04 * k), pan=-0.3 + 0.15 * k), at(bar, 0.5 + 0.75 * k))
    elif final:
        for k, note in enumerate(notes + [notes[3] + 10]):             # the last chord, gently rolled
            place(wet, stereo(rhodes(note, 4.5, 0.58), pan=-0.25 + 0.12 * k), start + 0.018 * k)
    else:
        for beat, hold, velocity in ((0, 1.4, 0.62), (1.5, 0.4, 0.45), (3, 0.6, 0.5)):
            for k, note in enumerate(notes):
                place(wet, stereo(rhodes(note, BEAT * hold, velocity), pan=-0.25 + 0.17 * k), at(bar, beat) + 0.006 * k)
        if bar % 2 == 1:                                               # a high answer every other bar
            place(wet, stereo(rhodes(notes[-1] + 12, BEAT * 0.9, 0.36), pan=0.4), at(bar, 3.5))
    # Bass and drums once the groove is in, until the end card.
    if 2 <= bar < END_BAR:
        for beat, hold, note in ((0, 1.4, root), (1.5, 0.45, root), (3, 0.4, root + 7), (3.5, 0.4, root + 10)):
            place(bass, stereo(sub_bass(note, BEAT * hold)), at(bar, beat))
        kicks = (0, 1.5) if bar % 4 != 3 else (0, 1.5, 3.75)
        for beat in kicks:
            place(dry, stereo(kick(1.0 if beat == 0 else 0.8)), at(bar, beat))
            i = int(at(bar, beat) * SR)
            if 0 <= i < N:
                t = np.arange(min(int(0.3 * SR), N - i)) / SR
                duck[i:i + len(t)] = np.minimum(duck[i:i + len(t)], 1 - 0.45 * np.exp(-t / 0.12))
        place(wet, stereo(clap(0.55), pan=0.05), at(bar, 2))
        for eighth in range(8):
            open_ = eighth == 7
            velocity = (0.32 if eighth % 2 else 0.2) * (0.8 + 0.4 * RNG.random())
            place(wet, stereo(hat(velocity, open_), pan=0.35), at(bar, eighth / 2) + RNG.normal(0, 0.004))

# FX: a riser into the first downbeat with an impact on it, a short swell into each scene cut, the end card's crash.
place(wet, swell(at(2) - at(1, 1)) * 0.25, at(1, 1))
place(wet, impact() * 0.9, at(2))
for bar in range(4, END_BAR, 2):
    place(wet, swell(BEAT * 1.5, 900, 9000, reverse=True) * 0.07, at(bar) - BEAT * 1.5)
place(wet, swell(BEAT * 2, 500, 9000, reverse=True) * 0.12, at(END_BAR) - BEAT * 2)
place(wet, impact(4.0) * 0.55, at(END_BAR))

# MARK: - Mix

pads *= duck
bass *= 0.75 + 0.25 * duck
wet += pads


def reverb(x, seconds=2.6, predelay=0.024):
    """A dark, wide hall: decorrelated noise tails that lose their highs as they decay."""
    n = int(seconds * 1.4 * SR)
    t = np.arange(n) / SR
    out = np.zeros_like(x)
    for ch in range(2):
        noise = RNG.standard_normal(n) * np.exp(-6.91 * t / seconds)
        early = signal.lfilter(*signal.butter(1, 9000 / (SR / 2)), noise)
        late = signal.lfilter(*signal.butter(1, 2500 / (SR / 2)), noise)
        ir = np.concatenate([np.zeros(int(predelay * SR)), early * np.exp(-t / 0.4) + late * (1 - np.exp(-t / 0.4))])
        ir /= np.sqrt(np.sum(ir ** 2))
        out[ch] = signal.fftconvolve(x[ch], ir)[:x.shape[1]]
    return out


mix = dry + bass * 0.55 + wet + reverb(wet) * 0.32
mix = signal.sosfilt(signal.butter(2, 28 / (SR / 2), "high", output="sos"), mix)
# Fade out with the end card's own fade (Music.duration - 1.5 to - 0.15).
t = np.arange(N) / SR
mix *= np.clip((DURATION - 0.15 - t) / 1.35, 0, 1) ** 1.5
mix = np.tanh(mix * 1.15) / 1.15

# -14 LUFS integrated, then a look-ahead limiter keeps true peaks (4x oversampled) under -1 dBTP.
def limit(x, ceiling, lookahead=0.004, release=0.12):
    need = np.minimum(1.0, ceiling / np.maximum(np.abs(x).max(axis=0), 1e-12))
    need = ndimage.minimum_filter1d(need, size=2 * int(lookahead * SR) + 1)   # duck before each peak arrives
    k = np.exp(-1 / (release * SR))
    gain, current = np.empty_like(need), 1.0
    for i, g in enumerate(need):
        current = g if g < current else k * current + (1 - k) * g
        gain[i] = current
    return x * gain


meter = pyloudnorm.Meter(SR)
mix *= 10 ** ((-14 - meter.integrated_loudness(mix.T)) / 20)
# Inter-sample peaks: 4x oversampled at 48 kHz; at 192 kHz and up the samples are already that close together.
OVERSAMPLE = max(1, 192_000 // SR)
true_peak = lambda x: np.max(np.abs(signal.resample_poly(x, OVERSAMPLE, 1, axis=1) if OVERSAMPLE > 1 else x))
ceiling = 10 ** (-1.2 / 20)
for _ in range(4):
    if true_peak(mix) <= 10 ** (-1 / 20):
        break
    mix = limit(mix, ceiling)
    ceiling *= 10 ** (-0.3 / 20)

if __name__ == "__main__":
    out = OPTIONS.out
    soundfile.write(out, mix.T, SR, subtype=f"PCM_{OPTIONS.bits}")
    final_peak = 20 * np.log10(true_peak(mix))
    print(f"{out}: {OPTIONS.bits}-bit / {SR / 1000:g} kHz, {DURATION:.3f} s, {meter.integrated_loudness(mix.T):.1f} LUFS, true peak {final_peak:.1f} dBTP")
