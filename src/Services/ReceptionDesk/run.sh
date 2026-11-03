#!/bin/sh
set -eu
cd "$(dirname "$0")"
exec mix run --no-halt
