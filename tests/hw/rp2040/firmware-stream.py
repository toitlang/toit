#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Stream changed firmware through application stdin and the firmware service."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import zlib

from containers import assets
from stdio import wait_application

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools/rp2040"))
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit", type=Path, required=True)
    parser.add_argument("--envelope", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--port")
    parser.add_argument("--id")
    parser.add_argument("--restore-image", type=Path)
    args = parser.parse_args()
    if not args.build_only and not (args.port and args.id and args.restore_image):
        parser.error("hardware testing requires --port, --id and --restore-image")
    toit = args.toit.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    environment.setdefault("TOIT_PACKAGE_CACHE_PATHS", str(ROOT / "tools/.packages-bootstrap"))

    def run(*arguments):
        subprocess.run([str(toit), *map(str, arguments)], env=environment, check=True)

    def build(name, asset_file=None):
        snapshot = output / f"{name}.snapshot"
        envelope = output / f"{name}.envelope"
        binary = output / f"{name}.bin"
        run("compile", "-s", "-o", snapshot, Path(__file__).with_name(f"{name}.toit"))
        options = ["--assets", asset_file] if asset_file else []
        run("tool", "firmware", "-e", args.envelope.resolve(), "container", "install",
            "--output", envelope, *options, "fixture", snapshot)
        run("tool", "firmware", "-e", envelope, "extract", "--format=binary", "-o", binary)
        upload.validate_image(binary.read_bytes())
        return binary

    target = build("firmware-stream-received")
    data = target.read_bytes()
    asset_file = output / "stream-assets.bin"
    asset_file.write_bytes(assets({"size": str(len(data)).encode(),
                                   "sha256": hashlib.sha256(data).digest()}))
    source = build("firmware-stream", asset_file)
    if args.build_only:
        return

    uploader = toit.parents[1] / "lib/toit/bin/rp2040-ota-upload"
    upload.validate_image(args.restore_image.read_bytes())

    def flash(image):
        result = subprocess.run([str(uploader), "--port", args.port, "--id", args.id,
                                 str(image)], check=True, capture_output=True, text=True, timeout=120)
        print(result.stdout, end="", flush=True)
        version = re.search(r"installed version (\d+),", result.stdout)
        if not version:
            raise RuntimeError("Uploader did not report the installed version")
        return int(version[1])

    def expect(console, marker):
        deadline = time.monotonic() + 30
        while True:
            line = console.line(deadline)
            if line == marker:
                return
            print(line, flush=True)
            if line.startswith("jag decode ") or "ASSERTION_FAILED" in line:
                raise RuntimeError(line)

    try:
        version = flash(source)
        stream, console = wait_application(args.port, "firmware-stream-rp2040: READY truncated")
        with stream:
            for name, limit in [("truncated", 4097), ("corrupt", len(data)), ("valid", len(data))]:
                if name != "truncated":
                    expect(console, f"firmware-stream-rp2040: READY {name}")
                for offset in range(0, limit, 1024):
                    chunk = bytearray(data[offset:min(offset + 1024, limit)])
                    if name == "corrupt" and offset == 0:
                        chunk[0] ^= 1
                    if stream.write(chunk) != len(chunk):
                        raise RuntimeError("Short USB write")
                    stream.flush()
                    end = offset + len(chunk)
                    expect(console, f"firmware-stream-rp2040: ACK {name} {end}")
                    if end == limit or end % 65536 == 0:
                        print(f"{name}: staged {end}/{limit} bytes", flush=True)
                if name != "valid":
                    expect(console, f"firmware-stream-rp2040: REJECTED {name}")
                    print(f"PASS rejected {name}", flush=True)
            expect(console, "firmware-stream-rp2040: COMMITTED")
        marker = (f"RP2040-UPDATER 1 id={args.id} app={version + 1} "
                  f"size={len(data)} crc={zlib.crc32(data):08x}")
        stream, _ = wait_application(
            args.port, "firmware-stream-rp2040: PASS changed image booted and SHA256 verified",
            required_lines=[marker], timeout=90)
        stream.close()
        print("RP2040 streamed changed-image firmware service: PASS", flush=True)
    finally:
        flash(args.restore_image.resolve())
        stream, _ = wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        stream.close()


if __name__ == "__main__":
    main()
