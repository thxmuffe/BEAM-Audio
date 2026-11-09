"""Three unnamed BEAM devices, real Desk signaling and real WebRTC PCM, test clock/sink."""
import importlib.util
import argparse
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
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--swarm-time",action="store_true")
    parser.add_argument('--opus',action='store_true',help='Exercise the configured GStreamer decoder, no hardware')
    parser.add_argument('--sustained',action='store_true',help='Continuous PCM capture at the default 1000ms Offset, then reference restart/rebind')
    args=parser.parse_args()
    root=control.ROOT
    paths=list((root/'builds/intermediates/control/default/lib').glob('*/ebin'))
    paths+=list((root/'builds/intermediates/BeamTransport/dev/lib').glob('*/ebin'))
    paths+=list((root/'builds/intermediates/tools/elixir/lib').glob('*/ebin'))
    assert any(p.parent.name=='ex_webrtc' for p in paths),'Compile the existing BeamTransport first'
    out=root/'builds/intermediates/swarm-control-check';out.mkdir(parents=True,exist_ok=True)
    fixture=out/'opus-fixture.bin'
    if args.opus:
        subprocess.run([os.environ['BA_GSTREAMER_PYTHON'],str(HERE/'opus-fixture.py'),str(fixture)],check=True)
    subprocess.run([shutil.which('erlc'),'-Werror','-o',str(out),
        str(HERE/'ba_swarm_control_probe.erl'),str(HERE/'ba_audio_stream_probe.erl')],check=True)
    runtimes=[];desk=None
    with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
    try:
        desk=relay.start_desk(port);url=f'ws://127.0.0.1:{port}/relay/v1'
        executable=None;extra_env={}
        native_lib=os.getenv('BA_TEST_NATIVE_LIBRARY_DIR')
        if sys.platform=='darwin' and native_lib:
            # The system shell removes DYLD variables; invoke OTP's launcher directly.
            erl_root=Path(shutil.which('erl')).resolve().parent.parent
            executable=str(next(erl_root.glob('erts-*/bin/erlexec')))
            extra_env={'DYLD_LIBRARY_PATH':native_lib,'ROOTDIR':str(erl_root),
                       'BINDIR':str(Path(executable).parent),'EMU':'beam','PROGNAME':'erl'}
        a,b,c=[control.Runtime([out,*paths],executable=executable,extra_env=extra_env) for _ in range(3)]
        runtimes.extend([a,b,c])
        if args.swarm_time:
            for r in runtimes:assert r.request('clock_prepare',interval_ms=250,samples=3)['ok']
        assert a.request('create',desks=[url])['ok']
        control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
        for r in (b,c):
            assert r.request('join',invitation=a.request('invite')['value'],desk=url)['ok']
            control.wait(r,lambda s:s['membership']['state']=='authorized')
        permissions=['status_read','stream_read','stream_subscribe']
        if args.swarm_time:
            permissions=['offset_write',*permissions,'time_read']
            assert a.request('grant',peer=c.identity['id'],permissions=['time_read'])['ok']
        assert a.request('grant',peer=b.identity['id'],permissions=permissions)['ok']
        revision=a.request('snapshot')['membership']['revision']
        for r in (b,c):control.wait(r,lambda s:s['membership']['state']=='authorized' and s['membership']['revision']==revision)
        for r in (a,c):
            current=b.request('snapshot')['sessions'].get(r.identity['id'],{}).get('stage')
            if current!='authorized':
                assert b.request('connect',peer=r.identity['id'])['ok']
            control.wait(b,lambda s:s['sessions'].get(r.identity['id'],{}).get('stage')=='authorized')
            control.wait(r,lambda s:s['sessions'].get(b.identity['id'],{}).get('stage')=='authorized')
        if args.swarm_time:
            for r in runtimes:
                deadline=time.monotonic()+20
                while time.monotonic()<deadline:
                    clock=r.request('clock_snapshot')
                    if clock['state']=='synchronized' and clock['offset_policy']['ready']:break
                    time.sleep(.05)
                else:raise AssertionError(clock)
            assert b.request('offset_set',offset_ms=250)['ok']
            for r in runtimes:
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    if r.request('clock_snapshot')['offset_policy']['offset_ms']==250:break
                    time.sleep(.05)
                else:raise AssertionError('Offset did not reach publisher')
        for r in runtimes:assert r.request('swarm_audio_prepare' if args.swarm_time else 'audio_prepare')['ok']
        def publish(r,key,format,channels):
            return r.request('publish_opus',source=key,fixture=str(fixture)) if args.opus else r.request('publish',source=key,format=format,channels=channels)
        assert publish(a,'music','pcm16_le',1)['ok']
        assert publish(c,'microphone','float32_le',2)['ok']
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
            if args.opus:
                # Real codec/jitter warm-up, with each packet's own presentation target.
                for n in range(20):
                    for r,key in ((a,'music'),(c,'microphone')):
                        reply=r.request('push_opus',source=key,target_ns=target+n*20_000_000,index=n+10)
                        if first:assert reply['deliveries']==1,reply
                    time.sleep(.02)
                time.sleep(.35)
                blocks=b.request('audio_output')['blocks']
                assert blocks, b.request('audio_snapshot')
                peak=max(s['peak'] for s in blocks)
                assert (.27<peak<.45 if expected==.75 else .12<peak<.25), (expected,peak,b.request('audio_snapshot'))
                assert all(s['write_ns']<s['target_ns'] for s in blocks),blocks
                assert abs(blocks[0]['target_ns']-target)<22000,blocks[0]
                return blocks
            for r,key,value in ((a,'music',.25),(c,'microphone',.5)):
                if args.swarm_time:
                    reply=r.request('capture_source',source=key,capture_ns=target-250_000_000,value=value,frames=960)
                    if first:assert reply.get('blocks')==1 and reply['send_errors']==0,reply
                else:
                    reply=r.request('push_source',source=key,target_ns=target,value=value,frames=960)
                    if first:assert reply['deliveries']==1,reply
            time.sleep(.35)
            blocks=b.request('audio_output')['blocks']
            assert blocks and all(abs(s['first']-expected)<.0001 for s in blocks),(blocks,b.request('audio_snapshot'))
            assert all(s['write_ns']<s['target_ns'] for s in blocks),blocks
            assert abs(blocks[0]['target_ns']-target)<22000,blocks
            return blocks
        mixed(.75)
        if args.sustained:
            assert args.swarm_time and not args.opus
            assert b.request('offset_set',offset_ms=1000)['ok']
            for r in runtimes:
                end=time.monotonic()+10
                while r.request('clock_snapshot')['offset_policy']['offset_ms']!=1000:
                    assert time.monotonic()<end;time.sleep(.05)
            before=b.request('audio_snapshot')['mixer'];b.request('audio_clear_output')
            start=time.monotonic();capture_start=time.time_ns()
            for n in range(200):
                capture=capture_start+n*20_000_000
                for r,key,value in ((a,'music',.25),(c,'microphone',.5)):
                    reply=r.request('capture_source',source=key,capture_ns=capture,value=value,frames=960)
                    assert reply['send_errors']==0,reply
                time.sleep(max(0,start+(n+1)*.02-time.monotonic()))
            time.sleep(1.1)
            after=b.request('audio_snapshot')['mixer'];blocks=b.request('audio_output')['blocks']
            assert after['dropped']==before['dropped'],(before,after)
            assert after['rendered']-before['rendered']>=600,(before,after)
            assert blocks and max(x['peak'] for x in blocks)==.75,blocks
            assert after['queued_bytes']==0,after
            # Restore the short fixture Offset, restart the reference and exercise
            # production capture's automatic incarnation/descriptor rebind.
            assert b.request('offset_set',offset_ms=250)['ok']
            previous=a.request('clock_snapshot')['timeline']
            assert a.request('clock_restart')['ok']
            for r in runtimes:
                end=time.monotonic()+20
                while True:
                    clock=r.request('clock_snapshot')
                    if clock.get('timeline')!=previous and clock['state']=='synchronized' and clock['offset_policy']['ready']:break
                    assert time.monotonic()<end,clock;time.sleep(.05)
            for r,key in ((a,'music'),(c,'microphone')):
                reply=r.request('capture_source',source=key,capture_ns=time.time_ns(),value=.25,frames=960)
                assert reply['send_errors']==0,reply
            wait_audio(b,lambda s:all(s['subscriptions'][i]['state']=='active' for i in subscriptions)
                       and all(o['profiles']['channel']['clock']!=previous for o in s['offers']))
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
        if args.opus:mixed(.5,False)
        else:
            b.request('audio_clear_output');target=time.time_ns()+300_000_000
            assert c.request('push_source',source='microphone',target_ns=target,value=.5,frames=960)['deliveries']==1
            time.sleep(.35);assert b.request('audio_output')['blocks']
        assert publish(a,'music','pcm16_le',1)['ok']
        wait_audio(b,lambda s:s['subscriptions'][x]['state']=='active');mixed(.75)
        assert b.request('audio_unsubscribe',id=x)['ok']
        s=b.request('audio_snapshot');assert x not in s['subscriptions'] and s['subscriptions'][y]['state']=='active'
        assert b.request('audio_clear_contract',direction='receive',peer=c.identity['id'],source='microphone')['ok']
        wait_audio(b,lambda s:s['subscriptions'][y]['state']=='waiting_for_source')
        assert all(r.request('snapshot')['nodes']==[] for r in runtimes)
        print(('PASS: authenticated shared Swarm clock and Offset; ' if args.swarm_time else 'PASS: test clock; ')+('real WebRTC Opus decoded by GStreamer' if args.opus else 'real WebRTC PCM')+' from two publishers mixed at their packet targets; independent receiver/source pause and resume; disappearance and new-incarnation restore; scoped unsubscribe and Contract revocation; no OTP distribution, product apps or hardware output')
    finally:
        for r in runtimes:r.close()
        if desk is not None:desk.terminate();desk.wait(timeout=5)
if __name__=='__main__':main()
