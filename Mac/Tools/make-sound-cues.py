#!/usr/bin/env python3
"""Generates the start/stop cue sounds (Mac/Resources/Sounds/*.wav).

Two soft, mallet-like notes: rising for "listening", falling for "done". Pure tones with a
gentle attack and a quick decay, so they read as a quiet confirmation rather than an alert
or an error beep. Re-run after changing the numbers below.
"""
import math, struct, wave, os

RATE = 44100

def note(freq, start, length, gain):
    """One mallet-like note: sine + a little 2nd/3rd harmonic, 6 ms attack, exponential decay."""
    out = {}
    n0 = int(start * RATE)
    for i in range(int(length * RATE)):
        t = i / RATE
        attack = min(1.0, t / 0.006)
        decay = math.exp(-t / (length * 0.28))
        tone = (math.sin(2 * math.pi * freq * t)
                + 0.22 * math.sin(2 * math.pi * freq * 2 * t)
                + 0.06 * math.sin(2 * math.pi * freq * 3 * t))
        out[n0 + i] = gain * attack * decay * tone
    return out

def render(notes, path):
    mix = {}
    for n in notes:
        for k, v in n.items():
            mix[k] = mix.get(k, 0.0) + v
    total = max(mix) + 1
    samples = [mix.get(i, 0.0) for i in range(total)]
    # Short fade-out so the file never ends on a click.
    fade = int(0.012 * RATE)
    for i in range(fade):
        samples[total - 1 - i] *= i / fade
    peak = max(abs(s) for s in samples) or 1.0
    scale = 0.55 / peak
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s * scale)) * 32767)) for s in samples))

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Resources", "Sounds")
os.makedirs(here, exist_ok=True)
E5, A5 = 659.26, 880.00
# Listening: two notes going up. Done: the same two going down, slightly softer.
render([note(E5, 0.00, 0.16, 1.0), note(A5, 0.085, 0.22, 0.9)], os.path.join(here, "cue-start.wav"))
render([note(A5, 0.00, 0.16, 0.9), note(E5, 0.085, 0.24, 0.85)], os.path.join(here, "cue-stop.wav"))
print("wrote cue-start.wav, cue-stop.wav")
