#!/usr/bin/env bash
# Builds the pinned llama.cpp iOS XCFramework (device + simulator) into
# ThirdParty/llama.xcframework. The framework — llama.cpp's C API plus
# ggml with Metal (shaders embedded) — is far too large for the Git
# repository, so like sherpa-onnx it is built locally and never committed.
#
# The llama.cpp commit is PINNED: Hy-MT2's GGUF requires the STQ kernel
# (llama.cpp PR #22836) and the runner carries no vendored fallback, so a
# pin guarantees the kernels present at runtime match the ones the model
# was converted for. Bump LLAMA_CPP_COMMIT only after re-verifying both
# translation models end-to-end.
#
# Requirements: cmake ≥ 3.28 (brew install cmake), Xcode with iOS SDK.
# Reuses a shallow clone under downloads/ so repeat runs are fast.
set -euo pipefail

cd "$(dirname "$0")/.."

LLAMA_CPP_COMMIT="465e49b9cea78a68b9c244ffb48d0ee24a82873d"
DEST="ThirdParty/llama.xcframework"
SRC="downloads/llama.cpp"

if [ -d "$DEST" ] && [ -d "$DEST/ios-arm64" ]; then
  echo "llama.xcframework already present, nothing to do."
  exit 0
fi

mkdir -p downloads ThirdParty

if [ ! -d "$SRC" ]; then
  git clone --filter=blob:none "$SRC" 2>/dev/null || true
  git clone https://github.com/ggml-org/llama.cpp "$SRC"
fi
cd "$SRC"
git checkout -q "$LLAMA_CPP_COMMIT"

echo "Building llama.cpp ${LLAMA_CPP_COMMIT:0:8} for iOS (device + simulator)..."
./build-xcframework.sh ios-sim ios-device

rm -rf "../$DEST"
mv build-apple/llama.xcframework "../$DEST"
test -d "../$DEST/ios-arm64"
echo "Built $DEST"
