#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Build test-only native faults and verify recovery through the Pico USB updater."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

import serial

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "tools" / "rp2040"))
import upload

FAULTS = ("abort", "exit", "fatal", "panic", "hardfault", "xip-fault",
          "stack-overflow", "watchdog-hang")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--version", required=True, type=int)
    parser.add_argument("--build", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--restore-expect", default="RP2040 VM/GC/timer smoke: PASS")
    parser.add_argument("--fault", action="append", choices=FAULTS)
    args = parser.parse_args()
    faults = args.fault or FAULTS
    if not 0 <= args.version <= 0xffffffff - len(faults):
        parser.error("version must leave room for each fault and the restore image")
    upload.validate_image(args.restore_image.read_bytes())
    build = args.build.resolve()
    cache = {}
    for line in (build / "CMakeCache.txt").read_text().splitlines():
        if line and not line.startswith(("#", "//")) and "=" in line:
            key, value = line.split("=", 1)
            cache[key.split(":", 1)[0]] = value
    if cache.get("PICO_PLATFORM") != "rp2040":
        parser.error("build must be an existing RP2040 VM build")
    original = {key: cache.get(key, "") for key in
                ("TOIT_RP2040_PROGRAM", "TOIT_RP2040_PROJECT_ROOT", "TOIT_RP2040_TEST_FAULT")}
    if original["TOIT_RP2040_TEST_FAULT"]:
        parser.error("start from an ordinary build with fault injection disabled")

    def configure(values):
        subprocess.run(["cmake", "-S", str(ROOT / "toolchains" / "rp2040"),
                        "-B", str(build),
                        *[f"-D{key}={value}" for key, value in values.items()]], check=True)

    def compile_image():
        subprocess.run(["cmake", "--build", str(build), "--target", "toit-rp2040",
                        "--parallel", "4"], check=True)

    def install(image, version, expected, request=False):
        command = [sys.executable, str(ROOT / "tools" / "rp2040" / "upload.py"),
                   "--port", args.port, "--id", args.id, "--version", str(version),
                   "--expect", expected, "--verbose", str(image)]
        if request:
            command.append("--request-update")
        subprocess.run(command, check=True)

    results = []
    try:
        for index, fault in enumerate(faults):
            configure({"TOIT_RP2040_TEST_FAULT": fault,
                       "TOIT_RP2040_PROGRAM": str(Path(__file__).with_name("native-failure.toit").resolve()),
                       "TOIT_RP2040_PROJECT_ROOT": str(Path(__file__).resolve().parent)})
            compile_image()
            image = build / "toit-rp2040.bin"
            # Keep the exact tested artifact independently of subsequent builds.
            saved = build / f"native-failure-{fault}.bin"
            saved.write_bytes(image.read_bytes())
            install(saved, args.version + index, f"[test] injecting native {fault}",
                    request=index == 0)
            started = time.monotonic()
            stream, _, _ = upload.wait_ready(serial, args.port, args.id, timeout=12)
            stream.close()
            elapsed = time.monotonic() - started
            results.append({"fault": fault, "version": args.version + index,
                            "recovery_seconds": elapsed, "image": str(saved)})
            (build / "native-failure-results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"PASS: {fault} reached recovery in {elapsed:.2f}s", flush=True)
        install(args.restore_image, args.version + len(faults), args.restore_expect)
    finally:
        configure(original)
        compile_image()
    print("RP2040 native failure hardware: PASS", flush=True)


if __name__ == "__main__":
    main()
