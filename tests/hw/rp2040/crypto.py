#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Check Pico random output/reset, RSA cancellation and EC, then restore smoke."""
import argparse
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
    remaining = {
        "crypto-rp2040: PASS random sizes, TLS random and reset",
        "crypto-rp2040: PASS asynchronous RSA, concurrent RNG, GC and timers",
        "crypto-rp2040: PASS abandoned and queued RSA generation",
        "crypto-rp2040: PASS secp256r1 ECDSA and ECDH",
        "crypto-rp2040: PASS secp384r1 ECDSA and ECDH",
        "crypto-rp2040: PASS secp521r1 ECDSA and ECDH",
    }
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        try:
            with upload.connect(serial, port) as stream:
                console = upload.Console(stream)
                while time.monotonic() < deadline:
                    line = console.line(deadline)
                    print(line, flush=True)
                    remaining.discard(line)
                    if line.startswith("jag decode ") or "FAIL" in line:
                        raise RuntimeError(line)
                    if line == "crypto-rp2040: PASS":
                        if remaining:
                            raise RuntimeError(f"Missing checks: {remaining}")
                        return
        except (serial.SerialException, FileNotFoundError):
            time.sleep(.1)
    raise TimeoutError("Crypto hardware test did not finish")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uploader", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    for path in (args.image, args.restore_image):
        upload.validate_image(path.read_bytes())

    def install(path):
        subprocess.run([str(args.uploader), "--port", args.port, "--id", args.id,
                        str(path)], check=True)

    try:
        install(args.image)
        exercise(args.port)
    finally:
        install(args.restore_image)
        stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        stream.close()


if __name__ == "__main__":
    main()
