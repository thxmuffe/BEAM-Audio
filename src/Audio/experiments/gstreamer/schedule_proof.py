#!/usr/bin/env python3
"""Finite, isolated Opus/WebRTC scheduling proof; never changes an app backend."""
import argparse
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def load_runtime(runtime):
    if os.name == 'nt':
        import gstreamer_libs
        gstreamer_libs.setup_python_environment()
        handles = [os.add_dll_directory(p) for p in os.environ.get('PYGI_DLL_DIRS','').split(os.pathsep) if os.path.isdir(p)]
    else:
        if not runtime or sys.version_info[:2] != (3,9):
            raise RuntimeError('On Mac use /usr/bin/python3 (3.9) and --runtime; see README.')
        runtime = runtime.resolve()
        sys.path.insert(0,str(runtime/'lib/python3.9/site-packages'))
        os.environ['GI_TYPELIB_PATH'] = str(runtime/'lib/girepository-1.0')
        os.environ['GST_PLUGIN_SYSTEM_PATH_1_0'] = str(runtime.parent/'plugins')
        os.environ['GST_REGISTRY_1_0'] = str(runtime.parent/'schedule-registry.bin')
        handles = []
    import gi
    if os.name != 'nt':
        gi.require_version('GIRepository','2.0')
        from gi.repository import GIRepository
        GIRepository.Repository.prepend_library_path(str(runtime/'lib'))
    for namespace in ['Gst','GstRtp','GstWebRTC','GstSdp','GstAudio','GstBase']:
        gi.require_version(namespace,'1.0')
    from gi.repository import GLib, Gst, GstRtp, GstWebRTC, GstSdp, GstAudio, GstBase
    Gst.init(None)
    return GLib,Gst,GstRtp,GstWebRTC,handles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime',type=Path)
    parser.add_argument('--escript',default=shutil.which('escript'))
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--seconds',type=int,default=8)
    parser.add_argument('--rate-ppm',type=float,default=0)
    parser.add_argument('--max-rate-ppm',type=float,default=50)
    parser.add_argument('--sink',choices=['fakesink','wasapisink','osxaudiosink'],default='fakesink')
    parser.add_argument('--transport',choices=['webrtc','rtp'],default='webrtc')
    args = parser.parse_args()
    if not args.escript or not 4 <= args.seconds <= 30:
        parser.error('Supply --escript and a duration between 4 and 30 seconds.')
    if not math.isfinite(args.rate_ppm) or not math.isfinite(args.max_rate_ppm) or args.max_rate_ppm<0:
        parser.error('Rate values must be finite, with a nonnegative maximum.')
    GLib,Gst,GstRtp,GstWebRTC,dll_handles = load_runtime(args.runtime)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    planner = subprocess.Popen([args.escript,str(Path(__file__).with_name('schedule_plan.escript'))],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    ready = planner.stdout.readline()
    if not ready:
        raise RuntimeError('Erlang planner failed: '+planner.stderr.read())
    loop = GLib.MainLoop()
    report = {'gstreamer':Gst.version_string(),'transport':args.transport,'sink':args.sink,
        'scope':'isolated local proof; not an app, cluster-clock or acoustic alignment result',
        'identity_basis':'exact RTP/decoded buffer PTS pairing; capture/converter/codec-content delay unqualified',
        'rtp_packets':0,'decoded_buffers':0,'mapped_buffers':0,'unmapped_buffers':0,
        'decoded_frames':0,'segment_events':0,'jitterbuffers':[],'errors':[],'warnings':[],
        'scheduled':False,'callback_errors_ns':[],'native_qos_arrival_diff_ns':[]}
    report['plugins']={}
    for element in ['webrtcbin','opusdec','rtpopusdepay','audioresample',args.sink]:
        factory=Gst.ElementFactory.find(element)
        if factory:
            plugin=factory.get_plugin()
            report['plugins'][element]={'plugin':plugin.get_name(),'version':plugin.get_version()}
    packet_pts = {}
    decoded = {}
    segment = [None]
    state = {'planning':False,'armed':False,'first_scheduled_pts':None}
    clock = Gst.SystemClock(name='erlang-directed-proof-clock')
    output = ('fakesink name=output sync=true signal-handoffs=true async=false' if args.sink=='fakesink' else
        args.sink+' name=output sync=true provide-clock=false slave-method=resample')
    downstream = ('queue name=input ! rtpopusdepay name=depay ! opusdec name=decode plc=true tolerance=0 ! '
        'audioconvert ! audioresample ! audio/x-raw,format=F32LE,rate=48000,channels=2 ! '
        'volume name=volume mute=true ! queue max-size-buffers=0 max-size-bytes=0 max-size-time=500000000 ! '+output)
    source = ('audiotestsrc is-live=true wave=sine freq=440 volume=0.015 samplesperbuffer=960 '
        f'num-buffers={args.seconds*50} ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! '
        'opusenc bitrate=192000 frame-size=20 ! rtpopuspay pt=111 ssrc=1 timestamp-offset=4294967040 seqnum-offset=0 ! ')
    if args.transport=='webrtc':
        rx = Gst.parse_launch('webrtcbin name=peer latency=200 bundle-policy=max-bundle '+downstream)
        tx = Gst.parse_launch(source+'application/x-rtp,media=audio,encoding-name=OPUS,clock-rate=48000,payload=111 ! '
            'webrtcbin name=peer bundle-policy=max-bundle')
    else:
        rx = Gst.parse_launch(source+'rtpjitterbuffer name=jitter latency=200 mode=none do-lost=true ! '+downstream)
        tx = None
    rx.use_clock(clock)
    sink = rx.get_by_name('output')
    volume = rx.get_by_name('volume')
    sink.set_property('qos',True)
    if args.sink!='fakesink':
        report['audio_sink_slave_method'] = str(sink.get_property('slave-method'))

    def fail(message):
        report['errors'].append(str(message))
        loop.quit()

    def plan_output(row):
        try:
            before = time.perf_counter_ns()
            clock_ns = clock.get_time()
            after = time.perf_counter_ns()
            host_ns = (before+after)//2
            # Fixture only: use native monotonic time as the local reference.
            # App integration must instead supply parvi_clock's real bridge/target.
            target = host_ns+1500000000
            request = {'target':{'local_handoff_time_ns':target,'revision':1,
                'stream_id':'isolated-fixture','clock_timeline':'local-proof-only'},
                'bridge':{'offset_ns':0},'pipeline':{'host_ns':host_ns,
                'pipeline_clock_ns':clock_ns,'base_time_ns':rx.get_base_time(),
                'running_time_ns':row['running_time_ns'],'pipeline_latency_ns':sink.get_latency(),
                'render_delay_ns':sink.get_property('render-delay'),
                'observation_uncertainty_ns':after-before}}
            planner.stdin.write(json.dumps(request)+'\n'); planner.stdin.flush()
            reply = json.loads(planner.stdout.readline())
            if not reply['ok']:
                raise RuntimeError(str(reply))
            if time.perf_counter_ns() >= target-100000000:
                raise RuntimeError('Erlang plan arrived too late for the proof target')
            sink.set_property('ts-offset',reply['plan']['ts_offset_ns'])
            state.update(armed=True,anchor_pts=row['pts'],target_ns=target)
            volume.set_property('mute',False)
            report.update(scheduled=True,plan=reply['plan'],pipeline_observation=request['pipeline'],
                schedule_source_rtp=row['rtp_timestamp'])
            if args.rate_ppm:
                GLib.timeout_add(2500,correct_rate)
        except Exception as error:
            fail(error)
        return False

    def correct_rate():
        try:
            if not state['armed']:
                raise RuntimeError('No schedule available for the rate proof')
            i0,e0,n,d = clock.get_calibration()
            request = {'operation':'rate','correction':{'correction_ppm':args.rate_ppm,
                'max_absolute_ppm':args.max_rate_ppm},'clock':{
                'internal_ns':clock.get_internal_time(),'calibration_internal_ns':i0,
                'calibration_external_ns':e0,'rate_numerator':n,'rate_denominator':d}}
            planner.stdin.write(json.dumps(request)+'\n'); planner.stdin.flush()
            reply=json.loads(planner.stdout.readline())
            if not reply['ok']:
                raise RuntimeError(str(reply))
            plan=reply['plan']
            clock.set_calibration(plan['internal_ns'],plan['external_ns'],
                plan['rate_numerator'],plan['rate_denominator'])
            state['rate'] = plan
            state['rate_host_anchor'] = state['target_ns']+plan['external_ns']-report['plan']['pipeline_target_ns']
            report['rate_change'] = {'requested_ppm':args.rate_ppm,'approved_max_ppm':args.max_rate_ppm,
                'plan':plan,'actual_calibration':list(clock.get_calibration()),
                'scope':'pipeline reference rate; actual DAC resampling/alignment not measured'}
        except Exception as error:
            fail(error)
        return False

    def observe_rtp(_pad,info):
        buffer = info.get_buffer()
        if buffer:
            valid,rtp = GstRtp.RTPBuffer.map(buffer,Gst.MapFlags.READ)
            if valid:
                packet_pts[buffer.pts] = rtp.get_timestamp()
                rtp.unmap()
                report['rtp_packets'] += 1
                while len(packet_pts)>128:
                    del packet_pts[next(iter(packet_pts))]
        return Gst.PadProbeReturn.OK

    def observe_decoded(_pad,info):
        if info.type & Gst.PadProbeType.EVENT_DOWNSTREAM:
            event = info.get_event()
            if event.type==Gst.EventType.SEGMENT:
                report['segment_events'] += 1
                if state['armed']:
                    fail('Decoded segment changed; proof schedule invalidated')
                segment[0] = event.parse_segment().copy()
            return Gst.PadProbeReturn.OK
        buffer = info.get_buffer()
        if buffer:
            if 'decoded_caps' not in report:
                caps=_pad.get_current_caps()
                report['decoded_caps']=caps.to_string()
                structure=caps.get_structure(0)
                if (structure.get_value('format'),structure.get_value('rate'),structure.get_value('channels'))!=('S16LE',48000,2):
                    fail('Unexpected proof decoder format: '+report['decoded_caps'])
            report['decoded_buffers'] += 1
            report['decoded_frames'] += buffer.get_size()//4  # opusdec S16 stereo
            rtp = packet_pts.pop(buffer.pts,None)
            if rtp is None or buffer.has_flags(Gst.BufferFlags.GAP):
                report['unmapped_buffers'] += 1
                if state['armed']: fail('Decoded source association lost; proof schedule invalidated')
                return Gst.PadProbeReturn.OK
            report['mapped_buffers'] += 1
            row = {'pts':buffer.pts,'rtp_timestamp':rtp,
                'running_time_ns':segment[0].to_running_time(Gst.Format.TIME,buffer.pts)}
            if 'first_pair' not in report: report['first_pair']=dict(row)
            report['last_pair']=dict(row)
            decoded.update(row)
            if report['decoded_buffers']>=25 and not state['planning']:
                state['planning']=True
                GLib.idle_add(plan_output,dict(row))
            if state['armed'] and state['first_scheduled_pts'] is None:
                state['first_scheduled_pts']=buffer.pts
        return Gst.PadProbeReturn.OK

    rx.get_by_name('depay').get_static_pad('sink').add_probe(Gst.PadProbeType.BUFFER,observe_rtp)
    rx.get_by_name('decode').get_static_pad('src').add_probe(
        Gst.PadProbeType.BUFFER|Gst.PadProbeType.EVENT_DOWNSTREAM,observe_decoded)
    if args.sink=='fakesink':
        def handoff(_sink,buffer,_pad):
            cutover = state['first_scheduled_pts']
            if cutover is not None and buffer.pts>=cutover:
                expected = state['target_ns']+buffer.pts-state['anchor_pts']
                if 'rate' in state and expected>=state['rate_host_anchor']:
                    rate=state['rate'];anchor=state['rate_host_anchor']
                    expected=anchor+(expected-anchor)*rate['rate_denominator']//rate['rate_numerator']
                report['callback_errors_ns'].append(time.perf_counter_ns()-expected)
        sink.connect('handoff',handoff)

    def observe_qos(_pad,info):
        event=info.get_event()
        if state['armed'] and event.type==Gst.EventType.QOS:
            _kind,_proportion,diff,_timestamp=event.parse_qos()
            report['native_qos_arrival_diff_ns'].append(diff)
        return Gst.PadProbeReturn.OK
    sink.get_static_pad('sink').add_probe(Gst.PadProbeType.EVENT_UPSTREAM,observe_qos)

    for pipeline in [p for p in [rx,tx] if p is not None]:
        bus = pipeline.get_bus();bus.add_signal_watch()
        def message(_bus,message):
            if message.type==Gst.MessageType.ERROR:
                error,debug=message.parse_error();fail(str(error)+' '+str(debug))
            elif message.type==Gst.MessageType.WARNING:
                report['warnings'].append(str(message.parse_warning()[0]))
            elif message.type==Gst.MessageType.LATENCY:
                rx.recalculate_latency()
            elif message.type==Gst.MessageType.EOS and tx is None:
                loop.quit()
        bus.connect('message',message)

    if tx:
        sender,receiver = tx.get_by_name('peer'),rx.get_by_name('peer')
        def jitter_created(_rtpbin,jitter,_session,_ssrc):
            jitter.set_property('mode',0)  # source RTP spacing; one output rate controller
            jitter.set_property('do-lost',True)
            report['jitterbuffers'].append({'mode':int(jitter.get_property('mode'))})
        receiver.get_by_name('rtpbin').connect('new-jitterbuffer',jitter_created)
        receiver.connect('pad-added',lambda _pc,pad: pad.link(rx.get_by_name('input').get_static_pad('sink'))
            if pad.get_direction()==Gst.PadDirection.SRC else None)
        pending = {'sender':[],'receiver':[]}
        applied = {'sender':False,'receiver':False}
        def candidate(_pc,index,value,other,key):
            if applied[key]: other.emit('add-ice-candidate',index,value)
            else: pending[key].append((index,value))
        sender.connect('on-ice-candidate',candidate,receiver,'receiver')
        receiver.connect('on-ice-candidate',candidate,sender,'sender')
        def flush(key,pc):
            applied[key]=True
            for index,value in pending[key]: pc.emit('add-ice-candidate',index,value)
            pending[key].clear()
        def sender_ready(_promise,*_):
            flush('sender',sender)
        def answered(promise,*_):
            reply=promise.get_reply()
            answer=reply.get_value('answer') if reply else None
            if answer is None:
                fail('Cannot create answer: '+str(reply));return
            receiver.emit('set-local-description',answer,None)
            sender.emit('set-remote-description',answer,
                Gst.Promise.new_with_change_func(sender_ready,None,None))
        def receiver_ready(_promise,*_):
            flush('receiver',receiver)
            receiver.emit('create-answer',None,Gst.Promise.new_with_change_func(answered,None,None))
        def offered(promise,*_):
            reply=promise.get_reply()
            offer=reply.get_value('offer') if reply else None
            if offer is None:
                fail('Cannot create offer: '+str(reply));return
            sender.emit('set-local-description',offer,None)
            receiver.emit('set-remote-description',offer,
                Gst.Promise.new_with_change_func(receiver_ready,None,None))
        def negotiate(_pc):
            if state.get('negotiating'): return
            state['negotiating']=True
            sender.emit('create-offer',None,Gst.Promise.new_with_change_func(offered,None,None))
        sender.connect('on-negotiation-needed',negotiate)
        rx.set_state(Gst.State.PLAYING)
        tx.set_state(Gst.State.PLAYING)
    else:
        rx.set_state(Gst.State.PLAYING)
    GLib.timeout_add_seconds(args.seconds+5,lambda: (loop.quit(),False)[1])
    try:
        loop.run()
        stats=sink.get_property('stats')
        report['output_stats'] = stats.to_string()
        report['rendered_buffers'] = stats.get_value('rendered')
        report['dropped_buffers'] = stats.get_value('dropped')
        if tx:
            report['sender_state']=str(sender.get_property('connection-state'))
            report['receiver_state']=str(receiver.get_property('connection-state'))
    finally:
        if tx: tx.set_state(Gst.State.NULL)
        rx.set_state(Gst.State.NULL)
        planner.stdin.close()
        try: planner.wait(timeout=3)
        except subprocess.TimeoutExpired: planner.kill();planner.wait()
    errors=report['callback_errors_ns']
    if errors:
        ordered=sorted(errors)
        report['software_callback_error_ms']={'median':ordered[len(ordered)//2]/1e6,
            'min':min(errors)/1e6,'max':max(errors)/1e6,
            'first_to_last_change':(errors[-1]-errors[0])/1e6,'count':len(errors)}
    qos=report['native_qos_arrival_diff_ns']
    if qos:
        ordered=sorted(qos)
        report['native_qos_arrival_diff_ms']={'median':ordered[len(ordered)//2]/1e6,
            'min':min(qos)/1e6,'max':max(qos)/1e6,'count':len(qos)}
    report['physical_alignment_measured']=False
    report['checks_passed']=(report['scheduled'] and report['mapped_buffers']>25
        and report['unmapped_buffers']==0 and report.get('rendered_buffers',0)>0
        and report.get('dropped_buffers',0)==0 and (not args.rate_ppm or 'rate_change' in report)
        and not report['errors'])
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['callback_errors_ns','native_qos_arrival_diff_ns']},indent=2))
    return 0 if report['checks_passed'] else 1

if __name__=='__main__':
    raise SystemExit(main())
