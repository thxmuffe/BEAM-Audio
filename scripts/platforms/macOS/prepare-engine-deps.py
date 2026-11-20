#!/usr/bin/env python3
"""Download the audio engine's pinned library sources and build them as static
libraries under builds/; nothing is installed system-wide."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / "builds/intermediates/engine-deps"
DOWNLOADS = BASE / "downloads"
PREFIX = BASE / "macOS"

# name: (url, sha256, cmake options). Checksums match the Homebrew formulae.
SOURCES = {
    "flac": ("https://ftp.osuosl.org/pub/xiph/releases/flac/flac-1.5.0.tar.xz",
             "f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920",
             ["-DBUILD_PROGRAMS=OFF", "-DBUILD_EXAMPLES=OFF", "-DBUILD_TESTING=OFF", "-DBUILD_DOCS=OFF",
              "-DINSTALL_MANPAGES=OFF", "-DWITH_OGG=OFF", "-DBUILD_CXXLIBS=OFF"]),
    "libsrtp": ("https://github.com/cisco/libsrtp/archive/refs/tags/v2.8.1.tar.gz",
                "ef5569220749529d778013aae1178391d972570a2b4f7288dda22effa875b07c",
                ["-DLIBSRTP_TEST_APPS=OFF"]),
    "libsamplerate": ("https://github.com/libsndfile/libsamplerate/releases/download/0.2.2/libsamplerate-0.2.2.tar.xz",
                      "3258da280511d24b49d6b08615bbe824d0cacc9842b0e4caf11c52cf2b043893",
                      ["-DBUILD_TESTING=OFF", "-DLIBSAMPLERATE_EXAMPLES=OFF", "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"]),
    "cpptrace": ("https://github.com/jeremy-rifkin/cpptrace/archive/refs/tags/v1.0.4.tar.gz",
                 "5c9f5b301e903714a4d01f1057b9543fa540f7bfcc5e3f8bd1748e652e24f9ea",
                 ["-DCPPTRACE_BUILD_TESTING=OFF"]),
    "nlohmann-json": ("https://github.com/nlohmann/json/archive/refs/tags/v3.12.0.tar.gz",
                      "4b92eb0c06d10683f7447ce9406cb97cd4b453be18d7279320f7b2f025c10187",
                      ["-DJSON_BuildTests=OFF", "-DJSON_Install=ON"]),
}


def fetch(name, url, sha256):
    archive = DOWNLOADS / f"{name}-{url.rsplit('/', 1)[1]}"
    if not archive.exists():
        print(f"Downloading {url}", flush=True)
        temporary = archive.with_suffix(".download")
        urllib.request.urlretrieve(url, temporary)
        temporary.replace(archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != sha256:
        archive.unlink()
        raise SystemExit(f"Checksum mismatch for {name}; download removed, run again.")
    return archive


def build(name, archive, options):
    stamp = PREFIX / f".{name}-{archive.name}.built"
    if stamp.exists():
        return
    source = BASE / "src" / name
    shutil.rmtree(source, ignore_errors=True)
    source.mkdir(parents=True)
    with tarfile.open(archive) as tar:
        tar.extractall(source, filter="data")
    (top,) = list(source.iterdir())
    work = BASE / "work" / name
    shutil.rmtree(work, ignore_errors=True)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.2")
    subprocess.run(["cmake", "-S", top, "-B", work, "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
                    f"-DCMAKE_INSTALL_PREFIX={PREFIX}", "-DBUILD_SHARED_LIBS=OFF",
                    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.2",
                    f"-DCMAKE_PREFIX_PATH={PREFIX}", *options], check=True, env=env)
    subprocess.run(["cmake", "--build", work, "--parallel"], check=True, env=env)
    subprocess.run(["cmake", "--install", work], check=True, env=env)
    stamp.write_text(archive.name + "\n")


def main():
    DOWNLOADS.mkdir(parents=True, exist_ok=True)
    PREFIX.mkdir(parents=True, exist_ok=True)
    for name, (url, sha256, options) in SOURCES.items():
        build(name, fetch(name, url, sha256), options)
    print(f"Engine libraries ready: {PREFIX}", flush=True)


if __name__ == "__main__":
    main()
