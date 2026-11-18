#!/usr/bin/env python3
"""First authenticated sample permits playback before the production filter fills."""
import importlib.util
from pathlib import Path
import shutil
import socket
import subprocess
import time

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('startup_control', HERE / 'automatic-response-time-smoke.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


def main():
    root = helper.control.ROOT
    out = root / 'builds/intermediates/buffee-control-check'
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(out), str(HERE / 'ba_buffee_control_probe.erl')], check=True)
    paths = [out, *(root / 'builds/intermediates/control/default/lib').glob('*/ebin')]
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    desk, devices = helper.relay.start_desk(port), []
    try:
        a, b = helper.control.Runtime(paths), helper.control.Runtime(paths)
        devices.extend([a, b])
        for device in devices:
            assert device.request('clock_prepare', interval_ms=5000, samples=20)['ok']
        url = f'ws://127.0.0.1:{port}/relay/v1'
        assert a.request('create', desks=[url])['ok']
        helper.control.wait(a, lambda s: all(d['connected'] for d in s['relay']['desks'].values()))
        assert b.request('join', invitation=a.request('invite')['value'], desk=url)['ok']
        helper.control.wait(b, lambda s: s['membership']['state'] == 'authorized')
        started = time.monotonic()
        assert a.request('grant', peer=b.identity['id'], permissions=['time_read'])['ok']
        until = started + 15
        while time.monotonic() < until:
            state = b.request('clock_snapshot')
            if state['state'] == 'synchronized' and state['offset_policy']['ready']:
                break
            time.sleep(.05)
        else:
            raise AssertionError('Raw clock was not available: ' + str(state))
        assert state['sample_interval_ms'] == 5000 and state['filter_required_samples'] == 20
        assert 1 <= state['filter_sample_count'] < 20 and not state['filter_ready'], state
        assert state['estimate_quality'] == 'provisional'
        assert isinstance(state['raw_offset_ns'], str) and isinstance(state['filtered_utc_time'], int)
        assert state['master_clock']['state'] == 'fresh'
        print(f'PASS: production 5s/20-sample filter remains warming while an authenticated raw mapping is usable after {time.monotonic()-started:.2f}s; raw offset and master time remain visible')
    finally:
        for device in devices:
            device.close()
        desk.terminate()
        desk.wait(timeout=5)


if __name__ == '__main__':
    main()
