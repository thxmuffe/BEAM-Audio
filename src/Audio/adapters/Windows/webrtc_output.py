"""Native GStreamer WebRTC/Opus output, controlled by the shared Erlang session.

No cluster networking, admission, peer selection or shared-clock policy lives here.
The loopback socket speaks the same packet-4 JSON protocol as the iOS binding.
"""
import json
import os
import socket
import struct
import sys
import threading
import time

import gstreamer_libs
gstreamer_libs.setup_python_environment()
_dll_handles = [os.add_dll_directory(p) for p in os.environ.get('PYGI_DLL_DIRS', '').split(os.pathsep) if os.path.isdir(p)]
import gi
gi.require_version('Gst', '1.0')
gi.require_version('GstWebRTC', '1.0')
gi.require_version('GstSdp', '1.0')
from gi.repository import GLib, Gst, GstSdp, GstWebRTC

Gst.init(None)


class Session:
    def __init__(self, connection):
        self.socket = connection
        self.write_lock = threading.Lock()
        self.pipeline = None
        self.pc = None
        self.playing = False
        self.remote_ready = False
        self.pending_candidates = []
        self.buffers = 0
        self.frames = 0
        self.minimum_delay = None
        self.closed = False

    def send(self, value):
        packet = json.dumps(value, separators=(',', ':')).encode('utf-8')
        with self.write_lock:
            if not self.closed:
                try:
                    self.socket.sendall(struct.pack('!I', len(packet)) + packet)
                except OSError:
                    pass

    def fail(self, message):
        self.send({'event': 'error', 'error': message})

    def start(self, command):
        self.pipeline = Gst.parse_launch(
            'webrtcbin name=peer bundle-policy=max-bundle latency=200 '
            'queue name=audio_queue ! rtpopusdepay ! opusdec plc=true ! audioconvert ! audioresample ! '
            'audio/x-raw,format=F32LE,rate=48000,channels=2 ! volume name=volume mute=true ! '
            'wasapisink name=output sync=true')
        self.pc = self.pipeline.get_by_name('peer')
        servers = command.get('ice_servers', [])
        for server in servers:
            urls = server.get('urls', []) if isinstance(server, dict) else []
            if isinstance(urls, str):
                urls = [urls]
            for url in urls:
                if url.startswith('stun:'):
                    self.pc.set_property('stun-server', 'stun://' + url.removeprefix('stun:').removeprefix('//'))
                    break
        self.pc.connect('on-ice-candidate', lambda _, index, candidate: self.send({
            'event': 'candidate', 'candidate': {'candidate': candidate, 'sdpMLineIndex': index, 'sdpMid': 'audio0'}}))
        self.pc.connect('pad-added', self.pad_added)
        self.pc.connect('notify::connection-state', self.connection_state)
        bus = self.pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect('message::error', lambda _, message: self.fail(str(message.parse_error()[0])))
        caps = Gst.Caps.from_string('application/x-rtp,media=audio,encoding-name=OPUS,clock-rate=48000,encoding-params=(string)2,payload=111,stereo=(string)1,sprop-stereo=(string)1,useinbandfec=(string)1')
        self.pc.emit('add-transceiver', GstWebRTC.WebRTCRTPTransceiverDirection.RECVONLY, caps)
        self.pipeline.set_state(Gst.State.PLAYING)
        promise = Gst.Promise.new_with_change_func(self.offer_created, None, None)
        self.pc.emit('create-offer', None, promise)

    def offer_created(self, promise, *_):
        if self.closed:
            return
        reply = promise.get_reply()
        offer = reply.get_value('offer') if reply else None
        if offer is None:
            self.fail('Cannot create WebRTC audio offer')
            return
        self.pc.emit('set-local-description', offer, None)
        self.send({'event': 'offer', 'sdp': offer.sdp.as_text()})

    def pad_added(self, _, pad):
        if pad.get_direction() != Gst.PadDirection.SRC:
            return
        sink = self.pipeline.get_by_name('audio_queue').get_static_pad('sink')
        if not sink.is_linked():
            if pad.link(sink) != Gst.PadLinkReturn.OK:
                self.fail('Cannot link received Opus audio')
        output = self.pipeline.get_by_name('volume').get_static_pad('sink')
        output.add_probe(Gst.PadProbeType.BUFFER, self.count_frames)

    def count_frames(self, _, info):
        buffer = info.get_buffer()
        if buffer:
            self.buffers += 1
            self.frames += buffer.get_size() // 8
        return Gst.PadProbeReturn.OK

    def connection_state(self, *_):
        state = self.pc.get_property('connection-state')
        if state == GstWebRTC.WebRTCPeerConnectionState.CONNECTED:
            self.send({'event': 'connected'})
        elif state == GstWebRTC.WebRTCPeerConnectionState.FAILED:
            self.fail('WebRTC audio connection failed')

    def answer_applied(self, promise, *_):
        GLib.idle_add(self.flush_candidates)

    def flush_candidates(self):
        if self.closed:
            return False
        self.remote_ready = True
        for index, value in self.pending_candidates:
            self.pc.emit('add-ice-candidate', index, value)
        self.pending_candidates.clear()
        return False

    def handle(self, command):
        if self.closed:
            return False
        try:
            op = command['op']
            if op == 'prepare':
                self.start(command)
            elif op == 'answer':
                result, sdp = GstSdp.SDPMessage.new_from_text(command['sdp'])
                if result != GstSdp.SDPResult.OK:
                    raise ValueError('Invalid SDP answer')
                description = GstWebRTC.WebRTCSessionDescription.new(GstWebRTC.WebRTCSDPType.ANSWER, sdp)
                self.pc.emit('set-remote-description', description, Gst.Promise.new_with_change_func(self.answer_applied, None, None))
            elif op == 'candidate':
                c = command['candidate']
                if self.remote_ready:
                    self.pc.emit('add-ice-candidate', int(c.get('sdpMLineIndex', 0)), c['candidate'])
                else:
                    self.pending_candidates.append((int(c.get('sdpMLineIndex', 0)), c['candidate']))
            elif op in ('play', 'pause'):
                self.playing = op == 'play'
                self.pipeline.get_by_name('volume').set_property('mute', not self.playing)
                self.send({'event': 'playing' if self.playing else 'paused'})
            elif op == 'minimum_delay':
                value = command.get('delay_ms')
                configured = value is None or (isinstance(value, (int, float)) and not isinstance(value, bool) and 0 <= value <= 10000)
                if configured:
                    self.pc.set_property('latency', 200 if value is None else round(value))
                    self.minimum_delay = value
                self.send({'event': 'minimum_delay', 'request_id': command.get('request_id'),
                           'configured': configured, 'requested_ms': value})
            elif op == 'clock':
                self.send({'event': 'clock', 'sent_ns': command['sent_ns'], 'host_ns': time.perf_counter_ns()})
            elif op == 'stats':
                self.pc.emit('get-stats', None, Gst.Promise.new_with_change_func(self.statistics, None, None))
        except Exception as error:
            self.fail(str(error))
        return False

    def statistics(self, promise, *_):
        reply = promise.get_reply()
        summary = {'event': 'stats', 'backend': 'gstreamer_webrtc', 'outputTrackEnabled': self.playing,
                   'outputSourceSampleMappingAvailable': False, 'estimatedPlayoutTimestampAvailable': False,
                   'decodedFrames': self.frames, 'decodedBuffers': self.buffers, 'totalSamplesReceived': self.frames,
                   'minimumDelayControlAvailable': True, 'requestedMinimumDelayMs': self.minimum_delay}
        if self.pipeline:
            output = self.pipeline.get_by_name('output').get_property('stats')
            summary['outputRenderedBuffers'] = output.get_value('rendered')
            summary['outputDroppedBuffers'] = output.get_value('dropped')
        keys = {'packets-received': 'packetsReceived', 'bytes-received': 'bytesReceived',
                'packets-lost': 'packetsLost', 'jitter': 'jitter'}
        if reply:
            for index in range(reply.n_fields()):
                row = reply.get_value(reply.nth_field_name(index))
                if isinstance(row, Gst.Structure) and row.has_field('type') and row.get_value('type') == GstWebRTC.WebRTCStatsType.INBOUND_RTP:
                    for native, common in keys.items():
                        if row.has_field(native):
                            summary[common] = row.get_value(native)
        self.send(summary)

    def close(self):
        self.closed = True
        if self.pipeline:
            self.pipeline.set_state(Gst.State.NULL)
            self.pipeline.get_bus().remove_signal_watch()
            self.pc = None
            self.pipeline = None
        self.socket.close()
        return False

    def serve(self):
        def read(size):
            result = b''
            while len(result) < size:
                chunk = self.socket.recv(size - len(result))
                if not chunk:
                    raise EOFError()
                result += chunk
            return result
        try:
            while True:
                size, = struct.unpack('!I', read(4))
                if not 0 < size <= 131072:
                    raise ValueError('Invalid local command size')
                GLib.idle_add(self.handle, json.loads(read(size)))
        except (EOFError, OSError, ValueError):
            GLib.idle_add(self.close)


def main():
    if '--check' in sys.argv:
        for name in ['webrtcbin', 'opusdec', 'rtpopusdepay', 'wasapisink', 'volume']:
            if not Gst.ElementFactory.find(name):
                raise RuntimeError('Missing GStreamer element: ' + name)
        print('Windows WebRTC/Opus output dependencies available')
        return
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    print(json.dumps({'port': listener.getsockname()[1]}), flush=True)
    def accept():
        while True:
            connection, _ = listener.accept()
            threading.Thread(target=Session(connection).serve, daemon=True).start()
    threading.Thread(target=accept, daemon=True).start()
    # The owning Erlang port holds stdin. EOF shuts down this helper only.
    loop = GLib.MainLoop()
    def watch_owner():
        sys.stdin.buffer.read()
        GLib.idle_add(loop.quit)
    threading.Thread(target=watch_owner, daemon=True).start()
    loop.run()


if __name__ == '__main__':
    main()
