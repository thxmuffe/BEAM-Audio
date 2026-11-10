#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
export REBAR_CACHE_DIR="$ROOT/builds/intermediates/rebar-cache"
# Erlang only: no native audio build or product checkout is needed.
cd "$ROOT/src/control"
rebar3 compile
cd "$ROOT/src/Services/DeviceWeb"
rebar3 compile
