#!/bin/sh
set -eu
cd "$(dirname "$0")"
mix deps.get
mix compile --warnings-as-errors
