#!/usr/bin/env python3
"""Prepare a pinned iOS BEAM runtime and the shared Erlang application."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
HASHES = {
    'device': '437475e8abb721f3ffbbfe6f17ddb495e8bddd13503eaee87aea5e2c14e5dd1d',
    'sim': 'a6066a1cce2391f78e1cbf45f89f758f78e42cf8f8fda7363660940f4a7b6755',
}
parser = argparse.ArgumentParser()
parser.add_argument('--target', choices=HASHES, default='device')
parser.add_argument('--transport', choices=['native', 'relay'], default='native')
args = parser.parse_args()
target = args.target
subprocess.run([sys.executable, str(ROOT / 'src/Audio/handlers/webrtc/prepare.py'), '--target', 'ios'], check=True)
subprocess.run([sys.executable, str(ROOT / 'scripts/platforms/iOS/prepare-gstreamer.py'), '--target', target], check=True)
archive = ROOT / f'builds/intermediates/iOS/downloads/otp-ios-{target}-d199a49a.tar.gz'
archive.parent.mkdir(parents=True, exist_ok=True)
if not archive.exists():
    url = f'https://github.com/GenericJam/mob/releases/download/otp-d199a49a/{archive.name}'
    print('Downloading', url, flush=True)
    urllib.request.urlretrieve(url, archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == HASHES[target], 'Runtime SHA-256 mismatch'
otp = ROOT / f'builds/intermediates/iOS/otp-{target}'
if not (otp / 'erts-17.1.1/lib/libbeam.a').exists():
    otp.mkdir(parents=True, exist_ok=True)
    # The release tarball contains one temporary staging directory at its root.
    subprocess.run(['tar', '-xzf', str(archive), '--strip-components', '1', '-C', str(otp)], check=True)
# Same OTP version/compiler as the phone runtime; do not copy host OTP libraries.
version = subprocess.check_output(['erl', '-noshell', '-eval',
    'io:put_chars(erlang:system_info(version)), halt().'], text=True)
assert version == '17.1.1', f'Expected ERTS 17.1.1 compiler, got {version}'
env = dict(os.environ, REBAR_CACHE_DIR=str(ROOT / 'builds/intermediates/rebar-cache'),
           ERL_CRASH_DUMP=str(ROOT / 'builds/intermediates/iOS/prepare-erl_crash.dump'))
subprocess.run(['rebar3', 'compile'], cwd=ROOT / 'src/control', env=env, check=True)
if args.transport == 'native':
    subprocess.run([sys.executable, str(ROOT / 'scripts/platforms/iOS/prepare-transport.py'), '--target', target], check=True)
resources = ROOT / f'builds/intermediates/iOS/Resources-{args.transport}-{target}/runtime'
# Resources are generated: replace, never merge obsolete modules into the app.
if resources.exists():
    shutil.rmtree(resources)
resources.mkdir(parents=True, exist_ok=True)
for name in ['kernel', 'stdlib', 'inets', 'crypto', 'asn1', 'public_key', 'ssl'] + (
        ['compiler'] if args.transport == 'native' else []):
    matches = list((otp / 'lib').glob(f'{name}-*'))
    assert len(matches) == 1, (name, matches)
    app = matches[0]
    shutil.copytree(app / 'ebin', resources / 'lib' / app.name / 'ebin', dirs_exist_ok=True)
shutil.copytree(ROOT / 'builds/intermediates/control/default/lib/ba_core/ebin',
                resources / 'lib/ba_core-0.1.0/ebin', dirs_exist_ok=True)
for name in ['gun', 'cowlib']:
    shutil.copytree(ROOT / f'builds/intermediates/control/default/lib/{name}/ebin',
                    resources / f'lib/{name}/ebin', dirs_exist_ok=True)
    for license in (ROOT / f'builds/intermediates/control/default/lib/{name}').glob('LICENSE*'):
        shutil.copy2(license, resources / f'{name}-{license.name}')
if args.transport == 'native':
    # BEAM bytecode is portable; Mac shared objects and resource symlinks are not.
    libraries = list((ROOT / 'builds/intermediates/BeamTransport/dev/lib').iterdir())
    elixir = ROOT / 'builds/intermediates/tools/elixir/lib'
    if not elixir.is_dir():
        elixir = Path(subprocess.check_output(['elixir', '-e', 'IO.puts(Path.dirname(:code.lib_dir(:elixir)))'], text=True).strip())
    libraries += [elixir / name for name in ['elixir', 'eex', 'logger']]
    notices = resources / 'NativeTransportLicenses'
    notices.mkdir(exist_ok=True)
    for library in libraries:
        shutil.copytree(library / 'ebin', resources / 'lib' / library.name / 'ebin', dirs_exist_ok=True)
        (resources / 'lib' / library.name / 'priv').mkdir(exist_ok=True)
        for base in [library, ROOT / 'builds/intermediates/BeamTransportDeps' / library.name]:
            for license in base.glob('*'):
                if license.is_file() and license.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
                    shutil.copy2(license, notices / f'{library.name}-{license.name}')
    shutil.copytree(ROOT / f'builds/intermediates/iOS/transport-{target}/licenses', notices, dirs_exist_ok=True)
    shutil.copy2(elixir.parent / 'LICENSE', notices / 'elixir-LICENSE')
# iOS does not expose the host's certificate-store loading commands to BEAM.
# Export public trust anchors at build time; never disable TLS verification.
ca_bundle = subprocess.check_output(['erl', '-noshell', '-eval',
    "Certs = [case C of {cert, DER, _} -> DER; DER when is_binary(DER) -> DER end "
    "|| C <- public_key:cacerts_get()], "
    "io:put_chars(public_key:pem_encode([{'Certificate', C, not_encrypted} || C <- Certs])), halt()."], env=env)
(resources / 'cacerts.pem').write_bytes(ca_bundle)
shutil.copy2(otp / 'releases/29/start_clean.boot', resources / 'start_clean.boot')
(resources / 'erts-17.1.1/bin').mkdir(parents=True, exist_ok=True)
shutil.copy2(ROOT / 'LICENSE', resources / 'LICENSE')
shutil.copy2(ROOT / 'scripts/platforms/iOS/MOB-LICENSE', resources / 'MOB-LICENSE')
(resources / 'prepared.stamp').write_text(f'{args.transport} {target}\n')
shutil.copy2(ROOT / 'builds/intermediates/webrtc-audio/WebRTC.xcframework/LICENSE', resources / 'WEBRTC-LICENSE')
shutil.copy2(ROOT / 'builds/intermediates/webrtc-audio/native-headers/third_party/abseil-cpp/LICENSE', resources / 'ABSEIL-LICENSE')
shutil.copy2(ROOT / 'builds/intermediates/webrtc-audio/native-headers/PATENTS', resources / 'WEBRTC-PATENTS')
if args.transport == 'native':
    subprocess.run(['escript', str(ROOT / 'scripts/check-runtime-calls.escript'), str(resources)], check=True)
print(f'Prepared {target}: {resources}', flush=True)
