#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Build separate ESP8285 service/client containers and optionally test on Pico."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit", type=Path, required=True)
    parser.add_argument("--envelope", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--port")
    parser.add_argument("--id")
    parser.add_argument("--restore-image", type=Path)
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    if not args.build_only and not (args.port and args.id and args.restore_image):
        parser.error("hardware testing requires --port, --id and --restore-image")
    toit = args.toit.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixture = Path(__file__).resolve().parent
    envelope = args.envelope.resolve()
    for source, name, trigger in [
        ("service-provider", "net-provider", "none"),
        ("service-client", "net-client", "none"),
        ("service-containers", "network-test", "boot"),
    ]:
        snapshot = output / f"{source}.snapshot"
        subprocess.run([str(toit), "compile", "-s", "-o", str(snapshot),
                        str(fixture / f"{source}.toit")], check=True)
        installed = output / f"{source}.envelope"
        subprocess.run([str(toit), "tool", "firmware", "-e", str(envelope),
                        "container", "install", "--trigger", trigger,
                        "--output", str(installed), name, str(snapshot)], check=True)
        envelope = installed
    binary = output / "service-containers.bin"
    subprocess.run([str(toit), "tool", "firmware", "-e", str(envelope),
                    "extract", "--format=binary", "--output", str(binary)], check=True)
    if args.build_only:
        return
    subprocess.run([
        sys.executable, str(fixture.parent / "pio-lifecycle.py"),
        "--uploader", str(toit.parents[1] / "lib/toit/bin/rp2040-ota-upload"),
        "--port", args.port, "--id", args.id, "--image", str(binary),
        "--restore-image", str(args.restore_image.resolve()),
        "--expect", "RP2040 ESP8285 separate containers: PASS", "--timeout", "300",
    ], check=True)


if __name__ == "__main__":
    main()
