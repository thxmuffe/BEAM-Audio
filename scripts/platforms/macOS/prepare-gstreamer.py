#!/usr/bin/env python3
"""Unpack the pinned official runtime for isolated media proofs; no installer."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / 'builds/intermediates/gstreamer'
NAME = 'gstreamer-1.0-1.28.8-universal.pkg'
SHA256 = 'd371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe'
BASE.mkdir(parents=True, exist_ok=True)
archive = BASE / NAME
if not archive.exists():
    urllib.request.urlretrieve('https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/' + NAME, archive)
with archive.open('rb') as source:
    digest = hashlib.sha256()
    for block in iter(lambda: source.read(1024 * 1024), b''):
        digest.update(block)
if digest.hexdigest() != SHA256:
    raise SystemExit('Runtime checksum mismatch: ' + str(archive))
runtime = BASE / 'runtime'
if not (runtime / 'bin/gst-launch-1.0').exists():
    expanded = BASE / 'expanded'
    if expanded.exists():
        shutil.rmtree(expanded)
    subprocess.run(['pkgutil', '--expand-full', str(archive), str(expanded)], check=True)
    for payload in expanded.glob('*/Payload'):
        if payload.is_dir():
            subprocess.run(['ditto', str(payload), str(runtime)], check=True)
plugins = BASE / 'plugins'
plugins.mkdir(exist_ok=True)
for name in ['coreelements','app','audiotestsrc','opus','rtp','rtpmanager',
             'audioconvert','audioresample','volume','osxaudio','webrtc','nice','dtls','srtp','sctp','netsim']:
    source = runtime / f'lib/gstreamer-1.0/libgst{name}.dylib'
    if not source.exists():
        raise SystemExit('Required plugin absent from official runtime: ' + str(source))
    target = plugins / source.name
    if not target.exists():
        target.symlink_to(source)
print('Prepared isolated GStreamer 1.28.8:', runtime)
