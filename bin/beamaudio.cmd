@echo off
rem Windows launcher for the same beamaudio escript used on macOS.
rem Prefers the repository's pinned OTP (scripts\platforms\Windows\setup.ps1).
setlocal
set "ROOT=%~dp0.."
if exist "%ROOT%\builds\intermediates\Windows\otp\bin\escript.exe" set "PATH=%ROOT%\builds\intermediates\Windows\otp\bin;%PATH%"
if /i "%~1"=="inspect" if /i "%~2"=="legacy" (
  echo The legacy Inspector is macOS-only. Use beamaudio monitor or inspect device. 1>&2
  exit /b 2
)
escript "%ROOT%\src\Tools\CLI\beam-audio" %*
