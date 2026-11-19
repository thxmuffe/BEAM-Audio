#!/usr/bin/env python3
"""Disposable native AAC/WebRTC endpoints; silent synthetic audio, no live Devices."""
import json
import os
from pathlib import Path
import selectors
import socket
import struct
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
# The same variables the apps use, so a packaged bundle can be checked too.
RUNTIME = Path(os.environ.get('BA_GSTREAMER_RUNTIME', ROOT / 'builds/intermediates/gstreamer/runtime'))
HELPER = Path(os.environ.get('BA_MAC_NATIVE_STREAM_HELPER', ROOT / 'builds/CLI/ba_native_stream'))


def frame(value):
    raw = json.dumps(value, separators=(',', ':')).encode()
    return struct.pack('!I', len(raw)) + raw


def read_file(stream, count):
    data = stream.read(count)
    if len(data) != count:
        raise RuntimeError('native helper ended before publishing its endpoint')
    return data


def start_host():
    env = dict(os.environ)
    env.update(DYLD_LIBRARY_PATH=str(RUNTIME / 'lib'),
               GST_PLUGIN_SYSTEM_PATH_1_0=str(RUNTIME.parent / 'plugins'),
               GST_REGISTRY_1_0=str(ROOT / 'builds/intermediates/gstreamer/smoke-registry.bin'),
               GST_REGISTRY_FORK='no')
    proc = subprocess.Popen([str(HELPER), '--protocol-test'],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    size, = struct.unpack('!I', read_file(proc.stdout, 4))
    packet = read_file(proc.stdout, size)
    assert len(packet) == 3 and packet[0] == 9, packet
    port, = struct.unpack('!H', packet[1:])
    stop = threading.Event()

    def renew():
        while not stop.wait(.2):
            try:
                proc.stdin.write(b'\0\0\0\1h')
                proc.stdin.flush()
            except (OSError, ValueError):
                break

    thread = threading.Thread(target=renew, daemon=True)
    thread.start()
    return proc, port, stop, thread


def clock_map(event, revision, reference):
    received = time.perf_counter_ns()
    target = reference + (int(event['sent_ns']) + received) // 2
    error = 0 if event['session_ns'] is None else target - int(event['session_ns'])
    return dict(op='clock_map', revision=revision, internal_ns=event['internal_ns'],
                session_ns=str(target), timeline='native-test-clock',
                correction_ppm=max(-500, min(500, error / 5000)), max_absolute_ppm=500)


def main():
    hosts = []
    sockets = []
    selector = selectors.DefaultSelector()
    try:
        for index in range(2):
            proc, port, stop, thread = start_host()
            hosts.append((proc, stop, thread))
            peer = socket.create_connection(('127.0.0.1', port), timeout=2)
            peer.setblocking(False)
            sockets.append(peer)
            selector.register(peer, selectors.EVENT_READ, index)
        generations = ['a' * 32, 'b' * 32]
        buffers = [bytearray(), bytearray()]
        prepared, connected = set(), set()
        stats = {}

        def send(index, command):
            sockets[index].sendall(frame(dict(command, generation=generations[index])))

        for index in range(2):
            send(index, {'op': 'hello', 'version': 2})
        # Deliberately different from OS UTC: scheduled output must use this reference.
        reference = time.time_ns() - time.perf_counter_ns() + 3 * 3600 * 1_000_000_000
        revisions = [0, 0]
        preparing = set()
        last_clock = time.monotonic()
        deadline = time.monotonic() + 18
        last_heartbeat = 0
        started = None
        stopping = False
        stopped = set()
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now - last_heartbeat > .2:
                for index in range(2):
                    if index not in stopped:
                        send(index, {'op': 'heartbeat'})
                last_heartbeat = now
            if now - last_clock > 5:
                for index in range(2):
                    send(index, {'op': 'clock', 'sent_ns': str(time.perf_counter_ns())})
                last_clock = now
            if len(connected) == 2 and started is None:
                started = now
                send(1, {'op': 'play'})
            if started and now - started > 6.2 and not stopping:
                for index in range(2):
                    send(index, {'op': 'stats'})
                stopping = True
            for key, _ in selector.select(.1):
                index = key.data
                chunk = key.fileobj.recv(65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    assert index in stopped, ('unexpected native close', index)
                    continue
                buffers[index].extend(chunk)
                while len(buffers[index]) >= 4:
                    size, = struct.unpack('!I', buffers[index][:4])
                    if len(buffers[index]) < size + 4:
                        break
                    event = json.loads(buffers[index][4:size + 4])
                    del buffers[index][:size + 4]
                    kind = event['event']
                    assert event['generation'] == generations[index]
                    assert kind != 'error', event
                    if kind == 'hello':
                        assert event['profile'] == 'gst_aac_rtp_v2' and event['owner_loss_stop'] and event['stop_ack']
                        assert event['schedule']
                        send(index, {'op': 'clock', 'sent_ns': str(time.perf_counter_ns())})
                    elif kind == 'clock':
                        revisions[index] += 1
                        send(index, clock_map(event, revisions[index], reference))
                        if index in preparing:
                            continue
                        preparing.add(index)
                        send(index, dict(op='prepare', role='provider' if index == 0 else 'receiver',
                                         rate=48000, channels=2, buffer_ms=800, ice_servers=[],
                                         synthetic=index == 0, silent=True))
                    elif kind == 'prepared':
                        prepared.add(index)
                    elif kind in ('offer', 'answer'):
                        assert 'MPEG4-GENERIC' in event['sdp'], event
                        send(1-index, {'op': kind, 'sdp': event['sdp']})
                    elif kind == 'candidate':
                        send(1-index, {k: v for k, v in event.items() if k in ('candidate', 'mid', 'line')} | {'op': 'candidate'})
                    elif kind == 'connected':
                        connected.add(index)
                    elif kind == 'stats':
                        stats[index] = event
                        if len(stats) == 2:
                            assert stats[1]['frames'] > 0, stats
                            assert stats[1]['rtcp_mapped_packets'] > 0 and stats[0]['sender_reports'] > 0, stats
                            assert stats[1]['clock_updates'] >= 2 and stats[1]['rendered_frames'] > 0, stats
                            assert stats[1]['mapping_acquired_ms'] < 1500, stats
                            # A device needs audio before its presentation time.
                            # The fake sink simulates 200 ms of output latency;
                            # RTP buffering must leave room for it in the 800 ms budget.
                            assert int(stats[1]['render_delay_ns']) == 200_000_000, stats
                            assert stats[1]['jitter_buffer_ms'] <= 600, stats
                            assert stats[1]['sink_rendered_buffers'] > 0, stats
                            assert int(stats[1]['max_schedule_error_ns']) < 50_000_000, stats
                            for target in range(2):
                                send(target, {'op': 'stop', 'request_id': 101 + target})
                    elif kind == 'stopped':
                        assert event['request_id'] == 101 + index
                        stopped.add(index)
            if len(stopped) == 2:
                print(json.dumps({'native_aac': 'pass', 'prepared': len(prepared),
                                  'connected': len(connected), 'decoded_frames': stats[1]['frames'],
                                  'confirmed_stops': len(stopped), 'synchronized': False,
                                  'rtcp_mapped_packets': stats[1]['rtcp_mapped_packets'],
                                  'clock_updates': stats[1]['clock_updates'],
                                  'mapping_acquired_ms': stats[1]['mapping_acquired_ms'],
                                  'sender_reports': stats[0]['sender_reports'],
                                  'max_schedule_error_ns': stats[1]['max_schedule_error_ns'],
                                  'simulated_output_latency_ms': 200,
                                  'jitter_buffer_ms': stats[1]['jitter_buffer_ms']}))
                return
        raise AssertionError(('native stream timed out', prepared, connected, stats))
    finally:
        for peer in sockets:
            peer.close()
        selector.close()
        for proc, stop, thread in hosts:
            stop.set()
            thread.join(timeout=1)
            proc.stdin.close()
            try:
                proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            error = proc.stderr.read().decode(errors='replace')
            if error:
                print(error[-5000:])


def lifecycle():
    results = []
    for mode in ['control_eof', 'control_timeout', 'clock_expiry', 'hung_media', 'source_owner_eof']:
        proc, port, stop, thread = start_host()
        peer = socket.create_connection(('127.0.0.1', port), timeout=2)
        generation = 'c' * 32

        def send(command):
            peer.sendall(frame(dict(command, generation=generation)))

        def event():
            header = b''
            while len(header) < 4:
                part = peer.recv(4 - len(header))
                if not part:
                    return None
                header += part
            size, = struct.unpack('!I', header)
            body = b''
            while len(body) < size:
                body += peer.recv(size - len(body))
            return json.loads(body)

        try:
            send({'op': 'hello', 'version': 2})
            assert event()['event'] == 'hello'
            send({'op': 'clock', 'sent_ns': str(time.perf_counter_ns())})
            observation = event()
            send(clock_map(observation, 1, time.time_ns() - time.perf_counter_ns()))
            assert event()['event'] == 'clock_mapped'
            send(dict(op='prepare', role='receiver', rate=48000, channels=2, buffer_ms=800,
                      silent=True, ice_servers=[]))
            assert event()['event'] == 'prepared'
            started = time.monotonic()
            if mode == 'control_eof':
                peer.close()
                # The host stays available for a fresh, separately owned stream.
                time.sleep(.2)
                assert proc.poll() is None
            elif mode == 'control_timeout':
                peer.settimeout(4)
                assert event() is None
                assert time.monotonic() - started < 3.8 and proc.poll() is None
            elif mode == 'clock_expiry':
                # Control remains alive; an expired Session mapping still ends media.
                peer.settimeout(.2)
                while time.monotonic() - started < 13:
                    send({'op': 'heartbeat'})
                    try:
                        assert event() is None
                        break
                    except socket.timeout:
                        continue
                else:
                    raise AssertionError('stream survived an expired Session mapping')
                assert 11 < time.monotonic() - started < 13 and proc.poll() is None
            elif mode == 'hung_media':
                send({'op': 'test_block_media'})
                time.sleep(.1)
                peer.close()
                assert proc.wait(timeout=3) == 70
                assert time.monotonic() - started < 2.5
            else:
                stop.set()
                thread.join(timeout=1)
                proc.stdin.close()
                assert proc.wait(timeout=2) == 70
            results.append(mode)
        finally:
            peer.close()
            stop.set()
            thread.join(timeout=1)
            if not proc.stdin.closed:
                try:
                    proc.stdin.close()
                except BrokenPipeError:
                    pass  # the helper already exited; that is what some checks provoke
            try:
                proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            error = proc.stderr.read().decode(errors='replace')
            if error:
                print(error[-3000:])
    print(json.dumps({'native_lifetime': 'pass', 'checks': results}))


if __name__ == '__main__':
    main()
    lifecycle()
