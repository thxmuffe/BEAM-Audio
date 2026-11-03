# Fetch a private, pinned runtime. This does not install software system-wide.
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$work = Join-Path $repo 'builds\intermediates\Windows'
$version = '29.1.2'
$expected = '4EFE9772A84C6C1EF75377E9326815584958776C905F2BF687B62509E2D809C0'
$downloads = Join-Path $work 'downloads'
$otp = Join-Path $work 'otp'
$archive = Join-Path $downloads "otp_win64_$version.zip"
New-Item -ItemType Directory -Force $downloads | Out-Null
if (!(Test-Path -LiteralPath $archive)) {
    Invoke-WebRequest "https://github.com/erlang/otp/releases/download/OTP-$version/otp_win64_$version.zip" -OutFile $archive
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) {
    throw 'OTP archive checksum mismatch. Remove the archive and investigate before retrying.'
}
if (!(Test-Path -LiteralPath "$otp\bin\erl.exe")) {
    New-Item -ItemType Directory -Force $otp | Out-Null
    & tar.exe -xf $archive -C $otp
    if ($LASTEXITCODE) { throw 'OTP extraction failed.' }
}
Write-Host "OTP $version ready at $otp"
