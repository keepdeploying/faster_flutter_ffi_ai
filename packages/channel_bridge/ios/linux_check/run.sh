#!/bin/bash
# Builds and runs the Linux check for the Swift half of channel_bridge/ios.
# Needs a Swift toolchain on PATH (swift.org, Linux) and gcc. Not part of any app build.
# Usage: ios/linux_check/run.sh [path/to/mobilenet.tflite path/to/labels.txt]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/../channel_bridge/Sources/channel_bridge"
repo="$here/../../../.."
model="${1:-$repo/app/assets/models/mobilenet_v1_1.0_224.tflite}"
labels="${2:-$repo/app/assets/models/labels.txt}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gcc -shared -fPIC -O2 -o "$work/libtflite_stub.so" "$here/tflite_stub.c" -lm
swiftc -O -module-name channel_bridge_check -o "$work/check" \
  "$src/Preprocess.swift" "$src/TfLiteRuntime.swift" "$src/Classifier.swift" "$here/main.swift"
"$work/check" "$work/libtflite_stub.so" "$model" "$labels"
