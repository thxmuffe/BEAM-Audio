#!/usr/bin/env python3
"""Isolated fixed-format RTP experiment; never selects an application backend."""
import argparse
import math
from pathlib import Path
import shutil
import struct
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("fixture", "send", "receive", "record"))
    parser.add_argument("--file", type=Path, help="fixture input or raw recording output")
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--host", default="127.0.0.1", help="destination or bind address")
    parser.add_argument("--port", type=int, default=5004)
    args = parser.parse_args()
    if args.mode in ("fixture", "send", "record") and args.file is None:
        parser.error("this mode requires --file")
    if args.mode == "fixture":
        if args.seconds <= 0:
            parser.error("--seconds must be positive")
        args.file.parent.mkdir(parents=True, exist_ok=True)
        # Quiet, distinct channels. Native S16BE samples, no float capture conversion.
        with args.file.open("wb") as output:
            for frame in range(args.seconds * 48000):
                output.write(struct.pack(">hh", *(
                    round(1000 * math.sin(2 * math.pi * hz * frame / 48000))
                    for hz in (440, 660))))
        print(f"{args.file}: {args.seconds * 48000} stereo frames, S16BE, 48000 Hz")
        return
    gst = shutil.which("gst-launch-1.0")
    if not gst:
        parser.error("gst-launch-1.0 is missing; see README.md for runtime setup")
    if args.mode == "send":
        pipeline = [
            "filesrc", f"location={args.file.resolve()}", "blocksize=960", "!",
            "rawaudioparse", "use-sink-caps=false", "format=pcm", "pcm-format=s16be",
            "sample-rate=48000", "num-channels=2", "!",
            "rtpL16pay", "pt=96", "mtu=1200", "!",
            "udpsink", f"host={args.host}", f"port={args.port}", "sync=true", "async=false",
        ]
    else:
        pipeline = [
            "udpsrc", f"address={args.host}", f"port={args.port}",
            "caps=application/x-rtp,media=audio,clock-rate=48000,encoding-name=L16,"
            "encoding-params=(string)2,channels=2,payload=96", "!",
            "rtpjitterbuffer", "latency=100", "drop-on-latency=true", "do-lost=true",
            "post-drop-messages=true", "!", "rtpL16depay", "!",
        ]
        if args.mode == "record":
            pipeline += ["filesink", f"location={args.file.resolve()}", "sync=false"]
        else:
            # Separate blocking device writes from the jitterbuffer's delivery thread.
            # Conversion is confined to the device boundary, after RTP depayloading.
            pipeline += [
                "queue", "max-size-time=100000000", "max-size-buffers=0", "max-size-bytes=0", "!",
                "audioconvert", "!", "audioresample", "!", "autoaudiosink",
            ]
    # No shell: file paths and addresses are passed as literal arguments.
    try:
        result = subprocess.call([gst, "-e", "-m", "-v", *pipeline])
    except KeyboardInterrupt:
        # Terminal Ctrl-C also reaches gst-launch, whose -e drains with EOS.
        return
    raise SystemExit(result)


if __name__ == "__main__":
    main()
