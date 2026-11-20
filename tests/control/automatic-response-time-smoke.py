#!/usr/bin/env python3
"""Signed minimum-time requests from an ordinary Device; no audio hardware."""
import importlib.util
from pathlib import Path
import shutil
import socket
import subprocess
import time

HERE = Path(__file__).resolve().parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


control = load('automatic_control', HERE / 'session-control-smoke.py')
relay = load('automatic_relay', HERE.parent / 'ReceptionDesk/local_reception.py')
relay.ERL = Path(shutil.which('erl'))


def policy(device, predicate):
    until = time.monotonic() + 15
    while time.monotonic() < until:
        value = device.request('clock_snapshot')['offset_policy']
        if value['ready'] and predicate(value):
            return value
        time.sleep(.05)
    raise AssertionError(f'Response-time policy did not converge: {value}')


def main():
    root = control.ROOT
    out = root / 'builds/intermediates/session-control-check'
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run([shutil.which('erlc'), '-Werror', '-o', str(out), str(HERE / 'ba_session_control_probe.erl')], check=True)
    paths = [out, *(root / 'builds/intermediates/control/default/lib').glob('*/ebin')]
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 0))
        port = probe.getsockname()[1]
    desk, devices = relay.start_desk(port), []
    try:
        a, b = control.Runtime(paths), control.Runtime(paths)
        devices.extend([a, b])
        for device in devices:
            assert device.request('clock_prepare', interval_ms=100, samples=3)['ok']
        url = f'ws://127.0.0.1:{port}/relay/v1'
        assert a.request('create', desks=[url])['ok']
        control.wait(a, lambda s: all(d['connected'] for d in s['relay']['desks'].values()))
        assert b.request('join', invitation=a.request('invite')['value'], desk=url)['ok']
        control.wait(b, lambda s: s['membership']['state'] == 'authorized')
        assert a.request('grant', peer=b.identity['id'], permissions=['time_read'])['ok']
        policy(b, lambda p: p['offset_ms'] == 150)
        assert b.request('offset_automatic', enabled=True) == {'error': 'forbidden'}
        assert a.request('offset_automatic', enabled=True)['ok']
        current = policy(b, lambda p: p.get('automatic') is True)
        assert b.request('offset_required', offset_ms=600, revision=current['revision'])['ok']
        raised = policy(a, lambda p: p['offset_ms'] > 150)
        assert raised['offset_ms'] == 330 and raised['automatic'] is True
        policy(b, lambda p: p['revision'] == raised['revision'])
        assert a.request('offset_set', offset_ms=800)['ok']
        manual = policy(b, lambda p: p['offset_ms'] == 800 and not p.get('automatic'))
        assert b.request('offset_required', offset_ms=2000, revision=manual['revision'])['ok']
        assert a.request('clock_snapshot')['offset_policy'] == manual
        print('PASS: ordinary Device requests measured minimum over signed control; only a settings editor enables Automatic; shared weighted increase is 150 -> 330 ms; manual 800 ms disables adjustment')
    finally:
        for device in devices:
            device.close()
        desk.terminate()
        desk.wait(timeout=5)


if __name__ == '__main__':
    main()
