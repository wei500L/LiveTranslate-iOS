#!/usr/bin/env python3
"""Generate golden fixtures for the GigaAM-v3 Core ML contract tests.

Produces, for each test WAV:
  * `<name>.wav`            — 16 kHz mono s16 Russian speech (macOS `say`,
                              license: locally synthesized, no third-party
                              audio content)
  * `<name>.logmel.f32`     — golden log-mel features, float32, [64 x frames]
                              (mel-major, frame-minor — matches the encoder's
                              [1, 64, 2999] MLMultiArray row layout; only the
                              real frames are stored, the zero-padding tail is
                              the constant log(1e-9))
  * `<name>.meta.json`      — sample count, frame count, mel parameters,
                              SHA256 of wav + features, expected encoder
                              length, PyTorch reference token ids and text

The PyTorch reference runs the real ai-sage/GigaAM-v3 checkpoint from the
local HF cache (read-only) with the same greedy RNN-T loop the Swift
GigaAMRNNTDecoder implements.

Usage:
    <venv-python> scripts/generate_coreml_golden_fixtures.py \
        [--output-dir LiveTranslateIOSTests/Fixtures] [--skip-torch]

`--skip-torch` regenerates audio + log-mel only (fast path for DSP work).

Idempotent: WAVs are regenerated from `say` on every run so the fixtures stay
reproducible; feature/JSON files are overwritten.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import pathlib
import struct
import subprocess
import sys
import wave

# --- contract constants (must match GigaAMLogMelExtractor + the conversion) ---
SR = 16_000
N_FFT = 320
WIN_LENGTH = 320
HOP_LENGTH = 160
N_MELS = 64
MEL_SCALE = "htk"
NORM = None
CENTER = False
WINDOW_SECONDS = 30
MAX_SAMPLES = WINDOW_SECONDS * SR  # 480_000
CLAMP_MIN = 1e-9
CLAMP_MAX = 1e9

# The locally cached PyTorch checkpoint (ai-sage/GigaAM-v3 @ e2e_rnnt),
# read-only. Resolved relative to this repository's documented reference
# project location; overridable with --model-dir.
DEFAULT_MODEL_DIR = "/Users/oo/project/LiveTranslate/models/huggingface/hub/models--ai-sage--GigaAM-v3/snapshots"

SAMPLES = [
    # (name, russian sentence, max_seconds) — classroom-flavored speech
    (
        "test_ru_long",
        "Добрый день, коллеги. Сегодня мы продолжаем курс математического "
        "анализа. На прошлой лекции мы доказали теорему о промежуточном "
        "значении непрерывной функции. Сегодня мы рассмотрим производную "
        "сложной функции и её геометрический смысл. Напомню, что домашнее "
        "задание номер пять нужно сдать до пятницы.",
        None,
    ),
    (
        "test_ru_short",
        "Здравствуйте, меня зовут профессор Иванов.",
        None,
    ),
    (
        "test_ru_35s",
        "Сегодня мы начинаем изучение линейной алгебры. Матрица это "
        "прямоугольная таблица чисел, расположенных в строках и столбцах. "
        "Определитель квадратной матрицы вычисляется разложением по первой "
        "строке. Обратная матрица существует тогда и только тогда, когда "
        "определитель не равен нулю. Ранг матрицы это максимальное число "
        "линейно независимых строк. Собственные значения находятся из "
        "характеристического уравнения. На семинаре мы решим задачи номер "
        "один, два и три. Контрольная работа назначена на следующую неделю.",
        None,
    ),
]

MEL_PARAMS = {
    "sample_rate": SR,
    "n_fft": N_FFT,
    "win_length": WIN_LENGTH,
    "hop_length": HOP_LENGTH,
    "n_mels": N_MELS,
    "mel_scale": MEL_SCALE,
    "norm": NORM,
    "center": CENTER,
    "power": 2.0,
    "window": "hann (periodic)",
    "log_clamp": [CLAMP_MIN, CLAMP_MAX],
}


def sha256_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def generate_wav(name: str, text: str, out_dir: pathlib.Path) -> pathlib.Path:
    """Synthesize 16 kHz mono s16 Russian speech with the macOS `say` voice."""
    raw = out_dir / f"{name}_raw.wav"
    final = out_dir / f"{name}.wav"
    subprocess.run(
        ["say", "-v", "Milena", "-o", str(raw), "--data-format=LEI16@16000", text],
        check=True,
    )
    # `say` may still emit a different container/rate; normalize with ffmpeg.
    ffmpeg = "/opt/homebrew/bin/ffmpeg"
    cmd = [ffmpeg, "-y", "-v", "error", "-i", str(raw),
           "-ar", str(SR), "-ac", "1", "-c:a", "pcm_s16le"]
    cmd += [str(final)]
    subprocess.run(cmd, check=True)
    raw.unlink(missing_ok=True)
    return final


def read_wav(path: pathlib.Path) -> list[float]:
    with wave.open(str(path), "rb") as wav:
        assert wav.getnchannels() == 1, "expected mono"
        assert wav.getframerate() == SR, "expected 16 kHz"
        assert wav.getsampwidth() == 2, "expected s16"
        frames = wav.readframes(wav.getnframes())
    ints = struct.unpack(f"<{len(frames) // 2}h", frames)
    return [v / 32768.0 for v in ints]


def frame_count(n_samples: int) -> int:
    """Frames reported in the encoder `length` input (out_len formula)."""
    if n_samples < WIN_LENGTH:
        return 1
    return (n_samples - WIN_LENGTH) // HOP_LENGTH + 1


def computed_frame_count(n_samples: int) -> int:
    """Frames of the padded 30 s window that overlap real audio.

    Frame f covers [f*hop, f*hop + win); it carries signal whenever
    f*hop < n. The reference computes mel over the FULL zero-padded window,
    so these boundary frames (1-2 past `frame_count`) hold real content and
    must match byte-for-byte, even though the encoder masks at `length`.
    """
    return min((MAX_SAMPLES - WIN_LENGTH) // HOP_LENGTH + 1,
               (n_samples + HOP_LENGTH - 1) // HOP_LENGTH)


def golden_logmel(samples: list[float]):
    """Reference log-mel exactly as the Core ML conversion computed it."""
    import torch
    import torchaudio

    n = min(len(samples), MAX_SAMPLES)
    frames = frame_count(n)
    computed = computed_frame_count(n)

    mel = torchaudio.transforms.MelSpectrogram(
        sample_rate=SR, n_mels=N_MELS, win_length=WIN_LENGTH,
        hop_length=HOP_LENGTH, n_fft=N_FFT, center=CENTER,
        mel_scale=MEL_SCALE, norm=NORM,
    )
    padded = torch.zeros(1, MAX_SAMPLES)
    padded[0, :n] = torch.tensor(samples[:n], dtype=torch.float32)
    feats = mel(padded).clamp(CLAMP_MIN, CLAMP_MAX).log()[0]  # [64, 2999]
    assert feats.shape == (N_MELS, (MAX_SAMPLES - WIN_LENGTH) // HOP_LENGTH + 1)
    assert feats.shape[1] == 2999
    # Sanity: frames with no audio overlap are exactly log(1e-9).
    tail = feats[:, computed:]
    if tail.numel():
        assert torch.allclose(tail, torch.full_like(tail, math.log(CLAMP_MIN))), \
            "no-overlap tail is not log(1e-9)"
    return feats[:, :computed].numpy().astype("float32"), n, frames, computed


def pytorch_reference(model, wav_path: pathlib.Path):
    """Run the real GigaAM-v3 greedy RNN-T and capture ids + text.

    Mirrors modeling_gigaam.RNNTGreedyDecoding._greedy_decode exactly.
    """
    import torch

    asr = model.model  # GigaAMASR
    with torch.inference_mode():
        wav, length = asr.prepare_wav(str(wav_path))
        # NOTE: prepare_wav loads the FULL file; the caller passes a
        # pre-truncated wav for >30 s sources (the Core ML window).
        encoded, encoded_len = asr.forward(wav, length)

        head = asr.head
        blank_id = asr.decoding.blank_id
        max_symbols = asr.decoding.max_symbols

        hyp: list[int] = []
        dec_state = None
        last_label = None
        inseq = encoded.transpose(1, 2)[0].unsqueeze(1)  # [T, 1, 768]
        for t in range(int(encoded_len[0])):
            f = inseq[t, :, :].unsqueeze(1)
            not_blank = True
            new_symbols = 0
            while not_blank and new_symbols < max_symbols:
                g, hidden = head.decoder.predict(last_label, dec_state)
                k = head.joint.joint(f, g)[0, 0, 0, :].argmax(0).item()
                if k == blank_id:
                    not_blank = False
                else:
                    hyp.append(int(k))
                    dec_state = hidden
                    last_label = torch.tensor([[hyp[-1]]]).to(encoded.device)
                    new_symbols += 1

        text = asr.decoding.tokenizer.decode(hyp)
        # Cross-check the instrumented loop against the model's own path —
        # only available below the 25 s longform threshold.
        longform_threshold = 25 * 16000
        if wav.shape[-1] <= longform_threshold:
            reference_text = asr.transcribe(str(wav_path))
            matches = text == reference_text
        else:
            reference_text = None
            matches = None
        return {
            "token_ids": hyp,
            "text": text,
            "transcribe_text": reference_text,
            "encoded_len": int(encoded_len[0]),
            "loop_matches_transcribe": matches,
        }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    here = pathlib.Path(__file__).resolve().parent.parent
    parser.add_argument(
        "--output-dir", type=pathlib.Path,
        default=here / "LiveTranslateIOSTests" / "Fixtures",
    )
    parser.add_argument("--model-dir", type=pathlib.Path,
                        default=pathlib.Path(DEFAULT_MODEL_DIR))
    parser.add_argument("--skip-torch", action="store_true",
                        help="regenerate audio + log-mel only")
    args = parser.parse_args()

    # Keep every cache/write strictly inside this project; the reference
    # project directory is read-only.
    args.output_dir.mkdir(parents=True, exist_ok=True)
    hf_cache = args.output_dir / ".hf-cache"
    hf_cache.mkdir(exist_ok=True)
    os.environ.setdefault("HF_HOME", str(hf_cache))
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("PATH", "/opt/homebrew/bin:" + os.environ.get("PATH", ""))

    model = None
    if not args.skip_torch:
        import torch
        from transformers import AutoModel

        snapshots = sorted(args.model_dir.glob("*/"))
        if not snapshots:
            print(f"No GigaAM-v3 snapshot under {args.model_dir}", file=sys.stderr)
            return 1
        model_dir = snapshots[-1]
        print(f"Loading PyTorch reference from {model_dir} ...")
        model = AutoModel.from_pretrained(str(model_dir), trust_remote_code=True)
        model.eval()
        print("Model loaded.")

    for name, text, _max in SAMPLES:
        wav = generate_wav(name, text, args.output_dir)
        samples = read_wav(wav)
        truncated = len(samples) > MAX_SAMPLES
        if truncated:
            # Mirror the Core ML 30 s window: truncate, then the extractor
            # pads back to 480k with zeros.
            truncated_path = args.output_dir / f"{name}_trunc30s.wav"
            with wave.open(str(wav), "rb") as src, \
                 wave.open(str(truncated_path), "wb") as dst:
                dst.setnchannels(1)
                dst.setsampwidth(2)
                dst.setframerate(SR)
                dst.writeframes(src.readframes(MAX_SAMPLES))
            reference_wav = truncated_path
            samples = samples[:MAX_SAMPLES]
        else:
            reference_wav = wav

        feats, n, frames, computed = golden_logmel(samples)
        feats_path = args.output_dir / f"{name}.logmel.f32"
        feats.tofile(feats_path)  # [64, computed] row-major

        meta = {
            "name": name,
            "wav": wav.name if not truncated else reference_wav.name,
            "wav_sha256": sha256_file(reference_wav),
            "n_samples": n,
            "frames": frames,
            "computed_frames": computed,
            "truncated_to_30s": truncated,
            "mel_params": MEL_PARAMS,
            "features_file": feats_path.name,
            "features_sha256": sha256_file(feats_path),
            "features_dtype": "float32",
            "features_layout": "[n_mels, computed_frames] row-major; columns >= computed_frames are the constant log(1e-9)",
            "padding_value": math.log(CLAMP_MIN),
        }

        if model is not None:
            ref = pytorch_reference(model, reference_wav)
            meta["pytorch"] = ref
            print(f"  {name}: frames={frames} enc_len={ref['encoded_len']} "
                  f"tokens={len(ref['token_ids'])} "
                  f"loop_matches_transcribe={ref['loop_matches_transcribe']}")
            print(f"    text: {ref['text']}")

        meta_path = args.output_dir / f"{name}.meta.json"
        meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2))
        print(f"  wrote {meta_path.name} ({n} samples, {frames} frames)")

    # The .hf-cache is scratch; remove it so the fixtures dir stays clean.
    import shutil
    shutil.rmtree(hf_cache, ignore_errors=True)
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
