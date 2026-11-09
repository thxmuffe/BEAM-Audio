"""GStreamer RTP jitter/Opus decoder binding; no device or presentation clock policy."""
import collections
import os
from pathlib import Path
import struct
import sys
import threading

runtime = os.getenv('PARVI_GSTREAMER_RUNTIME')
if runtime:
    runtime = Path(runtime).resolve()
    sys.path.insert(0, str(runtime / f'lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages'))
    os.environ['GI_TYPELIB_PATH'] = str(runtime / 'lib/girepository-1.0')
    os.environ['GST_PLUGIN_SYSTEM_PATH_1_0'] = str(runtime.parent / 'plugins')
import gi
gi.require_version('Gst', '1.0')
gi.require_version('GstRtp', '1.0')
if runtime:
    gi.require_version('GIRepository','2.0')
    from gi.repository import GIRepository
    GIRepository.Repository.prepend_library_path(str(runtime/'lib'))
from gi.repository import Gst, GstRtp, GLib
Gst.init(None)
lock = threading.Lock()
association_lock = threading.Lock()
associations = collections.OrderedDict()


def send(data):
    with lock:
        sys.stdout.buffer.write(struct.pack('!I',len(data))+data)
        sys.stdout.buffer.flush()


def error(reason):
    send(b'\x02'+reason.encode('ascii'))


def packet(pad, info):
    buffer = info.get_buffer()
    if buffer is None or buffer.pts == Gst.CLOCK_TIME_NONE:
        return Gst.PadProbeReturn.OK
    ok, rtp = GstRtp.RTPBuffer.map(buffer, Gst.MapFlags.READ)
    if ok:
        with association_lock:
            associations[buffer.pts] = rtp.get_timestamp()
            while len(associations)>128:
                associations.popitem(last=False)
        rtp.unmap()
    return Gst.PadProbeReturn.OK


def decoded(sink):
    sample = sink.emit('pull-sample')
    buffer = sample.get_buffer()
    with association_lock:
        timestamp = associations.pop(buffer.pts,None)
    if timestamp is None or buffer.has_flags(Gst.BufferFlags.GAP):
        error('decoded_packet_target_missing')
        return Gst.FlowReturn.OK
    data = buffer.extract_dup(0, buffer.get_size())
    if not data or len(data)%8 or len(data)>32768:
        error('unsupported_decoded_block')
    else:
        send(b'\x01'+struct.pack('!II',timestamp,len(data)//8)+data)
    return Gst.FlowReturn.OK


def bus_message(bus, message):
    if message.type == Gst.MessageType.ERROR:
        error('native_decoder_failed')
        loop.quit()


def read_exact(count):
    parts=[]
    while count:
        part=sys.stdin.buffer.read(count)
        if not part:return None
        parts.append(part);count-=len(part)
    return b''.join(parts)


def input_loop():
    try:
        while True:
            header=read_exact(4)
            if header is None:break
            size=struct.unpack('!I',header)[0]
            if not 12<=size<=16384:break
            data=read_exact(size)
            if data is None:break
            if source.get_property('current-level-buffers')>=64:
                error('native_input_overloaded');continue
            buffer=Gst.Buffer.new_allocate(None,len(data),None);buffer.fill(0,data)
            if source.emit('push-buffer',buffer)!=Gst.FlowReturn.OK:break
    finally:
        GLib.idle_add(loop.quit)


def main():
    global source,loop
    pipeline = Gst.parse_launch(
        'appsrc name=input is-live=true format=time do-timestamp=true block=false max-buffers=64 '
        'caps="application/x-rtp,media=audio,clock-rate=48000,encoding-name=OPUS,payload=111" ! '
        'rtpjitterbuffer latency=20 do-lost=true ! rtpopusdepay name=depay ! opusdec name=decoder plc=true ! '
        'audioconvert ! audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved ! '
        'appsink name=output emit-signals=true sync=false async=false max-buffers=32 drop=true enable-last-sample=false')
    source = pipeline.get_by_name('input')
    pipeline.get_by_name('depay').get_static_pad('sink').add_probe(Gst.PadProbeType.BUFFER,packet)
    pipeline.get_by_name('output').connect('new-sample',decoded)
    loop = GLib.MainLoop()
    bus = pipeline.get_bus();bus.add_signal_watch();bus.connect('message',bus_message)
    pipeline.set_state(Gst.State.PLAYING)
    threading.Thread(target=input_loop,daemon=True).start()
    send(b'\x03')
    try:loop.run()
    finally:pipeline.set_state(Gst.State.NULL)


if __name__=='__main__':main()
