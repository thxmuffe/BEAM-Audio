"""App-style OTP startup restores a participant, not a dead Owner's gathering."""
import importlib.util
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

HERE = Path(__file__).resolve().parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

control = load('control', HERE / 'session-control-smoke.py')
relay = load('relay', HERE.parent / 'ReceptionDesk/local_reception.py')
relay.ERL = Path(shutil.which('erl'))

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
paths = list((control.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin'))
output = control.ROOT / 'builds/intermediates/session-reconnect-check'
output.mkdir(parents=True, exist_ok=True)
subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(output),
                str(HERE / 'ba_session_control_probe.erl')], check=True)
paths = [output, *paths]
runtimes = []
desk = relay.start_desk(port)
try:
    with tempfile.TemporaryDirectory() as state:
        def runtime(name, seed=None, platform=None):
            r = control.Runtime(paths, seed=seed, state=str(Path(state) / name),
                                extra_env={'BA_PLATFORM': platform} if platform else {})
            runtimes.append(r)
            return r

        url = f'ws://127.0.0.1:{port}/relay/v1'
        owner = runtime('owner')
        assert owner.request('create', desks=[url])['ok']
        invitation = owner.request('invite')['value']
        member = runtime('member')
        assert member.request('join', invitation=invitation, desk=url)['ok']
        # v6 links carry no name; it arrives in the creator's signed policy.
        old = control.wait(member, lambda s: s['membership']['state'] == 'authorized'
                           and s['membership']['name'] == 'Test gathering')['membership']
        # A saved Passport replaces the admission link: no invitation required at restart.
        saved_path = Path(state) / 'member' / 'session_connection.term'
        # Saved asynchronously after authorization.
        deadline = time.monotonic() + 5
        while not saved_path.exists() and time.monotonic() < deadline:
            time.sleep(.1)
        assert saved_path.exists()
        # Windows has no POSIX permission bits; Python reports 0o666 there.
        if os.name != 'nt':
            assert saved_path.stat().st_mode & 0o777 == 0o600
        seed = member.seed
        assert member.request('disconnect_app')['ok']
        assert member.request('session_status') == {'state': 'idle'}
        member.close()
        member = runtime('member', seed)
        first = member.request('start_app')
        assert 'connection' in first, first
        assert first['connection']['name'] == 'Test gathering', first['connection']
        assert first['connection']['state'] in ('rejoining', 'joined')
        restored = control.wait(member, lambda s: s['membership']['state'] == 'authorized')['membership']
        assert restored['session'] == old['session']
        assert restored['membership'] == old['membership']
        assert member.request('start_app')['connection']['state'] == 'joined'
        # Kick is not Ban: a Device kicked while its app is closed returns
        # through its saved invitation on restart.
        assert member.request('disconnect_app')['ok']
        member.close()
        assert owner.request('revoke', peer=member.identity['id'])['ok']
        member = runtime('member', seed)
        member.request('start_app')
        control.wait(member, lambda s: s['membership']['state'] == 'authorized')
        # An explicit Leave differs from closing the app: it clears reconnect intent.
        assert member.request('leave_session')['ok']
        member.close()
        member = runtime('member', seed)
        fresh = member.request('start_app')
        assert fresh['session'] == {'state': 'idle'} and fresh['connection'] == {'state': 'idle'}
        # A grant holder's restart returns to the same Session through its link.
        owner_seed = owner.seed
        owner.close()
        for platform in ('mac', 'ios'):
            owner = runtime('owner', owner_seed, platform=platform)
            # Plain application startup, before any bridge/UI configure call.
            restarted = owner.request('start_runtime')['connection']
            assert restarted['state'] in ('joined', 'rejoining'), restarted
            assert restarted['name'] == 'Test gathering' and restarted['session'] == old['session']
            owner.close()
        print('PASS: OTP immediately restores participant from its saved link and policy; same Session; private storage; a kicked Device returns by its link; explicit Leave clears intent; grant holder restart returns to the same Session; no UI or audio')
finally:
    for r in runtimes:
        r.close()
    desk.terminate()
    try:
        desk.wait(timeout=5)
    except subprocess.TimeoutExpired:
        desk.kill()
        desk.wait()
