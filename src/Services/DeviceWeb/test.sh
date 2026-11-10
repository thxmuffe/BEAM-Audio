#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
bash "$ROOT/src/Services/DeviceWeb/build.sh"
export REBAR_CACHE_DIR="$ROOT/builds/intermediates/rebar-cache"
export ERL_LIBS="$ROOT/builds/intermediates/control/default/lib"
cd "$ROOT/src/Services/DeviceWeb"
rebar3 eunit
