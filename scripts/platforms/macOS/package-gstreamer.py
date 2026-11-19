#!/usr/bin/env python3
"""Copy the native stream helper's GStreamer dependencies into an app bundle.

Only the selected plugins (prepare-gstreamer.py) and the libraries they and the
helper load are copied, not the whole 700 MB runtime. Layout matches what
ba_mac_native_audio expects from BA_GSTREAMER_RUNTIME: <dest>/runtime/lib and
<dest>/plugins.
"""
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / 'builds/intermediates/gstreamer'
LIB = BASE / 'runtime/lib'


def deps(binary):
    out = subprocess.run(['otool', '-L', str(binary)], capture_output=True, text=True, check=True).stdout
    ident = subprocess.run(['otool', '-D', str(binary)], capture_output=True, text=True, check=True).stdout.split()
    own = ident[-1] if len(ident) > 1 else None  # a library lists its own install name first
    names = []
    for line in out.splitlines()[1:]:
        path = line.strip().split(' ')[0]
        if path.startswith('@rpath/') and path != own:
            names.append(path[len('@rpath/'):])
    return names


def main(helper, dest):
    dest = Path(dest)
    lib, plugins = dest / 'runtime/lib', dest / 'plugins'
    for folder in (lib, plugins):
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
    queue = deps(helper)
    for plugin in sorted((BASE / 'plugins').glob('*.dylib')):
        target = plugins / plugin.name
        shutil.copy2(plugin.resolve(), target)
        queue += deps(target)
    seen = set()
    while queue:
        name = queue.pop()
        if name in seen:
            continue
        seen.add(name)
        source = LIB / name
        if not source.exists():
            raise SystemExit('GStreamer library missing from runtime: ' + name)
        shutil.copy2(source.resolve(), lib / name)
        queue += deps(lib / name)
    print(f'Packaged GStreamer: {len(seen)} libraries, {len(list(plugins.iterdir()))} plugins -> {dest}')


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: package-gstreamer.py HELPER DEST')
    main(sys.argv[1], sys.argv[2])
