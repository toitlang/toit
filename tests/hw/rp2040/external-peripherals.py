#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Check external wiring, test ADC/I2C/SPI, and restore both devices."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload
import stdio


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uploader", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--wiring-image", required=True, type=Path)
    parser.add_argument("--image", type=Path,
                        help="Omit to run only the input/weak-pull wiring check")
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--jag", required=True, type=Path)
    parser.add_argument("--helper-device", required=True)
    parser.add_argument("--helper-repo", required=True, type=Path)
    args = parser.parse_args()
    for path in (args.wiring_image, args.image, args.restore_image):
        if path is not None:
            upload.validate_image(path.read_bytes())
    environment = dict(os.environ, JAG_TOIT_REPO_PATH=str(args.helper_repo.resolve()))

    def peer(name):
        subprocess.run([str(args.jag), "run", "--device", args.helper_device,
                        str(ROOT / "tests/hw/rp2040" / name)],
                       env=environment, check=True, timeout=90)

    def install(path):
        subprocess.run([str(args.uploader), "--port", args.port, "--id", args.id,
                        str(path)], check=True, timeout=120)

    def run_pair(path, name):
        install(path)
        stream, console = stdio.wait_application(args.port, f"{name}-rp2040: READY")
        with stream:
            peer(f"{name}-esp32.toit")
            deadline = time.monotonic() + 120
            while True:
                line = console.line(deadline)
                print(line, flush=True)
                if line.startswith("jag decode ") or "FAIL" in line:
                    raise RuntimeError(line)
                if line == f"{name}-rp2040: PASS":
                    return

    try:
        # The Pico only reports PASS after the peer has checked every wire in
        # both directions. Any failure prevents installation of output tests.
        run_pair(args.wiring_image, "peripheral-wiring")
        if args.image is not None:
            run_pair(args.image, "external-peripherals")
    finally:
        try:
            install(args.restore_image)
            stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
            stream.close()
        finally:
            peer("wifi-peer-esp32.toit")


if __name__ == "__main__":
    main()
