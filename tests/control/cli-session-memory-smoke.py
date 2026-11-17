#!/usr/bin/env python3
"""Session memory through the public CLI only: two real Devices, local Reception.
Uses disposable keys/state; no UI, capture or playback hardware.
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

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'bin/beamaudio'
spec = importlib.util.spec_from_file_location('relay', ROOT / 'tests/ReceptionDesk/relay-smoke.py')
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)
relay.ERL = Path(shutil.which('erl'))

with socket.socket() as sock:
    sock.bind(('127.0.0.1', 0))
    port = sock.getsockname()[1]

with tempfile.TemporaryDirectory(prefix='ba-cli-session-memory-') as directory:
    env = dict(os.environ, BA_CLI_HOME=directory)
    desk = relay.start_desk(port)

    def run(*args, scalar=False, ok=True):
        result = subprocess.run([str(CLI), *args, '--timeout', '10s'], cwd=ROOT,
                                env=env, capture_output=True, text=True, timeout=30)
        if not ok:
            assert result.returncode != 0, args[:2]
            return
        assert result.returncode == 0, (args[:2], result.stderr)
        return result.stdout.strip() if scalar else json.loads(result.stdout)

    def inspect(name):
        return run('inspect', 'device', '--devicename', name)

    def joined(name, session_id, peer):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            state = inspect(name)
            if (state['buffee'].get('buffee') == session_id and
                    any(d['id'] == peer and d['state'] == 'authorized' for d in state['devices'])):
                return state
            time.sleep(.1)
        raise AssertionError(f'{name} did not reconnect to its peer')

    try:
        url = f'ws://127.0.0.1:{port}/relay/v1'
        run('new', 'device', '--devicename', 'creator', '--createbuffee', '--desk', url)
        creator = inspect('creator')
        session_id = creator['buffee']['buffee']
        invitation = run('get', 'invitation', '--devicename', 'creator', scalar=True)
        run('new', 'device', '--devicename', 'member', '--joinbuffee', invitation)
        member = joined('member', session_id, creator['device'])
        assert not any(member['consent'].values())
        identity = member['device']
        frame = run('monitor', '--all', '--devicename', 'member', '--once', '--json', '--metrics')
        local = next(row for row in frame['devices'] if row['id'] == identity)
        assert local['state'] == 'ok' and 'audio_diagnostics' in local['capabilities']
        assert all(not row['consent'] for row in local['capabilities']['audio'].values())
        print('PASS: CLI exposes diagnostic JSON without enabling audio or creating an observer', flush=True)

        run('stop', 'device', '--devicename', 'member')
        run('new', 'device', '--devicename', 'member')
        assert joined('member', session_id, creator['device'])['device'] == identity
        print('PASS: public CLI restart retains Device identity and returns to its Session', flush=True)

        run('forget', 'session', '--devicename', 'member', '--sessionid', 'invalid', ok=False)
        forgotten = run('forget', 'session', '--devicename', 'member', '--sessionid', session_id)
        assert forgotten['buffee']['state'] == 'idle'
        assert session_id not in forgotten['contacts']['sessions']
        other = inspect('creator')
        assert other['buffee']['buffee'] == session_id and 'grant' in other['buffee']['privileges']
        assert other['device'] == creator['device']

        run('stop', 'device', '--devicename', 'member')
        run('new', 'device', '--devicename', 'member')
        restarted = inspect('member')
        assert restarted['device'] == identity and restarted['buffee']['state'] == 'idle'
        assert session_id not in restarted['contacts']['sessions']
        print('PASS: CLI Forget stays forgotten after restart; another Device keeps its Session', flush=True)

        run('stop', 'device', '--devicename', 'member')
        run('new', 'device', '--devicename', 'member', '--joinbuffee', invitation)
        returned = joined('member', session_id, creator['device'])
        assert returned['device'] == identity and session_id in returned['contacts']['sessions']
        print('PASS: explicit CLI Join remembers the same Session without changing Device identity', flush=True)
    finally:
        subprocess.run([str(CLI), 'stop', 'device', '--all', '--timeout', '5s'],
                       env=env, capture_output=True, timeout=30)
        desk.terminate()
        desk.wait(timeout=10)
