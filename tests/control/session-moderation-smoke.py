"""Public CLI regression: moderation kicks Devices without granting Admin rights."""
from pathlib import Path
import importlib.util
import json
import os
import shutil
import socket
import subprocess
import tempfile
import time

CORE = Path(__file__).resolve().parents[2]


def main():
    spec = importlib.util.spec_from_file_location('moderation_relay', CORE/'tests/ReceptionDesk/local_reception.py')
    relay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relay)
    otp = CORE/'builds/intermediates/Windows/otp/bin'
    executable = str(otp/'escript.exe') if os.name=='nt' else 'escript'
    relay.ERL = otp/'erl.exe' if os.name=='nt' else Path(shutil.which('erl') or 'erl')
    with socket.socket() as probe:
        probe.bind(('127.0.0.1',0))
        port = probe.getsockname()[1]
    desk = relay.start_desk(port)
    names = []
    try:
        with tempfile.TemporaryDirectory(prefix='session-moderation-cli-') as home:
            env = dict(os.environ, BA_CLI_HOME=home)
            if os.name=='nt':
                env['PATH'] = str(otp)+os.pathsep+env.get('PATH','')
            def cli(*args, request=None, check=True):
                result = subprocess.run([executable,str(CORE/'src/Tools/CLI/beam-audio'),*args],
                    env=env, input=json.dumps(request) if request is not None else None,
                    text=True, capture_output=True, encoding='utf-8',timeout=40)
                if check:
                    # Never include commands, requests, invitations or full snapshots.
                    assert result.returncode==0, f'CLI command failed: {args[0]}, exit {result.returncode}'
                return result
            def api(device_name,method,**fields):
                result=cli('call','device','--devicename',device_name,request=dict(method=method,**fields),check=False)
                # API denials are deliberately nonzero and JSON on stderr.
                for line in reversed((result.stdout+'\n'+result.stderr).splitlines()):
                    try:
                        value=json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(value,dict):return value
                raise AssertionError(f'CLI returned no JSON for public method {method}')
            def wait(name,predicate):
                deadline=time.monotonic()+20
                while True:
                    snap=api(name,'snapshot')
                    if predicate(snap):return snap
                    assert time.monotonic()<deadline, 'Public Device state did not converge'
                    time.sleep(.1)
            try:
                for name in ('admin','moderator','target','independent'):
                    names.append(name)
                    cli('new','device','--devicename',name,'--wait','endpoint','--timeout','20s')
                ids={name:api(name,'snapshot')['device'] for name in names}
                assert not api('admin','create_session',name='Local moderation test',desks=[f'ws://127.0.0.1:{port}/relay/v1'])['error']
                invitation=api('admin','invitation')['result']
                for name in names[1:]:
                    assert not api(name,'join_session',invitation=invitation)['error']
                    wait(name,lambda s:s['session']['state']=='authorized')
                denied=api('target','remove_device',device=ids['moderator'])
                assert denied['error']=='This Device needs moderator rights to remove a Device.'
                assert not api('admin','grant_privilege',device=ids['moderator'],privilege='end_session')['error']
                wait('moderator',lambda s:'end_session' in s['session']['privileges'])
                assert 'grant' not in api('moderator','snapshot')['session']['privileges']
                assert api('moderator','grant_privilege',device=ids['target'],privilege='grant')['error']=='Only a Device with the grant privilege can change privileges.'
                for target in ('target','admin','independent'):
                    # Dark Sessions: the moderator need not have bumped into the target;
                    # a signed End reaches any Device ID at the Session mailbox.
                    assert not api('moderator','remove_device',device=ids[target])['error']
                    wait(target,lambda s:s['session']['state']=='idle')
                    assert api('moderator','snapshot')['session']['state']=='authorized'
                print('PASS: public CLI moderator kicks Devices and Admin, continues without Admin, cannot grant rights; ordinary Device denied')
            finally:
                for name in reversed(names):
                    stopped=cli('stop','device','--devicename',name,'--timeout','5s',check=False)
                    if stopped.returncode:
                        cli('kill','device','--devicename',name,check=False)
    finally:
        desk.terminate()
        try:desk.wait(timeout=5)
        except subprocess.TimeoutExpired:desk.kill();desk.wait()


if __name__=='__main__':
    main()
