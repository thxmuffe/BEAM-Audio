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
RUNTIME = ROOT / 'builds/intermediates/gstreamer/runtime'


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
               GST_REGISTRY_1_0=str(RUNTIME.parent / 'native-stream-registry.bin'))
    proc = subprocess.Popen([str(ROOT / 'builds/CLI/ba_native_stream'), '--protocol-test'],
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
        deadline = time.monotonic() + 15
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
            if len(connected) == 2 and started is None:
                started = now
                send(1, {'op': 'play'})
            if started and now - started > 2 and not stopping:
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
                        assert event['profile'] == 'gst_aac_rtp_v1' and event['owner_loss_stop'] and event['stop_ack']
                        send(index, dict(op='prepare', role='provider' if index == 0 else 'receiver',
                                         rate=48000, channels=2, buffer_ms=800, ice_servers=[],
                                         diagnostic_unsynchronized=True, synthetic=index == 0, silent=True))
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
                            for target in range(2):
                                send(target, {'op': 'stop', 'request_id': 101 + target})
                    elif kind == 'stopped':
                        assert event['request_id'] == 101 + index
                        stopped.add(index)
            if len(stopped) == 2:
                print(json.dumps({'native_aac': 'pass', 'prepared': len(prepared),
                                  'connected': len(connected), 'decoded_frames': stats[1]['frames'],
                                  'confirmed_stops': len(stopped), 'synchronized': False}))
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
    for mode in ['control_eof', 'control_timeout', 'hung_media', 'source_owner_eof']:
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
            send(dict(op='prepare', role='receiver', rate=48000, channels=2, buffer_ms=800,
                      diagnostic_unsynchronized=True, silent=True, ice_servers=[]))
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
                proc.stdin.close()
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
