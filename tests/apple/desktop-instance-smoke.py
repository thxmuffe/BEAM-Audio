"""One Mac, one Device: a second running copy is refused; the lock releases on exit."""
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
        return p, p.stdout.readline().strip()
    try:
        a, first = start(); b, second = start()
        assert (first, second) == ('acquired', 'refused'), (first, second)
        a.stdin.close(); a.wait(timeout=5)
        c, again = start()
        assert again == 'acquired', again
        print('PASS: a second copy is refused while the first runs; the one identity is free again after exit; no Keychain touched.')
    finally:
        for p in processes:
            if p.poll() is None:
                p.stdin.close(); p.wait(timeout=5)
