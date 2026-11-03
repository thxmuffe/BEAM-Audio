"""Real ex_webrtc peers: chat must survive termination of an isolated desk."""
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import os
import shlex
import shutil
import socket
import subprocess

ROOT = Path(__file__).resolve().parents[2]
spec = spec_from_file_location('relay_smoke', ROOT / 'tests/ReceptionDesk/relay-smoke.py')
r = module_from_spec(spec)
spec.loader.exec_module(r)
otp = Path(subprocess.check_output([shutil.which('erl'), '-noshell', '-eval',
    'io:put_chars(code:root_dir()), halt().'], text=True))
r.ERL = next(otp.glob('erts-*/bin/erlexec'))
os.environ.update(ROOTDIR=str(otp), BINDIR=str(r.ERL.parent), EMU='beam', PROGNAME='erl')
r.APP = ROOT / 'builds/intermediates/control/default/lib/parvi'
transport = list((ROOT / 'builds/intermediates/BeamTransport/dev/lib').glob('*/ebin'))
transport += list((ROOT / 'builds/intermediates/tools/elixir/lib').glob('*/ebin'))
core = list((ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin'))
flags = shlex.join(['-pa', *map(str, transport + core)])
native_env = {'ERL_FLAGS': flags, 'DYLD_FALLBACK_LIBRARY_PATH': '/opt/homebrew/opt/openssl@3/lib'}

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
desk = r.start_desk(port)
nodes = []
try:
    url = f'ws://127.0.0.1:{port}/relay/v1'
    a, b = [r.Node(url, native_env) for _ in range(2)]
    nodes += [a, b]
    sa, sb = [r.wait(n, lambda s: s['relay']['connected']) for n in nodes]
    assert all(s['direct']['enabled'] for s in [sa, sb])
    group = sa['swarms'][0]
    assert b.request('join_swarm', invitation=group['invitation'])['error'] is None
    r.wait(a, lambda s: sb['node'] in s['direct']['peers'])
    r.wait(b, lambda s: sa['node'] in s['direct']['peers'])
    other = a.request('create_swarm')
    second = r.swarm(other, other['result']['swarm_id'])
    assert b.request('join_swarm', invitation=second['invitation'])['error'] is None

    desk.kill()  # Deliberate crash: graceful Phoenix shutdown drains live sockets.
    desk.wait(timeout=5)
    for n in nodes:
        r.wait(n, lambda s: not s['relay']['connected'] and len(s['direct']['peers']) == 1)
    for sender, receiver, text in [(a, b, 'BEAM direct: desk is gone'), (b, a, 'BEAM direct reply')]:
        assert sender.request('send_swarm', swarm_id=group['id'], text=text)['error'] is None
        state = r.wait(receiver, lambda s: any(m['text'] == text for m in r.swarm(s, group['id'])['messages']))
        assert all(n['state'] == 'running' for n in state['network']['nodes'])
    assert a.request('send_swarm', swarm_id=second['id'], text='Other swarm stays separate')['error'] is None
    r.wait(b, lambda s: any(m['text'] == 'Other swarm stays separate' for m in r.swarm(s, second['id'])['messages']))
    assert not any(m['text'] == 'Other swarm stays separate' for m in r.swarm(b.request(), group['id'])['messages'])
    assert b.request('leave_swarm', swarm_id=group['id'])['error'] is None
    r.wait(a, lambda s: len(r.swarm(s, group['id'])['members']) == 1 and len(s['direct']['peers']) == 1)

    desk = r.start_desk(port)
    for n in nodes:
        r.wait(n, lambda s: s['relay']['connected'])
    legacy = r.Node(url, {'ERL_FLAGS': shlex.join(['-pa', *map(str, core)])})
    nodes.append(legacy)
    r.wait(legacy, lambda s: s['relay']['connected'])
    assert legacy.request('join_swarm', invitation=r.swarm(a.request(), second['id'])['invitation'])['error'] is None
    assert legacy.request('send_swarm', swarm_id=second['id'], text='Relay-only peer still works')['error'] is None
    r.wait(a, lambda s: any(m['text'] == 'Relay-only peer still works' for m in r.swarm(s, second['id'])['messages']))
    print('PASS: third-party BEAM WebRTC; direct chat with desk stopped; scoped swarms; retained shared connection; relay-only interoperability')
finally:
    for node in nodes:
        node.close()
    if desk.poll() is None:
        desk.terminate()
        desk.wait(timeout=5)
