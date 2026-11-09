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
    parser.add_argument('--ephemeral',action='store_true',help='Contacts/group invitations, live PCM, leave/end, cold restart and Captain-loss teardown')
    parser.add_argument('--opus',action='store_true',help='Exercise the configured GStreamer decoder, no hardware')
    parser.add_argument('--sustained',action='store_true',help='Continuous PCM capture at the default 1000ms Offset, then reference restart/rebind')
    parser.add_argument('--renewal',action='store_true',help='Continuous two-source lease renewal proof; returns before lifecycle checks')
    parser.add_argument('--seconds',type=int,default=12)
    parser.add_argument('--offset-ms',type=int,default=1000)
    parser.add_argument('--lease-ms',type=int,default=60000)
    parser.add_argument('--deny-renewal',action='store_true',help='Test-only packet filter withholds control proofs while keeping the test clock fresh')
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
        for r in runtimes:assert r.request('renewal_prepare',lease_ms=args.lease_ms)['ok']
        if args.swarm_time:
            for r in runtimes:assert r.request('clock_prepare',interval_ms=250,samples=3)['ok']
        assert a.request('create',desks=[url])['ok']
        control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
        invitations={}
        if args.ephemeral:
            for r,name in ((b,'Receiver'),(c,'Second publisher')):
                assert a.request('put_contact',id=r.identity['id'],name=name)['ok']
            assert a.request('group_contacts',name='Session',ids=[b.identity['id'],c.identity['id']])['ok']
            links=a.request('invite_swarm',selection={'group':'Session'})['value']
            invitations={entry['device']:entry['invitation'] for entry in links}
        for r in (b,c):
            invitation=invitations[r.identity['id']] if args.ephemeral else a.request('invite')['value']
            assert r.request('join',invitation=invitation,desk=url)['ok']
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
        subscriptions=[];contracts=[]
        for r,key in ((a,'music'),(c,'microphone')):
            contract=secrets.token_hex(16).upper()
            assert r.request('audio_contract',direction='publish',peer=b.identity['id'],source=key,contract=contract)['ok']
            assert b.request('audio_contract',direction='receive',peer=r.identity['id'],source=key,contract=contract)['ok']
            result=b.request('audio_subscribe',peer=r.identity['id'],source=key)
            assert result.get('ok'),result
            subscriptions.append(result['value'])
            contracts.append((r,key,contract))
        x,y=subscriptions
        wait_audio(b,lambda s:all(s['subscriptions'][i]['state']=='active' for i in subscriptions))
        for i in subscriptions:assert b.request('audio_play',id=i,playing=True)['ok']
        if args.renewal:
            assert not args.opus,'PCM is used for exact continuous frame/mix accounting'
            if args.swarm_time:
                assert b.request('offset_set',offset_ms=args.offset_ms)['ok']
                for r in runtimes:
                    end=time.monotonic()+10
                    while r.request('clock_snapshot')['offset_policy']['offset_ms']!=args.offset_ms:
                        assert time.monotonic()<end;time.sleep(.05)
            identities=[r.request('audio_ids') for r in runtimes]
            before=b.request('audio_snapshot')['mixer'];b.request('audio_reset_stats')
            target=time.time_ns()+args.offset_ms*1_000_000
            start=time.monotonic()
            for n in range(args.seconds*50):
                for r,key,value in ((a,'music',.25),(c,'microphone',.5)):
                    if args.swarm_time:
                        reply=r.request('capture_source',source=key,capture_ns=target-args.offset_ms*1_000_000+n*20_000_000,value=value,frames=960)
                        assert reply['send_errors']==0,reply
                    else:
                        reply=r.request('push_source',source=key,target_ns=target+n*20_000_000,value=value,frames=960)
                        assert reply['deliveries']==1,reply
                if n%50==0:
                    for r,old in zip(runtimes,identities):assert r.request('audio_ids')==old
                    # Reinstall exactly the same Contracts during live playback.
                    for r,key,contract in contracts:
                        assert r.request('audio_contract',direction='publish',peer=b.identity['id'],source=key,contract=contract)['ok']
                        assert b.request('audio_contract',direction='receive',peer=r.identity['id'],source=key,contract=contract)['ok']
                time.sleep(max(0,start+(n+1)*.02-time.monotonic()))
            if args.deny_renewal:
                assert not args.swarm_time,'Keep the independent test clock fresh to isolate authorization expiry'
                for r in runtimes:assert r.request('block_handshakes')['ok']
                time.sleep(args.lease_ms/1000+.5)
                stopped=b.request('audio_snapshot')
                assert all(s['state']!='active' for s in stopped['subscriptions'].values()),stopped
                assert stopped['mixer']['streams']==0,stopped
                # Future audio was buffered under the previous lease, but cannot
                # execute after expiry, even though the test clock stays ready.
                if args.offset_ms>args.seconds*1000+args.lease_ms+1000:
                    assert b.request('audio_stats')['frames']==0
                print('PASS: withheld nonce proofs stop Media Sessions and discard future buffers at authorization expiry, with an independently healthy test clock')
                return
            time.sleep(args.offset_ms/1000+.2)
            after=b.request('audio_snapshot')['mixer'];stats=b.request('audio_stats')
            assert after['dropped']==before['dropped'],(before,after,stats)
            assert stats['frames']==args.seconds*48000 and stats['gaps']==0 and stats['bad_mix']==0 and stats['late']==0,stats
            assert abs(stats['first_target']-target)<22000,stats
            assert after['queued_bytes']==0,after
            for r,old in zip(runtimes,identities):assert r.request('audio_ids')==old
            for r in (a,c):
                session=b.request('snapshot')['sessions'][r.identity['id']]
                assert session.get('renewals',0)>=2,session
            # Revocation must still invalidate authorized media and future
            # buffers after successful in-place renewal.
            frames_before=b.request('audio_stats')['frames'];future=time.time_ns()+700_000_000
            for r,key,value in ((a,'music',.25),(c,'microphone',.5)):
                assert r.request('push_source',source=key,target_ns=future,value=value,frames=960)['deliveries']==1
            end=time.monotonic()+2
            while b.request('audio_snapshot')['mixer']['queued_bytes']==0:
                assert time.monotonic()<end;time.sleep(.01)
            assert a.request('revoke',peer=b.identity['id'])['ok']
            wait_audio(b,lambda s:s['mixer']['streams']==0 and all(v['state']!='active' for v in s['subscriptions'].values()))
            time.sleep(.75)
            assert b.request('audio_stats')['frames']==frames_before,'Revoked future PCM was rendered'
            print(f'PASS: {args.seconds}s continuous two-source PCM at {args.offset_ms}ms Offset; exact frame/mix/target accounting, no gaps/drops, unchanged Media Sessions and publications across authenticated renewal and repeated identical Contracts')
            return
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
        if args.ephemeral:
            assert not args.opus and not args.renewal
            def idle(r,timeout=15):
                end=time.monotonic()+timeout
                while time.monotonic()<end:
                    state=r.request('lifecycle')
                    if state['swarm']=={'state':'idle'}:
                        assert state['live']==[] and not state['transient_state'] and state['connections']==0,state
                        return
                    time.sleep(.1)
                raise AssertionError(('Swarm did not terminate',state))
            swarm=a.request('swarm_status')['swarm']
            address_book=a.request('list_contacts')
            assert b.request('end_swarm')=={'error':'captain_only'}
            assert b.request('leave_swarm')['ok'];idle(b)
            control.wait(a,lambda s:b.identity['id'] not in s['membership']['members'])
            assert a.request('swarm_status')['swarm']==swarm
            # A new invitation allows an explicit return to the still-live gathering.
            link=a.request('invite_swarm',selection=[b.identity['id']])['value'][0]['invitation']
            assert b.request('join_swarm',invitation=link)['ok']
            control.wait(b,lambda s:s['membership']['state']=='authorized')
            assert a.request('end_swarm')['ok']
            for r in runtimes:idle(r)
            assert a.request('list_contacts')==address_book
            for r in runtimes:
                directory=Path(r.state.name)
                assert sorted(p.name for p in directory.glob('*.term'))==(['contacts.term'] if r is a else []),list(directory.iterdir())
            # Same identity/storage, new VM: contacts survive, gathering does not.
            directory=a.state.name;seed=a.seed;identity=a.identity['id'];a.close()
            a=control.Runtime([out,*paths],seed=seed,state=directory,executable=executable,extra_env=extra_env)
            runtimes.append(a);idle(a)
            assert a.identity['id']==identity and a.request('list_contacts')==address_book
            assert a.request('create',desks=[url])['ok']
            assert a.request('swarm_status')['swarm']!=swarm
            control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
            # A ticket from the ended gathering never restores its old identity.
            assert b.request('join_swarm',invitation=link)['ok']
            assert b.request('swarm_status')['swarm']==swarm
            time.sleep(.5)
            assert b.request('swarm_status')['state']!='authorized'
            assert b.request('leave_swarm')['ok'];idle(b)
            link=a.request('invite_swarm',selection=[b.identity['id']])['value'][0]['invitation']
            assert b.request('join_swarm',invitation=link)['ok']
            control.wait(b,lambda s:s['membership']['state']=='authorized')
            # Loss of the Captain is terminal: no election or restored snapshot.
            assert a.request('crash_swarm')['ok'];idle(a)
            idle(b,70)
            assert a.request('list_contacts')==address_book
            print('PASS: saved group invitations, voluntary join/leave and return, real two-source PCM, Captain end and crash/lease expiry, full process/ETS/Desk teardown, new Swarm ID and contacts surviving cold restart; no apps or hardware')
            return
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
