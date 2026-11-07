#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Check USB recovery with unread output and an independent UART heartbeat.

Requires the verified GP16 -> helper GPIO34 connection and a running Jaguar
proxy whose log is supplied. The helper receives only. Any failure preserves
both devices; restoration happens only after recovery is verified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
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
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--jag", required=True, type=Path)
    parser.add_argument("--helper-device", required=True)
    parser.add_argument("--helper-repo", required=True, type=Path)
    parser.add_argument("--helper-log", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--seconds", type=float, default=15)
    args = parser.parse_args()
    if not 5 <= args.seconds <= 300:
        parser.error("seconds must be between 5 and 300")
    if not args.port.startswith("/dev/serial/by-id/"):
        parser.error("use the verified persistent serial identity")
    for path in (args.image, args.restore_image):
        upload.validate_image(path.read_bytes())
    offset = args.helper_log.stat().st_size
    args.output.mkdir(parents=True, exist_ok=False)
    environment = dict(os.environ, JAG_TOIT_REPO_PATH=str(args.helper_repo.resolve()))
    paths = (args.image, args.restore_image, args.uploader,
             Path(__file__), ROOT / "tests/hw/rp2040/usb-observer-esp32.toit")
    manifest = {
        "port": args.port, "id": args.id, "seconds": args.seconds,
        "helper_device": args.helper_device, "helper_log": str(args.helper_log),
        "helper_log_offset": offset,
        "sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths},
    }
    (args.output / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def record(event, **fields):
        entry = {"event": event, "time": time.time(), **fields}
        with (args.output / "events.jsonl").open("a") as log:
            log.write(json.dumps(entry) + "\n")
        print(json.dumps(entry), flush=True)

    pending = ""
    heartbeats = []
    observer_ready = False

    def observe():
        nonlocal offset, pending, observer_ready
        with args.helper_log.open("rb") as stream:
            stream.seek(offset)
            data = stream.read()
        offset += len(data)
        with (args.output / "observer.log").open("ab") as log:
            log.write(data)
        pending += data.decode(errors="replace")
        while "\n" in pending:
            line, pending = pending.split("\n", 1)
            if "usb-observer: READY" in line:
                observer_ready = True
            match = re.search(r"usb-observer: USB-HEALTH (\d+) (\d+)", line)
            if match:
                sequence, writes = map(int, match.groups())
                if heartbeats and sequence != heartbeats[-1][0] + 1:
                    raise RuntimeError(f"Heartbeat discontinuity: {sequence} after {heartbeats[-1][0]}")
                heartbeats.append((sequence, writes, time.monotonic()))

    def helper(source, name):
        with (args.output / f"{name}.log").open("w") as log:
            subprocess.run([str(args.jag), "run", "--device", args.helper_device,
                            str(ROOT / "tests/hw/rp2040" / source)], env=environment,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)

    def install(image, name):
        record("upload-start", image=str(image))
        with (args.output / f"{name}.log").open("w") as log:
            subprocess.run([str(args.uploader), "--verbose", "--port", args.port,
                            "--id", args.id, str(image)], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=180)
        record("upload-ended")

    def usb_node():
        tty = Path(args.port).resolve(strict=True)
        interface = (Path("/sys/class/tty") / tty.name / "device").resolve(strict=True)
        return next(parent for parent in interface.parents if (parent / "idVendor").exists())

    try:
        helper("usb-observer-esp32.toit", "helper-install")
        deadline = time.monotonic() + 10
        while not observer_ready:
            observe()
            if time.monotonic() >= deadline:
                raise TimeoutError("Helper observer did not become ready")
            time.sleep(.1)
        install(args.image, "install")
        stream, _ = stdio.wait_application(args.port, "usb-backpressure: READY")
        with stream:
            node = usb_node()
            identity = (node / "serial").read_text().strip()
            if identity.upper() != args.id.upper():
                raise RuntimeError("USB identity changed")
            previous_number = (node / "devnum").read_text().strip()
            stream.write(b"g")
            start = time.monotonic()
            record("unread-output-start", usb_node=str(node), devnum=previous_number)
            last_report = start
            while time.monotonic() - start < args.seconds:
                observe()
                if time.monotonic() - start > 3:
                    if not heartbeats or time.monotonic() - heartbeats[-1][2] > 2:
                        raise TimeoutError("Independent heartbeat stopped under USB backpressure")
                if time.monotonic() - last_report >= 5 and heartbeats:
                    record("heartbeat", sequence=heartbeats[-1][0], writes=heartbeats[-1][1])
                    last_report = time.monotonic()
                time.sleep(.1)
            if len(heartbeats) < 8 or heartbeats[-1][1] <= heartbeats[0][1]:
                raise RuntimeError("UART did not verify application progress")
            record("backpressure-pass", heartbeats=len(heartbeats), writes=heartbeats[-1][1])
            # Request recovery while the serial fd is still open and no USB
            # output has been drained. Do not retry if this request fails.
            request_start = time.monotonic()
            stream.baudrate = 1200
            record("recovery-request", control_seconds=time.monotonic() - request_start)
            disconnected = False
            while time.monotonic() - request_start < 4:
                observe()
                try:
                    disconnected = (node / "devnum").read_text().strip() != previous_number
                except FileNotFoundError:
                    disconnected = True
                if disconnected:
                    break
                time.sleep(.01)
            if not disconnected:
                raise TimeoutError("No USB reboot after the single recovery control request")
            record("usb-reboot", seconds=time.monotonic() - request_start)
        stream, _, _ = upload.wait_ready(serial, args.port, args.id, timeout=10)
        stream.close()
        record("recovery-verified")
        observe()
        install(args.restore_image, "restore")
        stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        stream.close()
        helper("wifi-peer-esp32.toit", "helper-restore")
        record("pass")
    except BaseException as error:
        record("failed-state-preserved", error=repr(error), heartbeats=len(heartbeats))
        raise


if __name__ == "__main__":
    main()
