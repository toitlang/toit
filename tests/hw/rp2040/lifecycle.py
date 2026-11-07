#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Test RP2040 identity, reset with active DMA, and application watchdog ownership."""

import argparse
from pathlib import Path
import subprocess
import sys
import time

import serial

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "rp2040"))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True, type=int)
    parser.add_argument("--reset-image", required=True, type=Path)
    parser.add_argument("--watchdog-image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--restore-expect", default="RP2040 VM/GC/timer smoke: PASS")
    args = parser.parse_args()
    if not 0 <= args.version <= 0xffffffff - 2:
        parser.error("version must leave room for three uint32 image versions")
    for path in (args.reset_image, args.watchdog_image, args.restore_image):
        upload.validate_image(path.read_bytes())

    def install(image, version, expected, request=False):
        command = [sys.executable, str(ROOT / "tools" / "rp2040" / "upload.py"),
                   "--port", args.port, "--id", args.id, "--version", str(version),
                   "--expect", expected, "--verbose", str(image)]
        if request:
            command.append("--request-update")
        subprocess.run(command, check=True)

    identity = f"platform-rp2040: identity={args.id} PASS"
    install(args.reset_image, args.version, identity, request=True)
    reset_seen = False
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        try:
            with upload.connect(serial, args.port) as stream:
                console = upload.Console(stream)
                while True:
                    line = console.line(deadline)
                    print(line, flush=True)
                    if line == "platform-rp2040: resetting with active DMA":
                        reset_seen = True
                    if reset_seen and line == identity:
                        stream.baudrate = 1200
                        break
                break
        except (OSError, serial.SerialException):
            time.sleep(0.1)
    else:
        raise TimeoutError("Normal reset did not restart the application")
    stream, _, _ = upload.wait_ready(serial, args.port, args.id)
    stream.close()
    print("PASS: identity stable across reset with active DMA", flush=True)

    install(args.watchdog_image, args.version + 1,
            "watchdog-rp2040: waiting for expiration")
    started = time.monotonic()
    # A runtime watchdog is eight seconds. A one-second application deadline
    # must enter recovery well before that, even while the boot task is alive.
    stream, _, _ = upload.wait_ready(serial, args.port, args.id, timeout=6)
    stream.close()
    print(f"PASS: application watchdog reached recovery in {time.monotonic() - started:.2f}s",
          flush=True)
    install(args.restore_image, args.version + 2, args.restore_expect)
    print("RP2040 lifecycle hardware: PASS", flush=True)


if __name__ == "__main__":
    main()
