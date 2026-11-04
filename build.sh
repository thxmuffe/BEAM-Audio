#!/bin/bash
# Build the reusable core and prepare target runtimes; never build product apps.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
TARGET=${1:-all}
case "$TARGET" in
  -h|--help) echo 'Usage: ./build.sh [all|mac|ios] (default: all; iOS device runtime)'; exit 0 ;;
  all|mac|ios) ;;
  *) echo 'Usage: ./build.sh [all|mac|ios]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo 'Only one target argument is supported.' >&2; exit 2; fi
if [ "$(uname -s)" != Darwin ]; then echo 'Use build.ps1 on Windows. This script requires macOS.' >&2; exit 2; fi
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
python3 "$ROOT/scripts/setup-host.py"
export PATH="$ROOT/builds/intermediates/tools/elixir/bin:$ROOT/builds/intermediates/tools/cargo/bin:/opt/homebrew/bin:$PATH"
export CARGO_HOME="$ROOT/builds/intermediates/tools/cargo"
export RUSTUP_HOME="$ROOT/builds/intermediates/tools/rustup"
export HEX_HOME="$ROOT/builds/intermediates/tools/hex"
export MIX_HOME="$ROOT/builds/intermediates/tools/mix"
export REBAR_CACHE_DIR="$ROOT/builds/intermediates/rebar-cache"
bash "$ROOT/scripts/build-native.sh"
if [ "$TARGET" = all ] || [ "$TARGET" = mac ]; then
  python3 "$ROOT/src/Audio/handlers/webrtc/prepare.py" --target mac
fi
if [ "$TARGET" = all ] || [ "$TARGET" = ios ]; then
  python3 "$ROOT/scripts/platforms/iOS/prepare-runtime.py" --target device --transport native
fi
echo "BEAM Audio build complete: $TARGET. Artifacts: $ROOT/builds"
