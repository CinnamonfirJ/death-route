"""Synthesizes Dead Route's sound effects as 16-bit mono WAVs (standard library only).

Usage:  python -I tools/gen_sfx.py assets/audio
Everything here is generated from scratch (no samples), so it's free to ship.
Re-run to regenerate; tweak the recipes below to taste.
"""
import math
import os
import random
import struct
import sys
import wave

RATE = 22050
rng = random.Random(7)


# ---------- building blocks ----------

def silence(sec):
    return [0.0] * int(sec * RATE)


def noise(sec):
    return [rng.uniform(-1, 1) for _ in range(int(sec * RATE))]


def tone(freq, sec, shape="sine", vib_rate=0.0, vib_depth=0.0, sweep_to=None):
    n = int(sec * RATE)
    out, phase = [], 0.0
    for i in range(n):
        t = i / RATE
        f = freq if sweep_to is None else freq + (sweep_to - freq) * (i / n)
        if vib_rate:
            f *= 1.0 + vib_depth * math.sin(2 * math.pi * vib_rate * t)
        phase += f / RATE
        p = phase % 1.0
        if shape == "sine":
            v = math.sin(2 * math.pi * p)
        elif shape == "saw":
            v = 2 * p - 1
        elif shape == "square":
            v = 1.0 if p < 0.5 else -1.0
        else:  # triangle
            v = 4 * abs(p - 0.5) - 1
        out.append(v)
    return out


def env(sig, attack=0.002, decay=0.2, curve=4.0):
    """Fast attack, exponential-ish decay over the whole length."""
    n = len(sig)
    a = max(1, int(attack * RATE))
    out = []
    for i, s in enumerate(sig):
        if i < a:
            g = i / a
        else:
            x = (i - a) / max(1, n - a)
            g = (1 - x) ** curve if decay <= 0 else math.exp(-x * (n / RATE) / max(decay, 1e-4))
        out.append(s * g)
    return out


def lowpass(sig, cutoff, end_cutoff=None):
    out, y = [], 0.0
    n = len(sig)
    for i, s in enumerate(sig):
        c = cutoff if end_cutoff is None else cutoff + (end_cutoff - cutoff) * (i / n)
        a = 1 - math.exp(-2 * math.pi * c / RATE)
        y += a * (s - y)
        out.append(y)
    return out


def highpass(sig, cutoff):
    lp = lowpass(sig, cutoff)
    return [s - l for s, l in zip(sig, lp)]


def bandpass(sig, lo, hi):
    return lowpass(highpass(sig, lo), hi)


def mix(*sigs, gains=None):
    n = max(len(s) for s in sigs)
    gains = gains or [1.0] * len(sigs)
    out = [0.0] * n
    for s, g in zip(sigs, gains):
        for i, v in enumerate(s):
            out[i] += v * g
    return out


def at(sig, offset_sec, total_sec):
    out = silence(total_sec)
    o = int(offset_sec * RATE)
    for i, v in enumerate(sig):
        if o + i < len(out):
            out[o + i] += v
    return out


def gain(sig, g):
    return [s * g for s in sig]


def normalize(sig, peak=0.85):
    m = max(1e-9, max(abs(s) for s in sig))
    return [s / m * peak for s in sig]


def fade_tail(sig, sec=0.01):
    n = int(sec * RATE)
    out = list(sig)
    for i in range(min(n, len(out))):
        out[-1 - i] *= i / n
    return out


def write(path, sig, peak=0.85):
    sig = fade_tail(normalize(sig, peak))
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in sig))


# ---------- recipes ----------

def pistol():
    crack = env(highpass(noise(0.16), 900), decay=0.025)
    body = env(lowpass(noise(0.2), 2200, 300), decay=0.05)
    thump = env(tone(130, 0.15, sweep_to=60), decay=0.04)
    return mix(crack, body, thump, gains=[0.6, 0.8, 0.7])


def shotgun():
    blast = env(lowpass(noise(0.45), 3500, 250), decay=0.11)
    crack = env(highpass(noise(0.1), 1200), decay=0.02)
    boom = env(tone(80, 0.4, sweep_to=40), decay=0.12)
    return mix(blast, crack, boom, gains=[1.0, 0.5, 0.9])


def click(sec=0.02, freq=2400):
    return mix(env(highpass(noise(sec), 2000), decay=0.004), env(tone(freq, sec), decay=0.006), gains=[0.8, 0.4])


def reload():
    total = 0.55
    slide = env(bandpass(noise(0.12), 600, 3000), attack=0.03, decay=0.05)
    return mix(at(click(0.03, 1900), 0.0, total), at(slide, 0.12, total), at(click(0.04, 2600), 0.38, total))


def jam():
    return click(0.035, 1500)


def hit_flesh():
    squelch = env(lowpass(noise(0.12), 1400, 300), decay=0.035)
    thud = env(tone(95, 0.1, sweep_to=55), decay=0.03)
    return mix(squelch, thud, gains=[0.9, 0.7])


def zombie_die():
    splat = env(lowpass(noise(0.35), 2000, 200), decay=0.09)
    groan = env(lowpass(tone(110, 0.6, "saw", 6, 0.05, sweep_to=55), 700), attack=0.02, decay=0.25)
    return mix(splat, groan, gains=[0.8, 0.6])


def groan(base):
    dur = rng.uniform(0.9, 1.3)
    voice = lowpass(tone(base, dur, "saw", rng.uniform(4, 7), 0.06, sweep_to=base * 0.8), 650)
    breath = lowpass(noise(dur), 900)
    sig = mix(voice, breath, gains=[0.9, 0.25])
    n = len(sig)
    return [s * math.sin(math.pi * min(1.0, i / n * 1.15)) ** 1.5 for i, s in enumerate(sig)]


def explosion():
    rumble = env(lowpass(noise(1.5), 1800, 90), attack=0.004, decay=0.45)
    sub = env(tone(55, 1.4, sweep_to=30), decay=0.5)
    crack = env(highpass(noise(0.15), 1500), decay=0.03)
    return mix(rumble, sub, crack, gains=[1.0, 0.8, 0.4])


def crash():
    metal = mix(*[env(tone(f, 0.7), decay=0.18) for f in (310, 470, 790, 1130)], gains=[0.5, 0.4, 0.3, 0.2])
    hit = env(lowpass(noise(0.3), 2500, 400), decay=0.07)
    return mix(metal, hit, gains=[0.6, 1.0])


def ram():
    thud = env(tone(85, 0.2, sweep_to=45), decay=0.05)
    smack = env(lowpass(noise(0.15), 1600), decay=0.03)
    return mix(thud, smack, gains=[1.0, 0.8])


def pickup():
    total = 0.3
    a = env(tone(988, 0.12, "triangle"), decay=0.05)
    b = env(tone(1480, 0.18, "triangle"), decay=0.07)
    return mix(at(a, 0, total), at(b, 0.07, total))


def task_work():
    total = 0.3
    return mix(*[at(click(0.025, 1400 + i * 120), i * 0.08, total) for i in range(3)])


def task_done():
    total = 0.6
    notes = [523, 659, 784, 1047]
    return mix(*[at(env(tone(f, 0.22, "triangle"), decay=0.09), i * 0.09, total) for i, f in enumerate(notes)])


def cough():
    total = 0.7
    out = silence(total)
    for i, t in enumerate((0.0, 0.22, 0.4)):
        burst = env(bandpass(noise(0.16), 350, 1600), attack=0.006, decay=0.05)
        burst = gain(burst, 1.0 - i * 0.25)
        out = mix(out, at(burst, t, total))
    return out


def player_hurt():
    grunt = env(lowpass(tone(170, 0.22, "saw", 9, 0.04, sweep_to=120), 900), attack=0.01, decay=0.08)
    air = env(bandpass(noise(0.2), 500, 1800), decay=0.06)
    return mix(grunt, air, gains=[0.8, 0.5])


def alert():
    dur = 1.1
    a = tone(73, dur, "saw")
    b = tone(77.8, dur, "saw")  # beating dissonance
    sig = lowpass(mix(a, b), 500)
    n = len(sig)
    return [s * math.sin(math.pi * i / n) for i, s in enumerate(sig)]


def ui_click():
    return click(0.03, 1800)


def engine():
    """Seamless 1 s loop: 55 Hz fits a whole number of cycles."""
    dur = 1.0
    base = tone(55, dur, "saw")
    harm = tone(110, dur, "square")
    rumble = lowpass(noise(dur), 300)
    sig = lowpass(mix(base, harm, rumble, gains=[0.7, 0.25, 0.4]), 900)
    # crossfade the edges so the loop point is clean
    n, x = len(sig), int(0.02 * RATE)
    for i in range(x):
        g = i / x
        sig[i] = sig[i] * g + sig[n - x + i] * (1 - g)
    return sig[: n - x]


RECIPES = {
    "pistol": pistol, "shotgun": shotgun, "reload": reload, "jam": jam,
    "hit_flesh": hit_flesh, "zombie_die": zombie_die,
    "groan_1": lambda: groan(95), "groan_2": lambda: groan(120), "groan_3": lambda: groan(80),
    "explosion": explosion, "crash": crash, "ram": ram, "pickup": pickup,
    "task_work": task_work, "task_done": task_done, "cough": cough, "player_hurt": player_hurt,
    "alert": alert, "ui_click": ui_click, "engine": engine,
}

if __name__ == "__main__":
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "assets/audio"
    os.makedirs(out_dir, exist_ok=True)
    for name, fn in RECIPES.items():
        path = os.path.join(out_dir, name + ".wav")
        write(path, fn(), peak=0.8 if name != "engine" else 0.6)
        print("wrote", path)
