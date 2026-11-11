"""Verify independent desktop slots and automatic process-exit lease release."""
from pathlib import Path
import os
import subprocess
import tempfile
root = Path(__file__).resolve().parents[2]
output = root / 'builds/intermediates/desktop-instance-check'
output.mkdir(parents=True, exist_ok=True)
env = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')
subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(output/'ModuleCache'),
    str(root/'src/control/adapters/Apple/NativeIdentity.swift'), str(Path(__file__).with_name('desktop-instance-probe.swift')),
    '-o', str(output/'probe')], check=True, env=env)
with tempfile.TemporaryDirectory() as directory:
    processes = []
    def start():
        p = subprocess.Popen([str(output/'probe'), directory], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        processes.append(p)
        return p, int(p.stdout.readline())
    try:
        a, one = start(); b, two = start()
        assert (one, two) == (1, 2)
        a.stdin.close(); a.wait(timeout=5)
        c, reused = start()
        assert reused == 1 and b.poll() is None
        print('PASS: simultaneous desktop processes lease distinct slots; closing one releases only its slot; no Keychain or app identity touched.')
    finally:
        for p in processes:
            if p.poll() is None:
                p.stdin.close(); p.wait(timeout=5)
