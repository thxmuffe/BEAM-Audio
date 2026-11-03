#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/builds/intermediates/macOS"
mkdir -p "$WORK/ModuleCache"
# XCTest ships with full Xcode. This selects it for this command only.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="$WORK/ModuleCache"
export SWIFT_MODULECACHE_PATH="$WORK/ModuleCache"
exec xcrun swift test --package-path "$ROOT/tests/UI" \
  --scratch-path "$WORK/SwiftTests" --cache-path "$WORK/SwiftPackageCache" "$@"
