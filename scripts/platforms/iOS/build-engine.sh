#!/bin/bash
# Build the in-process audio engine for the iPhone app as one static library:
# engine, iOS shell, pinned libraries and the iOS OTP runtime's own ei.
# Usage: build-engine.sh device|sim   (the OTP runtime must be prepared first)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TARGET=${1:-device}
case "$TARGET" in
  device) PLATFORM=iOS SDK=iphoneos MIN=-miphoneos-version-min=17.0 ;;
  sim) PLATFORM=iOS-sim SDK=iphonesimulator MIN=-mios-simulator-version-min=17.0 ;;
  *) echo 'Usage: build-engine.sh device|sim' >&2; exit 2 ;;
esac
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
python3 "$ROOT/scripts/platforms/prepare-engine-deps.py" --platform "$PLATFORM"
DEPS="$ROOT/builds/intermediates/engine-deps/$PLATFORM"
EI="$ROOT/builds/intermediates/iOS/otp-$TARGET/lib/erl_interface-5.8.2"
WORK="$ROOT/builds/intermediates/iOS/engine-$TARGET"
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
rm -rf "$WORK"; mkdir -p "$WORK/objects"
FLAGS=(-std=c++17 -O2 -g -Wall -Wextra -arch arm64 -isysroot "$SYSROOT" "$MIN" -I "$DEPS/include" -I "$EI/include")
OBJECTS=()
for SOURCE in "$ROOT"/src/Audio/engine/*.cpp "$ROOT/src/Audio/adapters/iOS/engine_shell.mm"; do
  OBJECT="$WORK/objects/$(basename "$SOURCE").o"
  xcrun --sdk "$SDK" clang++ "${FLAGS[@]}" -fobjc-arc -c "$SOURCE" -o "$OBJECT"
  OBJECTS+=("$OBJECT")
done
xcrun --sdk "$SDK" libtool -static -o "$WORK/libba_audio_engine.a" "${OBJECTS[@]}" \
  "$DEPS/lib/libFLAC.a" "$DEPS/lib/libsrtp2.a" "$DEPS/lib/libsamplerate.a" "$DEPS/lib/libcpptrace.a" "$EI/lib/libei.a" \
  2> >(grep -v 'has no symbols' >&2)
printf 'Built iOS audio engine: %s\n' "$WORK/libba_audio_engine.a"
