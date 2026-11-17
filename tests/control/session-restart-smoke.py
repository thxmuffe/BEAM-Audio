"""Two real local Devices both restart (new mailboxes on both sides) and find each other again.

The member knocks through the invitation link's mailbox, which the creator
re-registers on every start; chat flows again afterwards."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
control = load('control', HERE / 'buffee-control-smoke.py')
relay = load('relay', HERE.parent / 'ReceptionDesk/relay-smoke.py')
relay.ERL = Path(shutil.which('erl'))

def until(what, check, seconds=60):
    deadline = time.monotonic() + seconds
    while True:
        value = check()
        if value: return value
        assert time.monotonic() < deadline, what
        time.sleep(.2)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--url', help='use this Reception (e.g. wss://beamaudio.onrender.com/reception) instead of a local one')
    args = parser.parse_args()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    output = control.ROOT / 'builds/intermediates/buffee-control-check'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(output), str(HERE / 'ba_buffee_control_probe.erl')], check=True)
    paths = [output, *(control.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin')]
    devices = []; desk = None if args.url else relay.start_desk(port)
    try:
        with tempfile.TemporaryDirectory() as state:
            def device(name, seed=None):
                d = control.Runtime(paths, seed=seed, state=str(Path(state) / name)); devices.append(d)
                d.request('configure_app'); d.request('start_app'); return d
            api = lambda d, **r: d.request('api', request=r)
            url = args.url or f'ws://127.0.0.1:{port}/relay/v1'
            a = device('creator')
            made = api(a, method='create_buffee', name='Restart test', desks=[url]); assert made.get('error') is None, made.get('error')
            link = until('invitation', lambda: (lambda r: r.get('result') if isinstance(r.get('result'), str) else None)(api(a, method='invitation')))
            b = device('member')
            assert api(b, method='join_buffee', invitation=link).get('error') is None
            linked = lambda d, other: any(x['id'] == other.identity['id'] and x['state'] == 'authorized' for x in api(d, method='snapshot').get('devices', []))
            until('first link', lambda: linked(a, b) and linked(b, a))
            # Both restart: every mailbox is new.
            seeds = (a.seed, b.seed); a.close(); b.close(); devices.clear()
            a = device('creator', seeds[0]); b = device('member', seeds[1])
            until('creator back as authority', lambda: api(a, method='snapshot').get('buffee', {}).get('state') == 'authorized')
            until('member let back in', lambda: api(b, method='snapshot').get('buffee', {}).get('state') == 'authorized', 90)
            until('link after both restarted', lambda: linked(a, b) and linked(b, a), 90)
            api(a, method='send', text='after restart')
            until('chat after restart', lambda: any(m.get('text') == 'after restart' for m in api(b, method='snapshot').get('messages', [])))
            print('PASS: both Devices restarted with new mailboxes; the member knocked via the link, was let back in, linked, and chat flows')
    finally:
        for d in devices: d.close()
        if desk: desk.terminate(); desk.wait(timeout=5)

if __name__ == '__main__':
    main()
