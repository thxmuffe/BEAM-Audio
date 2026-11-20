"""Local Reception fixture for integration tests: start_desk() runs the Phoenix
Reception on loopback; ERL is the Windows app runtime used to run test Devices."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
APP_ROOT = Path(os.environ.get("OPENSOUND_ROOT", ROOT.parent / "OpenSound"))
APP = APP_ROOT / 'builds/Windows/OpenSound'
ERL = Path(os.environ.get('BA_TEST_ERL', APP / 'runtime/bin/erl.exe'))
ELIXIR = Path(os.environ.get('BA_ELIXIR_ROOT', ROOT / 'builds/intermediates/tools/elixir'))


def start_desk(port, tls_port=None, cert=None, key=None):
    paths = list((ROOT / 'builds/intermediates/ReceptionDeskMix/dev/lib').glob('*/ebin'))
    paths += list((ELIXIR / 'lib').glob('*/ebin'))
    assert paths, 'Compile the Phoenix service first'
    tls = '' if tls_port is None else (',{https,[{ip,{127,0,0,1}},{port,' + str(tls_port) + '},'
        '{certfile,' + json.dumps(str(cert).replace('\\', '/')) + '},'
        '{keyfile,' + json.dumps(str(key).replace('\\', '/')) + '}]}')
    config = ("application:load(reception_desk), application:set_env(reception_desk, "
        "'Elixir.ReceptionDesk.Endpoint', [{adapter,'Elixir.Phoenix.Endpoint.Cowboy2Adapter'},"
        "{server,true},{http,[{ip,{127,0,0,1}},{port," + str(port) + "}]},"
        "{pubsub_server,'Elixir.ReceptionDesk.PubSub'},"
        "{secret_key_base,<<\"local-test-secret-key-base-is-not-a-client-credential-12345678901234567890\">>}" + tls + " ]),"
        "{ok,_}=application:ensure_all_started(reception_desk), receive stop -> ok end.")
    proc = subprocess.Popen([str(ERL), '-noshell', '-noinput', '-pa', *map(str, paths), '-eval', config],
                            stdout=None if '--verbose' in sys.argv else subprocess.DEVNULL,
                            stderr=None if '--verbose' in sys.argv else subprocess.DEVNULL)
    for _ in range(100):
        if proc.poll() is not None:
            raise RuntimeError('Desk startup failed')
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/health', timeout=.2):
                return proc
        except OSError:
            time.sleep(.1)
    proc.kill()
    proc.wait()
    raise TimeoutError('Desk startup')
