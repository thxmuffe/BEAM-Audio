#!/usr/bin/env python3
"""Restore pinned, checkout-private Mac native build tools; no global installs."""
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'builds/intermediates/tools'
DOWNLOADS = TOOLS / 'downloads'
DOWNLOADS.mkdir(parents=True, exist_ok=True)
if platform.system() != 'Darwin' or platform.machine() != 'arm64':
    raise SystemExit('This host bootstrap supports Apple Silicon; Windows uses scripts/platforms/Windows/setup-native.py.')

def fetch(name, url, checksum):
    path = DOWNLOADS / name
    if not path.exists():
        print('Downloading', url, flush=True)
        urllib.request.urlretrieve(url, path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != checksum:
        raise SystemExit('Checksum mismatch: ' + str(path))
    return path

if not (TOOLS / 'elixir/bin/mix').exists():
    archive = fetch('elixir-1.19.5-otp-28.zip',
        'https://github.com/elixir-lang/elixir/releases/download/v1.19.5/elixir-otp-28.zip',
        'ca481510feb6dabc875bba43e44b25c7abafa53bd7a103639851b7aeace8a022')
    with zipfile.ZipFile(archive) as source:
        source.extractall(TOOLS / 'elixir')
    for path in (TOOLS / 'elixir/bin').iterdir():
        if path.is_file(): path.chmod(path.stat().st_mode | 0o111)

env = dict(os.environ, CARGO_HOME=str(TOOLS / 'cargo'), RUSTUP_HOME=str(TOOLS / 'rustup'),
           HEX_HOME=str(TOOLS / 'hex'), MIX_HOME=str(TOOLS / 'mix'))
env['PATH'] = os.pathsep.join([str(TOOLS / 'elixir/bin'), str(TOOLS / 'cargo/bin'), env['PATH']])
if not (TOOLS / 'cargo/bin/rustup').exists():
    installer = fetch('rustup-init-1.29.2',
        'https://static.rust-lang.org/rustup/archive/1.29.2/aarch64-apple-darwin/rustup-init',
        'f7c7e11eb2e07f006e532a8aaac77b32f4527d305ac386c0c633ca6133d35ca9')
    installer.chmod(0o755)
    subprocess.run([str(installer), '-y', '--no-modify-path', '--profile', 'minimal',
                    '--default-toolchain', '1.90.0'], env=env, check=True)
if not list((TOOLS / 'mix/archives').glob('hex-*')):
    subprocess.run(['mix', 'local.hex', '--force'], env=env, check=True)
print('Checkout-private native build tools ready:', TOOLS)
