#!/usr/bin/env python3
"""Noise-floor analysis for the golden log-mel fixtures.

Question: is the Swift-vs-golden residual (~1e-3 in low-energy high mel bins)
my DSP error, or the float32 reference's own noise?

Method: recompute the features in numpy float64 (ground truth, same formula),
then measure:
  A. |torchaudio float32 golden  -  float64 truth|   (reference noise floor)
  B. |Swift extractor output      -  float64 truth|   (my actual error)

If B << A and A matches the Swift-vs-golden residual in magnitude and bins,
then the 1e-4 threshold sat below the reference's own representational noise
and the Swift implementation is the more accurate of the two.

Usage:
    <venv-python> scripts/analyze_golden_noise_floor.py \
        <fixtures-dir> <swift-dump-dir>

The Swift dumps (`<name>.swiftout.f32`, [64, computed] row-major) are produced
by /tmp/gigaam_fixtures/dump.swift against the same WAVs.
"""
from __future__ import annotations

import json
import pathlib
import sys
import wave

import numpy as np

SR, N_FFT, WIN, HOP, N_MELS = 16_000, 320, 320, 160, 64
N_FREQ = N_FFT // 2 + 1
MAX_SAMPLES = 480_000
MAX_FRAMES = (MAX_SAMPLES - WIN) // HOP + 1


def read_wav(path: pathlib.Path) -> np.ndarray:
    with wave.open(str(path), "rb") as w:
        assert w.getnchannels() == 1 and w.getframerate() == SR
        assert w.getsampwidth() == 2
        raw = w.readframes(w.getnframes())
    ints = np.frombuffer(raw, dtype="<i2")
    return ints.astype(np.float64) / 32768.0


def computed_frame_count(n: int) -> int:
    return min(MAX_FRAMES, (n + HOP - 1) // HOP)


def float64_truth(samples: np.ndarray) -> np.ndarray:
    """Exact log-mel in float64 — same contract, no float32 roundings."""
    import torchaudio

    n = min(len(samples), MAX_SAMPLES)
    computed = computed_frame_count(n)

    x = np.zeros(MAX_SAMPLES)
    x[:n] = samples[:n]

    hann = 0.5 * (1.0 - np.cos(2.0 * np.pi * np.arange(WIN) / WIN))  # periodic
    frames = np.stack([x[f:f + WIN] for f in range(0, computed * HOP, HOP)]) * hann
    spec = np.fft.rfft(frames, n=N_FFT, axis=1)                    # float64
    power = (spec.real ** 2 + spec.imag ** 2).T                    # [161, F]

    # torchaudio's own HTK filterbank, cast up to float64 (weights are smooth;
    # the float32 cast contributes ~1e-7 relative — negligible vs FFT noise)
    fb = torchaudio.functional.melscale_fbanks(
        n_freqs=N_FREQ, f_min=0.0, f_max=SR / 2, n_mels=N_MELS,
        sample_rate=SR, norm=None, mel_scale="htk",
    ).numpy().astype(np.float64)                                   # [161, 64]
    mel = fb.T @ power                                             # [64, F]
    return np.log(np.clip(mel, 1e-9, 1e9))                         # [64, F]


def stats(diff: np.ndarray) -> str:
    return (f"max={diff.max():.6e} mean={diff.mean():.3e} "
            f">1e-4: {(diff > 1e-4).sum()}/{diff.size} "
            f"(worst mel bin: {int(np.unravel_index(diff.argmax(), diff.shape)[0])})")


def main() -> int:
    fixtures = pathlib.Path(sys.argv[1])
    swift_dir = pathlib.Path(sys.argv[2])

    for meta_path in sorted(fixtures.glob("*.meta.json")):
        meta = json.loads(meta_path.read_text())
        name = meta["name"]
        computed = meta["computed_frames"]

        samples = read_wav(fixtures / meta["wav"])
        golden = np.fromfile(fixtures / f"{name}.logmel.f32", dtype="<f4") \
            .reshape(N_MELS, computed).astype(np.float64)
        truth = float64_truth(samples)
        swift = np.fromfile(swift_dir / f"{name}.swiftout.f32", dtype="<f4") \
            .reshape(N_MELS, computed).astype(np.float64)

        print(f"{name}: computed_frames={computed}")
        print(f"  A. golden(f32) vs truth(f64): {stats(np.abs(golden - truth))}")
        print(f"  B. swift      vs truth(f64): {stats(np.abs(swift - truth))}")
        print(f"  C. swift      vs golden(f32): {stats(np.abs(swift - golden))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
