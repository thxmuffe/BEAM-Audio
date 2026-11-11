"""Independent handlers on the same named hardware advertise distinct UI labels."""
import importlib.util
import socket
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

control = load('control', HERE / 'swarm-control-smoke.py')
relay = load('relay', HERE.parent / 'ReceptionDesk/relay-smoke.py')

def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    output = control.ROOT / 'builds/intermediates/device-label-check'
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(['erlc', '-Werror', '-o', str(output), str(HERE / 'ba_swarm_control_probe.erl')], check=True)
    paths = [output, *list((control.ROOT / 'builds/intermediates/control/default/lib').glob('*/ebin'))]
    desk = relay.start_desk(port)
    runtimes = []
    try:
        for _ in range(2):
            runtimes.append(control.Runtime(paths, extra_env={'BA_DEVICE_NAME': 'MacBook Air'}))
        a, b = runtimes
        url = f'ws://127.0.0.1:{port}/relay/v1'
        assert a.request('create', desks=[url])['ok']
        assert b.request('join', invitation=a.request('invite')['value'], desk=url)['ok']
        control.wait(b, lambda s: s['membership']['state'] == 'authorized')
        assert a.request('grant', peer=b.identity['id'], permissions=['capabilities_read', 'status_read'])['ok']
        control.wait(b, lambda s: s['membership']['revision'] >= 3)
        assert a.request('connect', peer=b.identity['id'])['ok']
        names = []
        for local, peer in ((a, b), (b, a)):
            state = control.wait(local, lambda s: peer.identity['id'] in s.get('peer_names', {}))
            remote_name = state['peer_names'][peer.identity['id']]
            assert remote_name.startswith('MacBook Air | '), state
            app = local.request('start_runtime')
            row = next(d for d in app['devices'] if d['id'] == peer.identity['id'])
            assert row['name'] == remote_name
            assert app['device_name'] != remote_name
            names.append(app['device_name'])
        assert len(set(names)) == 2
        print('PASS: authenticated capability discovery and app snapshots distinguish two handlers with the same hardware name; no audio hardware.')
    finally:
        for runtime in runtimes:
            runtime.close()
        desk.terminate()
        desk.wait(timeout=5)

if __name__ == '__main__':
    main()
