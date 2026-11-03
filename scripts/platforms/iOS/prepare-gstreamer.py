#!/usr/bin/env python3
"""Prepare the official pinned GStreamer slice; never install it system-wide."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
VERSION = "1.28.8"
SHA256 = "d34ae6bd55b6cb9959734299536003d315deea1ab46f84182113692528d04fb5"
BASE = ROOT / "builds/intermediates/gstreamer/iOS"
ARCHIVE = BASE / f"gstreamer-{VERSION}-xcframework.tar.xz"
SLICES = {"device": "ios-arm64", "sim": "ios-arm64_x86_64-simulator"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", choices=SLICES, default="device")
    args = parser.parse_args()
    BASE.mkdir(parents=True, exist_ok=True)
    if not ARCHIVE.exists():
        url = f"https://gstreamer.freedesktop.org/data/pkg/ios/{VERSION}/{ARCHIVE.name}"
        print(f"Downloading {url}", flush=True)
        temporary = ARCHIVE.with_suffix(".download")
        urllib.request.urlretrieve(url, temporary)
        temporary.replace(ARCHIVE)
    digest = hashlib.sha256()
    with ARCHIVE.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    if digest.hexdigest() != SHA256:
        raise SystemExit(f"SDK checksum mismatch: {ARCHIVE}; download the pinned archive again")
    target = SLICES[args.target]
    sdk = BASE / f"sdk-{args.target}"
    prefix = f"GStreamer.xcframework/{target}/"
    stamp = sdk / "prepared.json"
    if not stamp.exists() or json.loads(stamp.read_text()).get("archive_sha256") != SHA256:
        # Stream only this platform slice; do not unpack the unrelated tvOS SDK.
        with tarfile.open(ARCHIVE, "r|xz") as archive:
            for member in archive:
                if member.name == "GStreamer.xcframework/Info.plist":
                    manifest = plistlib.loads(archive.extractfile(member).read())
                elif member.name.startswith(prefix):
                    archive.extract(member, sdk)
        library = next(item for item in manifest["AvailableLibraries"]
                       if item["LibraryIdentifier"] == target)
        assert library["SupportedPlatform"] == "ios" and "arm64" in library["SupportedArchitectures"]
        assert (sdk / prefix / library["LibraryPath"]).is_file()
        stamp.write_text(json.dumps({"version": VERSION, "archive_sha256": SHA256,
                                     "library": library}, indent=2) + "\n")
    print(f"Prepared {VERSION}: {sdk / prefix}", flush=True)


if __name__ == "__main__":
    main()
