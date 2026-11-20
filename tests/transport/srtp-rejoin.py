#!/usr/bin/env python3
"""Compile and run the native SRTP late-join regression; no audio or network."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DEPS = ROOT / "builds/intermediates/engine-deps/macOS"
OUT = ROOT / "builds/intermediates/srtp-rejoin"
OUT.mkdir(parents=True, exist_ok=True)
binary = OUT / "srtp-rejoin"
subprocess.run([
    "xcrun", "clang++", "-std=c++17", "-O2", "-Wall", "-Wextra",
    "-I", str(ROOT / "src/Audio/engine"), "-I", str(DEPS / "include"),
    str(Path(__file__).with_suffix(".cpp")), str(ROOT / "src/Audio/engine/net.cpp"),
    str(DEPS / "lib/libsrtp2.a"), "-o", str(binary),
], check=True)
subprocess.run([str(binary)], check=True)
