"""Unpack pinned official Python/GStreamer wheels into a private audio runtime."""
import hashlib
import json
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'builds/intermediates/Windows/audio-runtime'
DOWNLOADS = ROOT / 'builds/intermediates/Windows/downloads'
DOWNLOADS.mkdir(parents=True, exist_ok=True)

for artifact in json.loads(Path(__file__).with_name('audio-deps.json').read_text()):
    archive = DOWNLOADS / artifact['name']
    if not archive.exists():
        urllib.request.urlretrieve(artifact['url'], archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != artifact['sha256']:
        raise RuntimeError('Checksum mismatch: ' + archive.name)
    if archive.suffix == '.zip':
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(OUT)
    else:
        site = OUT / 'Lib/site-packages'
        with zipfile.ZipFile(archive) as bundle:
            for name in bundle.namelist():
                if name.endswith('/'):
                    continue
                relative = name.split('.data/purelib/', 1)[-1]
                target = site / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(bundle.read(name))
(OUT / 'python312._pth').write_text('python312.zip\n.\nLib/site-packages\nimport site\n')
print('Prepared private audio runtime:', OUT)
