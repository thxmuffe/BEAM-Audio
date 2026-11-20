"""Build the Windows native AAC stream host and package what it loads.

Output: builds/CLI/native-stream/ba_native_stream.exe, the GStreamer/GLib DLLs
it and its plugins import (beside it), and the selected plugins in plugins/.
Apps copy that folder whole and name the helper with
BA_WINDOWS_NATIVE_STREAM_HELPER.

The pinned official GStreamer MSVC package (gstreamer-sdk.json) supplies headers,
import libraries and runtime. It ships only as an Inno Setup installer, so it is
installed once per user into builds/intermediates/Windows/gstreamer-sdk; set
BA_GSTREAMER_SDK to use an existing installation's msvc_x86_64 folder instead.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / 'builds/intermediates/Windows'
OUT = ROOT / 'builds/CLI/native-stream'
SOURCE = ROOT / 'src/Audio/adapters/Windows/native_stream.cpp'
# Elements the host's graphs use: webrtcbin/nice/dtls/srtp/sctp, rtpbin and
# MPEG4-GENERIC RTP, AAC (FFmpeg avenc_aac/avdec_aac, aacparse), conversion,
# appsrc/appsink, volume, WASAPI capture/output and the synthetic test source.
PLUGINS = ['coreelements', 'app', 'audioconvert', 'audioresample', 'audiotestsrc', 'volume',
           'audioparsers', 'libav', 'rtp', 'rtpmanager', 'webrtc', 'nice', 'dtls', 'srtp',
           'sctp', 'wasapi2']
LIBRARIES = ['gstreamer-1.0', 'gstbase-1.0', 'gstapp-1.0', 'gstrtp-1.0', 'gstsdp-1.0',
             'gstwebrtc-1.0', 'gobject-2.0', 'glib-2.0', 'json-glib-1.0']


def sdk():
    explicit = os.environ.get('BA_GSTREAMER_SDK')
    candidates = [Path(explicit)] if explicit else [WORK / 'gstreamer-sdk']
    for base in candidates:
        for header in sorted(base.glob('**/include/gstreamer-1.0/gst/gst.h')):
            return header.parents[3]
    if explicit:
        raise RuntimeError('BA_GSTREAMER_SDK has no include/gstreamer-1.0/gst/gst.h')
    pinned = json.loads((Path(__file__).with_name('gstreamer-sdk.json')).read_text(encoding='utf-8'))
    downloads = WORK / 'gstreamer-sdk-download'
    downloads.mkdir(parents=True, exist_ok=True)
    installer = downloads / pinned['name']
    if not installer.exists():
        urllib.request.urlretrieve(pinned['url'], installer)
    digest = hashlib.sha256()
    with installer.open('rb') as data:
        for block in iter(lambda: data.read(1 << 20), b''):
            digest.update(block)
    if digest.hexdigest() != pinned['sha256']:
        raise RuntimeError('Checksum mismatch: ' + installer.name)
    # Per-user, repository-private installation; nothing is installed for all users.
    subprocess.run([str(installer), '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CURRENTUSER',
                    '/NOICONS', '/TYPE=full', f'/DIR={WORK / "gstreamer-sdk"}',
                    f'/LOG={WORK / "gstreamer-sdk-install.log"}'], check=True)
    return sdk()


def visual_studio():
    vswhere = Path(os.environ['ProgramFiles(x86)']) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    vs = subprocess.check_output([str(vswhere), '-latest', '-products', '*', '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], text=True).strip()
    if not vs:
        raise RuntimeError('Install Visual Studio Desktop development with C++ tools.')
    return Path(vs)


def msvc(commands):
    batch = WORK / 'native-stream-compile.cmd'
    lines = ['@echo off', f'call "{visual_studio() / "Common7/Tools/VsDevCmd.bat"}" -no_logo -arch=x64 -host_arch=x64',
             'if errorlevel 1 exit /b 1']
    for command in commands:
        lines += [command, 'if errorlevel 1 exit /b 1']
    batch.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    subprocess.run([os.environ.get('COMSPEC', 'cmd.exe'), '/d', '/c', str(batch)], check=True)


def imports(path):
    """DLL names a PE file imports, including delay-loaded ones."""
    data = path.read_bytes()
    pe, = struct.unpack_from('<I', data, 0x3c)
    sections, optional = struct.unpack_from('<H', data, pe + 6)[0], struct.unpack_from('<H', data, pe + 20)[0]
    opt = pe + 24
    directories = opt + (112 if struct.unpack_from('<H', data, opt)[0] == 0x20b else 96)
    table = [struct.unpack_from('<IIIII', data, pe + 24 + optional + 40 * i + 8) for i in range(sections)]

    def offset(rva):
        for size, address, raw_size, raw, _ in table:
            if address <= rva < address + max(size, raw_size):
                return rva - address + raw
        raise ValueError(f'{path.name}: RVA outside sections')

    def name(rva):
        start = offset(rva)
        return data[start:data.index(b'\0', start)].decode('ascii')

    names = []
    for index, stride, field in ((1, 20, 12), (13, 32, 4)):
        rva, size = struct.unpack_from('<II', data, directories + 8 * index)
        if not rva or not size:
            continue
        entry = offset(rva)
        while True:
            descriptor = data[entry:entry + stride]
            if descriptor == b'\0' * stride:
                break
            names.append(name(struct.unpack_from('<I', descriptor, field)[0]))
            entry += stride
    return names


def package(base, helper):
    bin_dir, plugin_dir = base / 'bin', base / 'lib/gstreamer-1.0'
    available = {p.name.lower(): p for p in bin_dir.glob('*.dll')}
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / 'plugins').mkdir(parents=True)
    shutil.copy2(helper, OUT / helper.name)
    queue = imports(helper)
    for plugin in PLUGINS:
        source = plugin_dir / f'gst{plugin}.dll'
        if not source.exists():
            raise RuntimeError('GStreamer plugin missing from SDK: ' + source.name)
        shutil.copy2(source, OUT / 'plugins' / source.name)
        queue += imports(source)
    seen = set()
    while queue:
        name = queue.pop().lower()
        # Anything not shipped by GStreamer is a Windows system library.
        if name in seen or name not in available:
            continue
        seen.add(name)
        shutil.copy2(available[name], OUT / available[name].name)
        queue += imports(available[name])
    # App-local Visual C++ runtime, as Microsoft permits, for PCs without the redistributable.
    redist = sorted((visual_studio() / 'VC/Redist/MSVC').glob('*/x64/Microsoft.VC*.CRT'))
    runtime = {p.name.lower(): p for p in redist[-1].glob('*.dll')} if redist else {}
    needed = {n.lower() for f in [OUT / helper.name, *OUT.glob('*.dll'), *(OUT / 'plugins').glob('*.dll')] for n in imports(f)}
    for name in sorted(needed & runtime.keys()):
        shutil.copy2(runtime[name], OUT / runtime[name].name)
    missing = {n for n in needed if n.startswith(('vcruntime', 'msvcp'))} - runtime.keys()
    if missing:
        raise RuntimeError('Visual C++ runtime DLLs not found in the Visual Studio redist: ' + ', '.join(sorted(missing)))
    licenses = base / 'share/licenses'
    if licenses.is_dir():
        shutil.copytree(licenses, OUT / 'licenses', dirs_exist_ok=True)
    print(f'Packaged GStreamer: {len(seen)} libraries, {len(PLUGINS)} plugins -> {OUT}')


def main():
    base = sdk()
    helper = WORK / 'native-stream/ba_native_stream.exe'
    helper.parent.mkdir(parents=True, exist_ok=True)
    includes = ['include/gstreamer-1.0', 'include/glib-2.0', 'lib/glib-2.0/include', 'include/json-glib-1.0']
    if not helper.exists() or SOURCE.stat().st_mtime_ns > helper.stat().st_mtime_ns:
        msvc([f'cl /nologo /W4 /WX /EHsc /MD /O2 /std:c++17 /utf-8 /DNDEBUG '
              + ' '.join(f'/I"{base / i}"' for i in includes)
              + f' "{SOURCE}" /Fo"{helper.with_suffix(".obj")}" /Fe"{helper}" /link /SUBSYSTEM:CONSOLE '
              + f'/LIBPATH:"{base / "lib"}" ' + ' '.join(f'{lib}.lib' for lib in LIBRARIES) + ' ws2_32.lib'])
    package(base, helper)


if __name__ == '__main__':
    main()
