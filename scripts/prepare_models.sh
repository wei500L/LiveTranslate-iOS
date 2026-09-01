#!/usr/bin/env bash
# Development-mode model preparation.
#
# Downloads every model file for both backends from their *pinned* HF
# revisions (immutable commit SHAs — never "main") into the git-ignored
# LocalModels/ directory, verifies sizes, then generates
# Resources/ModelManifest.json with measured SHA256 hashes.
#
# Idempotent: re-running resumes interrupted downloads (curl -C -) and
# skips files that already have the right size. No model file is ever
# committed to git (see .gitignore).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODELS_DIR="${MODELS_DIR:-$ROOT/LocalModels}"
cd "$ROOT"

COREML_REPO="smkrv/gigaam-v3-e2e-rnnt-coreml"
COREML_REV="846833ef075fde2a8e50521d093ddb9ed7b7fd45"

SHERPA_REPO="Alexxerm/gigaam-v3-e2e-rnnt-sherpa-onnx"
SHERPA_REV="c0acd38c8aeb2bdc04da221bd661ffcdb9645f7d"

SILERO_VAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
SILERO_VAD_BYTES=643854

# path|bytes — Core ML repo layout (leaf files of the .mlpackage trees).
COREML_FILES=(
  "GigaAMv3Encoder.mlpackage/Manifest.json|617"
  "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel|419364"
  "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin|441545792"
  "GigaAMv3DecoderStep.mlpackage/Manifest.json|617"
  "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel|7367"
  "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin|2297280"
  "GigaAMv3JointStep.mlpackage/Manifest.json|617"
  "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel|2916"
  "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin|1356098"
  "tokens.json|12406"
  "tokenizer.model|255336"
  "model_info.json|248"
  "convert_info.json|38"
  "v3_e2e_rnnt.yaml|1039"
  "README.md|8164"
  "example_infer.py|2768"
)

# path|bytes — sherpa-onnx INT8 repo (flat).
SHERPA_FILES=(
  "encoder.int8.onnx|224571327"
  "decoder.onnx|1159351"
  "joiner.onnx|687791"
  "tokens.txt|13354"
  "config.yaml|1041"
)

download() {
  local url="$1" dest="$2" expected="$3"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" ]]; then
    local actual
    actual=$(stat -f%z "$dest")
    if [[ "$actual" == "$expected" ]]; then
      echo "  ok (cached) $(basename "$dest")"
      return 0
    fi
  fi
  echo "  ↓ $(basename "$dest") ($((expected / 1024 / 1024)) MB)"
  # -C - resumes partial downloads; retry transient network failures.
  curl -fSL --retry 4 --retry-delay 3 -C - "$url" -o "$dest"
  local actual
  actual=$(stat -f%z "$dest")
  if [[ "$actual" != "$expected" ]]; then
    echo "ERROR: $dest is $actual bytes, expected $expected" >&2
    exit 1
  fi
}

echo "== Core ML FP16 backend ($COREML_REPO @ $COREML_REV) =="
for entry in "${COREML_FILES[@]}"; do
  path="${entry%%|*}"; bytes="${entry##*|}"
  if [[ "$path" == *.mlpackage/* ]]; then
    dest="$MODELS_DIR/coreml-fp16/Source/$path"
  else
    dest="$MODELS_DIR/coreml-fp16/Metadata/$path"
  fi
  download "https://huggingface.co/$COREML_REPO/resolve/$COREML_REV/$path" "$dest" "$bytes"
done

echo "== sherpa-onnx INT8 backend ($SHERPA_REPO @ $SHERPA_REV) =="
for entry in "${SHERPA_FILES[@]}"; do
  path="${entry%%|*}"; bytes="${entry##*|}"
  download "https://huggingface.co/$SHERPA_REPO/resolve/$SHERPA_REV/$path" \
    "$MODELS_DIR/sherpa-onnx-int8/$path" "$bytes"
done

echo "== Silero VAD (shared by both backends) =="
download "$SILERO_VAD_URL" "$MODELS_DIR/silero_vad.onnx" "$SILERO_VAD_BYTES"

echo "== Generating manifest with measured SHA256 =="
python3 scripts/generate_manifest.py --models-dir "$MODELS_DIR" --output Resources/ModelManifest.json

echo "Done. Model files live in $MODELS_DIR (git-ignored); the manifest is committed."
