#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Verify RP2040 storage across replacement with an independently compiled reader."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "rp2040"))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True, type=int)
    parser.add_argument("--writer-image", required=True, type=Path)
    parser.add_argument("--reader-image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    if not 0 <= args.version <= 0xffffffff - 2:
        parser.error("version must leave room for three uint32 image versions")
    images = [
        (args.writer_image, "storage-write-rp2040: PASS buckets, regions, page boundaries, and reopen"),
        (args.reader_image, "storage-read-rp2040: PASS persistent data survived firmware replacement"),
        (args.restore_image, "RP2040 VM/GC/timer smoke: PASS"),
    ]
    for path, _ in images:
        upload.validate_image(path.read_bytes())
    for offset, (path, expected) in enumerate(images):
        subprocess.run([
            sys.executable, str(ROOT / "tools" / "rp2040" / "upload.py"),
            "--port", args.port, "--id", args.id, "--version", str(args.version + offset),
            "--request-update", "--expect", expected, "--verbose", str(path),
        ], check=True)
    print("RP2040 storage hardware: PASS")


if __name__ == "__main__":
    main()
