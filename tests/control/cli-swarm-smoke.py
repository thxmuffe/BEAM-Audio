#!/usr/bin/env python3
"""CLI create/join/scoped reads through a temporary loopback Desk. No audio.
Clock reference/cadence are explicit fixtures, not production timing evidence.
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import signal

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'bin/beam-audio'
spec = importlib.util.spec_from_file_location('relay_fixture', ROOT / 'tests/ReceptionDesk/relay-smoke.py')
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
relay.ERL = Path(shutil.which('erl'))
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]
with tempfile.TemporaryDirectory(prefix='ba-cli-swarm-') as directory:
    # Normal production algorithm with an explicit system reference and short
    # sampling window for this no-audio fixture. CLI defaults remain unchanged.
    flags = '-ba_core clock_reference system clock_filter_samples 3 clock_sample_interval_ms 100'
    env = dict(os.environ, BA_CLI_HOME=directory, ERL_AFLAGS=flags)
    desk = relay.start_desk(port)
    try:
        def run(*args, scalar=False):
            result = subprocess.run([str(CLI), *args], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=40)
            assert result.returncode == 0, (args[:2], result.stderr)
            return result.stdout.strip() if scalar else json.loads(result.stdout)

        url = f'ws://127.0.0.1:{port}/relay/v1'
        run('new', 'device', '--devicename', 'test1', '--createswarm', '--desk', url, '--timeout', '15s')
        swarm = run('get', 'swarm', '--devicename', 'test1', scalar=True)
        invitation = run('get', 'invitation', '--devicename', 'test1', scalar=True)
        assert len(swarm) == 32 and invitation.startswith('parvi://')
        run('new', 'device', '--devicename', 'test2', '--joinswarm', invitation, '--timeout', '15s')
        ready = run('wait', 'device', '--devicename', 'test1,test2', '--until', 'ready', '--timeout', '20s')
        assert ready['state'] == 'ready'
        views = run('inspect', 'swarm', '--swarmid', swarm)['views']
        assert len(views) == 2
        assert all(v['swarm']['swarm'] == swarm and len(v['devices']) == 2 for v in views)
        assert all(v['managed']['node'] == 'nonode@nohost' and not any(v['consent'].values()) for v in views)
        member = run('inspect', 'device', '--devicename', 'test2')
        scoped = run('inspect', 'device', '--devicename', 'test1', '--deviceid', member['device'])
        assert scoped['error'] is None and 'instance' in scoped['result']
        monitor_invitation = run('get', 'invitation', '--devicename', 'test1', scalar=True)
        invitation_file = Path(directory, 'monitor-invitation.txt')
        invitation_file.write_text(monitor_invitation + '\n')
        invitation_file.chmod(0o600)
        def monitor():
            return run('monitor', '--all', '--once', '--json', '--invitation-file', str(invitation_file), '--timeout', '15s')
        frame = monitor()
        end = time.monotonic() + 15
        while not all(row['state'] == 'ok' for row in frame['devices']):
            assert time.monotonic() < end, frame
            frame = monitor()
        assert len(frame['devices']) == 3
        observer_name = 'ba-monitor-' + swarm
        observer = run('inspect', 'device', '--devicename', observer_name)
        assert observer['managed']['observer'] and not any(observer['consent'].values())
        # Foreground monitoring can be interrupted without ending membership.
        view = subprocess.Popen([str(CLI), 'monitor', '--all', '--json', '--interval', '500',
                                 '--invitation-file', str(invitation_file)], env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        assert json.loads(view.stdout.readline())['state'] == 'authorized'
        view.send_signal(signal.SIGINT)
        view.wait(timeout=5)
        assert run('inspect', 'device', '--devicename', observer_name)['swarm']['state'] == 'authorized'
        invitation_file.unlink()
        assert monitor()['state'] == 'authorized', 'active membership required another invitation'
        run('stop', 'device', '--all')
        assert not list(Path(directory).glob('*/running.json'))
        print('CLI Swarm smoke passed: loopback admission, invitation, shared readiness, scoped inspection, teardown; no audio.')
    finally:
        for name in ['test1', 'test2', 'ba-monitor-' + locals().get('swarm', '')]:
            subprocess.run([str(CLI), 'stop', 'device', '--devicename', name, '--timeout', '2s'],
                           env=env, capture_output=True, timeout=25)
        desk.terminate()
        desk.wait(timeout=10)
