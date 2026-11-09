#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
export REBAR_CACHE_DIR="$ROOT/builds/intermediates/rebar-cache"
cd "$ROOT/src/control"
rebar3 compile
mkdir -p "$ROOT/builds/CLI" "$ROOT/builds/intermediates/CLI/ModuleCache"
if [ ! -d "$ROOT/builds/intermediates/BeamTransport/dev/lib/ex_webrtc" ]; then
  bash "$ROOT/scripts/build-native.sh"
fi
python3 "$ROOT/scripts/platforms/macOS/package-native.py" "$ROOT/builds/CLI"
xcrun clang++ -std=c++17 -O2 -fobjc-arc -mmacosx-version-min=14.2 \
  -framework Foundation -framework CoreAudio -framework AVFoundation \
  -Wl,-sectcreate,__TEXT,__info_plist,"$ROOT/src/Tools/CLI/AudioInput-Info.plist" \
  "$ROOT/src/Audio/adapters/macOS/audio_input.mm" -o "$ROOT/builds/CLI/ba_audio_input"
xcrun swiftc -target "$(uname -m)-apple-macosx14.2" -swift-version 5 -O \
  -framework Foundation -framework AVFAudio -framework CoreAudio \
  -module-cache-path "$ROOT/builds/intermediates/CLI/ModuleCache" \
  "$ROOT/src/Audio/adapters/macOS/DeviceAudio.swift" -o "$ROOT/builds/CLI/ba_device_audio"
codesign --force --sign - "$ROOT/builds/CLI/ba_audio_input"
codesign --force --sign - "$ROOT/builds/CLI/ba_device_audio"
printf 'Ready: %s/bin/beamaudio --help\n' "$ROOT"
