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

# Absolute repo root (see fetch_litertlm.sh): the script cds into the
# clone, so destination paths must not be relative.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

LLAMA_CPP_COMMIT="465e49b9cea78a68b9c244ffb48d0ee24a82873d"
DEST="ThirdParty/llama.xcframework"
SRC="downloads/llama.cpp"

if [ -d "$DEST" ] && [ -d "$DEST/ios-arm64" ]; then
  echo "llama.xcframework already present, nothing to do."
  exit 0
fi

mkdir -p downloads ThirdParty

if [ ! -d "$SRC" ]; then
  git clone https://github.com/ggml-org/llama.cpp "$SRC"
fi
cd "$SRC"
git checkout -q "$LLAMA_CPP_COMMIT"

# A previously built xcframework under the clone is reused (the build
# takes ~10 min; rerunning the script must not redo it).
if [ ! -d build-apple/llama.xcframework ]; then
  echo "Building llama.cpp ${LLAMA_CPP_COMMIT:0:8} for iOS (device + simulator)..."
  ./build-xcframework.sh ios-sim ios-device
fi

rm -rf "$REPO_ROOT/$DEST"
cp -R build-apple/llama.xcframework "$REPO_ROOT/$DEST"
test -d "$REPO_ROOT/$DEST/ios-arm64"
echo "Built $DEST"
