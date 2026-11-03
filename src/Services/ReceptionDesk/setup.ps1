param([string]$OtpRoot = $env:PARVI_OTP_ROOT)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
if (!$OtpRoot) { $OtpRoot = Join-Path $repoRoot 'builds\intermediates\Windows\otp' }
if (!(Test-Path -LiteralPath $OtpRoot)) {
    $bundled = Join-Path $repoRoot 'builds\Windows\Parvi\runtime'
    if (Test-Path -LiteralPath "$bundled\bin\erl.exe") { $OtpRoot = $bundled }
}
$OtpRoot = (Resolve-Path -LiteralPath $OtpRoot).Path
$tools = Join-Path $repoRoot 'builds\intermediates\tools'
$elixir = Join-Path $tools 'elixir'
if (!(Test-Path -LiteralPath "$elixir\bin\mix.bat")) {
    New-Item -ItemType Directory -Force $tools | Out-Null
    $archive = Join-Path $tools 'elixir.zip'
    Invoke-WebRequest 'https://github.com/elixir-lang/elixir/releases/download/v1.19.5/elixir-otp-28.zip' -OutFile $archive
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne 'CA481510FEB6DABC875BBA43E44B25C7ABAFA53BD7A103639851B7AEACE8A022') {
        throw 'Elixir archive checksum mismatch.'
    }
    Expand-Archive -LiteralPath $archive -DestinationPath $elixir -Force
}
& (Join-Path $repoRoot 'scripts\erlang-deps.ps1') -OtpRoot $OtpRoot
$env:PATH = (Join-Path $OtpRoot 'bin') + ';' + (Join-Path $elixir 'bin') + ';' + $env:PATH
$env:MIX_HOME = Join-Path $tools 'mix'
$env:HEX_HOME = Join-Path $tools 'hex'
$env:MIX_REBAR3 = Join-Path $tools 'rebar3'
Push-Location $PSScriptRoot
try {
    if (!(Test-Path -LiteralPath (Join-Path $env:MIX_HOME 'archives'))) {
        & "$elixir\bin\mix.bat" local.hex --force
        if ($LASTEXITCODE) { throw 'Hex setup failed.' }
    }
    & "$elixir\bin\mix.bat" deps.get
    if ($LASTEXITCODE) { throw 'Desk dependency resolution failed.' }
    & "$elixir\bin\mix.bat" compile --warnings-as-errors
    if ($LASTEXITCODE) { throw 'Desk compilation failed.' }
} finally { Pop-Location }
