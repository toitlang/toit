#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Inspect/back up or start the W-2023 ESP8285 through the native USB bridge.

The ESP8285 must already be in download mode. This tool never writes flash.
Identification uses ROM commands. Backup loads esptool's readback stub into
RAM, reads flash and leaves the stub running. Starting the installed application
also uses a RAM stub, without writing flash. Requires pyserial and esptool 5.3.
"""

import argparse
from pathlib import Path
import subprocess
import sys
import time

import serial


def wait_line(stream, prefix, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = stream.readline().decode("ascii", errors="replace").strip()
        if line.startswith(prefix):
            return line
    raise TimeoutError(f"No {prefix!r} from native probe")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="Persistent Pico USB path")
    parser.add_argument("--id", required=True, help="Expected Pico unique ID")
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--backup", type=Path, help="Read all flash into a new file")
    operation.add_argument("--start-application", action="store_true",
                           help="Leave download mode and run the installed firmware")
    args = parser.parse_args()
    if args.backup and args.backup.exists():
        parser.error("Backup file already exists; refusing to overwrite it")
    with serial.Serial(args.port, 115200, timeout=0.1, exclusive=True) as stream:
        stream.reset_input_buffer()
        # Also waits out a previous bridge's 15-second idle timeout.
        line = wait_line(stream, "RP2040-PROBE ", 20)
        if f"id={args.id.upper()}" not in line.split():
            raise RuntimeError(f"Unexpected Pico identity: {line}")
        stream.write(b"modem-bridge 115200\n")
        print(wait_line(stream, "BRIDGE READY ", 3), flush=True)
    command = [
        sys.executable, "-m", "esptool", "--chip", "esp8266",
        "--port", args.port, "--baud", "115200", "--before", "no-reset",
        "--connect-attempts", "2",
    ]
    if args.backup or args.start_application:
        # The v2 stub shipped with esptool 5.3.1 leaves RUN_USER_CODE and
        # FLASH_END reset handling unimplemented. Use the legacy stub so a
        # later software exit can work without another physical BOOT cycle.
        command += ["--stub-version", "1"]
        if args.backup:
            command += ["--after", "no-reset-stub",
                        "read-flash", "0", "ALL", str(args.backup)]
        else:
            command += ["--after", "soft-reset", "flash-id"]
    else:
        command += ["--after", "no-reset", "--no-stub", "flash-id"]
    subprocess.run(command, check=True, timeout=300)


if __name__ == "__main__":
    main()
