param([string]$OtpRoot = $env:BA_OTP_ROOT)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if (!$OtpRoot) { $OtpRoot = Join-Path $repo 'builds\intermediates\Windows\otp' }
$OtpRoot = (Resolve-Path -LiteralPath $OtpRoot).Path
$out = Join-Path $repo 'builds\Services\ReceptionDesk\lib\ba_desk'
$ebin = Join-Path $out 'ebin'
New-Item -ItemType Directory -Force $ebin | Out-Null
$sources = Get-ChildItem -LiteralPath "$PSScriptRoot\src" -Filter '*.erl' | ForEach-Object FullName
& "$OtpRoot\bin\erlc.exe" -Werror -o $ebin @sources
if ($LASTEXITCODE) { throw 'Reception desk compilation failed.' }
Copy-Item -LiteralPath "$PSScriptRoot\src\ba_desk.app.src" -Destination "$ebin\ba_desk.app"
& "$OtpRoot\bin\erl.exe" -noshell -pa $ebin -eval '
  application:load(ba_desk),
  case os:getenv("BA_DESK_BIND") of
    false -> ok;
    Address -> {ok, IP} = inet:parse_address(Address),
               application:set_env(ba_desk, bind_address, IP)
  end,
  case os:getenv("BA_DESK_PORT") of
    false -> ok;
    Port -> application:set_env(ba_desk, port, list_to_integer(Port))
  end,
  {ok, _} = application:ensure_all_started(ba_desk),
  receive stop -> ok end.'
if ($LASTEXITCODE) { throw 'Reception desk stopped unexpectedly.' }
