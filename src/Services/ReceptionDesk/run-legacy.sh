#!/bin/bash
set -euo pipefail
SOURCE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$SOURCE/../../.." && pwd)
bash "$SOURCE/build.sh"
exec erl -noshell -pa "$ROOT/builds/Services/ReceptionDesk/lib/parvi_broker/ebin" -eval '
  case os:getenv("PARVI_BROKER_BIND") of
    false -> ok;
    Address -> {ok, IP} = inet:parse_address(Address),
               application:load(parvi_broker),
               application:set_env(parvi_broker, bind_address, IP)
  end,
  case os:getenv("PARVI_BROKER_PORT") of
    false -> ok;
    Port -> application:load(parvi_broker),
            application:set_env(parvi_broker, port, list_to_integer(Port))
  end,
  {ok, _} = application:ensure_all_started(parvi_broker),
  receive stop -> ok end.'
