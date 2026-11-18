"""Device/Session end-to-end test: joining, privileges, clocks and real WebRTC audio with test output."""
import importlib.util
import argparse
import secrets
import os
import sys
import shutil
import socket
import subprocess
import time
import threading
from pathlib import Path
HERE=Path(__file__).resolve().parent

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
control=load('control',HERE/'buffee-control-smoke.py')
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

def assert_session_clocks(runtimes,master,expected_offset_ms):
    """The fixture uses this host's system UTC, not an independent UTC oracle."""
    readings=[]
    for r in runtimes:
        before=time.time_ns();clock=r.request('clock_snapshot');after=time.time_ns()
        assert clock['state']=='synchronized' and clock['filter_ready'],clock
        assert clock['offset_policy']['ready'],clock
        assert clock['offset_policy']['offset_ms']==expected_offset_ms,clock
        assert clock['master']==master.identity['id'],clock
        # Explicit 5ms loopback tolerance, with RPC duration bracketed out.
        assert before-5_000_000<=clock['filtered_utc_time']<=after+5_000_000,clock
        if r is master:
            assert clock['role']=='master' and clock['upstream_acquisitions']>=1,clock
            assert clock['master_instance']==clock['instance'],clock
        else:
            assert clock['role']=='follower',clock
            assert clock['filter_sample_count']==clock['filter_required_samples'],clock
            assert clock['age_ns']<=2*clock['sample_interval_ms']*1_000_000,clock
            assert clock['master_clock']['state']=='fresh',clock
            assert clock['master_clock']['device']==master.identity['id'],clock
        readings.append(clock)
    assert len({c['timeline'] for c in readings})==1,readings
    assert len({c['master_instance'] for c in readings})==1,readings

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument("--buffee-time",action="store_true")
    parser.add_argument('--ephemeral',action='store_true',help='Contacts/group invitations, live PCM, leave/end, cold restart and Owner-loss teardown')
    parser.add_argument('--opus',action='store_true',help='Exercise the configured GStreamer decoder, no hardware')
    parser.add_argument('--sustained',action='store_true',help='Continuous PCM capture at the default 1000ms Offset, then reference restart/rebind')
    parser.add_argument('--renewal',action='store_true',help='Continuous two-source lease renewal proof; returns before lifecycle checks')
    parser.add_argument('--single-source',action='store_true',help='Two Devices, one publisher; requires --renewal')
    parser.add_argument('--seconds',type=int,default=12)
    parser.add_argument('--offset-ms',type=int,default=None)
    parser.add_argument('--lease-ms',type=int,default=60000)
    parser.add_argument('--deny-renewal',action='store_true',help='Test-only packet filter withholds control proofs while keeping the test clock fresh')
    args=parser.parse_args()
    if args.offset_ms is None:args.offset_ms=150 if args.single_source else 1000
    if args.single_source and (not args.renewal or args.opus):
        parser.error('--single-source requires --renewal and PCM')
    root=control.ROOT
    paths=list((root/'builds/intermediates/control/default/lib').glob('*/ebin'))
    transport=root/('builds/intermediates/Windows/transport/beam/dev/lib' if sys.platform=='win32'
                    else 'builds/intermediates/BeamTransport/dev/lib')
    paths+=list(transport.glob('*/ebin'))
    paths+=list((root/'builds/intermediates/tools/elixir/lib').glob('*/ebin'))
    assert any(p.parent.name=='ex_webrtc' for p in paths),'Compile the existing BeamTransport first'
    out=root/'builds/intermediates/buffee-control-check';out.mkdir(parents=True,exist_ok=True)
    fixture=out/'opus-fixture.bin'
    if args.opus:
        subprocess.run([os.environ['BA_GSTREAMER_PYTHON'],str(HERE/'opus-fixture.py'),str(fixture)],check=True)
    subprocess.run([shutil.which('erlc'),'-Werror','-o',str(out),
        str(HERE/'ba_buffee_control_probe.erl'),str(HERE/'ba_audio_stream_probe.erl')],check=True)
    runtimes=[];desk=None;inspector=None;monitor_stop=threading.Event();monitor_thread=None;monitor_errors=[];monitor_samples=[]
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
        runtimes.extend(control.Runtime([out,*paths],executable=executable,extra_env=extra_env) for _ in range(2 if args.single_source else 3))
        a,b=runtimes[:2];c=None if args.single_source else runtimes[2]
        if args.single_source:
            inspector=control.Runtime([out,*paths],executable=executable,extra_env={**extra_env,'BA_DEVICE_NAME':'Inspector Mac E2E'})
            assert inspector.request('renewal_prepare',lease_ms=args.lease_ms)['ok']
            if args.buffee_time:assert inspector.request('clock_prepare',interval_ms=250,samples=3)['ok']
        participants=runtimes+([inspector] if inspector else [])
        publishers=[a] if args.single_source else [a,c]
        sources=[(a,'music',.75)] if args.single_source else [(a,'music',.25),(c,'microphone',.5)]
        for r in runtimes:assert r.request('renewal_prepare',lease_ms=args.lease_ms)['ok']
        if args.buffee_time:
            for r in runtimes:assert r.request('clock_prepare',interval_ms=250,samples=3)['ok']
        assert a.request('create',desks=[url])['ok']
        control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
        invitations={}
        if args.ephemeral:
            for r,name in zip(participants[1:],['Receiver','Inspector Mac E2E'] if args.single_source else ['Receiver','Second publisher']):
                assert a.request('put_contact',id=r.identity['id'],name=name)['ok']
            assert a.request('group_contacts',name='Session',ids=[r.identity['id'] for r in participants[1:]])['ok']
            links=a.request('invite_buffee',selection={'group':'Session'})['value']
            invitations={entry['device']:entry['invitation'] for entry in links}
        for r in participants[1:]:
            invitation=invitations[r.identity['id']] if args.ephemeral else a.request('invite')['value']
            assert r.request('join',invitation=invitation,desk=url)['ok']
            control.wait(r,lambda s:s['membership']['state']=='authorized')
        permissions=['status_read','stream_read','stream_subscribe']
        if args.buffee_time:
            permissions=['offset_write',*permissions,'time_read']
            if c is not None:assert a.request('grant',peer=c.identity['id'],permissions=['time_read'])['ok']
        assert a.request('grant',peer=b.identity['id'],permissions=permissions)['ok']
        if inspector:
            assert a.request('grant',peer=inspector.identity['id'],permissions=['capabilities_read','status_read','time_read'])['ok']
        revision=a.request('snapshot')['membership']['revision']
        for r in participants[1:]:control.wait(r,lambda s:s['membership']['state']=='authorized' and s['membership']['revision']==revision)
        for r in publishers:
            # The control owner already initiates missing peer links. A second
            # initiator here can collide with its authenticated handshake.
            control.wait(b,lambda s:s['sessions'].get(r.identity['id'],{}).get('stage')=='authorized')
            control.wait(r,lambda s:s['sessions'].get(b.identity['id'],{}).get('stage')=='authorized')
        if inspector:
            for r in runtimes:
                control.wait(inspector,lambda s:s['sessions'].get(r.identity['id'],{}).get('stage')=='authorized')
        if args.buffee_time:
            for r in runtimes:
                deadline=time.monotonic()+20
                while time.monotonic()<deadline:
                    clock=r.request('clock_snapshot')
                    if clock['state']=='synchronized' and clock['offset_policy']['ready']:break
                    time.sleep(.05)
                else:raise AssertionError(clock)
            assert a.request('offset_set',offset_ms=250)['ok']
            for r in runtimes:
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    if r.request('clock_snapshot')['offset_policy']['offset_ms']==250:break
                    time.sleep(.05)
                else:raise AssertionError('Offset did not reach publisher')
        for r in runtimes:assert r.request('buffee_audio_prepare' if args.buffee_time else 'audio_prepare')['ok']
        consent=b.request('api',request={'method':'capability','capability':'speaker','enabled':True})
        assert consent.get('consent',{}).get('speaker') is True,consent.get('error')
        on_air=a.request('api',request={'method':'capability','capability':'broadcast','enabled':True})
        assert on_air.get('consent',{}).get('broadcast') is True,on_air.get('error')
        if c is not None:
            mic=c.request('api',request={'method':'capability','capability':'microphone','enabled':True})
            assert mic.get('consent',{}).get('microphone') is True,mic.get('error')
        def publish(r,key,format,channels):
            return r.request('publish_opus',source=key,fixture=str(fixture)) if args.opus else r.request('publish',source=key,format=format,channels=channels)
        assert publish(a,'music','pcm16_le',1)['ok']
        if c is not None:assert publish(c,'microphone','float32_le',2)['ok']
        wait_audio(b,lambda s:len(s['offers'])==len(sources))
        subscriptions=[];contracts=[]
        for r,key,_ in sources:
            contract=secrets.token_hex(16).upper()
            assert r.request('audio_contract',direction='publish',peer=b.identity['id'],source=key,contract=contract)['ok']
            assert b.request('audio_contract',direction='receive',peer=r.identity['id'],source=key,contract=contract)['ok']
            result=b.request('audio_subscribe',peer=r.identity['id'],source=key)
            assert result.get('ok'),result
            subscriptions.append(result['value'])
            contracts.append((r,key,contract))
        x=subscriptions[0];y=None if args.single_source else subscriptions[1]
        wait_audio(b,lambda s:all(s['subscriptions'][i]['state']=='active' for i in subscriptions))
        for i in subscriptions:
            reply=b.request('audio_play',id=i,playing=True)
            assert reply.get('ok'),reply
        if args.renewal:
            assert not args.opus,'PCM is used for exact continuous frame/mix accounting'
            if args.buffee_time:
                assert a.request('offset_set',offset_ms=args.offset_ms)['ok']
                for r in runtimes:
                    end=time.monotonic()+10
                    while r.request('clock_snapshot')['offset_policy']['offset_ms']!=args.offset_ms:
                        assert time.monotonic()<end;time.sleep(.05)
            identities=[r.request('audio_ids') for r in runtimes]
            if args.buffee_time:assert_session_clocks(runtimes,a,args.offset_ms)
            def monitor():
                reply=inspector.request('api',request={'method':'monitor','metrics':True})
                assert reply.get('error') is None,reply.get('error')
                rows={row['id']:row for row in reply['result']['devices']}
                for r in runtimes:
                    assert rows[r.identity['id']]['state']=='ok',rows
                return rows
            def configure(r,**options):
                reply=inspector.request('api',request={'method':'audio_diagnostics','device':r.identity['id'],'options':options})
                if reply.get('error') is not None:
                    local=r.request('api',request={'method':'monitor','metrics':True})
                    caps=[row for row in local.get('result',{}).get('devices',[]) if row.get('local')]
                    raise AssertionError({'error':reply.get('error'),'target_capabilities':caps})
                return reply
            if inspector:
                # Both local and remote public APIs control real instrumentation.
                for r in runtimes:
                    reply=r.request('api',request={'method':'audio_diagnostics','options':{'meters':False,'analysis':False}})
                    assert reply.get('error') is None,reply.get('error')
                off=monitor()
                for r in runtimes:
                    caps=off[r.identity['id']]['capabilities']
                    assert caps['audio_diagnostics']=={'diagnostics.meters':False,'diagnostics.analysis':False},caps
                    assert all('peak_db' not in row for row in caps.get('audio',{}).values()) and not caps.get('audio_meters'),caps
                    configure(r,meters=True,analysis=True)
                deadline=time.monotonic()+5
                while True:
                    initial=monitor()
                    if all('transport.sent' in initial[r.identity['id']]['capabilities']['audio_diagnostics'] for r in publishers) and 'mixer.submitted_frames' in initial[b.identity['id']]['capabilities']['audio_diagnostics']:break
                    assert time.monotonic()<deadline,initial;time.sleep(.05)
                monitored_before={r.identity['id']:initial[r.identity['id']]['capabilities']['audio_diagnostics'] for r in runtimes}
                def observe_stream():
                    try:
                        while not monitor_stop.is_set():
                            monitor_samples.append(monitor())
                            monitor_stop.wait(.1)
                    except BaseException as exc:monitor_errors.append(exc)
                monitor_thread=threading.Thread(target=observe_stream,daemon=True);monitor_thread.start()
            for r in runtimes:r.request('vm_monitor')
            before_audio=b.request('audio_snapshot');before=before_audio['mixer'];b.request('audio_reset_stats')
            sent_before=[sum(p['transport'].get('sent',0) for p in r.request('audio_snapshot')['provider_status']) for r in publishers]
            target=time.time_ns()+args.offset_ms*1_000_000
            start=time.monotonic()
            for n in range(args.seconds*50):
                for r,key,value in sources:
                    if args.buffee_time:
                        reply=r.request('capture_source',source=key,capture_ns=target-args.offset_ms*1_000_000+n*20_000_000,value=value,frames=960)
                        assert reply.get('send_errors')==0,reply
                    else:
                        reply=r.request('push_source',source=key,target_ns=target+n*20_000_000,value=value,frames=960)
                        assert reply['deliveries']==1,reply
                if n%50==0:
                    if args.buffee_time:assert_session_clocks(runtimes,a,args.offset_ms)
                    for r,old in zip(runtimes,identities):assert r.request('audio_ids')==old
                    # Reinstall exactly the same Contracts during live playback.
                    for r,key,contract in contracts:
                        assert r.request('audio_contract',direction='publish',peer=b.identity['id'],source=key,contract=contract)['ok']
                        assert b.request('audio_contract',direction='receive',peer=r.identity['id'],source=key,contract=contract)['ok']
                time.sleep(max(0,start+(n+1)*.02-time.monotonic()))
            if args.deny_renewal:
                assert not args.buffee_time,'Keep the independent test clock fresh to isolate authorization expiry'
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
            after_audio=b.request('audio_snapshot');after=after_audio['mixer'];stats=b.request('audio_stats')
            if args.buffee_time:assert_session_clocks(runtimes,a,args.offset_ms)
            expected_packets=args.seconds*50
            for sub in subscriptions:
                old=before_audio['subscriptions'][sub]['transport'];new=after_audio['subscriptions'][sub]['transport']
                assert new['received']-old['received']==expected_packets,(sub,old,new)
                assert new['rejected']==old['rejected'],(sub,old,new)
            for r,old in zip(publishers,sent_before):
                sent=sum(p['transport'].get('sent',0) for p in r.request('audio_snapshot')['provider_status'])-old
                assert sent==expected_packets,(sent,expected_packets)
            if inspector:
                monitor_stop.set();monitor_thread.join(timeout=10)
                assert not monitor_thread.is_alive(),'Monitor did not stop'
                assert not monitor_errors,monitor_errors
                deadline=time.monotonic()+5
                while True:
                    final=monitor();reported={r.identity['id']:final[r.identity['id']]['capabilities']['audio_diagnostics'] for r in runtimes}
                    out=reported[b.identity['id']]
                    if out.get('output.completed_frames')==args.seconds*48000:break
                    assert time.monotonic()<deadline,reported;time.sleep(.05)
                for r in publishers:
                    assert reported[r.identity['id']]['transport.sent']-monitored_before[r.identity['id']]['transport.sent']==expected_packets,reported
                assert out['transport.received']-monitored_before[b.identity['id']]['transport.received']==expected_packets,out
                assert out['mixer.submitted_frames']-monitored_before[b.identity['id']]['mixer.submitted_frames']==args.seconds*48000,out
                assert out['mixer.dropped']==monitored_before[b.identity['id']]['mixer.dropped'],out
                assert out['output.backend']=='test_sink' and out['output.queued_buffers']==0,out
                meters=[sample[b.identity['id']]['capabilities'].get('audio_meters',{}).get('output_submitted',{}) for sample in monitor_samples]
                received_meters=[sample[b.identity['id']]['capabilities'].get('audio_meters',{}).get('receive_max',{}) for sample in monitor_samples]
                assert any(m.get('meter_age_ms',9999)<500 and abs(m.get('peak_db',-96)-(-2.4987747321659985))<.1 for m in received_meters),received_meters
                assert any(m.get('meter_stage')=='output_submitted' and m.get('meter_age_ms',9999)<500 and abs(m.get('peak_db',-96)-(-2.4987747321659985))<.1 for m in meters),meters
                for r in runtimes:
                    assert reported[r.identity['id']]['clock.state']=='synchronized',reported
                    assert reported[r.identity['id']]['clock.offset_ms']==args.offset_ms,reported
                    assert reported[r.identity['id']]['clock.ready'] is True,reported
                # Disabling observation must leave media/consent/processes intact.
                for r in runtimes:configure(r,meters=False,analysis=False)
                disabled=monitor()
                for r,old in zip(runtimes,identities):
                    assert r.request('audio_ids')==old
                    caps=disabled[r.identity['id']]['capabilities']
                    assert caps['audio_diagnostics']=={'diagnostics.meters':False,'diagnostics.analysis':False},caps
                    assert all('peak_db' not in entry for entry in caps.get('audio',{}).values()) and not caps.get('audio_meters'),caps
                print('PASS: independent Inspector remotely toggled both Devices and validated packet/frame totals, output meter, synchronized clocks and response time through signed monitor replies',flush=True)
            print(f'PASS: {expected_packets} packets/source delivered; clocks and {args.offset_ms}ms response-time assertions passed',flush=True)
            if after['dropped']!=before['dropped']:
                print('VM scheduler report (receiver):',b.request('vm_report'),flush=True)
                for r in publishers:print('VM scheduler report (publisher):',r.request('vm_report'),flush=True)
            assert after['dropped']==before['dropped'],(before,after,stats)
            assert stats['frames']==args.seconds*48000 and stats['gaps']==0 and stats['bad_mix']==0 and stats['late']==0,stats
            assert abs(stats['first_target']-target)<22000,stats
            assert after['queued_bytes']==0,after
            for r,old in zip(runtimes,identities):assert r.request('audio_ids')==old
            for r in publishers:
                session=b.request('snapshot')['sessions'][r.identity['id']]
                assert session.get('renewals',0)>=2,session
            # Revocation must still invalidate authorized media and future
            # buffers after successful in-place renewal.
            frames_before=b.request('audio_stats')['frames'];future=time.time_ns()+700_000_000
            for r,key,value in sources:
                assert r.request('push_source',source=key,target_ns=future,value=value,frames=960)['deliveries']==1
            end=time.monotonic()+2
            while b.request('audio_snapshot')['mixer']['queued_bytes']==0:
                assert time.monotonic()<end;time.sleep(.01)
            assert a.request('revoke',peer=b.identity['id'])['ok']
            wait_audio(b,lambda s:s['mixer']['streams']==0 and all(v['state']!='active' for v in s['subscriptions'].values()))
            time.sleep(.75)
            assert b.request('audio_stats')['frames']==frames_before,'Revoked future PCM was rendered'
            print(f'PASS: {len(runtimes)} Devices, {len(sources)} source(s), {args.seconds}s PCM: {expected_packets} packets/source sent and received; {stats["frames"]} frames, no gaps/drops/late output, unchanged media across renewal; stop/revocation verified')
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
                if args.buffee_time:
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
                    if state['buffee']=={'state':'idle'}:
                        # The Device's shared Reception socket may stay open; no Session mailbox may.
                        assert state['live']==[] and not state['transient_state'] and state['connections']<=1 and state['mailboxes']==0,state
                        return
                    time.sleep(.1)
                raise AssertionError(('Buffee did not terminate',state))
            def stable_book(book):
                # A saved Session's 'last' seen time moves on every visit.
                return {**book,'sessions':{k:{f:v for f,v in e.items() if f!='last'} for k,e in book.get('sessions',{}).items()}}
            buffee=a.request('buffee_status')['buffee']
            address_book=a.request('list_contacts')
            assert b.request('end_buffee')=={'error':'end_privilege_required'}
            assert b.request('leave_buffee')['ok'];idle(b)
            # Leave preserves membership and privileges (2026-11-15): b can return.
            time.sleep(.5)
            assert b.identity['id'] in a.request('snapshot')['membership']['members']
            assert a.request('buffee_status')['buffee']==buffee
            # A new invitation allows an explicit return to the still-live gathering.
            link=a.request('invite_buffee',selection=[b.identity['id']])['value'][0]['invitation']
            assert b.request('join_buffee',invitation=link)['ok']
            control.wait(b,lambda s:s['membership']['state']=='authorized')
            # End reaches only currently paired participants (documented limit);
            # wait until the returning Device is paired again.
            control.wait(a,lambda s:b.identity['id'] in s['membership']['participants'])
            assert a.request('end_buffee')['ok']
            for r in runtimes:idle(r)
            after_end=a.request('list_contacts');assert stable_book(after_end)==stable_book(address_book),(address_book,after_end)
            # End clears saved return intent: no return link and no saved policy
            # for the ended Session (files may remain with other contents).
            for r in runtimes:
                saved=r.request('saved_sessions')
                assert not saved['return_link'] and buffee not in saved['sessions'],(saved,buffee)
            # Same identity/storage, new VM: contacts survive, gathering does not.
            directory=a.state.name;seed=a.seed;identity=a.identity['id'];a.close()
            a=control.Runtime([out,*paths],seed=seed,state=directory,executable=executable,extra_env=extra_env)
            runtimes.append(a);idle(a)
            assert a.identity['id']==identity and stable_book(a.request('list_contacts'))==stable_book(address_book)
            assert a.request('create',desks=[url])['ok']
            assert a.request('buffee_status')['buffee']!=buffee
            control.wait(a,lambda s:all(d['connected'] for d in s['relay']['desks'].values()))
            # Join model (2026-11-17): holding the link is enough to participate,
            # so the ended Session's link still opens an empty Session with that
            # ID. End cleared the saved policy, so no old privilege returns.
            assert b.request('join_buffee',invitation=link)['ok']
            assert b.request('buffee_status')['buffee']==buffee
            time.sleep(.5)
            returned=b.request('buffee_status')
            assert not set(returned.get('privileges',[]))&{'grant','owner','on_air','stream_publish','end_session'},returned
            assert b.request('leave_buffee')['ok'];idle(b)
            link=a.request('invite_buffee',selection=[b.identity['id']])['value'][0]['invitation']
            assert b.request('join_buffee',invitation=link)['ok']
            control.wait(b,lambda s:s['membership']['state']=='authorized')
            # Losing the grant holder ends nothing (BUFFEE_MEMBERSHIP.md): the other
            # Device stays in the Session with its own privileges, none gained.
            before=set(b.request('buffee_status').get('privileges',[]))
            assert a.request('crash_buffee')['ok'];idle(a)
            time.sleep(2)
            kept=b.request('buffee_status')
            assert kept['state']=='authorized' and set(kept.get('privileges',[]))==before,kept
            assert b.request('leave_buffee')['ok'];idle(b)
            final=a.request('list_contacts')
            # Contacts and groups survive; the saved-Session list follows later visits.
            assert {k:final[k] for k in ('contacts','groups')}=={k:address_book[k] for k in ('contacts','groups')},(address_book,final)
            print('PASS: saved group invitations, voluntary leave and return keeping privileges, real two-source PCM, End clearing return link and saved policy, grant-holder loss ending nothing, process/ETS/mailbox teardown, new Session ID and contacts surviving cold restart; no apps or hardware')
            return
        if args.sustained:
            assert args.buffee_time and not args.opus
            # Response time is a setting: grant or on_air holders only (privileges model).
            assert b.request('offset_set',offset_ms=1000)=={'error':'forbidden'}
            assert a.request('offset_set',offset_ms=1000)['ok']
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
            if inspector:
                monitor_stop.set();monitor_thread.join(timeout=10)
                assert not monitor_thread.is_alive(),'Monitor did not stop'
                assert not monitor_errors,monitor_errors
                deadline=time.monotonic()+5
                while True:
                    final=monitor();reported={r.identity['id']:final[r.identity['id']]['capabilities']['audio_diagnostics'] for r in runtimes}
                    out=reported[b.identity['id']]
                    if out.get('output.completed_frames')==args.seconds*48000:break
                    assert time.monotonic()<deadline,reported;time.sleep(.05)
                for r in publishers:
                    assert reported[r.identity['id']]['transport.sent']-monitored_before[r.identity['id']]['transport.sent']==expected_packets,reported
                assert out['transport.received']-monitored_before[b.identity['id']]['transport.received']==expected_packets,out
                assert out['mixer.submitted_frames']-monitored_before[b.identity['id']]['mixer.submitted_frames']==args.seconds*48000,out
                assert out['mixer.dropped']==monitored_before[b.identity['id']]['mixer.dropped'],out
                assert out['output.backend']=='test_sink' and out['output.queued_buffers']==0,out
                meters=[sample[b.identity['id']]['capabilities'].get('audio_meters',{}).get('output_submitted',{}) for sample in monitor_samples]
                received_meters=[sample[b.identity['id']]['capabilities'].get('audio_meters',{}).get('receive_max',{}) for sample in monitor_samples]
                assert any(m.get('meter_age_ms',9999)<500 and abs(m.get('peak_db',-96)-(-2.4987747321659985))<.1 for m in received_meters),received_meters
                assert any(m.get('meter_stage')=='output_submitted' and m.get('meter_age_ms',9999)<500 and abs(m.get('peak_db',-96)-(-2.4987747321659985))<.1 for m in meters),meters
                for r in runtimes:
                    assert reported[r.identity['id']]['clock.state']=='synchronized',reported
                    assert reported[r.identity['id']]['clock.offset_ms']==args.offset_ms,reported
                    assert reported[r.identity['id']]['clock.ready'] is True,reported
                # Disabling observation must leave media/consent/processes intact.
                for r in runtimes:configure(r,meters=False,analysis=False)
                disabled=monitor()
                for r,old in zip(runtimes,identities):
                    assert r.request('audio_ids')==old
                    caps=disabled[r.identity['id']]['capabilities']
                    assert caps['audio_diagnostics']=={'diagnostics.meters':False,'diagnostics.analysis':False},caps
                    assert all('peak_db' not in entry for entry in caps.get('audio',{}).values()) and not caps.get('audio_meters'),caps
                print('PASS: independent Inspector remotely toggled both Devices and validated packet/frame totals, output meter, synchronized clocks and response time through signed monitor replies',flush=True)
            assert after['dropped']==before['dropped'],(before,after)
            assert after['rendered']-before['rendered']>=600,(before,after)
            assert blocks and max(x['peak'] for x in blocks)==.75,blocks
            assert after['queued_bytes']==0,after
            # Restore the short fixture Offset, restart the reference and exercise
            # production capture's automatic incarnation/descriptor rebind.
            assert a.request('offset_set',offset_ms=250)['ok']
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
        print(('PASS: authenticated shared Buffee clock and Offset; ' if args.buffee_time else 'PASS: test clock; ')+('real WebRTC Opus decoded by GStreamer' if args.opus else 'real WebRTC PCM')+' from two publishers mixed at their packet targets; independent receiver/source pause and resume; disappearance and new-incarnation restore; scoped unsubscribe and Contract revocation; no OTP distribution, product apps or hardware output')
    finally:
        monitor_stop.set()
        if monitor_thread:monitor_thread.join(timeout=10)
        if inspector:inspector.close()
        for r in runtimes:r.close()
        if desk is not None:desk.terminate();desk.wait(timeout=5)
if __name__=='__main__':main()
