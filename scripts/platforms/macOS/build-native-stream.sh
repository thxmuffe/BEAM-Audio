#!/bin/bash
# Development trial only. Uses the matching SDK headers and pinned runtime.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
RUNTIME="$ROOT/builds/intermediates/gstreamer/runtime"
HEADERS=${BA_GSTREAMER_HEADERS:-"$ROOT/builds/intermediates/gstreamer/iOS/sdk-device/GStreamer.xcframework/ios-arm64/Headers"}
OUTPUT="$ROOT/builds/CLI/ba_native_stream"
if [ ! -f "$HEADERS/gst/gst.h" ]; then
  echo 'Set BA_GSTREAMER_HEADERS to the matching GStreamer SDK headers.' >&2
  exit 1
fi
python3 "$ROOT/scripts/platforms/macOS/prepare-gstreamer.py" --native-stream-headers
mkdir -p "$(dirname "$OUTPUT")"
xcrun clang++ -std=c++17 -O2 -fobjc-arc -DBA_NATIVE_STREAM -mmacosx-version-min=14.2 \
  -I "$ROOT/builds/intermediates/gstreamer/header-overlay" -I "$HEADERS" -L "$RUNTIME/lib" \
  -framework Foundation -framework CoreAudio -framework AVFoundation \
  -lgstreamer-1.0 -lgstbase-1.0 -lgstrtp-1.0 -lgstapp-1.0 -lgstwebrtc-1.0 -lgstsdp-1.0 -lgobject-2.0 -lglib-2.0 \
  -Wl,-sectcreate,__TEXT,__info_plist,"$ROOT/src/Tools/CLI/AudioInput-Info.plist" \
  "$ROOT/src/Audio/adapters/macOS/audio_input.mm" \
  "$ROOT/src/Audio/adapters/Apple/GStreamerStreamHost.mm" -o "$OUTPUT"
codesign --force --sign - "$OUTPUT"
printf 'Built native trial helper: %s\n' "$OUTPUT"
