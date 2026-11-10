"""Reuse one signed invitation across fresh gatherings through a real local Desk."""
import importlib.util
import argparse
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


control = load('control', HERE / 'swarm-control-smoke.py')
relay = load('relay', HERE.parent / 'ReceptionDesk/relay-smoke.py')
relay.ERL = Path(shutil.which('erl'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url',help='Use an existing Desk instead of starting a local one')
    args=parser.parse_args()
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    output = control.ROOT / 'builds/intermediates/reusable-invitation-check'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(output),
                    str(HERE / 'ba_swarm_control_probe.erl')], check=True)
    paths = [output, *list((control.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin'))]
    runtimes = []
    desk = None if args.url else relay.start_desk(port)
    try:
        with tempfile.TemporaryDirectory() as state:
            def runtime(name):
                r = control.Runtime(paths, state=str(Path(state) / name))
                runtimes.append(r)
                return r

            def authorized(r):
                return control.wait(r, lambda s: s['membership']['state'] == 'authorized')['membership']

            url = args.url or f'ws://127.0.0.1:{port}/relay/v1'
            original = runtime('original')
            assert original.request('create', desks=[url])['ok']
            old = authorized(original)
            shared = original.request('invite')['value']
            assert original.request('invite')['value'] == shared
            # This signed fixture has a timestamp in 1970. Both parsing and
            # admission must ignore it, not merely the browser's validation.
            link = original.request('invite_expired')['value']
            member = runtime('member')
            assert member.request('join', invitation=link, desk=url)['ok']
            first = authorized(member)
            assert first['captain'] == original.identity['id']
            assert first['swarm'] == old['swarm']
            assert original.request('grant', peer=member.identity['id'], permissions=['status_read'])['ok']
            assert original.request('end_swarm')['ok']
            deadline=time.monotonic()+10
            while member.request('lifecycle')['swarm'] != {'state': 'idle'}:
                assert time.monotonic()<deadline, 'Member did not stop the old gathering'
                time.sleep(.1)
            # An unrelated Device bearing the old link becomes a new Captain.
            captain = runtime('new-captain')
            assert captain.request('join', invitation=link, desk=url)['ok']
            fresh = authorized(captain)
            assert fresh['role'] == 'authority' and fresh['captain'] == captain.identity['id']
            assert fresh['swarm'] == old['swarm']
            assert fresh['members'] == [captain.identity['id']]
            assert captain.request('invite')['value'] == link
            assert member.request('join_swarm', invitation=link)['ok']
            joined = authorized(member)
            assert joined['captain'] == captain.identity['id'] and joined['swarm'] == old['swarm']
            assert joined['membership'] != first['membership']
            other = runtime('other')
            assert other.request('join', invitation=link, desk=url)['ok']
            assert authorized(other)['captain'] == captain.identity['id']
            # Revocation remains scoped to the current gathering.
            assert captain.request('revoke', peer=other.identity['id'])['ok']
            control.wait(other, lambda s: s['membership']['state'] == 'revoked')
            assert other.request('leave_swarm')['ok']
            assert other.request('join_swarm', invitation=link)['ok']
            control.wait(other, lambda s: s['membership']['state'] == 'revoked')
            assert captain.request('end_swarm')['ok']
            # Reusing a previous Captain's identity must not discover its stale
            # advertisement and mistakenly try to join itself.
            assert original.request('join_swarm', invitation=link)['ok']
            again=authorized(original)
            assert again['role']=='authority' and again['captain']==original.identity['id']
            assert again['swarm']==old['swarm'] and again['members']==[original.identity['id']]
            assert original.request('end_swarm')['ok']
            observer=runtime('observer')
            assert observer.request('set_observer')['ok']
            assert observer.request('join',invitation=link,desk=url)['ok']
            time.sleep(1.5)
            waiting=observer.request('snapshot')['membership']
            assert waiting['role']=='discovering' and waiting['state']=='waiting'
            print('PASS: no expiry; existing Captain discovery; old link starts same Swarm with fresh Captain/membership; identical link sharing; later joiners; current revocation retained.')
    finally:
        for runtime in runtimes:
            runtime.close()
        if desk:
            desk.terminate()
            try:
                desk.wait(timeout=5)
            except subprocess.TimeoutExpired:
                desk.kill()
                desk.wait()


if __name__ == '__main__':
    main()
