#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Verify lossless application stdin and USB recovery while a reader is blocked."""
import argparse
from pathlib import Path
import subprocess
import sys
import time

import serial

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload


def wait_application(port, expected, required_lines=(), timeout=30):
    deadline = time.monotonic() + timeout
    remaining = set(required_lines) | {expected}
    while time.monotonic() < deadline:
        stream = None
        try:
            stream = upload.connect(serial, port)
            console = upload.Console(stream)
            while True:
                line = console.line(deadline)
                print(line, flush=True)
                if line.startswith("jag decode "):
                    raise RuntimeError(line)
                remaining.discard(line)
                if not remaining:
                    return stream, console
        except (OSError, serial.SerialException):
            if stream:
                stream.close()
            time.sleep(.1)
        except BaseException:
            if stream:
                stream.close()
            raise
    raise TimeoutError("Application startup not verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uploader", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    for image in (args.image, args.restore_image):
        upload.validate_image(image.read_bytes())

    def install(image):
        subprocess.run([str(args.uploader), "--port", args.port, "--id", args.id,
                        str(image)], check=True)

    install(args.image)
    stream, console = wait_application(args.port, "stdio-rp2040: READY")
    with stream:
        stream.write(b"update\r\nhello\n")
        for block in range(32):
            data = bytes(((block * 1027 + i) * 37) % 256 for i in range(1027))
            # Exercise short, non-aligned USB packets as well as a transfer
            # larger than the VM's native stdin buffer.
            for start in range(0, len(data), 137):
                stream.write(data[start:start + 137])
            console.expect(f"stdio-rp2040: block {block}")
        console.expect("stdio-rp2040: PASS binary input, GC, timers and update text")
    print("PASS: application received all 32878 bytes, including update text", flush=True)
    install(args.restore_image)
    stream, _ = wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
    stream.close()
    print("RP2040 stdin ownership and USB control recovery: PASS", flush=True)


if __name__ == "__main__":
    main()
