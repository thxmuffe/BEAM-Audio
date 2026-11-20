#!/usr/bin/env python3
"""Settings across real CLI VM restarts; idle only, no Session/audio.

The CLI keeps the same plain-text settings file as every app. A restart starts
from it; undo/redo history lives only while the Device runs."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT / 'scripts/cli/beamaudio'
with tempfile.TemporaryDirectory(prefix='ba-cli-config-') as directory:
    env = dict(os.environ, BA_CLI_HOME=directory)
    settings = Path(directory) / 'saved' / 'settings.config'
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
        # Undo may take a grant back; Redo may not give it again (secure profile).
        assert not history()['consent']['microphone'] and not history()['can_redo']
        run('set', 'device', '--enable', 'mic')
        h = history()
        assert h['consent']['microphone'] and h['can_undo']
        run('set', 'device', '--enable', 'mic')
        assert history()['revision'] == h['revision'], 'no-op made another undo step'
        run('stop', 'device')
        assert settings.is_file() and 'microphone => true' in settings.read_text(), 'settings not saved as text'
        run('new', 'device')
        h = history()
        assert h['consent']['microphone'], 'restart did not start from the saved settings'
        assert not h['can_undo'], 'undo history should not survive a restart'
        run('set', 'device', '--enable', 'speaker')
        run('undo', 'device')
        run('set', 'device', '--enable', 'speaker')
        assert not history()['can_redo'], 'new edit retained redo branch'
        view = run('inspect', 'device')
        assert view['buffee']['state'] == 'idle'
        assert 'entries' not in view['configuration'], 'polling sends full history'
        run('stop', 'device')
        # A person edits the file while the Device is stopped; the next start uses it.
        settings.write_text(settings.read_text().replace('microphone => true', 'microphone => false'))
        run('new', 'device')
        assert not history()['consent']['microphone'], 'hand edit of settings.config ignored'
        run('stop', 'device')
        print('CLI configuration smoke passed: settings saved as text and restored across restarts, hand edits honoured, in-run undo and branching; no Session/audio.')
    finally:
        subprocess.run([str(CLI), 'stop', 'device', '--devicename', 'saved', '--timeout', '2s'],
                       env=env, capture_output=True, timeout=25)
