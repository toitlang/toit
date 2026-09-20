#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Exercise a TOIT_RP2350_TEST_FAULT image through the production OTA uploader.

Build with AUTO_VALIDATE=OFF for rollback, or ON and pass --validated to check
that confirmed firmware restarts itself. Python/pyserial are test-only tools.
For --fault=system-oom, use an envelope whose system snapshot is compiled from
system-oom-rp2350.toit instead of setting TOIT_RP2350_TEST_FAULT.
"""
import argparse
import pathlib
import re
import subprocess
import time

import serial


def device_info(path):
    with serial.Serial(path, 115200, timeout=0.1) as port:
        port.write(b"TOIT-OTA INFO\n")
        port.flush()
        output = ""
        end = time.monotonic() + 5
        while time.monotonic() < end:
            output += port.read(4096).decode(errors="replace")
            match = re.search(r"TOIT-OTA INFO 1 ([01]) 0 4194304", output)
            if match:
                return int(match[1])
    raise AssertionError("No confirmed starting firmware")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--uploader", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--fault", required=True,
                        choices=["abort", "exit", "fatal", "panic", "hardfault", "xip-fault",
                                 "stack-overflow", "system-oom", "watchdog-hang"])
    parser.add_argument("--validated", action="store_true")
    parser.add_argument("--log", required=True, type=pathlib.Path)
    args = parser.parse_args()
    original = device_info(args.port)
    expected = 1 - original if args.validated else original
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.with_suffix(".upload.log").open("w") as upload_log:
        subprocess.run([args.uploader, "--port", args.port, "--no-reboot", args.image],
                       stdout=upload_log, stderr=subprocess.STDOUT, check=True,
                       timeout=90)

    stream = serial.Serial(args.port, 115200, timeout=0.1)
    stream.write(b"TOIT-OTA REBOOT\n")
    stream.flush()
    end = time.monotonic() + 45
    probe = time.monotonic() + 2
    settled = None
    fault_seen = None
    output = ""
    disconnects = 0
    try:
        with args.log.open("w") as log:
            while time.monotonic() < end:
                try:
                    if stream is None:
                        stream = serial.Serial(args.port, 115200, timeout=0.1)
                    data = stream.read(4096).decode(errors="replace")
                    if data:
                        print(data, end="", flush=True)
                        log.write(data)
                        log.flush()
                        output += data
                    if time.monotonic() >= probe:
                        stream.write(b"TOIT-OTA INFO\n")
                        stream.flush()
                        probe = time.monotonic() + 1
                except serial.SerialException:
                    if stream is not None:
                        stream.close()
                        stream = None
                        disconnects += 1
                        log.write("[USB reconnect]\n")
                        log.flush()
                    time.sleep(0.05)

                marker = f"[test] injecting native {args.fault}"
                if marker not in output:
                    continue
                if fault_seen is None:
                    fault_seen = time.monotonic()
                after_fault = output.split(marker, 1)[1]
                boot = f"[toit] boot partition={expected} type=0 trial/update=0"
                info = f"TOIT-OTA INFO 1 {expected} 0 4194304"
                if boot in after_fault and info in after_fault and disconnects >= 2:
                    if (args.fault == "watchdog-hang" and
                            "watchdog-hang-rp2350: PASS recovered from native interrupt-off hang" not in after_fault):
                        continue
                    if args.fault == "system-oom":
                        before_recovery = after_fault.split(boot, 1)[0]
                        if ("RP2350 heap: out of memory" not in before_recovery or
                                "[toit] native panic" not in before_recovery):
                            raise AssertionError("Missing native system-process OOM evidence")
                    if settled is None:
                        settled = time.monotonic()
                        recovery_seconds = settled - fault_seen
                        log.write(f"\n[host] confirmed recovery {recovery_seconds:.2f}s after fault marker\n")
                        log.flush()
                        # ROM's original trial watchdog would expire much
                        # later. Require bounded fault recovery (including
                        # the one-second application watchdog hang test).
                        if recovery_seconds > 8:
                            raise AssertionError("Recovery too slow to distinguish it from the ROM trial timeout")
                    if time.monotonic() - settled >= 4:
                        if disconnects != 2 or after_fault.count("[toit] RP2350 VM starting") != 1:
                            raise AssertionError("Unexpected repeated reset")
                        print("native-failure-test: PASS " +
                              ("confirmed restart" if args.validated else "trial rollback"))
                        return
    finally:
        if stream is not None:
            stream.close()
    raise AssertionError("Did not observe fault, reset, and confirmed recovery")


if __name__ == "__main__":
    main()
