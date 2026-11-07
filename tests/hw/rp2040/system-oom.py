#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Build a privileged OOM fixture, verify USB recovery, and restore normal firmware."""
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit", required=True, type=Path)
    parser.add_argument("--native-base", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    upload.validate_image(args.restore_image.read_bytes())
    args.output.mkdir(parents=True, exist_ok=True)
    snapshot = args.output / "system-oom.snapshot"
    envelope = args.output / "system-oom.envelope"
    image = args.output / "system-oom.bin"
    subprocess.run([str(args.toit), "compile", "-s", "-o", str(snapshot),
                    str(Path(__file__).with_suffix(".toit"))], check=True)
    subprocess.run([str(args.toit), "tool", "firmware", "-e", str(envelope),
                    "create", "rp2040", "--firmware.bin", str(args.native_base),
                    "--system.snapshot", str(snapshot)], check=True)
    subprocess.run([str(args.toit), "tool", "firmware", "-e", str(envelope),
                    "extract", "--format=binary", "--output", str(image)], check=True)
    upload.validate_image(image.read_bytes())
    uploader = args.toit.resolve().parents[1] / "lib/toit/bin/rp2040-ota-upload"

    def install(path):
        subprocess.run([str(uploader), "--port", args.port, "--id", args.id,
                        str(path)], check=True)

    try:
        install(image)
        stream, console = stdio.wait_application(args.port, "[test] system-oom ready")
        try:
            stream.write(b"oom\n")
            stream.flush()
            deadline = time.monotonic() + 5
            while True:
                line = console.line(deadline)
                print(line, flush=True)
                if line == "[test] injecting native system-oom":
                    break
        finally:
            stream.close()
        started = time.monotonic()
        stream, _, _ = upload.wait_ready(serial, args.port, args.id, timeout=12)
        stream.close()
        print(f"PASS: privileged OOM reached USB recovery in {time.monotonic() - started:.2f}s", flush=True)
    finally:
        install(args.restore_image)
        stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        stream.close()


if __name__ == "__main__":
    main()
