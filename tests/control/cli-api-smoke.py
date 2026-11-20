#!/usr/bin/env python3
"""Public CLI pass-through against an idle real Device; no Reception/UI/audio.

Checks discovery, JSON argument types, stdin, Session routing and API errors.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
# The same escript on every platform; Windows starts it through the .cmd launcher.
CLI = ROOT / ('scripts/cli/beamaudio.cmd' if os.name == 'nt' else 'scripts/cli/beamaudio')

with tempfile.TemporaryDirectory(prefix='ba-cli-api-') as directory:
    env = dict(os.environ, BA_CLI_HOME=directory)

    def run(*args, stdin=None, code=0):
        result = subprocess.run([str(CLI), *args], env=env, cwd=ROOT,
                                input=stdin, capture_output=True, text=True, encoding='utf-8', timeout=30)
        assert result.returncode == code, (args[:2], result.stderr)
        return json.loads(result.stdout if code == 0 else result.stderr)

    def call(command, stdin=False, code=0):
        text = json.dumps(command, ensure_ascii=False)
        args = ['call', 'device', '--devicename', 'api']
        return run(*args, stdin=text, code=code) if stdin else run(*args, '--request', text, code=code)

    try:
        methods = run('get', 'methods')
        assert {'snapshot', 'offset', 'forget_saved_session', 'monitor', 'configuration', 'new_session'} <= set(methods)
        assert not {'stop', 'kill', 'apply', 'eval'} & set(methods)
        assert not list(Path(directory).iterdir()), 'discovery created Device state'
        run('new', 'device', '--devicename', 'api', '--timeout', '10s')
        original = run('inspect', 'device', '--devicename', 'api')
        snapshot = call({'method': 'snapshot'})
        assert snapshot['device'] == original['device'] and not any(snapshot['consent'].values())

        muted = call({'method': 'speaker_mute', 'muted': True, 'request_id': 'generic-1'})
        assert muted['live']['muted'] is True and muted['request_id'] == 'generic-1'
        group = 'Studio 🎵 "A"'
        grouped = call({'method': 'put_group', 'name': group, 'ids': []}, stdin=True)
        assert grouped['contacts']['groups'][group] == []
        assert call({'method': 'configuration'})['result']['consent'] == original['consent']
        print('PASS: public methods discovered; generic JSON/stdin preserves Unicode, arrays, booleans and request IDs', flush=True)

        slot = call({'method': 'new_session'})['session_id']
        scoped = call({'method': 'snapshot', 'session': slot})
        assert scoped['session_id'] == slot and scoped['device'] == original['device']
        assert slot in {s['id'] for s in call({'method': 'list_sessions'})['sessions']}
        call({'method': 'close_session', 'session': slot})
        print('PASS: generic calls route through the real Session owner, keeping Device identity', flush=True)

        invalid = run('call', 'device', '--devicename', 'api', '--request', '{invalid', code=2)
        assert invalid['error'] == 'Invalid Device API JSON.'
        for command in ([], {'method': 7}, {'method': 'eval'}, {'method': 'stop'},
                        {'method': 'snapshot', 'instance': 'caller-supplied'}):
            call(command, code=2)
        api_error = call({'method': 'ui_set', 'key': 'view', 'value': 'invalid'}, code=1)
        assert api_error['error'] == 'Unknown page.'
        assert run('inspect', 'device', '--devicename', 'api')['managed']['instance'] == original['managed']['instance']
        print('PASS: malformed calls, non-public methods and credentials are rejected; Device API errors reach the CLI', flush=True)
    finally:
        subprocess.run([str(CLI), 'stop', 'device', '--all', '--timeout', '5s'],
                       env=env, capture_output=True, timeout=30)
