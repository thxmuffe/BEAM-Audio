#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
case "$(uname -s)" in
  # Windows (Git Bash): pinned OTP, Web Device identity slots and the native AAC host.
  MINGW*|MSYS*|CYGWIN*) exec python "$ROOT/src/Services/DeviceWeb/run-windows.py" "$@" ;;
esac
bash "$ROOT/src/Services/DeviceWeb/build.sh"
exec erl -noshell \
  -pa "$ROOT"/builds/intermediates/control/default/lib/*/ebin \
      "$ROOT"/builds/intermediates/DeviceWeb/default/lib/*/ebin \
  -s ba_device_web_cli main -extra "$@"
