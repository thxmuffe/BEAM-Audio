#!/bin/sh
set -eu
cd "$(dirname "$0")"
case "$(uname -s)" in
  # Windows (Git Bash): private pinned Elixir with the core's OTP and rebar3.
  MINGW*|MSYS*|CYGWIN*) exec python run-windows.py "$@" ;;
esac
exec mix run --no-halt
