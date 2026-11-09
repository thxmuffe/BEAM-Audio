#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
BIN="$ROOT/builds/Inspector/ba_inspector"
if [ ! -x "$BIN" ]; then
  echo "Run bash src/Tools/Inspector/build.sh first." >&2
  exit 2
fi
exec "$BIN" --root "$ROOT" --erl "$(command -v erl)" "$@"
