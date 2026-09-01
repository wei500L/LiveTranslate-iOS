#!/usr/bin/env bash
# Downloads the pinned sherpa-onnx static XCFramework for iOS and unpacks it
# into ThirdParty/. The artifact is pinned to release v1.13.7 and verified by
# SHA256 — the framework is far too large for the Git repository.
set -euo pipefail

cd "$(dirname "$0")/.."

URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.7-ios-static.xcframework.zip"
SHA256="a808329c49da521b3af707da2e1a9d5b0a4595b2549ffdc771f2f560f012fd3d"
DEST="ThirdParty/sherpa-onnx.xcframework"
TMP="downloads/sherpa-onnx-v1.13.7-ios-static.xcframework.zip"

mkdir -p downloads ThirdParty

if [ -d "$DEST" ] && [ -d "$DEST/ios-arm64" ]; then
  echo "sherpa-onnx.xcframework already present, nothing to do."
  exit 0
fi

echo "Downloading sherpa-onnx v1.13.7 iOS static xcframework (~17 MB)..."
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
