#!/usr/bin/env python3
"""Matched local Opus/WebRTC receivers. Silent fixtures, not a speaker benchmark."""
import argparse
import array
import hashlib
import json
import os
from pathlib import Path
import resource
import subprocess
import sys
import threading
import time

from schedule_proof import load_runtime


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path,required=True)
    parser.add_argument('--receiver',choices=['gstreamer','neteq'],required=True)
    parser.add_argument('--native-receiver',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--seconds',type=int,default=8)
    parser.add_argument('--drop-every',type=int,default=0)
    parser.add_argument('--minimum-delay-ms',type=int)
    args=parser.parse_args()
    if sys.platform!='darwin' or args.seconds<8:
        parser.error('This matched fixture needs macOS and at least eight seconds.')
    if args.drop_every < 0 or args.drop_every == 1 or (args.minimum_delay_ms is not None and args.minimum_delay_ms < 0):
        parser.error('Use a drop interval of zero or at least two, and a nonnegative minimum delay.')
    if args.minimum_delay_ms is not None and args.receiver != 'neteq':
        parser.error('--minimum-delay-ms is the NetEq control; GStreamer uses its existing 200 ms jitter latency.')
    if args.receiver=='neteq' and not args.native_receiver:
        parser.error('Supply --native-receiver for NetEq.')
    GLib,Gst,GstRtp,_,dll_handles=load_runtime(args.runtime)
    args.output.mkdir(parents=True,exist_ok=True)
    loop=GLib.MainLoop()
    result={'receiver':args.receiver,'seconds':args.seconds,'drop_every':args.drop_every,
        'minimum_delay_ms':args.minimum_delay_ms,'gstreamer':Gst.version_string(),
        'scope':'same-host silent receiver fixture; not device quality or physical latency',
        'errors':[],'produced_packets':0,'injected_drops':[],'snapshots':{},'rss_sum_samples_bytes':[]}
    pcm=bytearray();blocks=[];digest=hashlib.sha256()
    state={'sender_ready':False,'pending':[],'measuring':False}
    child=None;child_log=None;write_lock=threading.Lock();native_clock_offset=0
    def fail(message):
        result['errors'].append(str(message));loop.quit()
    def native(command):
        with write_lock:
            child.stdin.write(json.dumps(command)+'\n');child.stdin.flush()
    def parent_cpu():
        r=resource.getrusage(resource.RUSAGE_SELF);return r.ru_utime+r.ru_stime
    source=('audiotestsrc is-live=true wave=sine freq=997 volume=0.05 samplesperbuffer=960 '
        f'num-buffers={args.seconds*50} ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! '
        'opusenc bitrate=192000 frame-size=20 ! rtpopuspay name=pay pt=111 ssrc=1 '
        'timestamp-offset=4294967040 seqnum-offset=0 ! '
        'application/x-rtp,media=audio,encoding-name=OPUS,clock-rate=48000,payload=111 ! '
        'webrtcbin name=peer bundle-policy=max-bundle')
    tx=Gst.parse_launch(source);sender=tx.get_by_name('peer')
    rx=None;jitters=[]
    def emit_candidate(index,value):
        if state['sender_ready']: sender.emit('add-ice-candidate',index,value)
        else: state['pending'].append((index,value))
        return False
    def remote_set(_promise,*_):
        state['sender_ready']=True
        for index,value in state['pending']: sender.emit('add-ice-candidate',index,value)
        state['pending'].clear()
    if args.receiver=='gstreamer':
        # Existing Windows media policy: default decoder tolerance, jitter mode
        # and 200 ms webrtcbin latency; output replaced by a silent collector.
        rx=Gst.parse_launch('webrtcbin name=peer latency=200 bundle-policy=max-bundle '
            'queue name=input ! rtpopusdepay ! opusdec name=decode plc=true ! '
            'audio/x-raw,format=S16LE,rate=48000,channels=2 ! '
            'fakesink name=output sync=true async=false signal-handoffs=true')
        receiver=rx.get_by_name('peer')
        receiver.connect('pad-added',lambda _p,pad:pad.link(rx.get_by_name('input').get_static_pad('sink'))
            if pad.get_direction()==Gst.PadDirection.SRC else None)
        receiver.get_by_name('rtpbin').connect('new-jitterbuffer',lambda _r,j,_s,_ss:jitters.append(j))
        receiver.connect('on-ice-candidate',lambda _p,i,c:emit_candidate(i,c))
        sender.connect('on-ice-candidate',lambda _p,i,c:receiver.emit('add-ice-candidate',i,c))
        def handoff(_sink,buffer,_pad):
            host=time.perf_counter_ns();frames=buffer.get_size()//4
            blocks.append([host,len(pcm)//4,frames]);pcm.extend(buffer.extract_dup(0,buffer.get_size()))
        rx.get_by_name('output').connect('handoff',handoff)
    else:
        child_log=(args.output/'native.log').open('w')
        child=subprocess.Popen([str(args.native_receiver.resolve()),str((args.output/'output.s16le').resolve())],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=child_log,text=True)
        native({'op':'prepare'})
        while True:
            line=child.stdout.readline()
            if not line: raise RuntimeError('Native receiver failed during preparation; see native.log')
            try: event=json.loads(line)
            except json.JSONDecodeError: continue
            if event.get('event')=='ready': break
        best=None
        for _ in range(8):
            before=time.perf_counter_ns();native({'op':'clock'})
            event=json.loads(child.stdout.readline());after=time.perf_counter_ns()
            sample={'round_trip_ns':after-before,'offset_ns':(before+after)//2-event['host_ns']}
            if best is None or sample['round_trip_ns']<best['round_trip_ns']: best=sample
        native_clock_offset=best['offset_ns'];result['native_clock_bridge']=best
        def native_event(event):
            kind=event.get('event')
            if kind=='candidate':
                c=event['candidate'];emit_candidate(c['sdpMLineIndex'],c['candidate'])
            elif kind=='answer':
                from gi.repository import GstSdp,GstWebRTC
                _ok,sdp=GstSdp.SDPMessage.new_from_text(event['sdp'])
                answer=GstWebRTC.WebRTCSessionDescription.new(GstWebRTC.WebRTCSDPType.ANSWER,sdp)
                sender.emit('set-remote-description',answer,Gst.Promise.new_with_change_func(remote_set,None,None))
                if args.minimum_delay_ms is not None:
                    native({'op':'minimum_delay','seconds':args.minimum_delay_ms/1000})
            elif kind=='minimum_delay':
                result['minimum_delay_configured']=event['configured']
                if not event['configured']: fail('Native minimum-delay setter unavailable')
            elif kind=='stats':
                key=event['request_id'];result['snapshots'].setdefault(key,{})['native']=event
            elif kind=='finished':
                result['native_final']=event
                blocks.extend([[row[0]+native_clock_offset,row[1],row[2]] for row in event['output_blocks']])
                loop.quit()
            elif kind=='error': fail(event.get('error'))
            return False
        def read_native():
            for line in child.stdout:
                try: event=json.loads(line)
                except json.JSONDecodeError: continue
                if event.get('event')=='finished': state['native_finished_received']=True
                GLib.idle_add(native_event,event)
            if not state.get('native_finished_received'):
                GLib.idle_add(fail,'Native receiver exited; inspect native.log')
        threading.Thread(target=read_native,daemon=True).start()
        sender.connect('on-ice-candidate',lambda _p,i,c:native({'op':'candidate',
            'candidate':{'candidate':c,'sdpMLineIndex':i,'sdpMid':'audio0'}}))
    def offered(promise,*_):
        reply=promise.get_reply();offer=reply.get_value('offer') if reply else None
        if offer is None: fail('Cannot create offer: '+str(reply));return
        sender.emit('set-local-description',offer,None)
        if child: native({'op':'offer','sdp':offer.sdp.as_text()})
        else:
            def receiver_set(_promise,*_):
                def answered(promise,*_):
                    reply=promise.get_reply();answer=reply.get_value('answer') if reply else None
                    if answer is None: fail('Cannot create answer');return
                    receiver.emit('set-local-description',answer,None)
                    sender.emit('set-remote-description',answer,Gst.Promise.new_with_change_func(remote_set,None,None))
                receiver.emit('create-answer',None,Gst.Promise.new_with_change_func(answered,None,None))
            receiver.emit('set-remote-description',offer,Gst.Promise.new_with_change_func(receiver_set,None,None))
    def negotiate(_sender):
        if state.get('negotiating'): return
        state['negotiating']=True;sender.emit('create-offer',None,Gst.Promise.new_with_change_func(offered,None,None))
    sender.connect('on-negotiation-needed',negotiate)
    def snapshot(key):
        now=time.perf_counter_ns()
        record={'host_ns':now,'parent_cpu_seconds':parent_cpu(),'source_packets_produced':result['produced_packets']}
        result['snapshots'][key]=record
        if child: native({'op':'stats','request_id':key})
        else:
            stats=rx.get_by_name('decode').get_property('stats')
            record['decoder']={stats.nth_field_name(i):stats.get_value(stats.nth_field_name(i)) for i in range(stats.n_fields())}
            record['jitter_config']=[{'mode':int(j.get_property('mode')),'do_lost':j.get_property('do-lost'),'latency_ms':j.get_property('latency')} for j in jitters]
            record['jitterbuffers']=[]
            for jitter in jitters:
                stats=jitter.get_property('stats')
                record['jitterbuffers'].append({stats.nth_field_name(i):stats.get_value(stats.nth_field_name(i)) for i in range(stats.n_fields())})
        if key=='start': state['measuring']=True
        if key=='end': state['measuring']=False
        return False
    def sent(_pad,info):
        buffer=info.get_buffer()
        if not buffer: return Gst.PadProbeReturn.OK
        valid,rtp=GstRtp.RTPBuffer.map(buffer,Gst.MapFlags.READ)
        if not valid: return Gst.PadProbeReturn.OK
        payload=rtp.get_payload_buffer();digest.update(payload.extract_dup(0,payload.get_size()))
        result['produced_packets']+=1;index=result['produced_packets']
        if index==1: result['first_payload_host_ns']=time.perf_counter_ns()
        rtp.unmap()
        if index==100: GLib.idle_add(snapshot,'start')
        if index==(args.seconds-2)*50: GLib.idle_add(snapshot,'end')
        if args.drop_every and index>100 and index%args.drop_every==args.drop_every//2:
            result['injected_drops'].append(index);return Gst.PadProbeReturn.DROP
        return Gst.PadProbeReturn.OK
    tx.get_by_name('pay').get_static_pad('src').add_probe(Gst.PadProbeType.BUFFER,sent)
    def rss_sample():
        if state['measuring']:
            ids=[str(os.getpid())]+([str(child.pid)] if child else [])
            output=subprocess.check_output(['/bin/ps','-o','rss=','-p',','.join(ids)],text=True)
            result['rss_sum_samples_bytes'].append(sum(int(v) for v in output.split())*1024)
        return True
    GLib.timeout_add(200,rss_sample)
    for pipeline in [p for p in [tx,rx] if p is not None]:
        bus=pipeline.get_bus();bus.add_signal_watch()
        def message(_bus,msg,pipeline=pipeline):
            if msg.type==Gst.MessageType.ERROR: fail(str(msg.parse_error()))
            elif msg.type==Gst.MessageType.LATENCY: pipeline.recalculate_latency()
        bus.connect('message',message)
    def finish():
        if child: native({'op':'finish'})
        else: loop.quit()
        return False
    GLib.timeout_add(int((args.seconds+0.5)*1000),finish)
    GLib.timeout_add_seconds(args.seconds+8,lambda:(fail('Fixture timeout'),False)[1])
    if rx: rx.set_state(Gst.State.PLAYING)
    tx.set_state(Gst.State.PLAYING)
    started=time.perf_counter_ns()
    try: loop.run()
    finally:
        tx.set_state(Gst.State.NULL)
        if rx: rx.set_state(Gst.State.NULL)
        if child:
            try: child.stdin.close()
            except BrokenPipeError: pass
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: child.kill();child.wait()
            child_log.close()
    if not child: (args.output/'output.s16le').write_bytes(pcm)
    result['output_blocks']=blocks
    result['encoded_source_sha256']=digest.hexdigest()
    result['elapsed_seconds']=(time.perf_counter_ns()-started)/1e9
    result['rss_sum_peak_bytes']=max(result['rss_sum_samples_bytes'],default=0)
    result['rss_definition']='sum of source/controller and receiver RSS; may double-count shared pages'
    result['resource_scope']='whole fixture including common sender and bindings; not isolated engine CPU'
    if 'start' in result['snapshots'] and 'end' in result['snapshots']:
        a,b=result['snapshots']['start'],result['snapshots']['end']
        cpu=b['parent_cpu_seconds']-a['parent_cpu_seconds']
        if child and 'native' in a and 'native' in b:
            cpu+=b['native']['cpu_seconds']-a['native']['cpu_seconds']
        result['window_cpu_seconds']=cpu
        result['window_duration_seconds']=(b['host_ns']-a['host_ns'])/1e9
    samples=array.array('h');samples.frombytes((args.output/'output.s16le').read_bytes())
    result['signal_present']=any(abs(sample)>32 for sample in samples)
    native_ok=not child or (all('native' in row for row in result['snapshots'].values())
        and 'native_final' in result and not result['native_final']['output_status_errors']
        and (args.minimum_delay_ms is None or result.get('minimum_delay_configured') is True))
    result['checks_passed']=(not result['errors'] and bool(blocks) and result['signal_present']
        and len(result['snapshots'])==2 and native_ok)
    (args.output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k not in ['output_blocks','native_final','rss_sum_samples_bytes','snapshots']},indent=2))
    return 0 if result['checks_passed'] else 1

if __name__=='__main__': raise SystemExit(main())
