#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Run a Pico fixture with a success marker and restore the smoke application."""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload
import stdio


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uploader", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--expect", default="pio-lifecycle-rp2040: PASS")
    parser.add_argument("--timeout", type=float, default=30,
                        help="Seconds allowed for the fixture's success marker")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    for path in (args.image, args.restore_image):
        upload.validate_image(path.read_bytes())

    def install(path):
        subprocess.run([str(args.uploader), "--port", args.port, "--id", args.id,
                        str(path)], check=True)

    try:
        install(args.image)
        stream, _ = stdio.wait_application(args.port, args.expect, timeout=args.timeout)
        stream.close()
    finally:
        install(args.restore_image)
        stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        stream.close()


if __name__ == "__main__":
    main()
