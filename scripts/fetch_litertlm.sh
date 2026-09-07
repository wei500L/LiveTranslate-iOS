#!/usr/bin/env bash
# Fetches the pinned LiteRT-LM Swift package (C API xcframework + module
# wrapper sources) into ThirdParty/LiteRTLM.xcframework. The runtime —
# Google's LiteRT-LM inference engine for .litertlm models (Gemma 4 E2B
# image understanding) — is far too large for the Git repository, so like
# sherpa-onnx and llama.cpp it is fetched locally and never committed.
#
# The commit is PINNED: the C API contract (engine.h) and the model
# format must match the vendored adapter (LiteRTLMVisionEngine.swift).
# Bump only after re-verifying Gemma image inference end-to-end.
#
# Requirements: git, Xcode. Reuses a clone under downloads/.
set -euo pipefail

cd "$(dirname "$0")/.."

LITERTLM_SWIFT_COMMIT="0e63b19c21ba562d6824fbfc409fba0916acea18"
REPO="https://github.com/mylovelycodes/LiteRTLM-Swift"
DEST="ThirdParty/LiteRTLM.xcframework"
SRC="downloads/LiteRTLM-Swift"

if [ -d "$DEST" ] && [ -d "$DEST/ios-arm64" ]; then
  echo "LiteRTLM.xcframework already present, nothing to do."
  exit 0
fi

mkdir -p downloads ThirdParty

if [ ! -d "$SRC" ]; then
  git clone --depth 1 "$REPO" "$SRC"
fi
cd "$SRC"
git fetch --depth 1 origin "$LITERTLM_SWIFT_COMMIT"
git checkout -q "$LITERTLM_SWIFT_COMMIT"

# The package vendors the xcframework in-repo (framework binary built from
# google-ai-edge/LiteRT-LM; module CLiteRTLM with engine.h).
rm -rf "../$DEST"
cp -R Frameworks/LiteRTLM.xcframework "../$DEST"
test -d "../$DEST/ios-arm64"
echo "Fetched $DEST"
