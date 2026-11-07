#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Check bundled config/assets and existing storage before and after a VM reset."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload
import stdio


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit", required=True, type=Path)
    parser.add_argument("--envelope", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--restore-image", required=True, type=Path)
    args = parser.parse_args()
    upload.validate_image(args.restore_image.read_bytes())
    uploader = args.toit.resolve().parents[1] / "lib/toit/bin/rp2040-ota-upload"
    with tempfile.TemporaryDirectory() as directory:
        config = Path(directory) / "config.json"
        config.write_text(json.dumps({
            "name": "rp2040-envelope-test", "enabled": True,
            "verify-persistence": True, "reset-check": True,
            "large-number": 0x100000001,
            "nested": {"message": "config survives reset"},
        }))
        image = Path(directory) / "firmware.bin"
        subprocess.run([str(args.toit), "tool", "firmware", "-e", str(args.envelope),
                        "extract", "--format=binary", "--config", str(config),
                        "--output", str(image)], check=True)
        upload.validate_image(image.read_bytes())
        try:
            subprocess.run([str(uploader), "--port", args.port, "--id", args.id,
                            str(image)], check=True)
            for boot in range(2):
                stream, console = stdio.wait_application(args.port,
                    "envelope-rp2040: READY reset check", required_lines=(
                        "envelope-rp2040: PASS existing flash bucket and region survived recovery",
                        "envelope-rp2040: PASS bundled container, assets, config, GC, storage RPC, and identity"))
                with stream:
                    if boot == 0:
                        console.command("RESET")
            print("PASS: firmware config, assets, container and persistent storage across reset", flush=True)
        finally:
            subprocess.run([str(uploader), "--port", args.port, "--id", args.id,
                            str(args.restore_image)], check=True)
            stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
            stream.close()


if __name__ == "__main__":
    main()
