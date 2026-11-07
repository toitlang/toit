#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
"""Test the installed loader or a recovery candidate in an ordinary application.

Use --installed-loader to test the current loader. For application-slot tests,
build with TOIT_RP2040_RECOVERY_TEST_APP=ON and use its recovery-test.bin.
This runner never replaces the loader. Stop on the first failure; successful
runs install the restore image through the tested protocol and verify boot.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import zlib

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
    parser.add_argument("--image", type=Path)
    parser.add_argument("--installed-loader", action="store_true",
                        help="Test the installed loader directly, without installing a candidate application")
    parser.add_argument("--restore-image", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not args.port.startswith("/dev/serial/by-id/"):
        parser.error("use the verified persistent serial identity")
    if args.installed_loader == bool(args.image):
        parser.error("supply either --image or --installed-loader")
    images = [args.restore_image] + ([args.image] if args.image else [])
    for path in images:
        upload.validate_image(path.read_bytes())
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {"port": args.port, "id": args.id, "installed_loader": args.installed_loader, "sha256": {
        str(path): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [*images, args.uploader, Path(__file__)]}}
    (args.output / "inputs.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def record(event, **fields):
        entry = {"event": event, "time": time.time(), **fields}
        with (args.output / "events.jsonl").open("a") as log:
            log.write(json.dumps(entry) + "\n")
        print(json.dumps(entry), flush=True)

    def install(image, name):
        record("upload-start", image=str(image))
        with (args.output / f"{name}.log").open("w") as log:
            subprocess.run([str(args.uploader), "--verbose", "--port", args.port,
                            "--id", args.id, str(image)], stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=180)
        record("upload-ended")

    ready = f"READY RP2040 1 983040 {args.id}"
    candidate = f"RP2040-RECOVERY-TEST id={args.id}"
    data = args.restore_image.read_bytes()
    # These sessions are abandoned without data or commit. Version 1 is only
    # an in-memory descriptor; the installed image/version remains unchanged.
    begin = f"begin {len(data)} {zlib.crc32(data):08x} 1"
    try:
        if args.installed_loader:
            with upload.connect(serial, args.port) as stream:
                stream.baudrate = 1200
            stream, console, _ = upload.wait_ready(serial, args.port, args.id)
        else:
            install(args.image, "install")
            stream, console = stdio.wait_application(args.port, candidate)
        with stream:
            for _ in range(64):
                console.command("hello")
                console.expect(ready)
            record("single-replies-pass", count=64)
            stream.reset_input_buffer()
            console.pending.clear()
            # A lossless device may stop consuming commands until replies are
            # drained. Do not deadlock the host by awaiting the entire write
            # before starting its bounded read pause.
            with ThreadPoolExecutor(max_workers=1) as writers:
                write = writers.submit(stream.write, b"hello\n" * 512)
                time.sleep(1.5)
                buffered = stream.in_waiting
                deadline = time.monotonic() + 8
                replies = 0
                with (args.output / "burst.log").open("w") as log:
                    while replies < 512:
                        line = console.line(deadline)
                        log.write(line + "\n")
                        if line == ready:
                            replies += 1
                        elif line != candidate and not line.startswith("RP2040-UPDATER 1 "):
                            raise RuntimeError(f"Truncated or unexpected reply: {line!r}")
                if write.result(timeout=6) != 512 * 6:
                    raise RuntimeError("Command burst was not written completely")
            record("unread-replies-pass", count=replies, buffered_bytes=buffered)
            console.command(begin)
            console.expect("OK begin")
        time.sleep(.3)
        start = time.monotonic()
        stream, console, _ = upload.wait_ready(serial, args.port, args.id, timeout=3)
        with stream:
            elapsed = time.monotonic() - start
            record("disconnected-session-pass", recovery_seconds=elapsed)
            console.command(begin)
            console.expect("OK begin")
            stream.write(b"block 0 ")
            start = time.monotonic()
            # Keep DTR asserted and leave a partial command. Inactivity alone
            # must release the session and reset command framing.
            while True:
                line = console.line(start + 13)
                if line == candidate or (args.installed_loader and
                        line.startswith(f"RP2040-UPDATER 1 id={args.id} ")):
                    elapsed = time.monotonic() - start
                    if elapsed < 8:
                        raise RuntimeError("Session ended before exercising its idle deadline")
                    break
            console.command("hello")
            console.expect(ready)
            record("idle-partial-command-pass", recovery_seconds=elapsed)
        install(args.restore_image, "restore")
        stream, _ = stdio.wait_application(args.port, "RP2040 VM/GC/timer smoke: PASS")
        stream.close()
        record("pass")
    except BaseException as error:
        record("failed-state-preserved", error=repr(error))
        raise


if __name__ == "__main__":
    main()
