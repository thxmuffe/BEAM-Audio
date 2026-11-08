"""Three unnamed BEAM devices, real Desk signaling and real WebRTC PCM, test clock/sink."""
import importlib.util
import secrets
import os
import sys
import shutil
import socket
import subprocess
import time
from pathlib import Path
HERE=Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
control=load('control',HERE/'swarm-control-smoke.py')
relay=load('relay',HERE.parent/'ReceptionDesk/relay-smoke.py')
relay.ERL=Path(shutil.which('erl'))

def wait_audio(r,predicate):
    end=time.monotonic()+20
    while time.monotonic()<end:
        s=r.request('audio_snapshot')
        assert 'subscriptions' in s,s
        if predicate(s):return s
        time.sleep(.05)
    raise AssertionError('Audio did not converge: '+str(s))

def main():
    root=control.ROOT
    paths=list((root/'builds/intermediates/control/default/lib').glob('*/ebin'))
    paths+=list((root/'builds/intermediates/BeamTransport/dev/lib').glob('*/ebin'))
    paths+=list((root/'builds/intermediates/tools/elixir/lib').glob('*/ebin'))
    assert any(p.parent.name=='ex_webrtc' for p in paths),'Compile the existing BeamTransport first'
    out=root/'builds/intermediates/swarm-control-check';out.mkdir(parents=True,exist_ok=True)
    subprocess.run([shutil.which('erlc'),'-Werror','-o',str(out),
        str(HERE/'parvi_swarm_control_probe.erl'),str(HERE/'parvi_audio_stream_probe.erl')],check=True)
    runtimes=[];desk=None
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    try:
        desk=relay.start_desk(port);url=f'ws://127.0.0.1:{port}/relay/v1'
        executable=None;extra_env={}
        native_lib=os.getenv('PARVI_TEST_NATIVE_LIBRARY_DIR')
        if sys.platform=='darwin' and native_lib:
            # The system shell removes DYLD variables; invoke OTP's launcher directly.
            erl_root=Path(shutil.which('erl')).resolve().parent.parent
            executable=str(next(erl_root.glob('erts-*/bin/erlexec')))
            extra_env={'DYLD_LIBRARY_PATH':native_lib,'ROOTDIR':str(erl_root),
                       'BINDIR':str(Path(executable).parent),'EMU':'beam','PROGNAME':'erl'}
        a,b,c=[control.Runtime([out,*paths],executable=executable,extra_env=extra_env) for _ in range(3)]
        runtimes.extend([a,b,c])
        assert a.request('create',desks=[url])['ok']
        control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
        for r in (b,c):
            assert r.request('join',invitation=a.request('invite')['value'],desk=url)['ok']
            control.wait(r,lambda s:s['membership']['state']=='authorized')
        assert a.request('grant',peer=b.identity['id'],permissions=['status_read','stream_read','stream_subscribe'])['ok']
        revision=a.request('snapshot')['membership']['revision']
        for r in (b,c):control.wait(r,lambda s:s['membership']['state']=='authorized' and s['membership']['revision']==revision)
        for r in (a,c):
            assert b.request('connect',peer=r.identity['id'])['ok']
            control.wait(b,lambda s:s['sessions'].get(r.identity['id'],{}).get('stage')=='authorized')
            control.wait(r,lambda s:s['sessions'].get(b.identity['id'],{}).get('stage')=='authorized')
        for r in runtimes:assert r.request('audio_prepare')['ok']
        assert a.request('publish',source='music',format='pcm16_le',channels=1)['ok']
        assert c.request('publish',source='microphone',format='float32_le',channels=2)['ok']
        wait_audio(b,lambda s:len(s['offers'])==2)
        subscriptions=[]
        for r,key in ((a,'music'),(c,'microphone')):
            contract=secrets.token_hex(16).upper()
            assert r.request('audio_contract',direction='publish',peer=b.identity['id'],source=key,contract=contract)['ok']
            assert b.request('audio_contract',direction='receive',peer=r.identity['id'],source=key,contract=contract)['ok']
            result=b.request('audio_subscribe',peer=r.identity['id'],source=key)
            assert result.get('ok'),result
            subscriptions.append(result['value'])
        x,y=subscriptions
        wait_audio(b,lambda s:all(s['subscriptions'][i]['state']=='active' for i in subscriptions))
        for i in subscriptions:assert b.request('audio_play',id=i,playing=True)['ok']
        def mixed(expected,first=True):
            b.request('audio_clear_output')
            target=time.time_ns()+300_000_000
            for r,key,value in ((a,'music',.25),(c,'microphone',.5)):
                reply=r.request('push_source',source=key,target_ns=target,value=value,frames=960)
                if first:assert reply['deliveries']==1,reply
            time.sleep(.35)
            blocks=b.request('audio_output')['blocks']
            assert blocks and all(abs(s['first']-expected)<.0001 for s in blocks),blocks
            assert all(s['write_ns']<s['target_ns'] for s in blocks),blocks
            assert abs(blocks[0]['target_ns']-target)<22000,blocks
            return blocks
        mixed(.75)
        assert b.request('audio_restart_receiver')['ok']
        restored=b.request('audio_snapshot')
        assert set(restored['subscriptions'])==set(subscriptions)
        assert all(i['playing'] and i['state']=='waiting_for_source' for i in restored['subscriptions'].values())
        assert restored['mixer']['streams']==0 and restored['providers']==0
        # Local receive permission is deliberately not restored from the checkpoint.
        for r,key in ((a,'music'),(c,'microphone')):
            contract=secrets.token_hex(16).upper()
            assert r.request('audio_contract',direction='publish',peer=b.identity['id'],source=key,contract=contract)['ok']
            assert b.request('audio_contract',direction='receive',peer=r.identity['id'],source=key,contract=contract)['ok']
        wait_audio(b,lambda s:all(s['subscriptions'][i]['state']=='active' for i in subscriptions))
        mixed(.75)
        assert b.request('audio_play',id=x,playing=False)['ok'];mixed(.5)
        assert b.request('audio_play',id=x,playing=True)['ok'];mixed(.75)
        assert a.request('pause_source',source='music',paused=True)['ok']
        wait_audio(b,lambda s:s['subscriptions'][x].get('source_paused') is True)
        mixed(.5,False)
        assert a.request('pause_source',source='music',paused=False)['ok']
        wait_audio(b,lambda s:s['subscriptions'][x].get('source_paused') is False);mixed(.75)
        assert a.request('unpublish',source='music')['ok']
        wait_audio(b,lambda s:s['subscriptions'][x]['state']=='waiting_for_source' and s['subscriptions'][y]['state']=='active')
        b.request('audio_clear_output');target=time.time_ns()+300_000_000
        assert c.request('push_source',source='microphone',target_ns=target,value=.5,frames=960)['deliveries']==1
        time.sleep(.35);assert b.request('audio_output')['blocks']
        assert a.request('publish',source='music',format='pcm16_le',channels=1)['ok']
        wait_audio(b,lambda s:s['subscriptions'][x]['state']=='active');mixed(.75)
        assert b.request('audio_unsubscribe',id=x)['ok']
        s=b.request('audio_snapshot');assert x not in s['subscriptions'] and s['subscriptions'][y]['state']=='active'
        assert b.request('audio_clear_contract',direction='receive',peer=c.identity['id'],source='microphone')['ok']
        wait_audio(b,lambda s:s['subscriptions'][y]['state']=='waiting_for_source')
        assert all(r.request('snapshot')['nodes']==[] for r in runtimes)
        print('PASS: real WebRTC PCM from two publishers mixed at their packet targets; independent receiver/source pause and resume; disappearance and new-incarnation restore; scoped unsubscribe and Contract revocation; no OTP distribution, product apps or hardware output')
    finally:
        for r in runtimes:r.close()
        if desk is not None:desk.terminate();desk.wait(timeout=5)
if __name__=='__main__':main()
