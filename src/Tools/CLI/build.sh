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
# Audio is native AAC only: build the native stream helper (needs GStreamer).
bash "$ROOT/scripts/platforms/macOS/build-native-stream.sh"
printf 'Ready: %s/bin/beamaudio --help\n' "$ROOT"
