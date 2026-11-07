#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Test installed-SDK firmware flash and restore through its native uploader."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

import serial

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit", required=True, type=Path)
    parser.add_argument("--envelope", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    upload.validate_image(args.restore_image.read_bytes())
    native = args.toit.resolve().parents[1] / "lib/toit/bin/rp2040-ota-upload"
    if not native.is_file():
        raise FileNotFoundError(native)

    def application(expected):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            try:
                with upload.connect(serial, args.port) as stream:
                    console = upload.Console(stream)
                    while True:
                        line = console.line(deadline)
                        print(line, flush=True)
                        if line == expected:
                            return
            except (OSError, serial.SerialException):
                time.sleep(.1)
        raise TimeoutError("Application startup was not verified")

    subprocess.run([str(args.toit), "tool", "firmware", "-e", str(args.envelope),
                    "flash", "--config", str(args.config), "--port", args.port], check=True)
    application("envelope-rp2040: PASS bundled container, assets, config, GC, storage RPC, and identity")
    subprocess.run([str(native), "--port", args.port, str(args.restore_image)], check=True)
    application("RP2040 VM/GC/timer smoke: PASS")
    print("RP2040 installed SDK flash hardware: PASS")


if __name__ == "__main__":
    main()
