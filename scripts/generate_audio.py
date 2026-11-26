#!/usr/bin/env python3
"""Procedural sound effects and ambience generator for 港区警报 (Harbor Alert).

Generates layered, headroom-normalized WAV SFX (mono for 3D spatial voices,
stereo for 2D feedback/stingers) and seamlessly looping OGG ambience beds into
assets/audio/. Uses only Python stdlib + numpy + ffmpeg.
"""

from __future__ import annotations

import math
import os
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

SR = 44100
OUT_DIR = Path(__file__).resolve().parent.parent / "assets" / "audio"


def _time(duration: float) -> np.ndarray:
    return np.arange(int(round(duration * SR)), dtype=np.float64) / SR


def _fade(sig: np.ndarray, fade_in_ms: float = 4.0, fade_out_ms: float = 12.0) -> np.ndarray:
    out = sig.copy()
    n = out.shape[0]
    fi = min(int(SR * fade_in_ms / 1000.0), n // 2)
    fo = min(int(SR * fade_out_ms / 1000.0), n // 2)
    if fi > 1:
        ramp = 0.5 - 0.5 * np.cos(np.linspace(0.0, math.pi, fi))
        if out.ndim == 2:
            out[:fi] *= ramp[:, None]
        else:
            out[:fi] *= ramp
    if fo > 1:
        ramp = 0.5 + 0.5 * np.cos(np.linspace(0.0, math.pi, fo))
        if out.ndim == 2:
            out[-fo:] *= ramp[:, None]
        else:
            out[-fo:] *= ramp
    return out


def _fft_filter(sig: np.ndarray, low_hz: float | None = None, high_hz: float | None = None,
                slope: float = 2.0) -> np.ndarray:
    n = sig.shape[0]
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    spec = np.fft.rfft(sig, axis=0)
    gain = np.ones_like(freqs)
    if low_hz is not None and low_hz > 0.0:
        ratio = np.maximum(freqs, 1e-6) / low_hz
        gain *= 1.0 / np.sqrt(1.0 + ratio ** (-2.0 * slope))
        gain[0] = 0.0
    if high_hz is not None and high_hz > 0.0:
        ratio = freqs / high_hz
        gain *= 1.0 / np.sqrt(1.0 + ratio ** (2.0 * slope))
    if sig.ndim == 2:
        spec *= gain[:, None]
    else:
        spec *= gain
    return np.fft.irfft(spec, n=n, axis=0)


def _pink_noise(n: int, rng: np.random.Generator) -> np.ndarray:
    white = rng.standard_normal(n)
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    scale = np.ones_like(freqs)
    scale[1:] = 1.0 / np.sqrt(freqs[1:])
    scale[0] = 0.0
    pink = np.fft.irfft(np.fft.rfft(white) * scale, n=n)
    peak = np.max(np.abs(pink))
    return pink / peak if peak > 1e-9 else pink


def _periodic_pink(n: int, rng: np.random.Generator, low_hz: float, high_hz: float) -> np.ndarray:
    """Strictly periodic filtered noise so sample N wraps cleanly to sample 0."""
    freqs = np.fft.rfftfreq(n, 1.0 / SR)
    phases = rng.uniform(0.0, 2.0 * math.pi, size=freqs.shape[0])
    mags = np.zeros_like(freqs)
    mask = freqs > 0.0
    mags[mask] = 1.0 / np.sqrt(freqs[mask])
    if low_hz > 0.0:
        mags[mask] *= 1.0 / np.sqrt(1.0 + (low_hz / freqs[mask]) ** 4.0)
    if high_hz > 0.0:
        mags[mask] *= 1.0 / np.sqrt(1.0 + (freqs[mask] / high_hz) ** 4.0)
    spec = mags * np.exp(1j * phases)
    spec[0] = 0.0
    if n % 2 == 0:
        spec[-1] = mags[-1]
    sig = np.fft.irfft(spec, n=n)
    peak = np.max(np.abs(sig))
    return sig / peak if peak > 1e-9 else sig


def _sine_sweep(t: np.ndarray, f0: float, f1: float, curve: float = 1.0, phase0: float = 0.0) -> np.ndarray:
    norm = t / max(t[-1], 1e-6)
    freq = f0 + (f1 - f0) * (norm ** curve)
    phase = phase0 + 2.0 * math.pi * np.cumsum(freq) / SR
    return np.sin(phase)


def _exp_sweep(t: np.ndarray, f0: float, f1: float, tau: float) -> np.ndarray:
    freq = f1 + (f0 - f1) * np.exp(-t / max(tau, 1e-5))
    phase = 2.0 * math.pi * np.cumsum(freq) / SR
    return np.sin(phase)


def _normalize(sig: np.ndarray, peak_db: float = -2.0) -> np.ndarray:
    sig = sig - np.mean(sig, axis=0, keepdims=True)
    peak = float(np.max(np.abs(sig)))
    if peak < 1e-9:
        return sig
    target = 10.0 ** (peak_db / 20.0)
    return sig * (target / peak)


def _stereo_widen(mono: np.ndarray, delay_ms: float = 6.0, spread: float = 0.25) -> np.ndarray:
    shift = max(1, int(SR * delay_ms / 1000.0))
    delayed = np.zeros_like(mono)
    delayed[shift:] = mono[:-shift]
    left = mono + delayed * spread
    right = mono - delayed * spread * 0.75 + np.roll(mono, shift // 2) * (spread * 0.4)
    return np.stack([left, right], axis=-1)


def _write_wav(path: Path, sig: np.ndarray) -> None:
    clipped = np.clip(sig, -1.0, 1.0)
    pcm = np.round(clipped * 32767.0).astype("<i2")
    channels = 1 if pcm.ndim == 1 else pcm.shape[1]
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(2)
        wf.setframerate(SR)
        wf.writeframes(pcm.tobytes())


def _write_ogg(path: Path, sig: np.ndarray, quality: float = 5.0) -> None:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_path = Path(tmp.name)
    try:
        _write_wav(tmp_path, sig)
        subprocess.run(
            [
                "ffmpeg", "-y", "-loglevel", "error",
                "-i", str(tmp_path),
                "-c:a", "libvorbis", "-q:a", str(quality),
                str(path),
            ],
            check=True,
        )
    finally:
        if tmp_path.exists():
            tmp_path.unlink()


# ---------------------------------------------------------------------------
# Giant locomotion & heavy impacts (Mono for 3D spatialization)
# ---------------------------------------------------------------------------

def gen_giant_step(seed: int, variant: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.76)
    n = t.shape[0]
    f_sub = 62.0 if variant == 0 else 56.0
    sub = _exp_sweep(t, f_sub, 27.0, 0.11) * np.exp(-t / 0.19) * (1.0 - np.exp(-t / 0.008))
    body = _exp_sweep(t, 128.0 if variant == 0 else 118.0, 44.0, 0.06) * np.exp(-t / 0.095)
    grit = _fft_filter(rng.standard_normal(n), 320.0, 2400.0) * np.exp(-t / 0.055)
    rumble = _fft_filter(_pink_noise(n, rng), 26.0, 115.0) * np.exp(-np.maximum(t - 0.02, 0.0) / 0.24)
    mix = np.tanh(sub * 1.45 + body * 0.72 + grit * 0.42 + rumble * 0.55)
    return _normalize(_fade(mix, 2.5, 45.0), -1.5)


def gen_giant_stomp(seed: int, variant: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(1.38)
    n = t.shape[0]
    f0 = 84.0 if variant == 0 else 76.0
    sub = _exp_sweep(t, f0, 23.0, 0.14) * np.exp(-t / 0.34) * (1.0 - np.exp(-t / 0.004))
    punch = _exp_sweep(t, 195.0, 52.0, 0.045) * np.exp(-t / 0.11)
    crack = _fft_filter(rng.standard_normal(n), 750.0, 4800.0) * np.exp(-t / 0.032)
    debris = _fft_filter(_pink_noise(n, rng), 320.0, 3400.0) * np.exp(-np.maximum(t - 0.015, 0.0) / 0.24)
    # Secondary gravel scatter pops
    scatter = np.zeros(n)
    for k in range(10):
        pos = int(rng.uniform(0.05, 0.55) * SR)
        dur = min(int(rng.uniform(0.02, 0.06) * SR), n - pos)
        if dur > 8:
            tt = np.arange(dur) / SR
            grain = _fft_filter(rng.standard_normal(dur), 900.0, 4500.0) * np.exp(-tt / 0.018)
            scatter[pos:pos + dur] += grain * rng.uniform(0.10, 0.28)
    quake = _fft_filter(_pink_noise(n, rng), 24.0, 95.0) * np.exp(-np.maximum(t - 0.03, 0.0) / 0.42)
    mix = np.tanh((sub * 1.65 + punch * 0.90 + crack * 0.72 + debris * 0.45 + scatter + quake * 0.75) * 0.85)
    return _normalize(_fade(mix, 2.0, 90.0), -1.0)


def gen_stomp_warn(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.54)
    n = t.shape[0]
    # Rising seismic air whoosh
    env = np.sin(math.pi * np.clip(t / 0.54, 0.0, 1.0)) ** 1.15
    noise_low = _fft_filter(_pink_noise(n, rng), 110.0, 420.0)
    noise_hi = _fft_filter(_pink_noise(n, rng), 420.0, 1400.0)
    sweep_mix = (noise_low * (1.0 - t / 0.54) + noise_hi * (t / 0.54)) * env
    # Subtle industrial alert telegraph ping (helps evacuees react!)
    ping_env = np.exp(-t / 0.14) * (1.0 - np.exp(-t / 0.006))
    ping = (np.sin(2.0 * math.pi * 520.0 * t) * 0.55 + np.sin(2.0 * math.pi * 780.0 * t) * 0.35) * ping_env
    # Rising low pressure tension
    rise = _sine_sweep(t, 68.0, 128.0, curve=1.5) * env * 0.38
    mix = sweep_mix * 0.65 + ping * 0.34 + rise
    return _normalize(_fade(mix, 6.0, 35.0), -4.0)


def gen_hand_whoosh(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.56)
    n = t.shape[0]
    env = (t / 0.56) ** 1.3 * np.exp(-((t - 0.30) / 0.19) ** 2.0)
    low = _fft_filter(_pink_noise(n, rng), 90.0, 320.0)
    mid = _fft_filter(_pink_noise(n, rng), 280.0, 1100.0)
    mix = (low * 0.78 + mid * (0.45 + 0.55 * np.sin(math.pi * t / 0.56))) * env
    air = _sine_sweep(t, 125.0, 62.0, curve=1.2) * env * 0.32
    return _normalize(_fade(mix + air, 8.0, 45.0), -3.0)


def gen_hand_grab(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.36)
    n = t.shape[0]
    thud = _exp_sweep(t, 145.0, 58.0, 0.045) * np.exp(-t / 0.085)
    grip = _fft_filter(_pink_noise(n, rng), 260.0, 1900.0) * np.exp(-t / 0.09)
    creak = np.sin(2.0 * math.pi * (210.0 + 35.0 * np.sin(2.0 * math.pi * 18.0 * t)) * t) * np.exp(-t / 0.14) * 0.16
    mix = np.tanh(thud * 1.15 + grip * 0.52 + creak)
    return _normalize(_fade(mix, 3.0, 30.0), -3.0)


def gen_hand_punch(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.68)
    n = t.shape[0]
    snap = _fft_filter(rng.standard_normal(n), 850.0, 4200.0) * np.exp(-t / 0.025)
    punch = _exp_sweep(t, 165.0, 36.0, 0.055) * np.exp(-t / 0.17)
    sub = _exp_sweep(t, 74.0, 28.0, 0.09) * np.exp(-t / 0.24)
    tail = _fft_filter(_pink_noise(n, rng), 90.0, 650.0) * np.exp(-t / 0.16)
    mix = np.tanh(snap * 0.95 + punch * 1.25 + sub * 1.15 + tail * 0.40)
    return _normalize(_fade(mix, 2.0, 50.0), -1.5)


def gen_hand_crush(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.84)
    n = t.shape[0]
    sub = _exp_sweep(t, 115.0, 30.0, 0.085) * np.exp(-t / 0.22)
    crunch = np.zeros(n)
    for offset, amp, tau, lo, hi in [
        (0.00, 0.95, 0.040, 900.0, 5200.0),
        (0.04, 0.85, 0.055, 650.0, 4200.0),
        (0.10, 0.65, 0.075, 450.0, 3600.0),
        (0.18, 0.45, 0.110, 300.0, 2800.0),
    ]:
        pos = int(offset * SR)
        seg = n - pos
        tt = np.arange(seg) / SR
        burst = _fft_filter(rng.standard_normal(seg), lo, hi) * np.exp(-tt / tau)
        crunch[pos:] += burst * amp
    rubble = _fft_filter(_pink_noise(n, rng), 80.0, 900.0) * np.exp(-t / 0.28) * 0.55
    mix = np.tanh(sub * 1.35 + crunch * 0.85 + rubble)
    return _normalize(_fade(mix, 2.0, 65.0), -1.5)


# ---------------------------------------------------------------------------
# Building & destruction SFX (Mono for 3D spatialization)
# ---------------------------------------------------------------------------

def gen_building_crack(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.62)
    n = t.shape[0]
    crack1 = _fft_filter(rng.standard_normal(n), 950.0, 5600.0) * np.exp(-t / 0.030)
    pos2 = int(0.055 * SR)
    crack2 = np.zeros(n)
    tt2 = np.arange(n - pos2) / SR
    crack2[pos2:] = _fft_filter(rng.standard_normal(n - pos2), 620.0, 3900.0) * np.exp(-tt2 / 0.048)
    groan = _exp_sweep(t, 138.0, 62.0, 0.12) * np.exp(-t / 0.22) * 0.55
    pebbles = _fft_filter(_pink_noise(n, rng), 1100.0, 6200.0) * np.exp(-np.maximum(t - 0.04, 0.0) / 0.19) * 0.35
    mix = np.tanh(crack1 * 0.95 + crack2 * 0.72 + groan + pebbles)
    return _normalize(_fade(mix, 2.0, 45.0), -2.5)


def gen_building_collapse(seed: int, variant: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(2.25)
    n = t.shape[0]
    # Initial structural break
    break_thud = _exp_sweep(t, 92.0 if variant == 0 else 82.0, 26.0, 0.18) * np.exp(-t / 0.42)
    shear = _fft_filter(rng.standard_normal(n), 700.0, 4600.0) * np.exp(-t / 0.065)
    # Cascading concrete slab hits
    slabs = np.zeros(n)
    for k in range(14):
        start_s = 0.05 + k * rng.uniform(0.06, 0.11)
        pos = int(start_s * SR)
        if pos >= n - 64:
            break
        seg = n - pos
        tt = np.arange(seg) / SR
        weight = math.exp(-start_s * 0.95) * rng.uniform(0.45, 1.0)
        hit = _exp_sweep(tt, rng.uniform(95.0, 175.0), rng.uniform(32.0, 52.0), 0.06) * np.exp(-tt / 0.16)
        gravel = _fft_filter(rng.standard_normal(seg), 420.0, 3800.0) * np.exp(-tt / 0.09)
        slabs[pos:] += (hit * 0.68 + gravel * 0.42) * weight
    # Deep cascading rubble roar
    roar_env = (1.0 - np.exp(-t / 0.07)) * np.exp(-np.maximum(t - 0.25, 0.0) / 0.72)
    roar = _fft_filter(_pink_noise(n, rng), 32.0, 360.0) * roar_env * 0.92
    # High glass / masonry dust shimmer
    shimmer_env = (1.0 - np.exp(-t / 0.05)) * np.exp(-t / 0.68)
    shimmer = _fft_filter(rng.standard_normal(n), 1800.0, 6800.0) * shimmer_env * 0.26
    mix = np.tanh((break_thud * 1.25 + shear * 0.80 + slabs * 0.62 + roar + shimmer) * 0.78)
    return _normalize(_fade(mix, 3.0, 220.0), -1.5)


def gen_barrier_break(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.68)
    n = t.shape[0]
    crack = _fft_filter(rng.standard_normal(n), 800.0, 5400.0) * np.exp(-t / 0.036)
    thud = _exp_sweep(t, 140.0, 42.0, 0.06) * np.exp(-t / 0.14)
    chunks = np.zeros(n)
    for k in range(6):
        pos = int(rng.uniform(0.04, 0.34) * SR)
        seg = n - pos
        tt = np.arange(seg) / SR
        chunks[pos:] += _fft_filter(rng.standard_normal(seg), 520.0, 3400.0) * np.exp(-tt / 0.04) * rng.uniform(0.25, 0.55)
    mix = np.tanh(crack * 0.95 + thud * 1.10 + chunks * 0.65)
    return _normalize(_fade(mix, 2.0, 60.0), -2.0)


def gen_building_restore(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.46)
    n = t.shape[0]
    rise = _sine_sweep(t, 82.0, 195.0, curve=1.25) * np.sin(math.pi * t / 0.46) * 0.65
    lock_pos = int(0.28 * SR)
    lock = np.zeros(n)
    tt = np.arange(n - lock_pos) / SR
    lock[lock_pos:] = (_exp_sweep(tt, 260.0, 110.0, 0.03) * np.exp(-tt / 0.07)
                       + _fft_filter(rng.standard_normal(n - lock_pos), 700.0, 2600.0) * np.exp(-tt / 0.025) * 0.4)
    return _normalize(_fade(rise + lock * 0.8, 8.0, 40.0), -4.5)


# ---------------------------------------------------------------------------
# Human & miniature bedroom SFX
# ---------------------------------------------------------------------------

def gen_human_step(seed: int, variant: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.15)
    n = t.shape[0]
    heel = _exp_sweep(t, 185.0 if variant == 0 else 165.0, 74.0, 0.018) * np.exp(-t / 0.032)
    grit = _fft_filter(rng.standard_normal(n), 750.0, 4200.0) * np.exp(-t / 0.028)
    toe = np.zeros(n)
    p2 = int(0.026 * SR)
    tt2 = np.arange(n - p2) / SR
    toe[p2:] = _fft_filter(rng.standard_normal(n - p2), 1100.0, 4600.0) * np.exp(-tt2 / 0.022) * 0.55
    mix = heel * 0.85 + grit * 0.50 + toe
    return _normalize(_fade(mix, 1.5, 16.0), -5.0)


def gen_human_hurt(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.38)
    n = t.shape[0]
    thud = _exp_sweep(t, 155.0, 46.0, 0.05) * np.exp(-t / 0.13)
    slap = _fft_filter(rng.standard_normal(n), 400.0, 2800.0) * np.exp(-t / 0.035) * 0.65
    tension = np.sin(2.0 * math.pi * 310.0 * t) * np.exp(-t / 0.09) * 0.24
    mix = np.tanh(thud * 1.25 + slap + tension)
    return _normalize(_fade(mix, 2.0, 35.0), -2.0)


def gen_human_defeat(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.48)
    n = t.shape[0]
    thud = _exp_sweep(t, 128.0, 40.0, 0.07) * np.exp(-t / 0.16)
    scuff = _fft_filter(_pink_noise(n, rng), 320.0, 2400.0) * np.exp(-np.maximum(t - 0.04, 0.0) / 0.13) * 0.45
    return _normalize(_fade(np.tanh(thud * 1.1 + scuff), 2.0, 40.0), -3.0)


def gen_stamina_empty(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.32)
    n = t.shape[0]
    env = (1.0 - np.exp(-t / 0.035)) * np.exp(-t / 0.11)
    breath = _fft_filter(_pink_noise(n, rng), 420.0, 1750.0) * env
    low_drop = _sine_sweep(t, 240.0, 150.0, curve=1.2) * env * 0.22
    return _normalize(_fade(breath * 0.78 + low_drop, 6.0, 35.0), -6.5)


def gen_bedroom_step(seed: int, variant: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.12)
    n = t.shape[0]
    # Warm damped wood floor tap
    wood_f = 285.0 if variant == 0 else 255.0
    tap = (_exp_sweep(t, wood_f, 120.0, 0.015) * 0.75 + np.sin(2.0 * math.pi * (wood_f * 1.9) * t) * 0.25) * np.exp(-t / 0.024)
    brush = _fft_filter(rng.standard_normal(n), 550.0, 2600.0) * np.exp(-t / 0.022) * 0.32
    return _normalize(_fade(tap + brush, 1.5, 14.0), -6.5)


def gen_bedroom_climb(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.15)
    n = t.shape[0]
    grip = _fft_filter(_pink_noise(n, rng), 500.0, 2900.0) * (1.0 - np.exp(-t / 0.01)) * np.exp(-t / 0.042)
    knock = _exp_sweep(t, 340.0, 170.0, 0.012) * np.exp(-t / 0.020) * 0.45
    return _normalize(_fade(grip * 0.72 + knock, 2.0, 18.0), -6.5)


def gen_bedroom_mantle(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.28)
    n = t.shape[0]
    rustle = _fft_filter(_pink_noise(n, rng), 600.0, 3200.0) * np.sin(math.pi * np.clip(t / 0.16, 0.0, 1.0)) * 0.48
    hop = _sine_sweep(t, 240.0, 420.0, curve=0.9) * np.exp(-t / 0.08) * 0.28
    land = np.zeros(n)
    p = int(0.12 * SR)
    tt = np.arange(n - p) / SR
    land[p:] = _exp_sweep(tt, 290.0, 130.0, 0.015) * np.exp(-tt / 0.032) * 0.70
    return _normalize(_fade(rustle + hop + land, 3.0, 28.0), -5.0)


# ---------------------------------------------------------------------------
# Growth, Brawl & Combat feedback SFX
# ---------------------------------------------------------------------------

def gen_coin_pickup(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.44)
    n = t.shape[0]
    # Crisp two-note golden chime: E6 -> B6
    note1 = (np.sin(2.0 * math.pi * 1318.5 * t) * 0.65
             + np.sin(2.0 * math.pi * 2637.0 * t) * 0.24
             + np.sin(2.0 * math.pi * 3955.5 * t) * 0.08) * np.exp(-t / 0.11) * (1.0 - np.exp(-t / 0.002))
    p2 = int(0.068 * SR)
    note2 = np.zeros(n)
    tt = np.arange(n - p2) / SR
    note2[p2:] = (np.sin(2.0 * math.pi * 1975.5 * tt) * 0.72
                  + np.sin(2.0 * math.pi * 3951.0 * tt) * 0.22
                  + np.sin(2.0 * math.pi * 5926.5 * tt) * 0.06) * np.exp(-tt / 0.15) * (1.0 - np.exp(-tt / 0.002))
    clink = _fft_filter(rng.standard_normal(n), 3200.0, 8800.0) * np.exp(-t / 0.012) * 0.18
    mono = note1 + note2 + clink
    return _normalize(_fade(_stereo_widen(mono, 4.0, 0.22), 1.5, 40.0), -3.5)


def gen_coin_drop(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.56)
    n = t.shape[0]
    out = np.zeros(n)
    for offset, amp, decay in [(0.0, 1.0, 0.18), (0.14, 0.52, 0.12), (0.24, 0.28, 0.09)]:
        pos = int(offset * SR)
        seg = n - pos
        tt = np.arange(seg) / SR
        clang = (np.sin(2.0 * math.pi * 987.8 * tt) * 0.55
                 + np.sin(2.0 * math.pi * 1480.0 * tt) * 0.35
                 + np.sin(2.0 * math.pi * 2560.0 * tt) * 0.22) * np.exp(-tt / decay)
        thud = _exp_sweep(tt, 220.0, 90.0, 0.02) * np.exp(-tt / 0.04) * 0.45
        out[pos:] += (clang + thud) * amp
    grit = _fft_filter(rng.standard_normal(n), 1800.0, 6200.0) * np.exp(-t / 0.025) * 0.18
    return _normalize(_fade(out + grit, 1.5, 45.0), -2.5)


def gen_growth_surge(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.46)
    n = t.shape[0]
    env = np.sin(math.pi * t / 0.46) ** 0.85 * np.exp(-t / 0.32)
    base = _sine_sweep(t, 165.0, 330.0, curve=0.9) * 0.62
    fifth = _sine_sweep(t, 247.5, 495.0, curve=0.9) * 0.36
    air = _fft_filter(_pink_noise(n, rng), 500.0, 2600.0) * env * 0.22
    mono = (base + fifth) * env + air
    return _normalize(_fade(_stereo_widen(mono, 7.0, 0.28), 8.0, 50.0), -4.5)


def gen_transform_giant(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(1.26)
    n = t.shape[0]
    # Deep sub ignition drop
    sub = _exp_sweep(t, 115.0, 36.0, 0.22) * np.exp(-t / 0.55) * (1.0 - np.exp(-t / 0.015))
    # Ascending power chord swell (C3 - G3 - C4 - E4 - G4)
    swell_env = (1.0 - np.exp(-t / 0.14)) * np.exp(-np.maximum(t - 0.36, 0.0) / 0.48)
    chord = np.zeros(n)
    for freq, amp in [(130.81, 0.45), (196.0, 0.38), (261.63, 0.35), (329.63, 0.28), (392.0, 0.24)]:
        glide = _sine_sweep(t, freq * 0.84, freq, curve=0.45)
        chord += (glide + 0.25 * np.sin(2.0 * math.pi * freq * 2.0 * t)) * amp
    # Peak crystalline chime at 0.22s
    p = int(0.22 * SR)
    chime = np.zeros(n)
    tt = np.arange(n - p) / SR
    chime[p:] = (np.sin(2.0 * math.pi * 1046.5 * tt) * 0.45
                 + np.sin(2.0 * math.pi * 1568.0 * tt) * 0.30) * np.exp(-tt / 0.36)
    whoosh = _fft_filter(_pink_noise(n, rng), 180.0, 2200.0) * np.sin(math.pi * np.clip(t / 0.6, 0.0, 1.0)) * 0.26
    mono = np.tanh((sub * 1.15 + chord * swell_env * 0.72 + chime * 0.52 + whoosh) * 0.85)
    return _normalize(_fade(_stereo_widen(mono, 8.5, 0.30), 6.0, 120.0), -2.0)


def gen_unlock_milestone() -> np.ndarray:
    t = _time(0.72)
    n = t.shape[0]
    out = np.zeros(n)
    for offset, freq, amp in [(0.00, 440.0, 0.55), (0.11, 587.33, 0.65), (0.22, 659.25, 0.80)]:
        pos = int(offset * SR)
        tt = np.arange(n - pos) / SR
        tone = (np.sin(2.0 * math.pi * freq * tt) * 0.65
                + np.sin(2.0 * math.pi * freq * 2.0 * tt) * 0.25
                + np.sin(2.0 * math.pi * freq * 3.0 * tt) * 0.10)
        out[pos:] += tone * np.exp(-tt / 0.22) * (1.0 - np.exp(-tt / 0.003)) * amp
    return _normalize(_fade(_stereo_widen(out, 5.5, 0.24), 2.0, 70.0), -3.5)


def gen_hit_confirm(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.13)
    n = t.shape[0]
    tick = (np.sin(2.0 * math.pi * 1950.0 * t) * 0.55
            + np.sin(2.0 * math.pi * 3350.0 * t) * 0.38) * np.exp(-t / 0.019)
    punch = _exp_sweep(t, 260.0, 95.0, 0.012) * np.exp(-t / 0.025) * 0.60
    snap = _fft_filter(rng.standard_normal(n), 1500.0, 6200.0) * np.exp(-t / 0.012) * 0.42
    mono = tick + punch + snap
    return _normalize(_fade(np.stack([mono, mono], axis=-1), 1.0, 15.0), -2.5)


def gen_giant_hurt(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.46)
    n = t.shape[0]
    thud = _exp_sweep(t, 120.0, 35.0, 0.065) * np.exp(-t / 0.17)
    slap = _fft_filter(rng.standard_normal(n), 300.0, 2600.0) * np.exp(-t / 0.04) * 0.72
    body = _fft_filter(_pink_noise(n, rng), 55.0, 240.0) * np.exp(-t / 0.19) * 0.58
    return _normalize(_fade(np.tanh(thud * 1.3 + slap + body), 2.0, 45.0), -2.0)


def gen_kill_confirm(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.68)
    n = t.shape[0]
    impact = _exp_sweep(t, 150.0, 48.0, 0.05) * np.exp(-t / 0.14) * 0.85
    n1 = (np.sin(2.0 * math.pi * 293.66 * t) * 0.65 + np.sin(2.0 * math.pi * 587.33 * t) * 0.30) * np.exp(-t / 0.18)
    p2 = int(0.10 * SR)
    n2 = np.zeros(n)
    tt = np.arange(n - p2) / SR
    n2[p2:] = (np.sin(2.0 * math.pi * 440.0 * tt) * 0.70
               + np.sin(2.0 * math.pi * 880.0 * tt) * 0.30
               + np.sin(2.0 * math.pi * 1320.0 * tt) * 0.10) * np.exp(-tt / 0.25)
    spark = _fft_filter(rng.standard_normal(n), 1800.0, 5800.0) * np.exp(-t / 0.03) * 0.24
    mono = np.tanh((impact + n1 * 0.6 + n2 * 0.75 + spark) * 0.9)
    return _normalize(_fade(_stereo_widen(mono, 5.5, 0.25), 2.0, 65.0), -2.5)


def gen_player_defeated(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.95)
    n = t.shape[0]
    boom = _exp_sweep(t, 92.0, 26.0, 0.22) * np.exp(-t / 0.42) * 1.15
    tone1 = np.sin(2.0 * math.pi * 293.66 * t) * np.exp(-t / 0.24) * 0.40
    p2 = int(0.18 * SR)
    tone2 = np.zeros(n)
    tt = np.arange(n - p2) / SR
    tone2[p2:] = (np.sin(2.0 * math.pi * 220.0 * tt) * 0.50
                  + np.sin(2.0 * math.pi * 110.0 * tt) * 0.45) * np.exp(-tt / 0.38)
    dust = _fft_filter(_pink_noise(n, rng), 60.0, 420.0) * np.exp(-t / 0.34) * 0.45
    mono = np.tanh((boom + tone1 + tone2 + dust) * 0.85)
    return _normalize(_fade(_stereo_widen(mono, 8.0, 0.25), 3.0, 95.0), -2.0)


def gen_respawn(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.62)
    n = t.shape[0]
    out = np.zeros(n)
    for offset, freq in [(0.00, 261.63), (0.09, 392.00), (0.18, 523.25)]:
        pos = int(offset * SR)
        tt = np.arange(n - pos) / SR
        out[pos:] += (np.sin(2.0 * math.pi * freq * tt) * 0.65
                      + np.sin(2.0 * math.pi * freq * 2.0 * tt) * 0.22) * np.exp(-tt / 0.20)
    air = _fft_filter(_pink_noise(n, rng), 350.0, 2200.0) * np.sin(math.pi * np.clip(t / 0.38, 0.0, 1.0)) * 0.22
    return _normalize(_fade(_stereo_widen(out + air, 6.0, 0.25), 4.0, 60.0), -3.5)


def gen_view_toggle(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.11)
    n = t.shape[0]
    click1 = _fft_filter(rng.standard_normal(n), 1400.0, 6200.0) * np.exp(-t / 0.009)
    p2 = int(0.028 * SR)
    click2 = np.zeros(n)
    tt = np.arange(n - p2) / SR
    click2[p2:] = _fft_filter(rng.standard_normal(n - p2), 1800.0, 7200.0) * np.exp(-tt / 0.011) * 0.72
    body = _exp_sweep(t, 420.0, 190.0, 0.01) * np.exp(-t / 0.018) * 0.45
    mono = click1 * 0.75 + click2 + body
    return _normalize(_fade(np.stack([mono, mono], axis=-1), 1.0, 12.0), -5.0)


# ---------------------------------------------------------------------------
# UI & Mode Outcome SFX (Stereo, crisp industrial switches & harbor horns)
# ---------------------------------------------------------------------------

def gen_ui_hover(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.048)
    n = t.shape[0]
    tick = np.sin(2.0 * math.pi * 1380.0 * t) * np.exp(-t / 0.008) * 0.55
    grit = _fft_filter(rng.standard_normal(n), 1100.0, 4200.0) * np.exp(-t / 0.007) * 0.45
    mono = tick + grit
    return _normalize(_fade(np.stack([mono, mono], axis=-1), 1.0, 8.0), -10.0)


def gen_ui_click(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.088)
    n = t.shape[0]
    detent = _exp_sweep(t, 640.0, 280.0, 0.012) * np.exp(-t / 0.020) * 0.75
    ping = np.sin(2.0 * math.pi * 1120.0 * t) * np.exp(-t / 0.024) * 0.42
    snap = _fft_filter(rng.standard_normal(n), 1200.0, 5200.0) * np.exp(-t / 0.009) * 0.48
    mono = detent + ping + snap
    return _normalize(_fade(np.stack([mono, mono], axis=-1), 1.0, 12.0), -5.0)


def gen_ui_back(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.105)
    n = t.shape[0]
    drop = _exp_sweep(t, 480.0, 210.0, 0.018) * np.exp(-t / 0.032) * 0.78
    snap = _fft_filter(rng.standard_normal(n), 900.0, 3800.0) * np.exp(-t / 0.010) * 0.40
    mono = drop + snap
    return _normalize(_fade(np.stack([mono, mono], axis=-1), 1.0, 14.0), -5.5)


def gen_ui_error() -> np.ndarray:
    t = _time(0.24)
    n = t.shape[0]
    out = np.zeros(n)
    for offset, freq in [(0.0, 185.0), (0.11, 148.0)]:
        pos = int(offset * SR)
        dur = min(int(0.085 * SR), n - pos)
        tt = np.arange(dur) / SR
        env = (1.0 - np.exp(-tt / 0.005)) * np.exp(-tt / 0.045)
        buzz = (np.sin(2.0 * math.pi * freq * tt) * 0.65
                + np.sin(2.0 * math.pi * freq * 2.0 * tt) * 0.30
                + np.sin(2.0 * math.pi * freq * 3.0 * tt) * 0.14) * env
        out[pos:pos + dur] += buzz
    return _normalize(_fade(np.stack([out, out], axis=-1), 2.0, 20.0), -5.0)


def gen_ui_pause(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.17)
    n = t.shape[0]
    n1 = np.sin(2.0 * math.pi * 520.0 * t) * np.exp(-t / 0.045) * 0.55
    p2 = int(0.045 * SR)
    n2 = np.zeros(n)
    tt = np.arange(n - p2) / SR
    n2[p2:] = np.sin(2.0 * math.pi * 340.0 * tt) * np.exp(-tt / 0.065) * 0.65
    click = _fft_filter(rng.standard_normal(n), 800.0, 3600.0) * np.exp(-t / 0.010) * 0.30
    mono = n1 + n2 + click
    return _normalize(_fade(np.stack([mono, mono], axis=-1), 1.5, 22.0), -5.0)


def gen_ui_resume(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(0.17)
    n = t.shape[0]
    n1 = np.sin(2.0 * math.pi * 360.0 * t) * np.exp(-t / 0.040) * 0.52
    p2 = int(0.045 * SR)
    n2 = np.zeros(n)
    tt = np.arange(n - p2) / SR
    n2[p2:] = np.sin(2.0 * math.pi * 540.0 * tt) * np.exp(-tt / 0.065) * 0.65
    click = _fft_filter(rng.standard_normal(n), 1100.0, 4400.0) * np.exp(-t / 0.010) * 0.30
    mono = n1 + n2 + click
    return _normalize(_fade(np.stack([mono, mono], axis=-1), 1.5, 22.0), -5.0)


def gen_evac_victory() -> np.ndarray:
    t = _time(2.15)
    n = t.shape[0]
    # Warm maritime clearance chord resolving upward (C3-G3-C4-E4-G4)
    out = np.zeros(n)
    notes = [
        (0.00, 261.63, 0.55, 0.55),
        (0.14, 329.63, 0.55, 0.65),
        (0.28, 392.00, 0.65, 0.85),
        (0.46, 523.25, 0.80, 1.15),
        (0.46, 130.81, 0.60, 1.25),
        (0.46, 196.00, 0.45, 1.15),
    ]
    for offset, freq, amp, decay in notes:
        pos = int(offset * SR)
        tt = np.arange(n - pos) / SR
        env = (1.0 - np.exp(-tt / 0.025)) * np.exp(-tt / decay)
        warm = (np.sin(2.0 * math.pi * freq * tt) * 0.68
                + np.sin(2.0 * math.pi * freq * 2.0 * tt) * 0.22
                + np.sin(2.0 * math.pi * freq * 3.0 * tt) * 0.08)
        out[pos:] += warm * env * amp
    out = _fft_filter(out, 50.0, 4800.0)
    return _normalize(_fade(_stereo_widen(out, 9.0, 0.30), 6.0, 260.0), -2.5)


def gen_evac_lost(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    t = _time(1.95)
    n = t.shape[0]
    # Distant ominous harbor foghorn + descending low impact
    env = (1.0 - np.exp(-t / 0.08)) * np.exp(-np.maximum(t - 0.55, 0.0) / 0.62)
    horn = np.zeros(n)
    for freq, amp in [(98.0, 0.65), (146.83, 0.32), (103.83, 0.24), (196.0, 0.20)]:
        detune = freq * (1.0 - 0.03 * (t / 1.95))
        phase = 2.0 * math.pi * np.cumsum(detune) / SR
        horn += (np.sin(phase) + 0.35 * np.sin(2.0 * phase) + 0.15 * np.sin(3.0 * phase)) * amp
    boom = _exp_sweep(t, 80.0, 28.0, 0.25) * np.exp(-t / 0.55) * 0.90
    air = _fft_filter(_pink_noise(n, rng), 80.0, 520.0) * env * 0.25
    mono = np.tanh((_fft_filter(horn * env, 45.0, 900.0) * 0.72 + boom + air) * 0.85)
    return _normalize(_fade(_stereo_widen(mono, 11.0, 0.32), 6.0, 280.0), -2.5)


# ---------------------------------------------------------------------------
# Seamless Looping Ambience Beds (16.0s exact periodic stereo OGG)
# ---------------------------------------------------------------------------

def gen_ambience_harbor(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    dur = 16.0
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    # Two decorrelated coastal wind + sea surf channels
    surf_l = _periodic_pink(n, rng, 70.0, 1450.0)
    surf_r = _periodic_pink(n, rng, 70.0, 1450.0)
    # Slow periodic ocean swell (integer cycle counts over 16s -> mathematically seamless)
    wave_l = 0.62 + 0.38 * (0.5 + 0.5 * np.sin(2.0 * math.pi * (2.0 / dur) * t)) \
             * (0.75 + 0.25 * np.sin(2.0 * math.pi * (3.0 / dur) * t + 0.8))
    wave_r = 0.62 + 0.38 * (0.5 + 0.5 * np.sin(2.0 * math.pi * (2.0 / dur) * t + 0.55)) \
             * (0.75 + 0.25 * np.sin(2.0 * math.pi * (3.0 / dur) * t + 1.9))
    breeze_l = _periodic_pink(n, rng, 260.0, 2600.0) * (0.20 + 0.10 * np.sin(2.0 * math.pi * (1.0 / dur) * t))
    breeze_r = _periodic_pink(n, rng, 260.0, 2600.0) * (0.20 + 0.10 * np.sin(2.0 * math.pi * (1.0 / dur) * t + 1.2))
    # Very faint distant port low air hum
    port_hum = _periodic_pink(n, rng, 34.0, 105.0) * 0.26
    left = surf_l * wave_l * 0.58 + breeze_l + port_hum
    right = surf_r * wave_r * 0.58 + breeze_r + port_hum
    stereo = np.stack([left, right], axis=-1)
    return _normalize(stereo, -10.5)


def gen_ambience_bedroom(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    dur = 16.0
    n = int(round(dur * SR))
    t = np.arange(n, dtype=np.float64) / SR
    # Warm soft indoor air tone + faint muffled outside breeze
    room_l = _periodic_pink(n, rng, 48.0, 420.0)
    room_r = _periodic_pink(n, rng, 48.0, 420.0)
    air_l = _periodic_pink(n, rng, 380.0, 1650.0) * (0.14 + 0.06 * np.sin(2.0 * math.pi * (1.0 / dur) * t))
    air_r = _periodic_pink(n, rng, 380.0, 1650.0) * (0.14 + 0.06 * np.sin(2.0 * math.pi * (1.0 / dur) * t + 1.4))
    left = room_l * 0.52 + air_l
    right = room_r * 0.52 + air_r
    stereo = np.stack([left, right], axis=-1)
    return _normalize(stereo, -14.0)


def gen_camera_shake(heavy: bool, seed: int) -> np.ndarray:
    """Deep seismic camera-shake rumble (Candidate A), stereo-widened."""
    rng = np.random.default_rng(seed)
    dur = 1.05 if heavy else 0.72
    t = _time(dur)
    n = t.shape[0]
    decay = 0.34 if heavy else 0.21
    env = (1.0 - np.exp(-t / 0.018)) * np.exp(-t / decay)
    flutter = 0.72 + 0.28 * np.sin(
        2.0 * math.pi * (16.5 if heavy else 19.0) * t
        + 0.4 * np.sin(2.0 * math.pi * 5.2 * t)
    )
    sub = _exp_sweep(t, 64.0 if heavy else 74.0, 29.0 if heavy else 36.0, 0.16) * env * flutter
    warm = (
        _exp_sweep(t, 128.0 if heavy else 142.0, 62.0 if heavy else 76.0, 0.14) * 0.42
        + np.sin(2.0 * math.pi * (96.0 if heavy else 112.0) * t) * 0.18
    ) * env * flutter
    earth = _fft_filter(_pink_noise(n, rng), 32.0, 185.0 if heavy else 210.0) * env * (1.05 if heavy else 0.85)
    pressure = _fft_filter(_pink_noise(n, rng), 140.0, 420.0) * env * (0.32 if heavy else 0.22) * flutter
    mono = np.tanh((sub * 1.35 + warm + earth + pressure) * (0.95 if heavy else 0.80))
    shift = int(0.008 * SR)
    delayed = np.zeros_like(mono)
    delayed[shift:] = mono[:-shift]
    side = _fft_filter(_pink_noise(n, rng), 55.0, 420.0) * np.abs(mono) * 0.18
    stereo = np.stack([mono + delayed * 0.14 + side, mono - delayed * 0.14 - side], axis=-1)
    return _normalize(_fade(stereo, 8.0, 95.0), -1.2 if heavy else -4.0)


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    wav_jobs: dict[str, np.ndarray] = {
        "giant_step_1.wav": gen_giant_step(101, 0),
        "giant_step_2.wav": gen_giant_step(102, 1),
        "giant_stomp_1.wav": gen_giant_stomp(201, 0),
        "giant_stomp_2.wav": gen_giant_stomp(202, 1),
        "stomp_warn.wav": gen_stomp_warn(210),
        "camera_shake_light.wav": gen_camera_shake(False, 801),
        "camera_shake_heavy.wav": gen_camera_shake(True, 802),
        "hand_whoosh.wav": gen_hand_whoosh(220),
        "hand_grab.wav": gen_hand_grab(221),
        "hand_punch.wav": gen_hand_punch(222),
        "hand_crush.wav": gen_hand_crush(223),
        "building_crack.wav": gen_building_crack(301),
        "building_collapse_1.wav": gen_building_collapse(302, 0),
        "building_collapse_2.wav": gen_building_collapse(303, 1),
        "barrier_break.wav": gen_barrier_break(304),
        "building_restore.wav": gen_building_restore(305),
        "human_step_1.wav": gen_human_step(401, 0),
        "human_step_2.wav": gen_human_step(402, 1),
        "human_hurt.wav": gen_human_hurt(403),
        "human_defeat.wav": gen_human_defeat(404),
        "stamina_empty.wav": gen_stamina_empty(405),
        "bedroom_step_1.wav": gen_bedroom_step(411, 0),
        "bedroom_step_2.wav": gen_bedroom_step(412, 1),
        "bedroom_climb.wav": gen_bedroom_climb(413),
        "bedroom_mantle.wav": gen_bedroom_mantle(414),
        "coin_pickup.wav": gen_coin_pickup(501),
        "coin_drop.wav": gen_coin_drop(502),
        "growth_surge.wav": gen_growth_surge(503),
        "transform_giant.wav": gen_transform_giant(504),
        "unlock_milestone.wav": gen_unlock_milestone(),
        "hit_confirm.wav": gen_hit_confirm(506),
        "giant_hurt.wav": gen_giant_hurt(507),
        "kill_confirm.wav": gen_kill_confirm(508),
        "player_defeated.wav": gen_player_defeated(509),
        "respawn.wav": gen_respawn(510),
        "view_toggle.wav": gen_view_toggle(511),
        "ui_hover.wav": gen_ui_hover(601),
        "ui_click.wav": gen_ui_click(602),
        "ui_back.wav": gen_ui_back(603),
        "ui_error.wav": gen_ui_error(),
        "ui_pause.wav": gen_ui_pause(605),
        "ui_resume.wav": gen_ui_resume(606),
        "evac_victory.wav": gen_evac_victory(),
        "evac_lost.wav": gen_evac_lost(608),
    }
    ogg_jobs: dict[str, np.ndarray] = {
        "ambience_harbor.ogg": gen_ambience_harbor(701),
        "ambience_bedroom.ogg": gen_ambience_bedroom(702),
    }

    total_bytes = 0
    for name, sig in wav_jobs.items():
        path = OUT_DIR / name
        _write_wav(path, sig)
        size = path.stat().st_size
        total_bytes += size
        ch = 1 if sig.ndim == 1 else sig.shape[1]
        peak = float(np.max(np.abs(sig)))
        print(f"WAV  {name:26s}  {sig.shape[0]/SR:5.2f}s  {ch}ch  peak={peak:.3f}  {size/1024:6.1f} KB")

    for name, sig in ogg_jobs.items():
        path = OUT_DIR / name
        _write_ogg(path, sig, quality=4.5)
        size = path.stat().st_size
        total_bytes += size
        ch = 1 if sig.ndim == 1 else sig.shape[1]
        peak = float(np.max(np.abs(sig)))
        print(f"OGG  {name:26s}  {sig.shape[0]/SR:5.2f}s  {ch}ch  peak={peak:.3f}  {size/1024:6.1f} KB")

    print(f"Generated {len(wav_jobs)} WAV + {len(ogg_jobs)} OGG files ({total_bytes / 1024 / 1024:.2f} MB total)")


if __name__ == "__main__":
    main()
