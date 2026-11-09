"""Isolated native OTP distribution over real WebRTC; no TCP distribution/EPMD.

The parent relays only SDP/ICE introductions through app-owned stdin/stdout.
Remote PIDs, RPC, binaries, links, monitors and ticks travel over the DataChannel.
"""
from pathlib import Path
import json
import os
import queue
import secrets
import shutil
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / 'builds/intermediates/OTPWebRTCProbe'
BUILD.mkdir(parents=True, exist_ok=True)
ERL = shutil.which('erl')
if not ERL and os.name == 'nt':
    ERL = str(ROOT / 'builds/intermediates/Windows/otp/bin/erl.exe')
assert ERL, 'Install the pinned OTP 29.1.2 runtime'
otp = Path(subprocess.check_output([ERL, '-noshell', '-eval',
    'io:put_chars(code:root_dir()), halt().'], text=True))
assert (otp / 'releases/29/OTP_VERSION').read_text().strip() == '29.1.2', 'Use OTP 29.1.2'
ERLEXEC = otp / 'bin/erl.exe' if os.name == 'nt' else next(otp.glob('erts-*/bin/erlexec'))
sources = sorted((ROOT / 'src/control/transport/experiments/otp_dist/src').glob('*.erl'))
sources += [ROOT / 'src/control/src' / f'{name}.erl' for name in (
    'ba_legacy_cluster_auth', 'ba_legacy_cluster_authority', 'ba_legacy_cluster_trust',
    'ba_legacy_cluster_desk', 'ba_dist_channel', 'ba_media_channel', 'ba_webrtc_dist')]
subprocess.run([str(otp / ('bin/erlc.exe' if os.name == 'nt' else 'bin/erlc')), '-Werror', '+debug_info', '-o', str(BUILD),
                *map(str, sources)], check=True)
paths = [BUILD]
transport = ROOT / ('builds/intermediates/Windows/transport/beam/dev/lib' if os.name == 'nt'
                    else 'builds/intermediates/BeamTransport/dev/lib')
paths += list(transport.glob('*/ebin'))
paths += list((ROOT / 'builds/intermediates/tools/elixir/lib').glob('*/ebin'))
assert any(p.parent.name == 'ba_transport' for p in paths), 'Compile src/control/transport first'


class Probe:
    def __init__(self, label, name, peer, cookie, entry='ba_dist_probe'):
        self.label, self.peer = label, None
        self.lines, self.replies = queue.Queue(), {}
        self.ready, self.booted, self.serial = False, None, 0
        self.log_path = BUILD / f'{label}.log'
        self.log = self.log_path.open('w')
        env = dict(os.environ, ROOTDIR=str(otp), BINDIR=str(ERLEXEC.parent), EMU='beam', PROGNAME='erl',
            BA_PROBE_NAME=name, BA_PROBE_PEER=peer, BA_PROBE_COOKIE=cookie,
            DYLD_FALLBACK_LIBRARY_PATH='/opt/homebrew/opt/openssl@3/lib')
        env.pop('ERL_FLAGS', None)
        env.pop('ERL_AFLAGS', None)
        env.pop('ERL_ZFLAGS', None)
        self.process = subprocess.Popen([str(ERLEXEC), '-noshell', '-pa', *map(str, paths),
            '-start_epmd', 'false', '-proto_dist', 'ba_webrtc',
            '-kernel', 'connect_all', 'false', 'dist_auto_connect', 'never',
            '-s', entry, 'main'], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.log, text=True, encoding='utf-8', env=env)
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            try:
                self.lines.put(json.loads(line))
            except json.JSONDecodeError:
                self.log.write(line)

    def post(self, op, **args):
        self.serial += 1
        self.process.stdin.write(json.dumps(dict(op=op, request=self.serial, **args)) + '\n')
        self.process.stdin.flush()
        return self.serial

    def request(self, op, **args):
        ref = self.post(op, **args)
        wait(lambda: ref in self.replies)
        reply = self.replies.pop(ref)
        assert 'error' not in reply, (self.label, op, reply, str(self.log_path))
        return reply['result']

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.log.close()


probes = []
introductions = True
signal_count = 0


def pump():
    global signal_count
    for probe in probes:
        while True:
            try:
                message = probe.lines.get_nowait()
            except queue.Empty:
                break
            if 'request' in message:
                probe.replies[message['request']] = message
            elif message['event'] == 'signal':
                if introductions:
                    signal_count += 1
                    probe.peer.post('signal', signal=message['signal'])
            elif message['event'] == 'ready':
                probe.ready = True
            elif message['event'] == 'booted':
                probe.booted = message
        assert probe.process.poll() is None, f'{probe.label} exited; inspect {probe.log_path}'


def wait(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pump()
        if predicate():
            return
        time.sleep(.01)
    raise AssertionError(f'Timed out; inspect logs under {BUILD}')


def run(matching_cookies):
    global introductions
    introductions = True
    suffix = secrets.token_hex(5)
    names = [f'ba_probe_{i}_{suffix}@127.0.0.1' for i in range(2)]
    cookie = secrets.token_hex(32)
    case = 'trusted' if matching_cookies else 'wrong-cookie'
    try:
        a = Probe(f'{case}-a', names[0], names[1], cookie)
        probes.append(a)
        b = Probe(f'{case}-b', names[1], names[0], cookie if matching_cookies else secrets.token_hex(32))
        probes.append(b)
        a.peer, b.peer = b, a
        wait(lambda: all(p.booted for p in probes))
        assert a.booted['os_pid'] != b.booted['os_pid']
        assert all(p.booted['otp'] == '29' and p.booted['erts'] == '17.1.1' for p in probes)
        b.request('start', initiator=False)
        a.request('start', initiator=True)
        wait(lambda: a.ready and b.ready)
        introductions = False  # No introduction service participates in the native handshake/data path.
        assert b.request('accept')
        connected = a.request('connect')
        if not matching_cookies:
            assert connected is False
            assert all(p.request('status')['connected'] is False for p in probes)
            print('PASS: OTP cookie handshake rejects a peer over an established WebRTC channel', flush=True)
            return
        assert connected is True
        for p in probes:
            result = p.request('exercise')
            assert result['binary_bytes'] == 262144 and result['ordered_messages'] == 100
            assert all(result[k] for k in ['remote_execution', 'monitor', 'link'])
            state = p.request('status')
            assert state['connected'] and state['channel']['native']
            print(f'PASS: {p.label}: remote PID/RPC/spawn; 256 KiB binary echo and SHA-256; '
                  f'100 ordered messages; remote exit monitor/link; {state["channel"]}', flush=True)
            p.request('arm_loss')
        before = [p.request('status')['channel'] for p in probes]
        deadline = time.monotonic() + 9  # More than two test net_ticktime periods; no native application traffic.
        while time.monotonic() < deadline:
            pump()
            time.sleep(.05)
        for p, previous in zip(probes, before):
            state = p.request('status')
            assert state['connected'] and state['channel']['native']
            assert state['channel']['sent'] > previous['sent']
            assert state['channel']['received'] > previous['received']
        print('PASS: native tick traffic keeps an otherwise idle WebRTC distribution connection alive', flush=True)
        for p in probes:
            p.request('blackhole')
        # Both WebRTC PCs stay alive until OTP's own tick timeout tears down distribution.
        for p in probes:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                state = p.request('status')
                if state['down'] and state['link'] and state['node_down'] and not state['connected']:
                    break
                time.sleep(.1)
            else:
                raise AssertionError((p.label, 'native disconnect events missing', state))
            assert state['down_reason'] == state['link_reason'] == 'noconnection'
            assert state['node_down_reason'] == 'net_tick_timeout'
            print(f'PASS: {p.label}: native DOWN/EXIT/nodedown after silent packet loss '
                  f'({state["node_down_reason"]})', flush=True)
    finally:
        for p in probes:
            p.close()
        probes.clear()


if __name__ == '__main__':
    run(True)
    run(False)
    print(f'PASS: native OTP 29 distribution over binary WebRTC; {signal_count} introduction messages; '
          'no TCP distribution listener, EPMD or application message router', flush=True)
