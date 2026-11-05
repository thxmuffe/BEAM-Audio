"""Run native-window reload tests against a private copy of the compiled app."""
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import tempfile

from smoke import Node, ROOT, REPO, APP_REPO, ERL, EBIN


def main():
    erlc = ERL.with_name('erlc.exe')
    tests = ROOT / 'parvi_reload_smoke.erl'
    build = (REPO / 'builds/intermediates/Windows').resolve()
    build.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='ui-reload-test-', dir=build) as temp:
        assert Path(temp).resolve().is_relative_to(build)
        ebin = Path(temp) / 'ebin'
        shutil.copytree(EBIN, ebin)
        shutil.copytree(EBIN.parent / 'relay_lib', Path(temp) / 'relay_lib')
        subprocess.run([str(erlc), '-Werror', '-o', str(ebin), str(tests)], check=True)
        gui_cookie = secrets.token_hex(24)
        # One ephemeral cookie for this test cluster keeps UI/reload checks
        # independent of the prototype's per-peer invitation authentication.
        peer = Node(8, cookie=gui_cookie)
        other = Node(7, cookie=gui_cookie)
        try:
            assert peer.request()['node'] == peer.name
            assert other.request()['node'] == other.name
            assert peer.request('connect', node=other.name, cookie=other.cookie)['error'] is None
            env = {**os.environ, 'ERL_EPMD_ADDRESS': '127.0.0.1', 'PARVI_RECEPTION_DESK_URL': '',
                   'PARVI_TEST_PEER': peer.name, 'PARVI_TEST_PEER_COOKIE': peer.cookie,
                   'PARVI_TEST_OTHER': other.name,
                   'PARVI_TEST_UI_SOURCE': str(APP_REPO / 'src/Apps/Windows/src/parvi_windows.erl')}
            result = subprocess.run([str(ERL), '-noshell', '-noinput',
                            '-name', f'parvi_windows_{os.getpid()}9@127.0.0.1',
                            '-setcookie', gui_cookie,
                            '-kernel', 'inet_dist_use_interface', '{127,0,0,1}',
                            '-pa', str(ebin), '-s', 'parvi_reload_smoke', 'main'],
                           timeout=60, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True)
            print(result.stdout)
            result.check_returncode()
            assert 'Callback fun crashed' not in result.stdout, 'wx paint callback failed'
        finally:
            peer.close()
            other.close()


if __name__ == '__main__':
    main()
