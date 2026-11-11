#!/usr/bin/env python3
"""Configuration/undo across real CLI VM restarts; idle only, no Buffee/audio."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'bin/beamaudio'
with tempfile.TemporaryDirectory(prefix='ba-cli-config-') as directory:
    env = dict(os.environ, BA_CLI_HOME=directory)
    def run(*args):
        result = subprocess.run([str(CLI), *args, '--devicename', 'saved', '--timeout', '10s'],
                                env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == 0, (args, result.stderr)
        return json.loads(result.stdout)
    def history(): return run('history', 'device')['result']
    try:
        run('new', 'device')
        assert not history()['can_undo']
        run('set', 'device', '--enable', 'mic')
        assert history()['undo_label'] == 'Enable microphone'
        run('undo', 'device')
        run('stop', 'device')
        run('new', 'device')
        assert not history()['consent']['microphone'] and history()['can_redo']
        run('redo', 'device')
        run('stop', 'device')
        run('new', 'device')
        h = history()
        assert h['consent']['microphone'] and h['can_undo']
        run('set', 'device', '--enable', 'mic')
        assert history()['revision'] == h['revision'], 'no-op made another undo step'
        run('undo', 'device')
        assert not history()['consent']['microphone']
        run('set', 'device', '--enable', 'speaker')
        assert not history()['can_redo'], 'new edit retained redo branch'
        view = run('inspect', 'device')
        assert view['buffee']['state'] == 'idle'
        assert 'entries' not in view['configuration'], 'polling sends full history'
        run('stop', 'device')
        print('CLI configuration smoke passed: resume, persistent undo/redo, no-op and redo branching; no Buffee/audio.')
    finally:
        subprocess.run([str(CLI), 'stop', 'device', '--devicename', 'saved', '--timeout', '2s'],
                       env=env, capture_output=True, timeout=25)
