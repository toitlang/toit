# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Check the ESP32 fixture against nRF5340 registers through OpenOCD Tcl RPC.

Requires pyserial, wiring-esp32.toit on the ESP32, and wiring-swd.cfg running.
This is an electrical fixture check, not a test of Toit nRF peripheral drivers.
"""

import argparse
import json
from pathlib import Path
import re
import socket
import struct
import time

WIRES = [
    (name, int(port), int(pin), int(esp))
    for name, port, pin, esp in re.findall(
        r'^\s*\["([^"]+)", (\d+), (\d+), (\d+)\]',
        Path(__file__).with_name("wiring.toit").read_text(), re.M)
]
GPIO = [0x50842500, 0x50842800]
ADC = 0x5000E000
BUFFER = 0x2007FF00


class Debug:
    def __init__(self, port):
        self.socket = socket.create_connection(("127.0.0.1", port), timeout=5)

    def call(self, command):
        # Catch Tcl errors explicitly: an error can otherwise look like a result.
        wrapped = f'if {{[catch {{{command}}} result]}} {{format "ERROR %s" $result}} else {{set result}}'
        self.socket.sendall(wrapped.encode() + b"\x1a")
        reply = b""
        while not reply.endswith(b"\x1a"):
            chunk = self.socket.recv(65536)
            if not chunk:
                raise RuntimeError("OpenOCD disconnected")
            reply += chunk
        result = reply[:-1].decode().strip()
        if result.startswith("ERROR"):
            raise RuntimeError(f"{command}: {result}")
        return result

    def read(self, address, count=1):
        values = self.call(f"nrf53.cpuapp read_memory {address:#x} 32 {count}")
        return [int(v, 0) for v in values.split()]

    def write(self, address, value):
        self.call(f"nrf53.cpuapp write_memory {address:#x} 32 {{{value:#x}}}")

    def wait(self, offset):
        deadline = time.monotonic() + 3
        while not self.read(ADC + offset)[0]:
            if time.monotonic() > deadline:
                raise RuntimeError(f"SAADC event {offset:#x} timed out")
            time.sleep(.01)


class Fixture:
    def __init__(self, port):
        import serial
        self.serial = serial.Serial(None, 115200, timeout=.2, write_timeout=2)
        self.serial.dtr = False
        self.serial.rts = False
        self.serial.port = port
        self.serial.open()
        time.sleep(2)
        self.command("PING", "READY")

    def command(self, command, expected="OK"):
        self.serial.reset_input_buffer()
        self.serial.write((command + "\n").encode())
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            line = self.serial.readline().decode(errors="replace").strip()
            if line.startswith("RIG PWM_"):
                print(line, flush=True)
            elif line and not line.startswith("RIG "):
                print(f"ESP32: {line}", flush=True)
            if line.startswith("RIG ERROR"):
                raise RuntimeError(line)
            if line.startswith("RIG " + expected):
                return line
        raise RuntimeError(f"ESP32 timed out: {command}")


def check_digital(debug, fixture, report):
    maximum = (1 << len(WIRES)) - 1
    patterns = [0, maximum]
    patterns += [1 << i for i in range(len(WIRES))]
    patterns += [maximum ^ (1 << i) for i in range(len(WIRES))]
    for direction in ["ESP32 -> nRF", "nRF -> ESP32"]:
        failures = []
        fixture.command("IDLE")
        for mask in patterns:
            for index, (_, port, pin, _) in enumerate(WIRES):
                pull = 0 if direction.startswith("ESP") else (12 if mask & (1 << index) else 4)
                debug.write(GPIO[port] + 0x200 + pin * 4, pull)
            if direction.startswith("ESP"):
                fixture.command(f"PATTERN {mask}")
            time.sleep(.03)
            if direction.startswith("ESP"):
                inputs = [debug.read(base + 0x10)[0] for base in GPIO]
                observed = sum(((inputs[p] >> n) & 1) << i for i, (_, p, n, _) in enumerate(WIRES))
            else:
                response = fixture.command("READ", "READ")
                values = dict((int(a), int(b)) for a, b in re.findall(r"(\d+)=(\d)", response))
                observed = sum(values[esp] << i for i, (_, _, _, esp) in enumerate(WIRES))
            if observed != mask:
                wrong = [name for i, (name, *_) in enumerate(WIRES) if (observed ^ mask) & (1 << i)]
                failures.append({"expected": mask, "observed": observed, "wires": wrong})
        report[direction] = {"patterns": len(patterns), "failures": failures}
        print(f"{direction}: {len(patterns) - len(failures)}/{len(patterns)} patterns passed", flush=True)
        for failure in failures:
            print("  " + json.dumps(failure), flush=True)
    fixture.command("IDLE")
    return not any(result["failures"] for result in report.values())


def check_adc(debug, fixture, report):
    if debug.read(ADC + 0x500)[0] or debug.read(ADC + 0x400)[0]:
        raise RuntimeError("SAADC already active; cannot borrow it for this test")
    # Preserve configuration, event flags, DMA scratch word, and DPPI routing.
    offsets = list(range(0x80, 0x90, 4)) + list(range(0x100, 0x158, 4))
    offsets += list(range(0x180, 0x1D8, 4)) + [0x300, 0x500]
    offsets += list(range(0x510, 0x590, 4)) + [0x5F0, 0x5F4, 0x5F8, 0x62C, 0x630]
    saved = {offset: debug.read(ADC + offset)[0] for offset in offsets}
    scratch = debug.read(BUFFER)[0]
    results = []
    try:
        for _, port, pin, _ in WIRES:
            debug.write(GPIO[port] + 0x200 + pin * 4, 2)  # Input buffer disconnected.
        for offset in list(range(0x80, 0x90, 4)) + list(range(0x180, 0x1D8, 4)) + [0x300]:
            debug.write(ADC + offset, 0)
        for channel in range(8):
            base = ADC + 0x510 + 16 * channel
            debug.write(base, channel + 1 if channel < 2 else 0)
            debug.write(base + 4, 0)
            debug.write(base + 8, 5 << 16)  # 40 us, gain 1/6, internal 0.6 V.
        for offset, value in [(0x5F0, 2), (0x5F4, 0), (0x5F8, 0),
                              (0x62C, BUFFER), (0x630, 2), (0x500, 1)]:
            debug.write(ADC + offset, value)
        debug.write(ADC + 0x110, 0)
        debug.write(ADC + 0x0C, 1)
        debug.wait(0x110)
        for first in [0, 500, 1000, 1500, 2000, 2500, 3000]:
            requested = [first, 3000 - first]
            fixture.command(f"DAC {requested[0]} {requested[1]}")
            time.sleep(.05)
            for offset in [0x100, 0x104, 0x114]:
                debug.write(ADC + offset, 0)
            debug.write(ADC, 1)
            debug.wait(0x100)
            debug.write(ADC + 4, 1)
            debug.wait(0x104)
            if debug.read(ADC + 0x634)[0] != 2:
                raise RuntimeError("Unexpected SAADC sample count")
            raw = struct.unpack("<hh", struct.pack("<I", debug.read(BUFFER)[0]))
            measured = [round(value * 3600 / 4096, 1) for value in raw]
            passed = all(abs(a - b) <= 200 for a, b in zip(requested, measured))
            results.append({"requested_mV": requested, "measured_mV": measured, "passed": passed})
            print(f"DAC {requested} mV -> ADC {measured} mV: {'PASS' if passed else 'FAIL'}", flush=True)
            debug.write(ADC + 8, 1)
            debug.wait(0x114)
    finally:
        fixture.command("IDLE")
        debug.write(ADC + 8, 1)
        debug.write(ADC + 0x500, 0)
        for offset, value in saved.items():
            debug.write(ADC + offset, value)
        debug.write(BUFFER, scratch)
    report["ADC"] = results
    return all(result["passed"] for result in results)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="Identified ESP32 /dev/serial/by-id path")
    parser.add_argument("--tcl-port", type=int, default=16666)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    report = {}
    fixture = Fixture(args.serial)
    debug = Debug(args.tcl_port)
    state = debug.call("nrf53.cpuapp curstate")
    saved = {}
    passed = False
    try:
        debug.call("halt")
        debug.call("wait_halt 2000")
        for _, port, pin, _ in WIRES:
            address = GPIO[port] + 0x200 + pin * 4
            saved[address] = debug.read(address)[0]
        passed = check_digital(debug, fixture, report)
        if passed:
            passed = check_adc(debug, fixture, report)
        else:
            report["ADC"] = "Skipped: correct digital continuity before driving DAC outputs"
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        try:
            fixture.command("IDLE")
        finally:
            for address, value in saved.items():
                debug.write(address, value)
            if state == "running":
                debug.call("resume")
            fixture.serial.close()
            debug.socket.close()
            args.report.write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
