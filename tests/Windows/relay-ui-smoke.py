"""An isolated native window joins a peer through a temporary reception desk."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('relay_smoke', ROOT / 'tests/ReceptionDesk/relay-smoke.py')
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def main():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        port = s.getsockname()[1]
    desk = r.start_desk(port)
    peer = r.Node(f'ws://127.0.0.1:{port}/relay/v1')
    build = (ROOT / 'builds/intermediates/Windows').resolve()
    try:
        state = r.wait(peer, lambda s: s['relay']['connected'])
        swarm = state['swarms'][0]
        with tempfile.TemporaryDirectory(dir=build) as temp:
            assert Path(temp).resolve().is_relative_to(build)
            subprocess.run([str(r.ERL.with_name('erlc.exe')), '-Werror', '-o', temp,
                str(ROOT / 'tests/Windows/parvi_relay_ui_smoke.erl')], check=True)
            subprocess.run([str(r.ERL), '-noshell', '-noinput', '-pa', str(r.APP / 'ebin'), temp,
                '-s', 'parvi_relay_ui_smoke', 'main'], check=True, timeout=30,
                env={**os.environ, 'PARVI_RECEPTION_DESK_URL': f'ws://127.0.0.1:{port}/relay/v1',
                     'PARVI_TEST_INVITATION': swarm['invitation']})
            r.wait(peer, lambda s: any(m['text'] == 'native relay send' for m in r.swarm(s, swarm['id'])['messages']))
    finally:
        peer.close()
        desk.terminate()
        desk.wait(timeout=5)


if __name__ == '__main__':
    main()
