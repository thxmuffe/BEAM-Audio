#!/bin/bash
set -euo pipefail
SOURCE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SOURCE/../../.." && pwd)
bash "$SOURCE/build.sh"
exec erl -noshell -pa "$ROOT/builds/Services/ReceptionDesk/lib/ba_desk/ebin" -eval '
  case os:getenv("BA_DESK_BIND") of
    false -> ok;
    Address -> {ok, IP} = inet:parse_address(Address),
               application:load(ba_desk),
               application:set_env(ba_desk, bind_address, IP)
  end,
  case os:getenv("BA_DESK_PORT") of
    false -> ok;
    Port -> application:load(ba_desk),
            application:set_env(ba_desk, port, list_to_integer(Port))
  end,
  {ok, _} = application:ensure_all_started(ba_desk),
  receive stop -> ok end.'
