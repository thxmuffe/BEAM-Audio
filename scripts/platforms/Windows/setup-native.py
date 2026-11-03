"""Prepare pinned, repository-private native build tools (no global installs)."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[3]
TOOLS = ROOT / 'builds/intermediates/tools'
DOWNLOADS = ROOT / 'builds/intermediates/Windows/downloads'
DOWNLOADS.mkdir(parents=True, exist_ok=True)
for artifact in json.loads(Path(__file__).with_name('tool-deps.json').read_text(encoding='utf-8-sig')):
    path = DOWNLOADS / artifact['name']
    # Earlier Windows setup kept the verified Elixir archive under tools.
    if not path.exists() and artifact['name'] == 'elixir.zip' and (TOOLS / 'elixir.zip').exists():
        import shutil
        shutil.copy2(TOOLS / 'elixir.zip', path)
    if not path.exists():
        urllib.request.urlretrieve(artifact['url'], path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != artifact['sha256']:
        raise RuntimeError('Tool checksum mismatch: ' + path.name)
    if artifact.get('directory') and not (TOOLS / artifact['directory']).exists():
        with zipfile.ZipFile(path) as archive:
            archive.extractall(TOOLS / artifact['directory'])
env = dict(os.environ, CARGO_HOME=str(TOOLS / 'cargo'), RUSTUP_HOME=str(TOOLS / 'rustup'))
if not (TOOLS / 'cargo/bin/cargo.exe').exists():
    subprocess.run([str(DOWNLOADS / 'rustup-init.exe'), '-y', '--no-modify-path',
                    '--profile', 'minimal', '--default-toolchain', '1.90.0'], env=env, check=True)
env.update(HEX_HOME=str(TOOLS / 'hex'), MIX_HOME=str(TOOLS / 'mix'))
env['PATH'] = str(ROOT / 'builds/intermediates/Windows/otp/bin') + os.pathsep + env['PATH']
mix = TOOLS / 'elixir/bin/mix.bat'
if not list((TOOLS / 'mix/archives').glob('hex-*')):
    subprocess.run([str(mix), 'local.hex', '--force'], env=env, check=True)
deps = ROOT / 'builds/intermediates/BeamTransportDeps'
if not (deps / 'ex_webrtc').exists():
    subprocess.run([str(mix), 'deps.get'], cwd=ROOT / 'src/control/transport', env=env, check=True)
print('Private native build tools ready.')
