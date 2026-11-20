"""Fetch the pinned, checksum-verified Windows build tools into this checkout.

OTP goes to builds/intermediates/Windows/otp and rebar3 to
builds/intermediates/tools/rebar3. Nothing is installed system-wide. A download
takes its final name only after its checksum passes, so an interrupted one is
fetched again on the next run instead of failing every build.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / 'builds/intermediates/Windows'
OTP_VERSION = '29.1.2'
OTP = dict(url=f'https://github.com/erlang/otp/releases/download/OTP-{OTP_VERSION}/otp_win64_{OTP_VERSION}.zip',
           sha256='4efe9772a84c6c1ef75377e9326815584958776c905f2bf687b62509e2d809c0')
# rebar3 3.28.0 release asset; a versioned URL keeps the pin valid after new releases.
REBAR = dict(url='https://github.com/erlang/rebar3/releases/download/3.28.0/rebar3',
             sha256='5a28b1cca082d3b023ec0f5df9d9f9d52557036c6f2a21c1ffa11b93a984dd42')


def digest(path):
    hash = hashlib.sha256()
    with path.open('rb') as data:
        for block in iter(lambda: data.read(1 << 20), b''):
            hash.update(block)
    return hash.hexdigest()


def fetch(pinned, target):
    """Download pinned['url'] to target unless present; verify pinned['sha256'] either way.

    Windows' own curl.exe (Schannel) validates TLS with the Windows certificate
    store, including corporate roots and missing intermediates that Python's
    OpenSSL rejects.
    """
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        partial = target.with_name(target.name + '.partial')
        print('Downloading', pinned['url'], flush=True)
        curl = Path(os.environ.get('SystemRoot', r'C:\Windows')) / 'System32/curl.exe'
        subprocess.run([str(curl), '--fail', '--location', '--retry', '3', '--silent', '--show-error',
                        '--output', str(partial), pinned['url']], check=True)
        if digest(partial) != pinned['sha256']:
            partial.unlink()
            raise RuntimeError(f'Downloaded {target.name} failed its checksum; it was discarded. '
                               'Retry, and investigate if it fails again.')
        partial.replace(target)
    elif digest(target) != pinned['sha256']:
        raise RuntimeError(f'Checksum mismatch: {target}. Delete it to download again; '
                           'investigate if a fresh download also fails.')
    return target


def main():
    archive = fetch(OTP, WORK / f'downloads/otp_win64_{OTP_VERSION}.zip')
    otp = WORK / 'otp'
    if not (otp / 'bin/erl.exe').is_file():
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(otp)
    fetch(REBAR, ROOT / 'builds/intermediates/tools/rebar3')
    print(f'OTP {OTP_VERSION} and rebar3 ready under {ROOT / "builds/intermediates"}', flush=True)


if __name__ == '__main__':
    main()
