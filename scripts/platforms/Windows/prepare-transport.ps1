$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'Visual Studio C++ tools are required.' }
$dev = Join-Path $vs 'Common7\Tools\VsDevCmd.bat'
& $env:ComSpec /d /s /c "`"$dev`" -no_logo -arch=x64 -host_arch=x64 && python `"$PSScriptRoot\prepare-transport.py`""
if ($LASTEXITCODE) { throw 'Windows transport preparation failed.' }
