#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Prove that an application assertion leaves USB OTA usable.

Use the container-failure-rp2350 and vm-smoke images built with OTA enabled.
Python/pyserial are test dependencies only; uploads use the native tool.
"""
import argparse
import pathlib
import re
import subprocess
import time

import serial


def upload(args, image, label):
    with (args.logs / (label + "-upload.log")).open("w") as log:
        subprocess.run([args.uploader, "--port", args.port, image],
                       stdout=log, stderr=subprocess.STDOUT, check=True,
                       timeout=90)


def capture(args, label, expected, *, check_console=False):
    transcript = ""
    deadline = time.monotonic() + 25
    with serial.Serial(args.port, 115200, timeout=0.1) as port, \
            (args.logs / (label + ".log")).open("w") as log:
        def read():
            nonlocal transcript
            text = port.read(4096).decode(errors="replace")
            transcript += text
            log.write(text)
            log.flush()

        while expected not in transcript:
            if time.monotonic() >= deadline:
                raise AssertionError("Missing test result: " + expected)
            read()
        if "VM exited" in transcript:
            raise AssertionError("Application failure stopped the system VM")
        if check_console:
            # Let process termination/trace handling finish before probing.
            quiet_until = time.monotonic() + 2
            while time.monotonic() < quiet_until:
                read()
            port.write(b"TOIT-OTA INFO\n")
            port.flush()
            deadline = time.monotonic() + 5
            while not re.search(r"TOIT-OTA INFO 1 [01] 0 4194304", transcript):
                if time.monotonic() >= deadline:
                    raise AssertionError("OTA console did not survive the assertion")
                read()
            if "VM exited" in transcript:
                raise AssertionError("Application failure stopped the system VM")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uploader", required=True)
    parser.add_argument("--port", required=True)
    parser.add_argument("--failure-image", required=True)
    parser.add_argument("--healthy-image", required=True)
    parser.add_argument("--logs", type=pathlib.Path, required=True)
    args = parser.parse_args()
    args.logs.mkdir(parents=True, exist_ok=True)
    upload(args, args.failure_image, "container-failure")
    capture(args, "container-failure", "Expected <expected>, but was <deliberate failure>",
            check_console=True)
    upload(args, args.healthy_image, "after-container-failure")
    capture(args, "after-container-failure", "RP2350 VM/GC/timer smoke: PASS")
    print("container-failure-test: PASS assertion isolation and subsequent OTA")


if __name__ == "__main__":
    main()
