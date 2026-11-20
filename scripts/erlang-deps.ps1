param([Parameter(Mandatory=$true)][string]$OtpRoot)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path $PSScriptRoot -Parent
$tools = Join-Path $repoRoot 'builds\intermediates\tools'
New-Item -ItemType Directory -Force $tools | Out-Null
$rebar = Join-Path $tools 'rebar3'
if (!(Test-Path -LiteralPath $rebar)) {
    Invoke-WebRequest 'https://s3.amazonaws.com/rebar3/rebar3' -OutFile $rebar
}
if ((Get-FileHash -LiteralPath $rebar -Algorithm SHA256).Hash -ne '5A28B1CCA082D3B023EC0F5DF9D9F9D52557036C6F2A21C1FFA11B93A984DD42') {
    throw 'Rebar3 checksum mismatch. Review the official tool release before updating the pin.'
}
$oldPath = $env:PATH
try {
    $env:PATH = (Join-Path $OtpRoot 'bin') + ';' + $oldPath
    $env:REBAR_CACHE_DIR = Join-Path $tools 'rebar-cache'
    Push-Location (Join-Path $repoRoot 'src/control')
    try {
        & "$OtpRoot\bin\escript.exe" $rebar compile
        if ($LASTEXITCODE) { throw 'Shared Erlang dependency build failed.' }
    } finally { Pop-Location }
} finally { $env:PATH = $oldPath }
