"""Real Web launcher + WASAPI capture, isolated identity and local Reception only."""
import importlib.util
import json
import os
from pathlib import Path
import queue
import re
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import urllib.request

CORE = Path(__file__).resolve().parents[2]
PRODUCT = Path(os.environ.get('OPENSOUND_ROOT', CORE.parent/'OpenSound'))


def main():
    spec = importlib.util.spec_from_file_location('web_audio_relay', CORE/'tests/ReceptionDesk/relay-smoke.py')
    relay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relay)
    relay.ERL = CORE/'builds/intermediates/Windows/otp/bin/erl.exe'
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    desk, process = relay.start_desk(port), None
    temporary = tempfile.TemporaryDirectory(prefix="opensound-web-audio-")
    try:
        folder = temporary.name
        state = Path(folder)/'state'
        state.mkdir()
        (state/'settings.config').write_text('{runtime,#{clock_reference => system,clock_sample_interval_ms => 100,clock_filter_samples => 3}}.\n')
        env = dict(os.environ, BA_STATE_DIR=str(state), BA_IDENTITY_SEED=secrets.token_hex(32).upper())
        for key in ('BA_NATIVE_APP', 'BA_PLATFORM', 'BA_RECEPTION_DESK_URL', 'BA_WINDOWS_AUDIO_HELPER_DIR',
                    'BA_WINDOWS_AUDIO_OUTPUT_HELPER', 'BA_WINDOWS_AUDIO_CAPTURE_HELPER'):
            env.pop(key, None)
        lines = queue.Queue()
        process = subprocess.Popen(['powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', str(PRODUCT/'src/Apps/WebApp/run.ps1'), '--local-device'],
            env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, encoding='utf-8', errors='replace')
        def read():
            for line in process.stdout:
                lines.put(line)
        threading.Thread(target=read, daemon=True).start()
        deadline = time.monotonic()+90
        origin = None
        while time.monotonic()<deadline:
            try:
                line = lines.get(timeout=.5)
            except queue.Empty:
                assert process.poll() is None, 'Web launcher exited before publishing its endpoint'
                continue
            found = re.search(r'BEAM Audio: (http://127\.0\.0\.1:\d+)', line)
            if found:
                origin = found[1]
                break
        assert origin, 'Web launcher did not publish an endpoint'
        http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with http.open(origin+'/api/session', timeout=5) as response:
            token = json.load(response)['token']
        def request(method, **fields):
            req = urllib.request.Request(origin+'/api/command', json.dumps(dict(method=method, **fields)).encode(),
                headers={'Content-Type':'application/json', 'Origin':origin, 'X-BEAM-Audio-Token':token})
            with http.open(req, timeout=30) as response:
                value = json.load(response)
            assert not value.get('error'), value.get('error')
            return value
        snap = request('snapshot')
        assert 'Web' in snap['device_name'], 'Browser Device lost its Web label'
        assert not snap.get('unavailable_capabilities'), 'Windows capture helpers were not configured'
        request('create_buffee', name='Private Web audio startup test', desks=[f'ws://127.0.0.1:{port}/relay/v1'])
        request('policy', key='speaker', value='always')
        request('capability', capability='broadcast', enabled=True)
        deadline = time.monotonic()+35
        while time.monotonic()<deadline:
            snap = request('snapshot')
            broadcast = snap.get('handler',{}).get('audio',{}).get('broadcast',{})
            if broadcast.get('state')=='running' and broadcast.get('frames',0)>0:
                break
            time.sleep(.2)
        else:
            raise AssertionError({'broadcast':broadcast, 'clock':snap.get('clock',{}).get('state')})
        assert snap['handler']['audio']['speaker']['state']=='ready', snap['handler']['audio']['speaker']
        assert snap['consent']['speaker'] and snap['consent']['broadcast']
        request('capability', capability='broadcast', enabled=False)
        request('leave_buffee')
        print('PASS: real Web launcher configures shared Windows audio; ON AIR captures frames; speaker is ready; no microphone or public Session used')
    finally:
        if process and process.poll() is None:
            # Stop only this launcher's process tree, including its audio helper.
            subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            process.wait(timeout=10)
        if process:
            process.stdout.close()
        desk.terminate()
        try:
            desk.wait(timeout=5)
        except subprocess.TimeoutExpired:
            desk.kill()
            desk.wait()
        temporary.cleanup()


if __name__ == '__main__':
    main()
