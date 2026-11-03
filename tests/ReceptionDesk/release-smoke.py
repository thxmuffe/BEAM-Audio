"""Boot the packaged Windows production release on a temporary loopback port."""
import os
from pathlib import Path
import socket
import subprocess
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    release = ROOT / 'builds/Services/ReceptionDesk/bin/reception_desk.bat'
    assert release.exists(), 'Build mix release first'
    env = {**os.environ, 'PORT': str(port), 'PARVI_BROKER_BIND': '127.0.0.1',
           'RELEASE_DISTRIBUTION': 'none', 'SECRET_KEY_BASE': 'local-release-smoke-' * 8}
    proc = subprocess.Popen([os.environ['COMSPEC'], '/d', '/c', str(release), 'start'],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(150):
            if proc.poll() is not None:
                raise RuntimeError('Release exited before health check')
            try:
                with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=.2) as response:
                    assert response.status == 200
                    print('PASS: production release boots with runtime configuration and Distributed Erlang disabled')
                    break
            except OSError:
                time.sleep(.1)
        else:
            raise TimeoutError('Release startup')
    finally:
        # Only this test's tracked launcher and its children; no user sessions.
        subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        proc.wait(timeout=5)


if __name__ == '__main__':
    main()
