#!/usr/bin/env python3
"""Real independent CLI VMs and local sockets; no Buffee/network/audio hardware."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'bin/beam-audio'

with tempfile.TemporaryDirectory(prefix='ba-cli-check-') as directory:
    env = dict(os.environ, BA_CLI_HOME=directory)

    def run(*args, ok=True):
        result = subprocess.run([str(CLI), *args], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=35)
        if ok:
            assert result.returncode == 0, (args, result.stderr)
            return json.loads(result.stdout)
        assert result.returncode != 0, args
        return result

    try:
        help_result = subprocess.run([str(CLI), '--help'], env=env, capture_output=True, text=True, timeout=10)
        assert help_result.returncode == 0 and 'inspect' in help_result.stdout
        assert not list(Path(directory).iterdir()), 'help created state'
        run('new', 'device', '--devicename', '../invalid', ok=False)
        run('new', 'device', '--devicename', 'bad', '--enable', 'publish', ok=False)
        run('new', 'device', '--devicename', 'badtimeout', '--timeout', '0ms', ok=False)
        assert not Path(directory, 'badtimeout').exists(), 'invalid timeout launched a Device'
        for name in ['test1', 'test2']:
            response = run('new', 'device', '--devicename', name, '--timeout', '10s')
            assert response['condition'] == 'endpoint'
        one = run('inspect', 'device', '--devicename', 'test1')
        two = run('inspect', 'device', '--devicename', 'test2')
        for name, view in [('test1', one), ('test2', two)]:
            assert view['profile'] == 'buffee_control'
            assert view['managed']['node'] == 'nonode@nohost'
            assert view['managed']['name'] == name
            assert view['buffee']['state'] == 'idle'
            assert not any(view['consent'].values())
            record_path = Path(directory, name, 'running.json')
            assert record_path.stat().st_mode & 0o077 == 0
            assert Path(directory, name, 'identity.seed').stat().st_mode & 0o077 == 0
            record = json.loads(record_path.read_text())
            assert Path(record['socket']).stat().st_mode & 0o777 == 0o600
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.connect(record['socket'])
                connection.sendall(b'{"instance":"wrong","method":"stop"}\n')
                assert json.loads(connection.recv(4096))['error'] == 'Device instance mismatch.'
        assert one['device'] != two['device']
        assert one['managed']['os_pid'] != two['managed']['os_pid']
        assert one['managed']['instance'] != two['managed']['instance']
        run('new', 'device', '--devicename', 'test1', ok=False)
        assert run('inspect', 'device', '--devicename', 'test1')['managed']['instance'] == one['managed']['instance']
        run('wait', 'device', '--devicename', 'test1,test2', '--until', 'endpoint', '--timeout', '1s')
        failure = run('wait', 'device', '--devicename', 'test1,test2', '--until', 'ready', '--timeout', '100ms', ok=False)
        assert json.loads(failure.stderr)['error'] == 'readiness_timeout'
        run('get', 'buffee', '--devicename', 'test1', ok=False)
        run('get', 'invitation', '--devicename', 'test1', ok=False)
        run('stop', 'device', '--devicename', 'test1')
        assert run('inspect', 'device', '--devicename', 'test2')['device'] == two['device']
        # Explicit new, not saved start/restore: only identity persists in step 1/2.
        run('new', 'device', '--devicename', 'test1', '--timeout', '10s')
        again = run('inspect', 'device', '--devicename', 'test1')
        assert again['device'] == one['device']
        assert again['managed']['instance'] != one['managed']['instance']
        assert again['buffee']['state'] == 'idle' and not any(again['consent'].values())
        run('kill', 'device', '--devicename', 'test1')
        run('stop', 'device', '--all')
        assert not list(Path(directory).glob('*/running.json'))
        assert not list(Path(directory).glob('*/launch.json'))
        print('CLI smoke passed: independent VMs, protected local API, identity isolation, readiness, stop/kill; no audio/Buffee.')
    finally:
        for name in ['test1', 'test2']:
            subprocess.run([str(CLI), 'stop', 'device', '--devicename', name, '--timeout', '2s'],
                           env=env, capture_output=True, timeout=25)
