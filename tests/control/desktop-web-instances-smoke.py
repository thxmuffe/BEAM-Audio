"""Two real idle web Devices use different identities/ports and stop independently."""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import urllib.request
root = Path(__file__).resolve().parents[2]
product = Path(os.environ.get('OPENSOUND_ROOT', root.parent/'OpenSound'))
with tempfile.TemporaryDirectory() as directory:
    env = dict(os.environ, BA_CLI_HOME=directory)
    def cli(*args):
        return subprocess.run([str(root/'bin/beamaudio'), *args], env=env, check=True,
            capture_output=True, text=True).stdout.strip()
    names = []
    try:
        for _ in range(2):
            result = json.loads(cli('new', 'device', '--devicename', 'InstanceTest', '--next-instance',
                '--web-assets', str(product/'builds/WebApp'), '--web-port', '0', '--timeout', '20s'))
            names.append(next(iter(result['devices'])))
        assert names == ['InstanceTest', 'InstanceTest-2'], names
        states = [json.loads(cli('inspect', 'device', '--devicename', name)) for name in names]
        assert states[0]['device'] != states[1]['device']
        urls = [cli('get', 'web', '--devicename', name) for name in names]
        assert urls[0] != urls[1]
        for url in urls:
            with urllib.request.urlopen(url+'/native.mjs', timeout=3) as response:
                assert response.status == 200
        cli('stop', 'device', '--devicename', names[0], '--timeout', '10s')
        with urllib.request.urlopen(urls[1], timeout=3) as response:
            assert response.status == 200
        print('PASS: two actual web Devices have distinct identities and ports; stopping one leaves the other serving; no Buffee or audio hardware.')
    finally:
        subprocess.run([str(root/'bin/beamaudio'), 'stop', 'device', '--all', '--timeout', '10s'],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
