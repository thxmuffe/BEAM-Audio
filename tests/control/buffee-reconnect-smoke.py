"""App-style OTP startup restores a participant, not a dead Owner's gathering."""
import importlib.util
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

control = load('control', HERE / 'buffee-control-smoke.py')
relay = load('relay', HERE.parent / 'ReceptionDesk/relay-smoke.py')
relay.ERL = Path(shutil.which('erl'))

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
paths = list((control.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin'))
output = control.ROOT / 'builds/intermediates/buffee-reconnect-check'
output.mkdir(parents=True, exist_ok=True)
subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(output),
                str(HERE / 'ba_buffee_control_probe.erl')], check=True)
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
        old = control.wait(member, lambda s: s['membership']['state'] == 'authorized')['membership']
        # A saved Passport replaces the admission link: no invitation required at restart.
        saved_path = Path(state) / 'member' / 'buffee_connection.term'
        assert saved_path.exists() and saved_path.stat().st_mode & 0o777 == 0o600
        seed = member.seed
        assert member.request('disconnect_app')['ok']
        assert member.request('buffee_status') == {'state': 'idle'}
        member.close()
        member = runtime('member', seed)
        first = member.request('start_app')
        assert 'connection' in first, first
        assert first['connection']['name'] == 'Test gathering'
        assert first['connection']['state'] in ('rejoining', 'joined')
        restored = control.wait(member, lambda s: s['membership']['state'] == 'authorized')['membership']
        assert restored['buffee'] == old['buffee']
        assert restored['membership'] == old['membership']
        assert member.request('start_app')['connection']['state'] == 'joined'
        # A persisted Passport cannot bypass removal while the app is closed.
        assert member.request('disconnect_app')['ok']
        member.close()
        assert owner.request('revoke', peer=member.identity['id'])['ok']
        member = runtime('member', seed)
        member.request('start_app')
        control.wait(member, lambda s: s['membership']['state'] == 'revoked')
        assert member.request('start_app')['connection']['state'] == 'revoked'
        # An explicit Leave differs from closing the app: it clears reconnect intent.
        assert member.request('leave_buffee')['ok']
        member.close()
        member = runtime('member', seed)
        fresh = member.request('start_app')
        assert fresh['buffee'] == {'state': 'idle'} and fresh['connection'] == {'state': 'idle'}
        # Restarting a Owner must not manufacture a new gathering under the old name.
        owner_seed = owner.seed
        owner.close()
        for platform in ('mac', 'ios'):
            owner = runtime('owner', owner_seed, platform=platform)
            # Plain application startup, before any bridge/UI configure call.
            ended = owner.request('start_runtime')
            assert ended['buffee'] == {'state': 'idle'}
            assert ended['connection']['state'] == 'ended'
            assert ended['connection']['name'] == 'Test gathering'
            owner.close()
        print('PASS: OTP immediately restores participant from saved Passport; same membership and Buffee; private storage; revocation still enforced; explicit Leave clears intent; Owner restart explains ended gathering; no UI or audio')
finally:
    for r in runtimes:
        r.close()
    desk.terminate()
    try:
        desk.wait(timeout=5)
    except subprocess.TimeoutExpired:
        desk.kill()
        desk.wait()
