#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Stress simultaneous USB CDC input/output and line-coding control transfers.

Pipeline binary blocks while verifying each acknowledgement, with GC running
on the Pico. Stop at the first failure, preserving hardware state. Use ordinary
application images only; no loader or GPIO changes are made.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
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
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--blocks", type=int, default=16384)
    parser.add_argument("--window", type=int, default=8)
    parser.add_argument("--idle-seconds", type=float, default=30)
    args = parser.parse_args()
    if not 1 <= args.blocks <= 100000 or not 1 <= args.window <= 8:
        parser.error("blocks must be 1..100000; window must be 1..8")
    if not 0 <= args.idle_seconds <= 600:
        parser.error("idle-seconds must be 0..600")
    if not args.port.startswith("/dev/serial/by-id/"):
        parser.error("use the verified persistent serial identity")
    for path in (args.image, args.restore_image):
        upload.validate_image(path.read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {
        "port": args.port, "id": args.id, "blocks": args.blocks,
        "window": args.window, "idle_seconds": args.idle_seconds,
        "sha256": {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in (args.image, args.restore_image, args.uploader)},
    }
    (args.output / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def record(event, **fields):
        entry = {"event": event, "time": time.time(), **fields}
        with (args.output / "events.jsonl").open("a") as log:
            log.write(json.dumps(entry) + "\n")
        print(json.dumps(entry), flush=True)

    def install(image, name):
        record("upload-start", image=str(image))
        with (args.output / f"{name}.log").open("w") as log:
            result = subprocess.run(
                [str(args.uploader), "--verbose", "--port", args.port,
                 "--id", args.id, str(image)],
                stdout=log, stderr=subprocess.STDOUT, timeout=180)
        record("upload-ended", exit_code=result.returncode)
        result.check_returncode()

    try:
        install(args.image, "install")
        stream, console = stdio.wait_application(args.port, "usb-stress: READY")
        with stream:
            stream.write(struct.pack("<I", args.blocks))
            sent = 0
            controls = 0
            start = time.monotonic()

            def send_block(block):
                nonlocal controls
                # CDC baud changes exercise endpoint zero alongside bulk I/O.
                # Neither value requests recovery or changes a physical UART.
                if block % 32 == 0:
                    stream.baudrate = 57600 if controls % 2 == 0 else 115200
                    controls += 1
                data = bytes(((block + i) * 37) % 256 for i in range(1031))
                for offset in range(0, len(data), 137):
                    stream.write(data[offset:offset + 137])

            for received in range(args.blocks):
                # Bound unread device output below the USB TX FIFO size. This
                # tests USB service concurrency without intentionally dropping
                # stdout when the host stops reading it for too long.
                while sent < min(args.blocks, received + args.window):
                    send_block(sent)
                    sent += 1
                line = console.line(time.monotonic() + 10)
                expected = f"usb-stress: block {received}"
                if line != expected:
                    raise RuntimeError(f"Expected {expected!r}, received {line!r}")
                if (received + 1) % 256 == 0 or received + 1 == args.blocks:
                    record("traffic", blocks=received + 1, controls=controls,
                           seconds=time.monotonic() - start)
            line = console.line(time.monotonic() + 10)
            if not line.startswith(f"usb-stress: PASS {args.blocks} blocks, "):
                raise RuntimeError(f"Missing workload success: {line!r}")
            record("workload-pass", marker=line, bytes=args.blocks * 1031,
                   controls=controls, seconds=time.monotonic() - start)
        record("closed-port-idle", seconds=args.idle_seconds)
        time.sleep(args.idle_seconds)
        install(args.restore_image, "restore")
        stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        stream.close()
        record("pass")
    except BaseException as error:
        record("failed-state-preserved", error=repr(error),
               serial_path_exists=Path(args.port).exists())
        raise


if __name__ == "__main__":
    main()
