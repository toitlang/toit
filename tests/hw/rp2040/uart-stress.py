#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Run the verified UART rig, then restore Pico smoke and the ESP32 Wi-Fi peer."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

import serial

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload
import stdio


def exercise(port):
    deadline = time.monotonic() + 150
    required = {"uart-stress-rp2040: PASS traffic, baud, GC and timers",
                "uart-stress-rp2040: PASS overflow accounting and recovery"}
    while time.monotonic() < deadline:
        try:
            with upload.connect(serial, port) as stream:
                console = upload.Console(stream)
                while time.monotonic() < deadline:
                    line = console.line(deadline)
                    print(line, flush=True)
                    required.discard(line)
                    if line.startswith("jag decode ") or "FAIL" in line:
                        raise RuntimeError(line)
                    if line == "uart-stress-rp2040: PASS":
                        if required:
                            raise RuntimeError(f"Missing checks: {required}")
                        return
        except (serial.SerialException, FileNotFoundError):
            time.sleep(.1)
    raise TimeoutError("UART test did not finish")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uploader", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--jag", required=True, type=Path)
    parser.add_argument("--helper-device", required=True)
    parser.add_argument("--helper-repo", required=True, type=Path)
    args = parser.parse_args()
    for path in (args.image, args.restore_image):
        upload.validate_image(path.read_bytes())
    environment = dict(os.environ, JAG_TOIT_REPO_PATH=str(args.helper_repo.resolve()))

    def peer(name):
        subprocess.run([str(args.jag), "run", "--device", args.helper_device,
                        str(ROOT / "tests/hw/rp2040" / name)], env=environment, check=True, timeout=90)

    def install(path):
        subprocess.run([str(args.uploader), "--port", args.port, "--id", args.id,
                        str(path)], check=True, timeout=120)

    try:
        peer("uart-stress-esp32.toit")
        install(args.image)
        exercise(args.port)
    finally:
        try:
            install(args.restore_image)
            stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
            stream.close()
        finally:
            peer("wifi-peer-esp32.toit")


if __name__ == "__main__":
    main()
