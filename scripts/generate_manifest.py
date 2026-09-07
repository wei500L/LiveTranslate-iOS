#!/usr/bin/env python3
"""Generate Resources/ModelManifest.json from actually-downloaded model files.

Every SHA256 in the manifest is measured from a real file on disk — never
guessed or copied from a listing. Both Hugging Face repos are pinned to
immutable commit SHAs (resolved via the HF API), never a moving branch.

Usage:
    python3 scripts/generate_manifest.py [--models-dir LocalModels] [--output Resources/ModelManifest.json]

The models directory defaults to LocalModels/ (git-ignored) so the script
can run either at repo root or from an adjacent checkout.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys

# ---------------------------------------------------------------------------
# Pinned revisions (immutable commit SHAs, resolved from the HF API —
# deliberately NOT "main").
# ---------------------------------------------------------------------------
COREML_REPO = "smkrv/gigaam-v3-e2e-rnnt-coreml"
COREML_REVISION = "846833ef075fde2a8e50521d093ddb9ed7b7fd45"

SHERPA_REPO = "Alexxerm/gigaam-v3-e2e-rnnt-sherpa-onnx"
SHERPA_REVISION = "c0acd38c8aeb2bdc04da221bd661ffcdb9645f7d"

SHERPA_ONNX_RUNTIME_VERSION = "1.13.7"
SILERO_VAD_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"

# ---------------------------------------------------------------------------
# On-device AI models (offline translation GGUFs + image-understanding
# LiteRT-LM). Same pinned-revision + measured-SHA256 discipline.
# ---------------------------------------------------------------------------

# tencent/Hy-MT2-1.8B-GGUF — default offline ru→zh-CN translation model.
HYMT2_REPO = "tencent/Hy-MT2-1.8B-GGUF"
HYMT2_REVISION = "1cd5208700acedef4ef93019b6cfc148b8522d45"
HYMT2_FILES = [
    # (path, expected_bytes) — authoritative sizes from the HF API; a
    # truncated download fails the assertion instead of hashing quietly.
    ("Hy-MT2-1.8B-Q4_K_M.gguf", 1_133_080_448),
]

# xiaomi-research/MiLMMT-46-1B-v1.0 via mradermacher static quant — the
# battery-saver offline translation model.
MILMMT_REPO = "mradermacher/MiLMMT-46-1B-v1.0-GGUF"
MILMMT_REVISION = "34df5efbe6592773ec168cc7b307728c08623472"
MILMMT_FILES = [
    ("MiLMMT-46-1B-v1.0.Q4_K_M.gguf", 806_057_408),
]

# litert-community/gemma-4-E2B-it-litert-lm — image understanding model
# (LiteRT-LM runtime format).
GEMMA_REPO = "litert-community/gemma-4-E2B-it-litert-lm"
GEMMA_REVISION = "b3ca0d2f076785a8f4b2219ddbd2bdb99954eae1"
GEMMA_FILES = [
    ("gemma-4-E2B-it.litertlm", 2_588_147_712),
]

# Disk-space budgets (bytes): download + staging margin.
HYMT2_MIN_FREE = 1_400_000_000
MILMMT_MIN_FREE = 1_000_000_000
GEMMA_MIN_FREE = 3_100_000_000

# Local checkout subdirectories (git-ignored).
HYMT2_LOCAL_PREFIX = "hy-mt2-1.8b"
MILMMT_LOCAL_PREFIX = "milmmt-46-1b"
GEMMA_LOCAL_PREFIX = "gemma-4-e2b"

# Compiled-cache version: bump whenever the Core ML loading contract changes
# in a way that requires recompilation (SDK migration, model contract change).
COREML_COMPILED_CACHE_VERSION = 1

# ---------------------------------------------------------------------------
# File inventories. Paths are relative to the backend install root
# (Application Support/Models/gigaam-v3-e2e-rnnt/<backend-key>/).
# Sizes come from the HF repo listing and are enforced on the local files.
# ---------------------------------------------------------------------------

# Core ML: .mlpackage is a directory; every leaf file is listed individually
# so the runtime can rebuild the tree file-by-file and verify each hash.
COREML_FILES = [
    # (path, expected_bytes)
    ("Source/GigaAMv3Encoder.mlpackage/Manifest.json", 617),
    ("Source/GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel", 419364),
    ("Source/GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 441545792),
    ("Source/GigaAMv3DecoderStep.mlpackage/Manifest.json", 617),
    ("Source/GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel", 7367),
    ("Source/GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 2297280),
    ("Source/GigaAMv3JointStep.mlpackage/Manifest.json", 617),
    ("Source/GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel", 2916),
    ("Source/GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin", 1356098),
    ("Metadata/tokens.json", 12406),
    ("Metadata/tokenizer.model", 255336),
    ("Metadata/model_info.json", 248),
    ("Metadata/convert_info.json", 38),
    ("Metadata/v3_e2e_rnnt.yaml", 1039),
    ("Metadata/README.md", 8164),
    ("Metadata/example_infer.py", 2768),
]

SHERPA_FILES = [
    ("encoder.int8.onnx", 224571327),
    ("decoder.onnx", 1159351),
    ("joiner.onnx", 687791),
    ("tokens.txt", 13354),
    ("config.yaml", 1041),
]

SILERO_VAD_BYTES = 643854

# Disk-space budgets (bytes).
# Core ML staging: source (~446 MB) + compiled copy (~450 MB) + temp files
# during compilation + safety margin — NOT just the 425 MB download.
COREML_MIN_FREE = 1_300_000_000
SHERPA_MIN_FREE = 520_000_000

# The local checkout mirrors the runtime layout under the backend root, plus
# a top-level silero_vad.onnx for the VAD layer.
COREML_LOCAL_PREFIX = "coreml-fp16"
SHERPA_LOCAL_PREFIX = "sherpa-onnx-int8"
SILERO_VAD_LOCAL = "silero_vad.onnx"


def sha256_of(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            block = fh.read(1 << 20)  # 1 MiB
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def build_file_entries(
    files: list[tuple[str, int]],
    repo: str,
    revision: str,
    local_dir: pathlib.Path,
    local_prefix: str,
) -> list[dict]:
    entries = []
    for rel_path, expected_bytes in files:
        # Local download tree mirrors the runtime layout below the prefix.
        local_path = local_dir / local_prefix / rel_path
        if not local_path.is_file():
            sys.exit(
                f"ERROR: missing {local_path} — run scripts/prepare_models.sh first"
            )
        actual_bytes = local_path.stat().st_size
        if expected_bytes is not None and actual_bytes != expected_bytes:
            sys.exit(
                f"ERROR: {local_path} is {actual_bytes} bytes, expected "
                f"{expected_bytes}. Re-download with scripts/prepare_models.sh."
            )
        # URL-encode nothing here: HF paths contain no spaces or non-ASCII
        # characters (verified against the repo tree).
        url = f"https://huggingface.co/{repo}/resolve/{revision}/{urllib_escape(rel_path, local_prefix)}"
        entries.append(
            {
                "path": rel_path,
                "url": url,
                "bytes": actual_bytes,
                "sha256": sha256_of(local_path),
            }
        )
    return entries


def urllib_escape(rel_path: str, local_prefix: str) -> str:
    """Map an install-relative path back to its HF repo path.

    Core ML repo paths keep their root names (GigaAMv3Encoder.mlpackage/...,
    tokens.json, ...) while the install tree adds Source/ and Metadata/
    prefixes; the sherpa repo is flat.
    """
    if local_prefix == COREML_LOCAL_PREFIX:
        if rel_path.startswith("Source/"):
            return rel_path[len("Source/"):]
        if rel_path.startswith("Metadata/"):
            return rel_path[len("Metadata/"):]
        return rel_path
    return rel_path


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--models-dir",
        default="LocalModels",
        help="Directory holding the downloaded model files (default: LocalModels)",
    )
    parser.add_argument(
        "--output",
        default="Resources/ModelManifest.json",
        help="Output manifest path (default: Resources/ModelManifest.json)",
    )
    args = parser.parse_args()

    local_dir = pathlib.Path(args.models_dir)
    if not local_dir.is_dir():
        sys.exit(f"ERROR: models directory not found: {local_dir}")

    coreml_entries = build_file_entries(
        COREML_FILES, COREML_REPO, COREML_REVISION, local_dir, COREML_LOCAL_PREFIX
    )
    sherpa_entries = build_file_entries(
        SHERPA_FILES, SHERPA_REPO, SHERPA_REVISION, local_dir, SHERPA_LOCAL_PREFIX
    )
    # On-device AI models: measured from the real downloads (prepare via
    # scripts/prepare_models.sh or a direct curl into LocalModels/).
    hymt2_entries = build_file_entries(
        HYMT2_FILES, HYMT2_REPO, HYMT2_REVISION, local_dir, HYMT2_LOCAL_PREFIX
    )
    milmmt_entries = build_file_entries(
        MILMMT_FILES, MILMMT_REPO, MILMMT_REVISION, local_dir, MILMMT_LOCAL_PREFIX
    )
    gemma_entries = build_file_entries(
        GEMMA_FILES, GEMMA_REPO, GEMMA_REVISION, local_dir, GEMMA_LOCAL_PREFIX
    )

    vad_local = local_dir / SILERO_VAD_LOCAL
    if not vad_local.is_file():
        sys.exit(f"ERROR: missing {vad_local} — run scripts/prepare_models.sh first")
    if vad_local.stat().st_size != SILERO_VAD_BYTES:
        sys.exit(
            f"ERROR: {vad_local} is {vad_local.stat().st_size} bytes, "
            f"expected {SILERO_VAD_BYTES}"
        )

    coreml_total = sum(e["bytes"] for e in coreml_entries)
    sherpa_total = sum(e["bytes"] for e in sherpa_entries)

    def ai_model_entry(
        key: str, repo: str, revision: str, files: list[dict],
        min_free: int, license: str
    ) -> dict:
        total = sum(e["bytes"] for e in files)
        return {
            "id": key,
            "kind": key,
            "repo": repo,
            "revision": revision,
            "files": files,
            "totalDownloadBytes": total,
            "installedBytes": total,
            # Staging: the .partial sibling during download (the old
            # partial is banked on resume).
            "stagingBytes": total,
            "minimumFreeDiskBytes": min_free,
            "license": license,
        }

    hymt2_total = sum(e["bytes"] for e in hymt2_entries)
    milmmt_total = sum(e["bytes"] for e in milmmt_entries)
    gemma_total = sum(e["bytes"] for e in gemma_entries)

    manifest = {
        "schemaVersion": 2,
        "model": {
            "id": "gigaam-v3-e2e-rnnt",
            "name": "GigaAM-v3 e2e_rnnt",
            "revision": "e2e_rnnt",
            "language": "ru",
            "license": "MIT",
            "upstreamRepo": "ai-sage/GigaAM-v3",
        },
        "backends": {
            "coreml-fp16": {
                "id": "coreml-fp16",
                "kind": "coreMLFP16",
                "repo": COREML_REPO,
                "revision": COREML_REVISION,
                "files": coreml_entries,
                "totalDownloadBytes": coreml_total,
                # Install size = source + metadata; the compiled cache adds
                # roughly the same again but lives in stagingBytes accounting.
                "installedBytes": coreml_total,
                "stagingBytes": coreml_total + 500_000_000,
                "minimumFreeDiskBytes": COREML_MIN_FREE,
                "license": "MIT",
                "coreMLCompiledCacheVersion": COREML_COMPILED_CACHE_VERSION,
            },
            "sherpa-onnx-int8": {
                "id": "sherpa-onnx-int8",
                "kind": "sherpaONNXInt8",
                "repo": SHERPA_REPO,
                "revision": SHERPA_REVISION,
                "files": sherpa_entries,
                "totalDownloadBytes": sherpa_total,
                "installedBytes": sherpa_total,
                "stagingBytes": 30_000_000,
                "minimumFreeDiskBytes": SHERPA_MIN_FREE,
                "license": "MIT",
            },
        },
        "runtime": {
            "sherpaOnnxVersion": SHERPA_ONNX_RUNTIME_VERSION,
            "sileroVAD": {
                "url": SILERO_VAD_URL,
                "bytes": vad_local.stat().st_size,
                "sha256": sha256_of(vad_local),
            },
        },
        "aiModels": {
            "hy-mt2-1.8b-q4km": ai_model_entry(
                "hy-mt2-1.8b-q4km", HYMT2_REPO, HYMT2_REVISION,
                hymt2_entries, HYMT2_MIN_FREE, "Apache-2.0"
            ),
            "milmmt-46-1b-q4km": ai_model_entry(
                "milmmt-46-1b-q4km", MILMMT_REPO, MILMMT_REVISION,
                milmmt_entries, MILMMT_MIN_FREE, "gemma"
            ),
            "gemma-4-e2b-it": ai_model_entry(
                "gemma-4-e2b-it", GEMMA_REPO, GEMMA_REVISION,
                gemma_entries, GEMMA_MIN_FREE, "Apache-2.0"
            ),
        },
    }

    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")

    print(f"Wrote {output}")
    print(f"  Core ML FP16 : {len(coreml_entries)} files, {coreml_total:,} bytes")
    print(f"  sherpa INT8  : {len(sherpa_entries)} files, {sherpa_total:,} bytes")
    print(f"  Hy-MT2 Q4_K_M    : {len(hymt2_entries)} files, {hymt2_total:,} bytes")
    print(f"  MiLMMT Q4_K_M    : {len(milmmt_entries)} files, {milmmt_total:,} bytes")
    print(f"  Gemma E2B litertlm: {len(gemma_entries)} files, {gemma_total:,} bytes")
    for entry in coreml_entries + sherpa_entries + hymt2_entries + milmmt_entries + gemma_entries:
        print(f"    {entry['sha256'][:12]}  {entry['bytes']:>12,}  {entry['path']}")
    print(f"  silero VAD   : {manifest['runtime']['sileroVAD']['sha256'][:12]}  "
          f"{manifest['runtime']['sileroVAD']['bytes']:,} bytes")


if __name__ == "__main__":
    main()
