#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Repeat idle and exception recovery, preserving the first failed device state.

Uses application images only. Does not flash a loader, pulse GPIOs, or retry a
failed upload.
"""
import argparse
import hashlib
import json
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
    parser.add_argument("--uploader", required=True, type=Path)
    parser.add_argument("--port", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--idle-image", required=True, type=Path)
    parser.add_argument("--exception-image", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path,
                        help="New directory; existing evidence is never overwritten")
    parser.add_argument("--cycles", type=int, default=3)
    parser.add_argument("--delays", type=float, nargs="+", default=[0, 1, 10, 30])
    parser.add_argument("--port-state", choices=("both", "closed", "open"), default="both")
    parser.add_argument("--exception-timeout", type=float, default=5,
                        help="Seconds to allow the triggered exception workload to complete")
    parser.add_argument("--exception-marker",
                        help="Require this line before the exception, to verify its intended cause")
    args = parser.parse_args()
    if args.cycles < 1 or any(not 0 <= delay <= 600 for delay in args.delays):
        parser.error("cycles must be positive; delays must be between 0 and 600 seconds")
    if not 0 < args.exception_timeout <= 600:
        parser.error("exception-timeout must be between 0 and 600 seconds")
    if not args.port.startswith("/dev/serial/by-id/"):
        parser.error("use the verified persistent serial identity")
    for path in (args.idle_image, args.exception_image):
        upload.validate_image(path.read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {
        "port": args.port, "id": args.id, "cycles": args.cycles,
        "delays": args.delays, "port_state": args.port_state, "images": {
            str(path): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (args.idle_image, args.exception_image)
        },
        "exception_timeout": args.exception_timeout,
        "exception_marker": args.exception_marker,
    }
    (args.output / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")
    sequence = 0

    def record(event, **fields):
        entry = {"event": event, "time": time.time(), **fields}
        with (args.output / "events.jsonl").open("a") as stream:
            stream.write(json.dumps(entry) + "\n")
        print(json.dumps(entry), flush=True)

    def install(image):
        nonlocal sequence
        sequence += 1
        record("upload-start", sequence=sequence, image=str(image))
        with (args.output / f"upload-{sequence:03}.log").open("w") as log:
            result = subprocess.run(
                [str(args.uploader), "--verbose", "--port", args.port, "--id", args.id, str(image)],
                stdout=log, stderr=subprocess.STDOUT, timeout=180,
            )
        record("upload-ended", sequence=sequence, exit_code=result.returncode)
        result.check_returncode()

    def usb_state():
        # Read sysfs without opening the serial port or changing the device.
        # In particular, retain whether host runtime power management has
        # suspended the device when a recovery request stops working.
        state = {}
        try:
            tty = Path(args.port).resolve(strict=True)
            state["tty"] = str(tty)
            interface = (Path("/sys/class/tty") / tty.name / "device").resolve(strict=True)
            for parent in (interface, *interface.parents):
                if not (parent / "idVendor").exists():
                    continue
                state["usb_device"] = str(parent)
                for name in ("idVendor", "idProduct", "serial", "busnum", "devnum",
                             "power/control", "power/runtime_status",
                             "power/autosuspend_delay_ms"):
                    path = parent / name
                    if path.exists():
                        state[name] = path.read_text().strip()
                break
        except OSError as error:
            state["error"] = str(error)
        record("host-usb-state", **state)

    def smoke():
        stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        return stream

    def capture_exception(console):
        # Ordinary container failure leaves the system container alive. Record
        # its trace, then exercise USB recovery while that system is idle.
        deadline = time.monotonic() + args.exception_timeout
        cause_verified = args.exception_marker is None
        with (args.output / f"exception-{sequence:03}.log").open("w") as log:
            while time.monotonic() < deadline:
                line = console.line(deadline)
                log.write(line + "\n")
                log.flush()
                if line == args.exception_marker:
                    cause_verified = True
                if line.startswith("jag decode "):
                    if not cause_verified:
                        raise RuntimeError("Application failed before its expected exception marker")
                    record("application-exception", sequence=sequence)
                    return
        raise TimeoutError("No exception trace after failure trigger")

    try:
        usb_state()
        install(args.idle_image)
        idle_stream = smoke()
        idle_stream.close()
        for cycle in range(args.cycles):
            for delay in args.delays:
                states = (False, True) if args.port_state == "both" else (args.port_state == "open",)
                for hold_open in states:
                    record("idle-start", cycle=cycle, delay=delay, hold_open=hold_open)
                    stream = upload.connect(serial, args.port) if hold_open else None
                    try:
                        time.sleep(delay)
                    finally:
                        if stream:
                            stream.close()
                    install(args.exception_image)
                    stream, console = stdio.wait_application(
                        args.port, "RP2040 recovery exception: READY")
                    with stream:
                        console.command("fail")
                        console.expect("RP2040 recovery exception: TRIGGERED")
                        capture_exception(console)
                    time.sleep(delay)
                    install(args.idle_image)
                    idle_stream = smoke()
                    idle_stream.close()
        record("pass", uploads=sequence)
    except BaseException as error:
        record("failed-state-preserved", error=repr(error), sequence=sequence)
        usb_state()
        raise


if __name__ == "__main__":
    main()
