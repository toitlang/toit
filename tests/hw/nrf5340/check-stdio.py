# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Reset a flashed stdio-nrf5340 image and exercise its USB-TTL input."""
import argparse
from contextlib import contextmanager
import importlib.util
from pathlib import Path
import re
import subprocess
import time

import serial

ROOT = Path(__file__).resolve().parents[3]


@contextmanager
def test_fixture(port):
    spec = importlib.util.spec_from_file_location("wiring", Path(__file__).with_name("check-wiring.py"))
    wiring = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wiring)
    fixture = wiring.Fixture(port)
    try:
        fixture.command("IDLE")
        yield fixture
    finally:
        try:
            fixture.command("IDLE")
        finally:
            fixture.serial.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Identified nRF USB-TTL persistent path")
    parser.add_argument("--esp-serial", required=True, help="Identified ESP32 wired fixture")
    parser.add_argument("--log-dir", type=Path, required=True)
    args = parser.parse_args()
    args.log_dir.mkdir(parents=True, exist_ok=True)
    requests = set()
    passes = set()
    shared_ready = set()
    shared_values = {}
    overflow = False
    passed = False
    teardown = False
    uart_passed = False
    with test_fixture(args.esp_serial) as fixture, serial.Serial(None, 115200, timeout=.2, write_timeout=5) as port:
        port.dtr = port.rts = False
        port.port = args.serial
        port.open()
        port.reset_input_buffer()
        with (args.log_dir / "reset.log").open("w") as log:
            subprocess.run([
                str(ROOT / ".cache/nrf5340/openocd/src/openocd"),
                "-s", str(ROOT / ".cache/nrf5340/openocd/tcl"),
                "-f", str(ROOT / "toolchains/nrf5340/openocd.cfg"),
                "-c", "reset run; shutdown",
            ], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=30)
        deadline = time.monotonic() + 60
        with (args.log_dir / "console.log").open("w") as log:
            while time.monotonic() < deadline:
                line = port.readline().decode(errors="replace").strip()
                if not line:
                    continue
                print(line, flush=True)
                log.write(line + "\n")
                log.flush()
                match = re.fullmatch(r"STDIN REQUEST (\S+) (\d+) (\d+)", line)
                if match:
                    label, size, seed = match.groups()
                    if label in requests:
                        raise RuntimeError(f"Repeated request: {label}")
                    requests.add(label)
                    port.write(bytes((i * 73 + int(seed)) & 255 for i in range(int(size))))
                    port.flush()
                match = re.fullmatch(r"STDIN DATA PASS (\S+)", line)
                if match:
                    passes.add(match[1])
                match = re.fullmatch(r"STDIN SHARED READY ([01])", line)
                if match:
                    shared_ready.add(int(match[1]))
                    if len(shared_ready) == 2:
                        port.write(bytes([17]))
                match = re.fullmatch(r"STDIN SHARED PASS ([01]) (\d+)", line)
                if match:
                    shared_values[int(match[1])] = int(match[2])
                    if len(shared_values) == 1:
                        # Reader buffering can consume more than a read-byte.
                        # Send the second byte only after the first was consumed.
                        port.write(bytes([29]))
                if line == "STDIN OVERFLOW READY":
                    port.write(bytes([0x55]) * 8192)
                    port.flush()
                if line == "STDIN UART OPEN":
                    fixture.command("UART_OPEN 32 33 115200 1")
                    port.write(bytes([0xac]))
                if line == "STDIN UART CLOSE":
                    fixture.command("UART_CLOSE")
                    port.write(bytes([0xad]))
                if line == "STDIN concurrent UART PASS":
                    uart_passed = True
                # The pinned newlib formats EOVERFLOW this way. Do not accept
                # another failure (such as a timeout) as overflow evidence.
                if line == "STDIN OVERFLOW PASS Value too large for defined data type":
                    overflow = True
                if line == "NRF5340 STDIN PASS":
                    passed = True
                if "VM teardown complete" in line:
                    teardown = True
                    break
    expected = {f"child-{i}" for i in range(16)}
    expected.update(f"binary-{n}" for n in [1, 255, 1023, 1024, 1025, 4095, 4096, 4097, 16385])
    expected.update(["after-cancel", "after-shared", "after-overflow", "binary-dual"])
    if not (requests == passes == expected and sorted(shared_values.values()) == [17, 29]
            and overflow and passed and teardown and uart_passed):
        raise SystemExit(f"STDIN verification failed: requests={len(requests)}, "
                         f"passes={len(passes)}, shared={shared_values}, "
                         f"overflow={overflow}, uart={uart_passed}, pass={passed}, teardown={teardown}")
    print(f"STDIN HOST PASS: {len(passes)} binary transfers, shared input, overflow and teardown")


if __name__ == "__main__":
    main()
