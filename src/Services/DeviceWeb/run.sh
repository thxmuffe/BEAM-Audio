#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
bash "$ROOT/src/Services/DeviceWeb/build.sh"
exec erl -noshell \
  -pa "$ROOT"/builds/intermediates/control/default/lib/*/ebin \
      "$ROOT"/builds/intermediates/DeviceWeb/default/lib/*/ebin \
  -s ba_device_web_cli main -extra "$@"
