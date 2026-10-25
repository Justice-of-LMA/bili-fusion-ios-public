#!/bin/bash
# Run explicitly for the separate AI edition. Ordinary project.yml is unchanged.
set -euo pipefail
VERSION=1.24.2
SHA=f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
mkdir -p Vendor/onnxruntime
ARCHIVE="$ROOT/Vendor/onnxruntime/onnxruntime-c-$VERSION.zip"
if [ ! -f "$ARCHIVE" ]; then
 curl --fail --location --retry 0 --max-time 180 "https://download.onnxruntime.ai/pod-archive-onnxruntime-c-$VERSION.zip" -o "$ARCHIVE"
fi
printf '%s  %s\n' "$SHA" "$ARCHIVE" | shasum -a 256 -c -
mkdir -p Vendor/onnxruntime/unpacked
unzip -q -o "$ARCHIVE" 'Headers/*' 'LICENSE' 'onnxruntime.xcframework/Info.plist' 'onnxruntime.xcframework/ios-arm64/*' 'onnxruntime.xcframework/ios-arm64_x86_64-simulator/*' -d Vendor/onnxruntime/unpacked
printf '%s  %s\n' b4718df6228e7bdf1a8a435cf98f838636eb2fd331acabf86ba87c5192ebcb87 AIAssets/gtcrn_simple.onnx | shasum -a 256 -c -
# Ruby/Psych ships with the macOS runner. No Python/YAML package installation.
ruby scripts/make-ai-project.rb
echo 'AI project ready: xcodegen generate --spec project-ai.yml; scheme Fusion'
