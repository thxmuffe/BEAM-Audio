#!/usr/bin/env python3
"""Pinned dependencies for the explicitly enabled Opus comparison."""
import hashlib
import argparse
import base64
from pathlib import Path
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[4]
BASE = ROOT / "builds/intermediates/webrtc-audio"
WEBRTC_REV = "2a990ce0ccd00a3ad449f2201a8e5c2dad53177d"
THIRD_PARTY_REV = "6eabe54fa10922ba0d3f9a8e5a01055d371ebaf7"


def prepare_receiver_headers():
    """Exact-revision interfaces for the existing binary, not a WebRTC rebuild."""
    headers = BASE / "native-headers"
    marker = headers / "prepared.stamp"
    if marker.exists() and marker.read_text() == WEBRTC_REV:
        return
    archives = {
        "api": "0f05542fab86726128af54256bf080367ff5cce595b2052d90fe4fc038746f25",
        "rtc_base": "a0a7e57f93266d7f6a944fad98136ccfa328005a379d2e3d2b7d22e3c1c4412c",
        "system_wrappers": "486cbcba123c92a0ab06bcc1d38019babddf7a5e30287a26925f580eff4ec5dd",
        "modules": "63b7020ee5616c0feed4dff234368cf41836fb659384ee9c0f4527ff667be654",
        "third_party/abseil-cpp": "4d61b8fb5e8fcaccd4df6c232edf1a7162ad9dd431bf04d63d3c4a6898418112",
    }
    for folder, checksum in archives.items():
        if folder.startswith("third_party/"):
            url = f"https://chromium.googlesource.com/chromium/src/third_party/+archive/{THIRD_PARTY_REV}/abseil-cpp.tar.gz"
        else:
            url = f"https://webrtc.googlesource.com/src/+archive/{WEBRTC_REV}/{folder}.tar.gz"
        archive = BASE / f"headers-{folder.replace('/', '-')}-{WEBRTC_REV}.tar.gz"
        if not archive.exists():
            urllib.request.urlretrieve(url, archive)
        with tarfile.open(archive) as source:
            members = sorted((m for m in source.getmembers() if m.isfile() and
                (m.name.endswith((".h", ".inc")) or Path(m.name).name.startswith(("LICENSE", "COPYING", "PATENTS")))),
                key=lambda m: str(Path(m.name)))
            # Gitiles archive timestamps change between requests. Pin the names
            # and contents of all extracted files instead of archive metadata.
            digest = hashlib.sha256()
            for member in members:
                digest.update(str(Path(member.name)).encode() + b"\0")
                digest.update(hashlib.sha256(source.extractfile(member).read()).digest())
            if digest.hexdigest() != checksum:
                raise SystemExit(f"Header content checksum mismatch: {folder}")
            source.extractall(headers / folder, members=members, filter="data")
    files = {
        "sdk/objc/api/peerconnection/RTCRtpReceiver+Private.h": "fefb2d4493ccd06e78e1f62d607da5a65af169be92671606a0ecee12d8d1df66",
        "LICENSE": "ab00a482b6a3902e40211b43c5d0441962ea99b6cc7c25c0f243fa270b78d482",
        "PATENTS": "01462e2068d1a04c2274f3389773014c14ed9bc3446b28303543bd3e3c064145",
    }
    for path, checksum in files.items():
        url = f"https://webrtc.googlesource.com/src/+/{WEBRTC_REV}/{path}?format=TEXT"
        data = base64.b64decode(urllib.request.urlopen(url).read())
        if hashlib.sha256(data).hexdigest() != checksum:
            raise SystemExit(f"Header checksum mismatch: {path}")
        (headers / Path(path).name).write_bytes(data)
    marker.write_text(WEBRTC_REV)


def fetch(name, url, checksum):
    path = BASE / name
    if not path.exists():
        urllib.request.urlretrieve(url, path)
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != checksum:
        raise SystemExit(f"Checksum mismatch: {path}")
    return path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", choices=("ios", "mac", "all"), default="all")
    args = parser.parse_args()
    BASE.mkdir(parents=True, exist_ok=True)
    if args.target in ("ios", "all"):
        framework = fetch("WebRTC-M156.xcframework.zip",
            "https://github.com/stasel/WebRTC/releases/download/156.0.0/WebRTC-M156.xcframework.zip",
            "43c2a6f7a650185bbc911d7605a979589671886e8fc0ac283f54fdf3f511dc46")
        if not (BASE / "WebRTC.xcframework/Info.plist").exists():
            subprocess.run(["ditto", "-x", "-k", str(framework), str(BASE)], check=True)
        prepare_receiver_headers()
    if args.target == "ios":
        return
    opus = fetch("opus-1.5.2.tar.gz", "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz",
        "65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1")
    source = BASE / "opus-source"
    if not (source / "CMakeLists.txt").exists():
        source.mkdir(exist_ok=True)
        subprocess.run(["tar", "-xzf", str(opus), "--strip-components", "1", "-C", str(source)], check=True)
    subprocess.run(["cmake", "-S", str(source), "-B", str(BASE / "opus-mac"),
        "-DOPUS_BUILD_TESTING=OFF", "-DOPUS_BUILD_PROGRAMS=OFF", "-DBUILD_SHARED_LIBS=OFF",
        "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.2", "-DCMAKE_OSX_ARCHITECTURES=arm64"], check=True)
    subprocess.run(["cmake", "--build", str(BASE / "opus-mac"), "-j", "4"], check=True)


if __name__ == "__main__":
    main()
