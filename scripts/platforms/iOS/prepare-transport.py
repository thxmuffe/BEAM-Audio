#!/usr/bin/env python3
"""Cross-build upstream static NIFs; leave dependency source trees unchanged."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--target', choices=['device', 'sim'], default='device')
target = parser.parse_args().target
deps = ROOT / 'builds/intermediates/BeamTransportDeps'
host = ROOT / 'builds/intermediates/BeamTransport/dev/lib'
build = ROOT / f'builds/intermediates/iOS/transport-{target}'
lib = build / 'lib'
lib.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
env['CARGO_HOME'] = str(ROOT / 'builds/intermediates/tools/cargo')
env['RUSTUP_HOME'] = str(ROOT / 'builds/intermediates/tools/rustup')
env['CARGO_TARGET_DIR'] = str(build / 'cargo-target')
env['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
env['PATH'] = str(ROOT / 'builds/intermediates/tools/cargo/bin') + os.pathsep + env['PATH']
sdk_name = 'iphoneos' if target == 'device' else 'iphonesimulator'
triple = 'aarch64-apple-ios' if target == 'device' else 'aarch64-apple-ios-sim'

def run(args, cwd=None):
    print('+', ' '.join(map(str, args)), flush=True)
    subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True)

def output(args):
    return subprocess.check_output(list(map(str, args)), env=env, text=True).strip()

sdk = output(['xcrun', '--sdk', sdk_name, '--show-sdk-path'])
clang = output(['xcrun', '--sdk', sdk_name, '--find', 'clang'])
apple_target = 'arm64-apple-ios17.0' + ('-simulator' if target == 'sim' else '')
flags = ['-target', apple_target, '-isysroot', sdk, '-O2', '-fPIC']
otp = ROOT / f'builds/intermediates/iOS/otp-{target}'
include = otp / 'usr/include'
if not include.exists():
    raise SystemExit('Prepare the pinned OTP runtime first with prepare-runtime.py.')
if not (host / 'ex_dtls/ebin').exists():
    raise SystemExit('Compile src/control/transport with Mix first (see its README).')

def source(name, url, digest=None):
    downloads = ROOT / 'builds/intermediates/iOS/downloads'
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / (name + '.tar.gz')
    if not archive.exists():
        print('Downloading', url, flush=True)
        urllib.request.urlretrieve(url, archive)
    if digest and hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
        raise RuntimeError(f'{name}: source checksum mismatch')
    destination = build / name
    if not destination.exists():
        destination.mkdir()
        with tarfile.open(archive) as bundle:
            # Upstream release archives have one enclosing source directory.
            for member in bundle.getmembers():
                parts = Path(member.name).parts[1:]
                if parts:
                    member.name = str(Path(*parts))
                    bundle.extract(member, destination, filter='data')
    return destination

openssl = source('openssl-3.5.9',
    'https://www.openssl.org/source/openssl-3.5.9.tar.gz',
    '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a')
if not (lib / 'libssl.a').exists():
    env['CC'] = clang
    env['CFLAGS'] = ' '.join(flags)
    configuration = 'ios64-xcrun' if target == 'device' else 'iossimulator-arm64-xcrun'
    run(['perl', 'Configure', configuration, 'no-shared', 'no-tests', 'no-apps',
         'no-docs', 'no-module', 'no-engine', '--prefix=' + str(build / 'openssl-install')], openssl)
    run(['make', '-j8', 'build_libs'], openssl)
    for name in ['libssl.a', 'libcrypto.a']:
        shutil.copy2(openssl / name, lib / name)

srtp = source('libsrtp-2.7.0', 'https://github.com/cisco/libsrtp/archive/refs/tags/v2.7.0.tar.gz')
srtp_headers = build / 'srtp-include/srtp2'
srtp_headers.mkdir(parents=True, exist_ok=True)
for folder in ['include', 'crypto/include']:
    for path in (srtp / folder).glob('*.h'):
        shutil.copy2(path, srtp_headers / path.name)
if not (lib / 'libsrtp2.a').exists():
    srtp_build = build / 'srtp-build'
    run(['cmake', '-S', srtp, '-B', srtp_build, '-DCMAKE_SYSTEM_NAME=iOS',
         '-DCMAKE_OSX_SYSROOT=' + sdk, '-DCMAKE_OSX_ARCHITECTURES=arm64',
         '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0', '-DBUILD_SHARED_LIBS=OFF',
         '-DENABLE_OPENSSL=ON', '-DTEST_APPS=OFF',
         '-DOPENSSL_INCLUDE_DIR=' + str(openssl / 'include'),
         '-DOPENSSL_CRYPTO_LIBRARY=' + str(lib / 'libcrypto.a'),
         '-DOPENSSL_SSL_LIBRARY=' + str(lib / 'libssl.a')])
    run(['cmake', '--build', srtp_build, '--target', 'srtp2', '-j8'])
    shutil.copy2(srtp_build / 'libsrtp2.a', lib / 'libsrtp2.a')

# Build a separate manifest over the unmodified ExSCTP implementation. Rustler
# 0.37 adds upstream staticlib support missing in the desktop's pinned 0.34.
cargo = ROOT / 'scripts/platforms/iOS/transport'
if not (lib / 'libex_sctp.a').exists():
    run(['rustup', 'target', 'add', triple])
    run(['cargo', 'build', '--locked', '--release', '--target', triple,
         '--manifest-path', cargo / 'Cargo.toml'])
    shutil.copy2(build / f'cargo-target/{triple}/release/libex_sctp.a', lib / 'libex_sctp.a')

# Common C support is compiled into each NIF's own namespace. Desktop shared
# objects isolate these globals; static linking needs explicit symbol prefixes.
common_sources = [
    deps / 'unifex/c_src/unifex/nif/unifex/unifex.c',
    deps / 'unifex/c_src/unifex/nif/unifex/payload.c',
    deps / 'shmex/c_src/shmex/nif/shmex/shmex.c',
    deps / 'shmex/c_src/shmex/shmex/lib.c',
    deps / 'bunch_native/c_src/bunch/nif/bunch/bunch.c',
    deps / 'bunch_native/c_src/bunch/bunch/lib.c',
]
common_includes = [include, openssl / 'include',
    deps / 'unifex/c_src/unifex/nif', deps / 'shmex/c_src/shmex/nif',
    deps / 'shmex/c_src/shmex', deps / 'bunch_native/c_src/bunch/nif',
    deps / 'bunch_native/c_src/bunch']
objects = []

def nif(name, sources, headers, host_nif):
    work = build / name
    work.mkdir(exist_ok=True)
    symbols = output(['nm', '-gU', host_nif]).splitlines()
    header = work / 'namespace.h'
    names = [line.split()[-1].removeprefix('_') for line in symbols]
    header.write_text(''.join(f'#define {n} {name}_{n}\n' for n in names
                              if n != 'nif_init' and re.fullmatch(r'[A-Za-z_]\w*', n)))
    for index, path in enumerate(sources):
        obj = work / f'{name}-{index}.o'
        run([clang, *flags, '-DBUNDLEX_NIF', '-DSTATIC_ERLANG_NIF_LIBNAME=' + name,
             '-include', header, *[arg for p in headers for arg in ['-I', p]],
             '-c', path, '-o', obj])
        objects.append(obj)

dtls = deps / 'ex_dtls/c_src/ex_dtls'
nif('parvi_dtls', [*sorted(dtls.glob('*.c')), dtls / '_generated/nif/native.c', *common_sources],
    [dtls, dtls / '_generated/nif', *common_includes],
    host / 'ex_dtls/priv/bundlex/nif/native.so')
srtp_nif = deps / 'ex_libsrtp/c_src/ex_libsrtp'
nif('parvi_srtp', [*sorted(srtp_nif.glob('*.c')), srtp_nif / '_generated/nif/srtp.c', *common_sources],
    [srtp_nif, srtp_nif / '_generated/nif', srtp_headers.parent, srtp / 'include', srtp / 'crypto/include',
     build / 'srtp-build', *common_includes], host / 'ex_libsrtp/priv/bundlex/nif/srtp.so')
crc = deps / 'crc/c_src/nif'
nif('parvi_crc', sorted(crc.glob('*.c')), [crc, include], host / 'crc/priv/crc_nif.so')
archive = lib / 'libparvi_transport.a'
archive.unlink(missing_ok=True)
run(['xcrun', 'ar', 'rcs', archive, *objects])

notices = build / 'licenses'
notices.mkdir(exist_ok=True)
for base in [openssl, srtp, *[deps / n for n in
             ['ex_dtls', 'ex_libsrtp', 'ex_sctp', 'crc', 'unifex', 'shmex', 'bunch_native']]]:
    for path in base.glob('*'):
        if path.is_file() and path.name.upper().startswith(('LICENSE', 'COPYING', 'NOTICE')):
            shutil.copy2(path, notices / f'{base.name}-{path.name}')
print(f'Prepared static transport for {target}: {lib}', flush=True)
