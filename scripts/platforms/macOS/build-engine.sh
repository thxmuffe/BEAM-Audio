#!/bin/bash
# Build the audio engine executable for macOS from the pinned libraries.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
DEPS="$ROOT/builds/intermediates/engine-deps/macOS"
OUTPUT="$ROOT/builds/CLI/ba_audio_engine"
python3 "$ROOT/scripts/platforms/macOS/prepare-engine-deps.py"
# OTP's ei library (erl_interface) from the Erlang that builds the core.
EI=$(erl -noshell -eval 'io:format("~s",[code:lib_dir(erl_interface)]),halt().')
WORK="$ROOT/builds/intermediates/engine/macOS"
mkdir -p "$(dirname "$OUTPUT")" "$WORK"
# Objects stay on disk so dsymutil can collect their DWARF for crash traces.
FLAGS=(-std=c++17 -O2 -g -Wall -Wextra -mmacosx-version-min=14.2 -I "$DEPS/include" -I "$EI/include")
OBJECTS=()
for SOURCE in src/Audio/engine/*.cpp src/Audio/adapters/macOS/engine_shell.mm; do
  OBJECT="$WORK/$(basename "$SOURCE").o"
  xcrun clang++ "${FLAGS[@]}" -fobjc-arc -c "$ROOT/$SOURCE" -o "$OBJECT"
  OBJECTS+=("$OBJECT")
done
# Homebrew's libei targets the host macOS; packaged apps link their own OTP's ei.
xcrun clang++ -mmacosx-version-min=14.2 "${OBJECTS[@]}" \
  -L "$DEPS/lib" -L "$EI/lib" -lFLAC -lsrtp2 -lsamplerate -lcpptrace -ldwarf -lzstd -lz -lei \
  -framework Foundation -framework CoreAudio -framework AudioToolbox \
  -Wl,-sectcreate,__TEXT,__info_plist,"$ROOT/src/Tools/CLI/AudioInput-Info.plist" \
  -o "$OUTPUT" 2> >(grep -v 'was built for newer' >&2)
# Keep DWARF next to the binary so crash traces show files and lines.
dsymutil "$OUTPUT" -o "$OUTPUT.dSYM"
codesign --force --sign - "$OUTPUT"
printf 'Built audio engine: %s\n' "$OUTPUT"
