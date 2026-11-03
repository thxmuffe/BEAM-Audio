#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TOOLS="$ROOT/builds/intermediates/tools"
export PATH="$TOOLS/elixir/bin:$TOOLS/cargo/bin:/opt/homebrew/bin:$PATH"
export CARGO_HOME="$TOOLS/cargo" RUSTUP_HOME="$TOOLS/rustup"
export HEX_HOME="$TOOLS/hex" MIX_HOME="$TOOLS/mix"
export REBAR_CACHE_DIR="$ROOT/builds/intermediates/rebar-cache"
if ! command -v mix >/dev/null 2>&1 || ! command -v cargo >/dev/null 2>&1; then
  echo 'Run python3 scripts/setup-host.py first.' >&2
  exit 2
fi
cd "$ROOT/src/control/transport"
mix deps.get
mix compile
cd "$ROOT/src/control"
rebar3 compile
