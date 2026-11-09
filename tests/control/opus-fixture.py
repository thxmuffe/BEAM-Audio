"""Test-only GStreamer encoder: sine PCM -> framed Opus, without audio hardware."""
import math
import runpy
import struct
import sys
from pathlib import Path

# Reuse runtime discovery; importing the binding does not start its decoder/I/O.
binding=Path(__file__).resolve().parents[2]/'src/Audio/adapters/gstreamer/pcm_bridge.py'
namespace=runpy.run_path(str(binding))
Gst=namespace['Gst']
pipeline=Gst.parse_launch('appsrc name=input format=time caps="audio/x-raw,format=F32LE,rate=48000,channels=2,layout=interleaved" ! audioconvert ! opusenc frame-size=20 ! appsink name=output sync=false')
source=pipeline.get_by_name('input');sink=pipeline.get_by_name('output')
pipeline.set_state(Gst.State.PLAYING)
try:
    for n in range(100):
        pcm=b''.join(struct.pack('<ff',*[.2*math.sin(2*math.pi*440*(n*960+i)/48000)]*2) for i in range(960))
        buffer=Gst.Buffer.new_allocate(None,len(pcm),None);buffer.fill(0,pcm)
        buffer.pts=n*20_000_000;buffer.duration=20_000_000
        assert source.emit('push-buffer',buffer)==Gst.FlowReturn.OK
    source.emit('end-of-stream')
    count=0
    with open(sys.argv[1],'wb') as output:
        while True:
            sample=sink.emit('try-pull-sample',5*Gst.SECOND)
            if sample is None:
                assert sink.get_property('eos');break
            buffer=sample.get_buffer()
            if buffer.has_flags(Gst.BufferFlags.HEADER):continue
            data=buffer.extract_dup(0,buffer.get_size())
            assert 0<len(data)<=1275
            output.write(struct.pack('!I',len(data))+data);count+=1
    assert count>=100,count
    print(f'Generated {count} Opus packets without hardware')
finally:pipeline.set_state(Gst.State.NULL)
