# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.
"""Test the native probe's binary bridge against uart-peer-esp32.toit.

Requires the previously verified GP16->GPIO34 and GP17<-GPIO4 wiring.
Pass the Pico's persistent /dev/serial/by-id path as --port.
"""

import argparse
import time

import serial


def expect_line(stream, prefix, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = stream.readline()
        if line.startswith(prefix):
            return line
    raise RuntimeError(f"Timed out waiting for {prefix!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    args = parser.parse_args()
    with serial.Serial(args.port, 115200, timeout=0.2, exclusive=True) as stream:
        stream.reset_input_buffer()
        stream.write(b"uart-bridge 115200\n")
        print(expect_line(stream, b"BRIDGE READY", 3).decode().strip(), flush=True)
        for iteration in range(16):
            data = bytes((i * 37 + iteration * 13) & 255 for i in range(4096))
            stream.write(data)
            received = bytearray()
            deadline = time.monotonic() + 3
            while len(received) < len(data) and time.monotonic() < deadline:
                received.extend(stream.read(len(data) - len(received)))
            if received != data:
                raise RuntimeError(
                    f"Echo mismatch at iteration {iteration}: "
                    f"received {len(received)} bytes, prefix={received[:32].hex()}"
                )
        print("PASS: 16 x 4096-byte binary echo", flush=True)
        expect_line(stream, b"BRIDGE DONE", 18)
        stream.write(b"pins\n")
        expect_line(stream, b"PINS READY", 3)
        print("PASS: idle timeout restores the command console", flush=True)


if __name__ == "__main__":
    main()
