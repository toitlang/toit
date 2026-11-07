#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Verify changed-image OTA through ESP8285 HTTP, restoring both test boards."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import zlib

FIXTURE = Path(__file__).resolve().parent
ROOT = FIXTURE.parents[3]
sys.path.insert(0, str(FIXTURE.parent))
sys.path.insert(0, str(ROOT / "tools/rp2040"))
from containers import assets
from stdio import wait_application
import upload


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toit", type=Path, required=True)
    parser.add_argument("--envelope", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--http-only", action="store_true",
                        help="Read and hash HTTP bodies without flash writes or a network service")
    parser.add_argument("--diagnose-helper-memory", action="store_true",
                        help="Diagnose sender stalls with the helper's explicit GC probe; changes timing")
    parser.add_argument("--gzip-strategy", choices=("fixed", "dynamic"), default="dynamic",
                        help="Dynamic coding exercises helper memory pressure; fixed coding is a comparison control")
    parser.add_argument("--jag", type=Path)
    parser.add_argument("--helper", default="pico-w-helper")
    parser.add_argument("--port")
    parser.add_argument("--id")
    parser.add_argument("--restore-image", type=Path)
    args = parser.parse_args()
    if not args.build_only and not (args.jag and args.port and args.id and args.restore_image):
        parser.error("hardware testing requires --jag, --port, --id and --restore-image")
    toit = args.toit.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)

    def install(envelope, source, name, trigger, asset_file=None):
        snapshot = output / f"{source}.snapshot"
        subprocess.run([str(toit), "compile", "-s", "-o", str(snapshot),
                        str(FIXTURE / f"{source}.toit")], check=True)
        installed = output / f"{source}.envelope"
        options = ["--assets", str(asset_file)] if asset_file else []
        subprocess.run([str(toit), "tool", "firmware", "-e", str(envelope),
                        "container", "install", "--trigger", trigger,
                        "--output", str(installed), *options, name, str(snapshot)], check=True)
        return installed

    def extract(envelope, name):
        binary = output / f"{name}.bin"
        subprocess.run([str(toit), "tool", "firmware", "-e", str(envelope),
                        "extract", "--format=binary", "--output", str(binary)], check=True)
        upload.validate_image(binary.read_bytes())
        return binary

    target_envelope = install(args.envelope.resolve(), "firmware-received", "ota-target", "boot")
    target = extract(target_envelope, "firmware-received")
    data = target.read_bytes()
    client_assets = output / "download-assets.bin"
    client_assets.write_bytes(assets({"size": str(len(data)).encode(),
                                     "sha256": hashlib.sha256(data).digest()}))
    helper_assets = output / "helper-assets.bin"
    # The helper's program partition cannot hold its code plus a raw image.
    # It inflates this asset as it sends the ordinary, uncompressed HTTP body.
    # Bound history at 1 KiB while Wi-Fi and Jaguar share the helper's RAM.
    # Dynamic coding also exercises native TCP allocation failures under memory
    # pressure. Fixed coding remains available as a comparison control.
    strategy = zlib.Z_FIXED if args.gzip_strategy == "fixed" else zlib.Z_DEFAULT_STRATEGY
    compressor = zlib.compressobj(wbits=16 + 10, strategy=strategy)
    compressed = compressor.compress(data) + compressor.flush()
    assert zlib.decompress(compressed, wbits=16 + 10) == data
    print(f"Firmware asset: {len(data)} bytes, gzip {len(compressed)} bytes, "
          f"{args.gzip_strategy} Huffman, 1024-byte history", flush=True)
    helper_values = {"firmware-gzip": compressed,
                     "firmware-window": b"1024",
                     "firmware-size": str(len(data)).encode()}
    if args.diagnose_helper_memory:
        helper_values["firmware-memory-probe"] = b"1"
    helper_assets.write_bytes(assets(helper_values))
    if args.http_only:
        source_envelope = install(args.envelope.resolve(), "http-download", "http-download", "boot", client_assets)
        source = extract(source_envelope, "http-download")
    else:
        source_envelope = install(args.envelope.resolve(), "service-provider", "net-provider", "none")
        source_envelope = install(source_envelope, "firmware-download", "ota-download", "boot", client_assets)
        source = extract(source_envelope, "firmware-download")
    if args.build_only:
        return

    uploader = toit.parents[1] / "lib/toit/bin/rp2040-ota-upload"
    helper_fixture = FIXTURE.parent / "wifi-peer-esp32.toit"
    environment = dict(os.environ, JAG_TOIT_REPO_PATH=str(ROOT))

    def deploy_helper(with_image):
        options = ["--assets", str(helper_assets)] if with_image else []
        subprocess.run([str(args.jag.resolve()), "run", "--device", args.helper,
                        *options, str(helper_fixture)], env=environment, check=True, timeout=90)

    def flash(image):
        result = subprocess.run([str(uploader), "--port", args.port, "--id", args.id,
                                 str(image)], check=True, capture_output=True, text=True, timeout=120)
        print(result.stdout, end="", flush=True)
        version = re.search(r"installed version (\d+),", result.stdout)
        if not version:
            raise RuntimeError("Uploader did not report the installed version")
        return int(version[1])

    upload.validate_image(args.restore_image.read_bytes())
    try:
        deploy_helper(True)
        version = flash(source)
        marker = (f"RP2040-UPDATER 1 id={args.id} app={version + 1} "
                  f"size={len(data)} crc={zlib.crc32(data):08x}")
        expected = ("RP2040 ESP8285 HTTP download: PASS" if args.http_only else
                    "RP2040 WiFi firmware: PASS changed image booted and SHA256 verified")
        stream, _ = wait_application(args.port, expected,
                                    required_lines=[] if args.http_only else [marker], timeout=660)
        stream.close()
        print("RP2040 Wi-Fi HTTP control: PASS" if args.http_only else
              "RP2040 changed-image Wi-Fi OTA: PASS", flush=True)
    finally:
        try:
            flash(args.restore_image.resolve())
            stream, _ = wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
            stream.close()
        finally:
            deploy_helper(False)


if __name__ == "__main__":
    main()
