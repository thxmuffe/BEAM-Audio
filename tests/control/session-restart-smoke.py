"""Disposable local Devices retain identity and reconnect after restarting.
Forgetting a Session prevents automatic return; an explicit Join restores it.
"""
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
relay = load('relay', HERE.parent / 'ReceptionDesk/local_reception.py')
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
            # The link carries no name; the joiner learns it from the creator's signed policy.
            until('name learned', lambda: api(b, method='snapshot').get('buffee', {}).get('name') == 'Restart test')
            print('link length', len(link))
            # Both restart: every mailbox is new.
            seeds = (a.seed, b.seed); identities = (a.identity['id'], b.identity['id'])
            a.close(); b.close(); devices.clear()
            a = device('creator', seeds[0]); b = device('member', seeds[1])
            assert (a.identity['id'], b.identity['id']) == identities
            until('creator back as authority', lambda: api(a, method='snapshot').get('buffee', {}).get('state') == 'authorized')
            until('member let back in', lambda: api(b, method='snapshot').get('buffee', {}).get('state') == 'authorized', 90)
            until('link after both restarted', lambda: linked(a, b) and linked(b, a), 90)
            api(a, method='send', text='after restart')
            until('chat after restart', lambda: any(m.get('text') == 'after restart' for m in api(b, method='snapshot').get('messages', [])))
            print('PASS: both Devices restarted with new mailboxes and stable identities; linked and exchanged chat', flush=True)
            # Leave keeps a grant holder's return record. Forget must override
            # that record without affecting another Device's participation.
            session_id = api(a, method='snapshot')['buffee']['buffee']
            assert api(a, method='leave_buffee').get('error') is None
            assert api(a, method='forget_saved_session', entry=session_id).get('error') is None
            a.close(); a = device('creator', seeds[0])
            snap = api(a, method='snapshot')
            assert snap['buffee']['state'] == 'idle'
            assert session_id not in snap['contacts']['sessions']
            assert api(b, method='snapshot')['buffee']['buffee'] == session_id
            print('PASS: forgotten Session stays absent after a cold restart; other Device keeps its Session', flush=True)
            assert api(a, method='join_buffee', invitation=link).get('error') is None
            until('explicit return', lambda: linked(a, b) and linked(b, a))
            snap = api(a, method='snapshot')
            assert snap['device'] == a.identity['id']
            assert 'grant' in snap['buffee']['privileges']
            assert session_id in snap['contacts']['sessions']
            a.close(); a = device('creator', seeds[0])
            until('return restored after explicit Join', lambda: linked(a, b) and linked(b, a))
            assert session_id in api(a, method='snapshot')['contacts']['sessions']
            print('PASS: explicit Join remembers the same Session and privileges; next restart restores it', flush=True)
            # Forget also discards delegated privileges. With every other
            # Device offline, rejoining must not recover them from local disk.
            assert api(a, method='grant_privilege', device=b.identity['id'], privilege='grant').get('error') is None
            until('delegated grant', lambda: 'grant' in api(b, method='snapshot')['buffee'].get('privileges', []))
            assert api(b, method='leave_buffee').get('error') is None
            assert api(b, method='forget_saved_session', entry=session_id).get('error') is None
            a.close(); b.close(); b = device('member', seeds[1])
            assert api(b, method='snapshot')['buffee']['state'] == 'idle'
            assert api(b, method='join_buffee', invitation=link).get('error') is None
            snap = api(b, method='snapshot')
            assert snap['device'] == identities[1]
            assert not {'grant', 'on_air', 'end_session'} & set(snap['buffee']['privileges'])
            assert snap['buffee']['revision'] == 0
            print('PASS: Forget removes saved delegated privileges; offline rejoin uses only the initial policy', flush=True)
    finally:
        for d in devices: d.close()
        if desk: desk.terminate(); desk.wait(timeout=5)

if __name__ == '__main__':
    main()
