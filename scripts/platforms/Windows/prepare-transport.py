"""Build Windows transport from pinned upstream sources in a private staging tree."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / 'builds/intermediates/Windows/transport'
DEPS = WORK / 'deps'
BUILD = WORK / 'beam'
TOOLS = ROOT / 'builds/intermediates/tools'
OTP = ROOT / 'builds/intermediates/Windows/otp'
ENV = dict(os.environ)
ENV.update(CARGO_HOME=str(TOOLS / 'cargo'), RUSTUP_HOME=str(TOOLS / 'rustup'),
           HEX_HOME=str(TOOLS / 'hex'), MIX_HOME=str(TOOLS / 'mix'))
ENV['PATH'] = os.pathsep.join(map(str, [OTP / 'bin', TOOLS / 'elixir/bin', TOOLS / 'cargo/bin'])) + os.pathsep + ENV['PATH']
ENV['LC_ALL'] = 'C'
ENV['LANG'] = 'C'
ENV['CL'] = '/FS ' + ENV.get('CL','')


def run(args, cwd=None):
    print('+', ' '.join(map(str, args)), flush=True)
    if Path(args[0]).name == 'jom.exe':
        log = WORK / 'openssl-build.log'
        print('Compiler output:', log, flush=True)
        with log.open('w') as output:
            result = subprocess.run(list(map(str,args)),cwd=cwd,env=ENV,stdout=output,stderr=subprocess.STDOUT)
        if result.returncode:
            print(log.read_text(errors='replace')[-8000:])
            result.check_returncode()
    else:
        subprocess.run(list(map(str, args)), cwd=cwd, env=ENV, check=True)


def source(name, url, digest=None):
    download = ROOT / 'builds/intermediates/Windows/downloads' / (name + '.tar.gz')
    download.parent.mkdir(parents=True, exist_ok=True)
    if not download.exists():
        urllib.request.urlretrieve(url, download)
    if digest and hashlib.sha256(download.read_bytes()).hexdigest() != digest:
        raise RuntimeError('Source checksum mismatch: ' + name)
    dest = WORK / name
    if not dest.exists():
        with tarfile.open(download) as archive:
            for member in archive.getmembers():
                parts = Path(member.name).parts[1:]
                if parts:
                    member.name = str(Path(*parts))
                    archive.extract(member, dest, filter='data')
    return dest


def stage():
    lock = ROOT / 'src/control/transport/mix.lock'
    digest = hashlib.sha256(lock.read_bytes()).hexdigest()
    marker = WORK / 'beam.stamp'
    if marker.exists() and marker.read_text() == digest:
        return
    original = ROOT / 'builds/intermediates/BeamTransportDeps'
    for dep in original.iterdir():
        if dep.is_dir() and not (DEPS / dep.name).exists():
            shutil.copytree(dep, DEPS / dep.name, ignore=shutil.ignore_patterns('_build', 'target'))
    # Keep the upstream BEAM modules/spec generators; build their C NIFs below
    # instead of invoking the POSIX native build recipes. Original caches stay intact.
    for name in ['bunch_native', 'shmex', 'unifex', 'ex_dtls', 'ex_libsrtp']:
        path = DEPS / name / 'mix.exs'
        text = path.read_text().replace('[:unifex, :bundlex]', '[:unifex]').replace('[:bundlex] ++ ', '')
        path.write_text(text)
    crc = DEPS / 'crc/mix.exs'
    crc.write_text(crc.read_text().replace('[:crc_nif] ++ ', ''))
    project = WORK / 'project'
    project.mkdir(parents=True, exist_ok=True)
    original_project = ROOT / 'src/control/transport'
    manifest = (original_project / 'mix.exs').read_text()
    manifest = manifest.replace('../../../builds/intermediates/BeamTransportDeps', DEPS.as_posix())
    manifest = manifest.replace('../../../builds/intermediates/BeamTransport', BUILD.as_posix())
    (project / 'mix.exs').write_text(manifest)
    shutil.copy2(original_project / 'mix.lock', project / 'mix.lock')
    run([TOOLS / 'elixir/bin/mix.bat', 'deps.compile'], project)
    run([TOOLS / 'elixir/bin/mix.bat', 'compile'], project)
    marker.write_text(digest)


def native():
    openssl = source('openssl-3.5.9', 'https://www.openssl.org/source/openssl-3.5.9.tar.gz',
                     '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a')
    perl = TOOLS / 'perl/perl/bin/perl.exe'
    if not all((openssl / name).exists() for name in ['libcrypto.lib','libssl.lib']):
        if not (openssl / 'makefile').exists():
            run([perl, 'Configure', 'VC-WIN64A', 'no-asm', 'no-shared', 'no-tests', 'no-apps',
                 'no-docs', 'no-module', 'no-engine'], openssl)
        run([TOOLS / 'jom/jom.exe', '-j4', 'build_libs'], openssl)
    srtp = source('libsrtp-2.7.0', 'https://github.com/cisco/libsrtp/archive/refs/tags/v2.7.0.tar.gz',
                  '54facb1727a557c2a76b91194dcb2d0a453aaf8e2d0cbbf1e3c2848c323e28ad')
    srtp_build = WORK / 'srtp-build'
    cmake = shutil.which('cmake')
    if not cmake:
        cmake = next(Path('C:/Program Files/Microsoft Visual Studio').glob('*/Community/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'))
    if not (srtp_build / 'srtp2.lib').exists():
        run([cmake, '-S', srtp, '-B', srtp_build, '-G', 'NMake Makefiles',
             '-DCMAKE_BUILD_TYPE=Release', '-DENABLE_OPENSSL=ON', '-DTEST_APPS=OFF', '-DBUILD_SHARED_LIBS=OFF',
             '-DOPENSSL_USE_STATIC_LIBS=TRUE', '-DOPENSSL_INCLUDE_DIR=' + str(openssl / 'include'),
             '-DOPENSSL_CRYPTO_LIBRARY=' + str(openssl / 'libcrypto.lib'),
             '-DLIB_EAY_RELEASE=' + str(openssl / 'libcrypto.lib'),
             '-DLIB_EAY_LIBRARY_RELEASE=' + str(openssl / 'libcrypto.lib'),
             '-DSSL_EAY_RELEASE=' + str(openssl / 'libssl.lib'),
             '-DSSL_EAY_LIBRARY_RELEASE=' + str(openssl / 'libssl.lib'),
             '-DOPENSSL_SSL_LIBRARY=' + str(openssl / 'libssl.lib')])
        run([cmake, '--build', srtp_build, '--target', 'srtp2'])
    # POSIX headers here are unused by ExDTLS; OpenSSL supplies Windows timeval.
    dtls = DEPS / 'ex_dtls/c_src/ex_dtls'
    path = dtls / 'native.c'
    text = path.read_text()
    for header in ['sys/socket.h', 'sys/un.h', 'unistd.h']:
        text = text.replace('#include <' + header + '>', '')
    if '  FILE *urandom =' in text:
        begin, end = text.index('  FILE *urandom ='), text.index('  srand(seed);')
        text = text[:begin] + '  unsigned int seed;\n  if (RAND_bytes((unsigned char *)&seed, sizeof(seed)) != 1) return -1;\n' + text[end:]
        path.write_text('#include <openssl/rand.h>\n' + text)
    path = dtls / 'dtls.h'
    text = path.read_text().replace('#include <sys/time.h>', '').replace('#include <winsock2.h>', '')
    path.write_text('#include <winsock2.h>\n' + text)
    clang = next(Path('C:/Program Files/Microsoft Visual Studio').glob('*/Community/VC/Tools/Llvm/x64/bin/clang-cl.exe'))
    includes = [OTP / 'usr/include', openssl / 'include',
                DEPS / 'unifex/c_src/unifex/nif', DEPS / 'shmex/c_src/shmex/nif',
                DEPS / 'shmex/c_src/shmex', DEPS / 'bunch_native/c_src/bunch/nif',
                DEPS / 'bunch_native/c_src/bunch']
    common = [DEPS / 'unifex/c_src/unifex/nif/unifex/unifex.c',
              ROOT / 'scripts/platforms/Windows/transport/binary_payload.c']
    app_root = BUILD / 'dev/lib'
    for app, name, folder, more_includes, libs in [
        ('ex_dtls', 'native', dtls, [], [openssl / 'libssl.lib', openssl / 'libcrypto.lib']),
        ('ex_libsrtp', 'srtp', DEPS / 'ex_libsrtp/c_src/ex_libsrtp',
         [srtp / 'include', srtp / 'crypto/include', srtp_build, WORK / 'srtp-include'],
         [srtp_build / 'srtp2.lib', openssl / 'libcrypto.lib'])]:
        if app == 'ex_libsrtp':
            headers = WORK / 'srtp-include/srtp2'
            headers.mkdir(parents=True, exist_ok=True)
            for h in (srtp / 'include').glob('*.h'):
                shutil.copy2(h, headers / h.name)
        out = app_root / app / 'priv/bundlex/nif'
        out.mkdir(parents=True, exist_ok=True)
        sources = [*folder.glob('*.c'), folder / f'_generated/nif/{name}.c', *common]
        objects = []
        for i, src in enumerate(sources):
            obj = WORK / f'{app}-{i}.obj'
            run([clang, '/nologo', '/O2', '/MD', '/std:c11', '/DBUNDLEX_NIF',
                 '/D_CRT_SECURE_NO_WARNINGS', *['/I' + str(p) for p in [folder, folder / '_generated/nif', *includes, *more_includes]],
                 '/c', src, '/Fo' + str(obj)])
            objects.append(obj)
        run(['link', '/NOLOGO', '/DLL', '/OUT:' + str(out / f'{name}.dll'), *objects, *libs,
             'ws2_32.lib', 'crypt32.lib', 'advapi32.lib', 'user32.lib', 'bcrypt.lib'])
    crc = DEPS / 'crc/c_src/nif'
    crc_out = app_root / 'crc/priv'
    crc_out.mkdir(parents=True, exist_ok=True)
    run(['cl', '/nologo', '/LD', '/O2', '/MD', '/I' + str(OTP / 'usr/include'),
         '/I' + str(crc), *crc.glob('*.c'), '/Fo' + str(WORK) + '/',
         '/link', '/OUT:' + str(crc_out / 'crc_nif.dll')], WORK)
    # Copy Elixir support apps and dependency licenses beside the native bundle.
    for app in ['elixir','eex','logger']:
        shutil.copytree(TOOLS / 'elixir/lib' / app, app_root / app, dirs_exist_ok=True)
    for dep in DEPS.iterdir():
        dest = app_root / dep.name
        if dest.exists():
            for notice in dep.glob('*'):
                if notice.is_file() and notice.name.upper().startswith(('LICENSE','COPYING','NOTICE')):
                    shutil.copy2(notice, dest / notice.name)
    licenses = app_root / 'parvi_transport'
    for base in [openssl, srtp]:
        for notice in base.glob('*'):
            if notice.is_file() and notice.name.upper().startswith(('LICENSE','COPYING','NOTICE')):
                shutil.copy2(notice, licenses / (base.name + '-' + notice.name))
    print('Prepared native libraries:', app_root)


if __name__ == '__main__':
    WORK.mkdir(parents=True, exist_ok=True)
    stage()
    native()
