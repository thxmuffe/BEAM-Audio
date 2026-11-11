"""A supervised child crash reaches a peer's existing authenticated Buffee chat."""
import importlib.util
import shutil
import socket
import subprocess
import time
from pathlib import Path

HERE=Path(__file__).resolve().parent


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


control=load('control',HERE/'buffee-control-smoke.py')
relay=load('relay',HERE.parent/'ReceptionDesk/relay-smoke.py')
relay.ERL=Path(shutil.which('erl'))


def main():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        port=sock.getsockname()[1]
    output=control.ROOT/'builds/intermediates/crash-chat-check'
    output.mkdir(parents=True,exist_ok=True)
    subprocess.run(['erlc','-Werror','-o',str(output),str(HERE/'ba_buffee_control_probe.erl')],check=True)
    paths=[output,*list((control.ROOT/'builds/intermediates/control/default/lib').glob('*/ebin'))]
    desk=relay.start_desk(port)
    runtimes=[]
    try:
        a,b=[control.Runtime(paths) for _ in range(2)]
        runtimes.extend([a,b])
        url=f'ws://127.0.0.1:{port}/relay/v1'
        assert a.request('create',desks=[url])['ok']
        link=a.request('invite')['value']
        assert b.request('join',invitation=link,desk=url)['ok']
        control.wait(b,lambda s:s['membership']['state']=='authorized')
        assert a.request('connect',peer=b.identity['id'])['ok']
        for node,peer in ((a,b),(b,a)):
            control.wait(node,lambda s:s['sessions'].get(peer.identity['id'],{}).get('stage')=='authorized')
        assert a.request('crash_test_worker')['ok']
        deadline=time.monotonic()+10
        while True:
            history=b.request('chat_history')
            if history:
                assert history[-1]['text']=='System: ba_buffee_control_probe stopped (badmatch).'
                assert 'PRIVATE_EXCEPTION' not in str(history)
                break
            assert time.monotonic()<deadline,'Crash notice was not delivered'
            time.sleep(.05)
        assert a.request('snapshot')['membership']['state']=='authorized'
        print('PASS: supervised crash summary delivered to peer chat; exception data excluded; Device stays authorized; no audio hardware.')
    finally:
        for runtime in runtimes:
            runtime.close()
        desk.terminate()
        try:
            desk.wait(timeout=5)
        except subprocess.TimeoutExpired:
            desk.kill()
            desk.wait()


if __name__=='__main__':
    main()
