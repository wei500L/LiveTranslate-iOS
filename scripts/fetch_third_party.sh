#!/usr/bin/env bash
# Downloads the pinned sherpa-onnx iOS XCFramework and unpacks it into
# ThirdParty/. The artifact is pinned to release v1.13.7 and verified by
# SHA256 — the framework is far too large for the Git repository.
#
# Asset choice: "ios-shared-onnxruntime-static" — a dynamic framework with
# onnxruntime statically linked inside (self-contained). The plain
# "ios-static" asset leaves Ort* symbols undefined with no companion
# onnxruntime library for iOS and does not link.
set -euo pipefail

cd "$(dirname "$0")/.."

URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.7-ios-shared-onnxruntime-static.xcframework.zip"
SHA256="72db1b34ff75c6b4f3f40a73d46c4241e1c2b23599638975c66ad6dec10bb298"
DEST="ThirdParty/sherpa-onnx.xcframework"
TMP="downloads/sherpa-onnx-v1.13.7-ios-shared-onnxruntime-static.xcframework.zip"

mkdir -p downloads ThirdParty

if [ -d "$DEST" ] && [ -d "$DEST/ios-arm64" ]; then
  echo "sherpa-onnx.xcframework already present, nothing to do."
  exit 0
fi

echo "Downloading sherpa-onnx v1.13.7 iOS shared-onnxruntime-static xcframework (~84 MB)..."
curl -fSL --retry 3 -C - "$URL" -o "$TMP"

actual=$(shasum -a 256 "$TMP" | awk '{print $1}')
if [ "$actual" != "$SHA256" ]; then
  echo "SHA256 mismatch for $TMP:" >&2
  echo "  expected $SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi
echo "SHA256 verified."

rm -rf "$DEST"
unzip -q "$TMP" -d ThirdParty/
echo "Unpacked to $DEST"
