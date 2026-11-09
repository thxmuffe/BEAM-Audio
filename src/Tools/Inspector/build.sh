#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
export REBAR_CACHE_DIR="$ROOT/builds/intermediates/rebar-cache"
cd "$ROOT/src/control"
rebar3 compile
mkdir -p "$ROOT/builds/Inspector"
# Reuse the native packager so transitive OpenSSL/SRTP links are self-contained.
python3 "$ROOT/scripts/platforms/macOS/package-native.py" "$ROOT/builds/Inspector"
swiftc -O -parse-as-library -framework Foundation -framework CryptoKit -framework Security \
  -module-cache-path "$ROOT/builds/intermediates/macOS/ModuleCache" \
  "$ROOT/src/control/adapters/Apple/NativeIdentity.swift" \
  "$ROOT/src/Tools/Inspector/Inspector.swift" -o "$ROOT/builds/Inspector/ba_inspector"
codesign --force --sign - "$ROOT/builds/Inspector/ba_inspector"
