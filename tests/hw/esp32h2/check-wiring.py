#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Verify the documented rig using the C fixture on both boards (pyserial)."""

import argparse
import json
import time
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path

import serial

WIRES = {0: 12, 1: 14, 2: 27, 3: 26, 4: 32, 5: 35, 10: 13}


class Board:
    def __init__(self, port):
        self.serial = serial.Serial()
        self.serial.port = port
        self.serial.baudrate = 115200
        self.serial.timeout = 0.2
        self.serial.dtr = False
        self.serial.rts = False
        self.serial.open()

    def close(self):
        try:
            self.command("RESET")
        finally:
            self.serial.close()

    def command(self, command):
        self.serial.write((command + "\n").encode())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            line = self.serial.readline().decode(errors="replace").strip()
            if line.startswith("RIG "):
                if line == "RIG ERROR":
                    raise RuntimeError(f"{self.serial.port}: {command}: {line}")
                if line.startswith("RIG READY"):
                    continue
                return line
        raise TimeoutError(f"{self.serial.port}: {command}")

    def levels(self):
        reply = self.command("READ")
        assert reply.startswith("RIG READ "), reply
        return int(reply.split()[2], 16)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--h2-port", required=True)
    parser.add_argument("--helper-port", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = {"date": datetime.now(timezone.utc).isoformat(), "checks": []}
    failures = []

    def check(name, actual, expected):
        passed = actual == expected
        report["checks"].append(dict(name=name, actual=actual, expected=expected, passed=passed))
        print(f"{'PASS' if passed else 'FAIL'} {name}: {actual}", flush=True)
        if not passed:
            failures.append(f"{name}: expected {expected}, got {actual}")

    try:
        with ExitStack() as stack:
            h2 = Board(args.h2_port)
            stack.callback(h2.close)
            helper = Board(args.helper_port)
            stack.callback(helper.close)
            # Opening a bridge can reset it on some hosts, even with DTR/RTS off.
            time.sleep(1)
            h2.serial.reset_input_buffer()
            helper.serial.reset_input_buffer()
            report["h2"] = h2.command("INFO")
            report["helper"] = helper.command("INFO")
            print(report["h2"], report["helper"], sep="\n", flush=True)
            assert "INFO esp32h2 " in report["h2"]
            assert "INFO esp32 " in report["helper"]

            for reverse in (False, True):
                h2.command("RESET")
                helper.command("RESET")
                source, observer = (helper, h2) if reverse else (h2, helper)
                mapping = {v: k for k, v in WIRES.items()} if reverse else WIRES
                for pin in mapping.values():
                    observer.command(f"INPUT {pin} {0 if pin == 35 else 1}")
                for pin, peer in mapping.items():
                    if reverse and pin == 35:
                        continue
                    for level in (1, 0, 1):
                        source.command(f"OD {pin} {level}")
                        time.sleep(0.03)
                        levels = observer.levels()
                        observed = {str(p): (levels >> p) & 1 for p in mapping.values()
                                    if p != 35 or peer == 35}
                        expected = {str(p): level if p == peer else 1 for p in mapping.values()
                                    if p != 35 or peer == 35}
                        check(f"{'ESP32->H2' if reverse else 'H2->ESP32'} {pin}->{peer} OD={level}",
                              observed, expected)
                    source.command(f"INPUT {pin} 0")

            h2.command("RESET")
            helper.command("RESET")
            for pull, bias, expected in ((0, 0, 0), (0, 1, 1), (1, 0, 1), (2, 1, 0)):
                h2.command(f"INPUT 4 {pull}")
                helper.command(f"DRIVE 33 {bias}")
                time.sleep(0.1)
                check(f"resistor H2 GPIO4 pull={pull} helper GPIO33={bias}",
                      [(h2.levels() >> 4) & 1, (helper.levels() >> 32) & 1],
                      [expected, expected])
            report["passed"] = True
            if failures:
                raise AssertionError("; ".join(failures))
    except Exception as error:
        report["passed"] = False
        report["error"] = str(error)
        raise
    finally:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
