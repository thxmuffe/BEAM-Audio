"""Windows DeviceWeb launcher (run.sh delegates here under Git Bash).

Compiles the core and DeviceWeb with the pinned Windows OTP/rebar3, then starts
ba_device_web_cli. With --local-device it gives the Device a stable slot: the
slot's lease is a named mutex held until the runtime exits, and its seed lives in
%LOCALAPPDATA%\\BEAM-Audio\\Web\\device-N\\identity.dpapi, protected by Windows
DPAPI for this user (the same files earlier launchers wrote). The core's native
AAC helper is used for audio when it has been built.
"""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import secrets
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
OTP = Path(os.environ.get('BA_OTP_ROOT', ROOT / 'builds/intermediates/Windows/otp'))
REBAR = ROOT / 'builds/intermediates/tools/rebar3'
ERROR_ALREADY_EXISTS = 183
CRYPTPROTECT_UI_FORBIDDEN = 1


class Blob(ctypes.Structure):
    _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_char))]


def dpapi(data, protect):
    crypt, kernel = ctypes.windll.crypt32, ctypes.windll.kernel32
    kernel.LocalFree.argtypes = [ctypes.c_void_p]
    source = ctypes.create_string_buffer(data, len(data))
    inp, out = Blob(len(data), ctypes.cast(source, ctypes.POINTER(ctypes.c_char))), Blob()
    call = crypt.CryptProtectData if protect else crypt.CryptUnprotectData
    if not call(ctypes.byref(inp), None, None, None, None, CRYPTPROTECT_UI_FORBIDDEN, ctypes.byref(out)):
        raise RuntimeError('The saved Web Device identity could not be read for this Windows user.')
    try:
        return ctypes.string_at(out.data, out.size)
    finally:
        kernel.LocalFree(out.data)


def lease():
    """First free Device slot; the returned handle holds it until this process exits."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateMutexW.restype = wintypes.HANDLE
    kernel.CreateMutexW.argtypes = [ctypes.c_void_p, wintypes.BOOL, wintypes.LPCWSTR]
    for slot in range(1, 101):
        handle = kernel.CreateMutexW(None, True, f'Local\\BEAMAudio.Web.{slot}')
        if handle and ctypes.get_last_error() != ERROR_ALREADY_EXISTS:
            return slot, handle
        if handle:
            kernel.CloseHandle(handle)
    raise RuntimeError('All Web Device slots are in use.')


def identity(slot):
    state = Path(os.environ['LOCALAPPDATA']) / f'BEAM-Audio/Web/device-{slot}'
    state.mkdir(parents=True, exist_ok=True)
    saved = state / 'identity.dpapi'
    if saved.exists():
        seed = dpapi(saved.read_bytes(), protect=False)
    else:
        seed = secrets.token_bytes(32)
        saved.write_bytes(dpapi(seed, protect=True))
    if len(seed) != 32:
        raise RuntimeError('The saved Web Device identity is invalid.')
    return state, seed.hex().upper()


def main(args):
    if not (OTP / 'bin/erl.exe').is_file() or not REBAR.is_file():
        subprocess.run([sys.executable, ROOT / 'scripts/platforms/Windows/setup.py'], check=True)
    env = dict(os.environ, REBAR_CACHE_DIR=str(ROOT / 'builds/intermediates/rebar-cache'))
    env['PATH'] = str(OTP / 'bin') + os.pathsep + env['PATH']
    for project in ('src/control', 'src/Services/DeviceWeb'):
        subprocess.run([OTP / 'bin/escript.exe', REBAR, 'compile'], cwd=ROOT / project, env=env, check=True)
    if '--build-only' in args:
        return 0
    paths = [str(p) for project in ('control', 'DeviceWeb')
             for p in (ROOT / f'builds/intermediates/{project}/default/lib').glob('*/ebin')]
    local = '--local-device' in args
    if local and not env.get('BA_IDENTITY_SEED'):
        slot, _handle = lease()  # kept open for the runtime's lifetime
        state, seed = identity(slot)
        env.update(BA_STATE_DIR=str(state), BA_IDENTITY_SEED=seed)
    entry = 'windows_main' if local else 'main'
    return subprocess.run([OTP / 'bin/erl.exe', '-noshell', '-pa', *paths, '-s', 'ba_device_web_cli', entry,
                           '-extra', *args], env=env).returncode


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'DeviceWeb failed: {error}', file=sys.stderr)
        sys.exit(1)
