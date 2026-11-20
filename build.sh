#!/bin/bash
# Build the reusable core and prepare target runtimes; never build product apps.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # Windows (Git Bash): pinned OTP/rebar3, the core and the native AAC host.
    # No legacy transport or Python GStreamer runtime.
    python "$ROOT/scripts/platforms/Windows/setup.py"
    OTP="$ROOT/builds/intermediates/Windows/otp"
    export PATH="$OTP/bin:$PATH" REBAR_CACHE_DIR="$ROOT/builds/intermediates/rebar-cache"
    (cd "$ROOT/src/control" && "$OTP/bin/escript.exe" "$ROOT/builds/intermediates/tools/rebar3" compile)
    python "$ROOT/scripts/platforms/Windows/build-native-stream.py"
    echo "BEAM Audio build complete: windows. Artifacts: $ROOT/builds"
    exit 0 ;;
esac
TARGET=${1:-all}
case "$TARGET" in
  -h|--help) echo 'Usage: ./build.sh [all|mac|ios] (default: all; iOS device runtime)'; exit 0 ;;
  all|mac|ios) ;;
  *) echo 'Usage: ./build.sh [all|mac|ios]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then echo 'Only one target argument is supported.' >&2; exit 2; fi
if [ "$(uname -s)" != Darwin ]; then echo 'This script supports macOS and Windows (Git Bash).' >&2; exit 2; fi
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
  # Audio is native AAC only: the Mac helper captures into GStreamer.
  bash "$ROOT/scripts/platforms/macOS/build-native-stream.sh"
fi
if [ "$TARGET" = all ] || [ "$TARGET" = ios ]; then
  python3 "$ROOT/scripts/platforms/iOS/prepare-runtime.py" --target device --transport native
fi
echo "BEAM Audio build complete: $TARGET. Artifacts: $ROOT/builds"
