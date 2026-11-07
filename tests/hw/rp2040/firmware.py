#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Exercise the RP2040 firmware service and verify the resulting installed image."""

import argparse
from pathlib import Path
import subprocess
import sys

import serial

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "rp2040"))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True, type=int)
    parser.add_argument("--test-image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    if not 0 <= args.version <= 0xffffffff - 2:
        parser.error("version must leave room for three uint32 image versions")
    data = args.test_image.read_bytes()
    upload.validate_image(data)
    upload.validate_image(args.restore_image.read_bytes())

    def install(path, version, expected):
        subprocess.run([
            sys.executable, str(ROOT / "tools" / "rp2040" / "upload.py"),
            "--port", args.port, "--id", args.id, "--version", str(version),
            "--request-update", "--expect", expected, "--verbose", str(path),
        ], check=True)

    install(args.test_image, args.version, "firmware-rp2040: committed; upgrading")
    # The firmware service increments the installed descriptor's version.
    # Require that new version, exact size/CRC, and the application's digest
    # verification; a pre-reboot success message alone is insufficient.
    upload.wait_installed(serial, args.port, args.id, data, args.version + 1,
                          "firmware-rp2040: PASS upgraded through the firmware service",
                          timeout=90, verbose=True)
    install(args.restore_image, args.version + 2, "RP2040 VM/GC/timer smoke: PASS")
    print("RP2040 firmware service hardware: PASS")


if __name__ == "__main__":
    main()
