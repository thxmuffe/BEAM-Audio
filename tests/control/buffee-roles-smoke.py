"""Three real local Devices: shared ownership, participation and owner return."""
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

def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    output = control.ROOT / 'builds/intermediates/buffee-control-check'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(output), str(HERE / 'ba_buffee_control_probe.erl')], check=True)
    paths = [output, *(control.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin')]
    devices = []
    desk = relay.start_desk(port)
    try:
        with tempfile.TemporaryDirectory() as state:
            def device(name, seed=None):
                d = control.Runtime(paths, seed=seed, state=str(Path(state) / name))
                devices.append(d)
                return d
            def role(d, wanted):
                return control.wait(d, lambda s: s['membership']['state'] == 'authorized' and s['membership']['role'] == wanted)
            def revision(d, rev):
                return control.wait(d, lambda s: s['membership']['revision'] == rev)
            url = f'ws://127.0.0.1:{port}/relay/v1'
            a = device('owner')
            a.request('clock_prepare',interval_ms=1000,samples=2)
            assert a.request('create', desks=[url])['ok']
            control.wait(a, lambda s: s['relay']['desks'][url]['connected'])
            invitation = a.request('invite')['value']
            b, c = device('second'), device('third')
            for d in (b, c):
                d.request('clock_prepare',interval_ms=1000,samples=2)
                assert d.request('join', invitation=invitation, desk=url)['ok']
                role(d, 'guest')
            assert a.request('grant',peer=b.identity['id'],permissions=['stream_publish','time_read'])['ok']
            assert a.request('grant',peer=c.identity['id'],permissions=['time_read'])['ok']
            role(b, 'chef')
            assert b.request('set_role', peer=c.identity['id'], role='chef') == {'error': 'owner_only'}
            assert a.request('set_role', peer=b.identity['id'], role='owner')['ok']
            assert role(b, 'owner')['membership']['roles'] == ['owner', 'chef']
            rev = a.request('snapshot')['membership']['revision']
            revision(c, rev)
            import time
            deadline=time.monotonic()+10
            while not all(d.request('clock_snapshot')['state']=='synchronized' for d in (a,b,c)):
                assert time.monotonic()<deadline, [(d.identity["id"][:8],d.request("clock_snapshot")) for d in (b,c)]
                time.sleep(.05)
            timeline=b.request('clock_snapshot')['timeline']
            first_id, first_seed = a.identity['id'], a.seed
            assert a.request('leave_buffee')['ok']
            assert b.request('set_role', peer=c.identity['id'], role='chef')['ok']
            role(c, 'chef')
            deadline=time.monotonic()+10
            while not all(d.request('clock_snapshot')['state']=='synchronized' for d in (b,c)):
                assert time.monotonic()<deadline, [(d.identity["id"][:8],d.request("clock_snapshot")) for d in (b,c)]
                time.sleep(.05)
            assert b.request('clock_snapshot')['timeline']==timeline
            assert c.request('clock_snapshot')['timeline']==timeline
            # Removing ownership does not stop a Chef or its clock service.
            assert b.request('set_role',peer=b.identity['id'],role='remove_owner')['ok']
            role(b,'chef')
            deadline=time.monotonic()+10
            while not all(d.request('clock_snapshot')['state']=='synchronized' for d in (b,c)):
                assert time.monotonic()<deadline, [(d.identity["id"][:8],d.request("clock_snapshot")) for d in (b,c)]
                time.sleep(.05)
            assert b.request('clock_snapshot')['timeline']==timeline
            assert not b.request('snapshot')['membership']['owner_present']
            assert b.request('start_runtime')['connection']['state']=='joined'
            a.close()
            a = device('owner', first_seed)
            assert a.identity['id'] == first_id
            a.request('start_app')
            role(a, 'owner')
            control.wait(a, lambda s: s['membership']['revision'] == b.request('snapshot')['membership']['revision'])
            # The returning owner keeps its original Buffee identity.
            assert a.request('snapshot')['membership']['buffee'] == b.request('snapshot')['membership']['buffee']
            assert a.request('set_role',peer=b.identity['id'],role='owner')['ok']
            role(b,'owner')
            assert b.request('set_role', peer=first_id, role='remove_owner')['ok']
            role(a, 'chef')
            assert a.request('set_role', peer=c.identity['id'], role='guest') == {'error': 'owner_only'}
            assert b.request('end_buffee')['ok']
            for d in (a, b, c):
                import time
                deadline = time.monotonic() + 10
                while d.request('buffee_status') != {'state': 'idle'}:
                    assert time.monotonic() < deadline
                    time.sleep(.1)
            saved_seed=b.seed;b.close();b=device('second',saved_seed);b.request('start_app')
            assert b.request('buffee_status')=={'state':'idle'}
            print('PASS: Guest/Chef permissions; shared ownership; owner return; acquired clock continues with Chefs and no online Owner; ownership removal; any Owner destroys the Buffee (software timing only)')
    finally:
        for d in devices:
            d.close()
        desk.terminate()
        desk.wait(timeout=5)

if __name__ == '__main__':
    main()
