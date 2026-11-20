@echo off
rem Windows launcher for the same beamaudio escript used on macOS.
rem Prefers the repository's pinned OTP (scripts\platforms\Windows\setup.py).
setlocal
set "ROOT=%~dp0..\.."
if exist "%ROOT%\builds\intermediates\Windows\otp\bin\escript.exe" set "PATH=%ROOT%\builds\intermediates\Windows\otp\bin;%PATH%"
escript "%ROOT%\src\Tools\CLI\beam-audio" %*
