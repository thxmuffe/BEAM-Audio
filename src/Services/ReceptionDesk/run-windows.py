"""Windows Reception (run.sh delegates here under Git Bash).

Prepares a private, checksum-pinned Elixir 1.19.5 under builds/intermediates/tools
with the core's pinned OTP and rebar3 (scripts/platforms/Windows/setup.py),
resolves and compiles the locked dependencies, then runs Reception unless
--setup-only is given. Nothing is installed system-wide.
"""
import os
from pathlib import Path
import subprocess
import sys
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / 'scripts/platforms/Windows'))
from setup import fetch  # noqa: E402  pinned, checksum-verified download via Windows curl
TOOLS = ROOT / 'builds/intermediates/tools'
OTP = Path(os.environ.get('BA_OTP_ROOT', ROOT / 'builds/intermediates/Windows/otp'))
ELIXIR = dict(url='https://github.com/elixir-lang/elixir/releases/download/v1.19.5/elixir-otp-28.zip',
              sha256='ca481510feb6dabc875bba43e44b25c7abafa53bd7a103639851b7aeace8a022')


def elixir():
    target = TOOLS / 'elixir'
    if (target / 'bin/mix.bat').is_file():
        return target
    archive = fetch(ELIXIR, TOOLS / 'elixir.zip')
    with zipfile.ZipFile(archive) as bundle:
        bundle.extractall(target)
    return target


def main(args):
    if not (OTP / 'bin/erl.exe').is_file() or not (TOOLS / 'rebar3').is_file():
        subprocess.run([sys.executable, ROOT / 'scripts/platforms/Windows/setup.py'], check=True)
    mix = elixir() / 'bin/mix.bat'
    env = dict(os.environ, MIX_HOME=str(TOOLS / 'mix'), HEX_HOME=str(TOOLS / 'hex'), MIX_REBAR3=str(TOOLS / 'rebar3'))
    env['PATH'] = os.pathsep.join([str(OTP / 'bin'), str(mix.parent), env['PATH']])
    if not (TOOLS / 'mix/archives').is_dir():
        subprocess.run([mix, 'local.hex', '--force'], cwd=HERE, env=env, check=True)
    subprocess.run([mix, 'deps.get'], cwd=HERE, env=env, check=True)
    subprocess.run([mix, 'compile', '--warnings-as-errors'], cwd=HERE, env=env, check=True)
    if '--setup-only' in args:
        return 0
    return subprocess.run([mix, 'run', '--no-halt'], cwd=HERE, env=env).returncode


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Reception failed: {error}', file=sys.stderr)
        sys.exit(1)
