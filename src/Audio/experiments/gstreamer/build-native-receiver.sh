#!/bin/bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
FRAMEWORK="$ROOT/builds/intermediates/webrtc-audio/WebRTC.xcframework"
OUT="$ROOT/builds/intermediates/gstreamer/comparison"
mkdir -p "$OUT"
HEADERS="$ROOT/builds/intermediates/webrtc-audio/native-headers"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -DNDEBUG -DWEBRTC_MAC -DWEBRTC_POSIX \
  -F "$FRAMEWORK/macos-x86_64_arm64" \
  -I "$FRAMEWORK/macos-x86_64_arm64/WebRTC.framework/Headers" \
  -I "$HEADERS" -I "$HEADERS/third_party/abseil-cpp" \
  -c "$ROOT/src/Audio/adapters/iOS/WebRTCReceiverControl.mm" -o "$OUT/controls.o"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -module-cache-path "$OUT/ModuleCache" \
  -F "$FRAMEWORK/macos-x86_64_arm64" -framework WebRTC \
  -I "$FRAMEWORK/ios-arm64/WebRTC.framework/Headers" \
  -I "$ROOT/src/Audio/adapters/iOS" \
  -import-objc-header "$HERE/NativeReceiver-Bridging-Header.h" \
  -Xlinker -rpath -Xlinker "$FRAMEWORK/macos-x86_64_arm64" \
  "$HERE/NativeReceiver.swift" "$OUT/controls.o" -lc++ -o "$OUT/libwebrtc-receiver"
codesign --force --sign - "$OUT/libwebrtc-receiver"
