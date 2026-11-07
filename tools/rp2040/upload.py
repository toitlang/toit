#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Upload a staged RP2040 application through the persistent USB updater."""

import argparse
import pathlib
import struct
import time
import zlib

CAPACITY = 0xF0000
APP_ADDRESS = 0x10020000
SECTOR = 4096


def validate_image(data):
    if not 264 <= len(data) <= CAPACITY:
        raise ValueError("Image must be a raw RP2040 application binary, 264..983040 bytes")
    stack, entry = struct.unpack_from("<II", data, 256)
    if not (0x20000000 < stack <= 0x20042000 and stack % 8 == 0):
        raise ValueError("Invalid RP2040 initial stack pointer")
    if not (entry & 1 and APP_ADDRESS + 264 <= entry < APP_ADDRESS + len(data)):
        raise ValueError("Image must be linked for 0x10020000, not the normal flash origin")


class Console:
    def __init__(self, stream):
        self.stream = stream
        self.pending = bytearray()

    def command(self, text):
        self.stream.write((text + "\n").encode("ascii"))
        self.stream.flush()

    def line(self, deadline):
        while time.monotonic() < deadline:
            if b"\n" in self.pending:
                line, _, self.pending = self.pending.partition(b"\n")
                return line.decode("ascii", errors="replace").strip()
            # Wait for the first byte, then drain bytes already available.
            # Reading a fixed 256 bytes waits for the serial timeout on every
            # short ACK, needlessly delaying each uploaded block twice.
            available = getattr(self.stream, "in_waiting", 1)
            self.pending.extend(self.stream.read(max(1, min(256, available))))
            if len(self.pending) > 4096:
                raise RuntimeError("Overlong device response")
        raise TimeoutError("Timed out waiting for the RP2040 updater")

    def expect(self, expected, timeout=10):
        deadline = time.monotonic() + timeout
        while True:
            line = self.line(deadline)
            if line == expected:
                return
            if line.startswith("ERR "):
                raise RuntimeError(line)


def transfer(console, data, version):
    crc = zlib.crc32(data)
    console.command(f"begin {len(data)} {crc:08x} {version}")
    console.expect("OK begin")
    for offset in range(0, len(data), SECTOR):
        block = data[offset:offset + SECTOR]
        console.command(f"block {offset} {len(block)} {zlib.crc32(block):08x}")
        console.expect("READY block")
        console.stream.write(block)
        console.stream.flush()
        console.expect(f"OK block {offset + len(block)}")
    console.command("commit")
    console.expect("OK commit")


def connect(serial, port):
    return serial.Serial(port, 115200, timeout=0.1, write_timeout=5, exclusive=True)


def wait_ready(serial, port, expected_id, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        stream = None
        try:
            stream = connect(serial, port)
            console = Console(stream)
            attempt = min(deadline, time.monotonic() + 2)
            while True:
                line = console.line(attempt)
                if line.startswith("RP2040-UPDATER 1 "):
                    console.command("hello")
                parts = line.split()
                if len(parts) == 5 and parts[:4] == ["READY", "RP2040", "1", str(CAPACITY)]:
                    if expected_id and parts[4] != expected_id:
                        raise ValueError("Board identity changed")
                    return stream, console, parts[4]
        except (OSError, serial.SerialException, TimeoutError):
            pass
        except BaseException:
            if stream:
                stream.close()
            raise
        if stream:
            stream.close()
        time.sleep(0.1)
    raise TimeoutError("Updater unavailable; request USB recovery or use the matching board-specific recovery loader")


def wait_installed(serial, port, board_id, data, version, expected, timeout=45, verbose=False):
    deadline = time.monotonic() + timeout
    marker = (f"RP2040-UPDATER 1 id={board_id} app={version} "
              f"size={len(data)} crc={zlib.crc32(data):08x}")
    installed = False
    while time.monotonic() < deadline:
        try:
            with connect(serial, port) as stream:
                console = Console(stream)
                while True:
                    line = console.line(deadline)
                    if verbose:
                        print(line, flush=True)
                    if line == marker:
                        installed = True
                        if not expected:
                            return
                    if installed and expected and line == expected:
                        return
        except (OSError, serial.SerialException):
            time.sleep(0.1)
    raise TimeoutError("Update was committed, but installation/application startup was not verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="Observed /dev/serial/by-id/... link")
    parser.add_argument("--id", help="Expected Pico unique board ID")
    parser.add_argument("--version", required=True, type=int)
    parser.add_argument("--request-update", action="store_true", help="Ask the running probe to reboot to its updater")
    parser.add_argument("--expect", help="Exact application startup line; {id} expands to the board ID")
    parser.add_argument("--verbose", action="store_true", help="Print installation and application startup output")
    parser.add_argument("image", type=pathlib.Path)
    args = parser.parse_args()
    if not 0 <= args.version <= 0xFFFFFFFF:
        parser.error("version must fit in uint32")
    data = args.image.read_bytes()
    validate_image(data)
    import serial  # Only the hardware transport needs pyserial.
    if args.request_update:
        with connect(serial, args.port) as stream:
            stream.baudrate = 1200
    stream, console, board_id = wait_ready(serial, args.port, args.id)
    print(f"Uploading {len(data)} bytes to RP2040 {board_id}, version {args.version}", flush=True)
    with stream:
        transfer(console, data, args.version)
    expected = args.expect.replace("{id}", board_id) if args.expect else None
    wait_installed(serial, args.port, board_id, data, args.version, expected, verbose=args.verbose)
    print("PASS: installation verified" + ("; application startup verified" if expected else ""))


if __name__ == "__main__":
    main()
