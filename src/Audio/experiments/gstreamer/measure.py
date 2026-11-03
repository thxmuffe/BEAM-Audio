#!/usr/bin/env python3
"""Finite local media measurements using the runtime's PyGObject bindings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", choices=("clean", "playback", "reorder", "loss", "late"))
    parser.add_argument("--runtime", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=("l16", "float32"), default="l16")
    args = parser.parse_args()
    runtime = args.runtime.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    output = args.output.resolve()
    # The official macOS 1.28.8 package supplies CPython 3.9 bindings.
    if sys.version_info[:2] != (3, 9):
        parser.error("use /usr/bin/python3 (3.9) with the macOS runtime bindings")
    sys.path.insert(0, str(runtime / "lib/python3.9/site-packages"))
    os.environ["GI_TYPELIB_PATH"] = str(runtime / "lib/girepository-1.0")
    os.environ["GST_PLUGIN_SYSTEM_PATH_1_0"] = str(runtime.parent / "plugins")
    os.environ["GST_REGISTRY_1_0"] = str(runtime.parent / "l16-registry.bin")
    import gi
    gi.require_version("GIRepository", "2.0")
    from gi.repository import GIRepository
    GIRepository.Repository.prepend_library_path(str(runtime / "lib"))
    gi.require_version("Gst", "1.0")
    gi.require_version("GstRtp", "1.0")
    from gi.repository import GLib, Gst, GstRtp
    Gst.init(None)

    profiles = {
        "clean": "",
        "playback": "",
        "reorder": "delay-probability=0.5 min-delay=10 max-delay=40 allow-reordering=true",
        "loss": "drop-probability=0.01",
        "late": "delay-probability=0.1 min-delay=180 max-delay=220 allow-reordering=true",
    }
    simulation = profiles[args.case]
    floating = args.profile == "float32"
    sample_format = "f32le" if floating else "s16be"
    payloader = "rtpgstpay config-interval=1" if floating else "rtpL16pay"
    split = "audiobuffersplit output-buffer-duration=1/200 ! " if floating else ""
    depayloader = "rtpgstdepay" if floating else "rtpL16depay"
    rtp_caps = ("application/x-rtp,media=application,clock-rate=90000,encoding-name=X-GST,payload=96"
                if floating else "application/x-rtp,media=audio,clock-rate=48000,encoding-name=L16,"
                "encoding-params=(string)2,channels=2,payload=96")
    network = f"netsim name=network {simulation} ! " if simulation else ""
    sink = ("queue max-size-time=100000000 max-size-buffers=0 max-size-bytes=0 ! "
            "audioconvert ! audioresample ! osxaudiosink name=output"
            if args.case == "playback" else
            f"filesink name=output location={json.dumps(str(output / 'received.raw'))} sync=false")
    rx = Gst.parse_launch(
        'udpsrc name=input address=127.0.0.1 port=5004 '
        f'caps="{rtp_caps}" ! ' + network +
        'rtpjitterbuffer name=jitter latency=100 drop-on-latency=true do-lost=true '
        f'post-drop-messages=true drop-messages-interval=0 ! {depayloader} name=depay ! ' + sink)
    tx = Gst.parse_launch(
        f"filesrc location={json.dumps(str(args.source.resolve()))} blocksize=960 ! "
        f'rawaudioparse use-sink-caps=false format=pcm pcm-format={sample_format} '
        f'sample-rate=48000 num-channels=2 ! {split}{payloader} name=pay pt=96 mtu=1200 '
        'seqnum-offset=0 timestamp-offset=0 ssrc=1 ! '
        'udpsink host=127.0.0.1 port=5004 sync=true async=false')
    loop = GLib.MainLoop()
    packets = {"sent": [], "arrived": [], "after_simulation": []}
    errors, warnings, qos, drops = [], [], [], []
    drop_counts = {"too_late": 0, "latency": 0}
    payload = {"bytes": 0, "buffers": 0}
    completed = {"sender_eos": False, "receiver_eos": False}

    def observe(label):
        def probe(_pad, info):
            if info.type & Gst.PadProbeType.BUFFER_LIST:
                buffers = info.get_buffer_list()
                items = [buffers.get(i) for i in range(buffers.length())]
            else:
                items = [info.get_buffer()]
            for buffer in items:
                ok, packet = GstRtp.RTPBuffer.map(buffer, Gst.MapFlags.READ)
                if ok:
                    packets[label].append(packet.get_seq())
                    packet.unmap()
            return Gst.PadProbeReturn.OK
        return probe

    tx.get_by_name("pay").get_static_pad("src").add_probe(
        Gst.PadProbeType.BUFFER | Gst.PadProbeType.BUFFER_LIST, observe("sent"))
    rx.get_by_name("input").get_static_pad("src").add_probe(Gst.PadProbeType.BUFFER, observe("arrived"))
    if simulation:
        rx.get_by_name("network").get_static_pad("src").add_probe(
            Gst.PadProbeType.BUFFER, observe("after_simulation"))

    def count_payload(_pad, info):
        payload["bytes"] += info.get_buffer().get_size()
        payload["buffers"] += 1
        return Gst.PadProbeReturn.OK

    rx.get_by_name("depay").get_static_pad("src").add_probe(
        Gst.PadProbeType.BUFFER, count_payload)

    def fields(structure):
        return {structure.nth_field_name(i): structure.get_value(structure.nth_field_name(i))
                for i in range(structure.n_fields())}

    def drain():
        rx.send_event(Gst.Event.new_eos())
        return GLib.SOURCE_REMOVE

    def message(_bus, msg, label):
        if msg.type == Gst.MessageType.ERROR:
            error, detail = msg.parse_error()
            errors.append({"pipeline": label, "error": str(error), "detail": detail})
            loop.quit()
        elif msg.type == Gst.MessageType.WARNING:
            warning, detail = msg.parse_warning()
            warnings.append({"pipeline": label, "warning": str(warning), "detail": detail})
        elif msg.type == Gst.MessageType.QOS:
            qos.append(msg.get_structure().to_string())
        elif msg.type == Gst.MessageType.ELEMENT:
            structure = msg.get_structure()
            if structure and structure.get_name() == "drop-msg":
                values = fields(structure)
                drop_counts["too_late"] += values["num-too-late"]
                drop_counts["latency"] += values["num-drop-on-latency"]
                if len(drops) < 5:
                    drops.append(values)
        elif msg.type == Gst.MessageType.EOS:
            completed[label + "_eos"] = True
            if label == "sender":
                GLib.timeout_add(1000, drain)
            else:
                loop.quit()

    for pipeline, label in ((rx, "receiver"), (tx, "sender")):
        bus = pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect("message", message, label)
    started = time.monotonic()
    usage = resource.getrusage(resource.RUSAGE_SELF)
    rx.set_state(Gst.State.PLAYING)

    def start_sender():
        tx.set_state(Gst.State.PLAYING)
        return GLib.SOURCE_REMOVE

    def timeout():
        errors.append({"error": "measurement exceeded fixture duration plus 10 seconds"})
        loop.quit()
        return GLib.SOURCE_REMOVE

    seconds = args.source.stat().st_size / (48000 * (8 if floating else 4))
    GLib.timeout_add(250, start_sender)
    GLib.timeout_add(int((seconds + 10) * 1000), timeout)
    try:
        loop.run()
        jitter_stats = fields(rx.get_by_name("jitter").get_property("stats"))
        device = rx.get_by_name("output")
        sink_stats = fields(device.get_property("stats"))
        device_id = device.get_property("unique-id") if args.case == "playback" else None
        caps = device.get_static_pad("sink").get_current_caps()
        sink_caps = caps.to_string() if caps else None
    finally:
        tx.set_state(Gst.State.NULL)
        rx.set_state(Gst.State.NULL)
    after = packets["after_simulation"] if simulation else packets["arrived"]
    high, reordered = -1, 0
    for seq in after:
        if seq < high:
            reordered += 1
        high = max(high, seq)
    final_usage = resource.getrusage(resource.RUSAGE_SELF)
    source = args.source.read_bytes()
    received = (output / "received.raw").read_bytes() if args.case != "playback" else None
    result = {
        "case": args.case, "profile": args.profile,
        "gstreamer": Gst.version_string(), "transport": "loopback UDP",
        "simulation": simulation, "fixture_seconds": seconds, "jitter_latency_ms": 100,
        "elapsed_seconds": round(time.monotonic() - started, 3), **completed,
        "packets_sent": len(packets["sent"]), "packets_arrived": len(packets["arrived"]),
        "packets_after_simulation": len(after), "out_of_order_arrivals": reordered,
        "packets_removed_by_simulation": len(set(packets["arrived"]) - set(after)),
        "depayloaded_bytes": payload["bytes"], "depayloaded_buffers": payload["buffers"],
        "jitter_stats": jitter_stats, "sink_stats": sink_stats, "device_id": device_id,
        "sink_caps": sink_caps, "source_bytes": len(source),
        "received_bytes": len(received) if received is not None else None,
        "received_sha256": hashlib.sha256(received).hexdigest() if received is not None else None,
        "identical": source == received if received is not None else None,
        "cpu_seconds": round(final_usage.ru_utime + final_usage.ru_stime - usage.ru_utime - usage.ru_stime, 3),
        "process_peak_rss_bytes": final_usage.ru_maxrss,
        "warnings": warnings, "errors": errors, "qos_messages": qos,
        "drop_counts": drop_counts, "drop_examples": drops,
        "hardware_underruns": None, "acoustic_alignment": None,
    }
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 1 if errors or not all(completed.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
