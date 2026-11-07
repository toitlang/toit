#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Map the rig using only Pico input pulls and an input-only ESP32 observer."""
import argparse
import json
import time
import serial

ESP_PINS = [4, 13, 14, 16, 17, 18, 19, 21, 22, 23, 25, 26, 27, 32, 33, 34, 35]
EXPECTED = {16: 34, 4: 19, 5: 27, 6: 18, 7: 23, 8: 13,
            9: 14, 10: 32, 11: 33, 22: 22, 26: 25, 27: 26, 21: 35}


def reply(stream, command, prefix):
    stream.write((command + "\n").encode())
    stream.flush()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        line = stream.readline().decode(errors="replace").strip()
        if line.startswith(prefix):
            return line
    raise TimeoutError(f"No reply to {command}")


def samples(log, duration):
    values = []
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        line = log.readline()
        if line.startswith("WIRE-ESP "):
            try:
                values.append(int(line.split()[1]))
            except ValueError:
                pass
        if not line:
            time.sleep(0.005)
    if len(values) < 3:
        raise RuntimeError("ESP32 observer stopped or insufficient samples")
    return values


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--port", required=True)
    p.add_argument("--esp-log", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--board", choices=["pico_w_2023", "pico_w"], default="pico_w_2023")
    args = p.parse_args()
    pins = list(range(2 if args.board == "pico_w_2023" else 0, 23)) + [26, 27, 28]
    expected_map = dict(EXPECTED)
    expected_map[17 if args.board == "pico_w_2023" else 1] = 4
    report = {"method": "input-only; Pico internal pull resistors", "pins": {},
              "board": args.board, "run_tested": False, "pass": True}
    with open(args.esp_log) as log, serial.Serial(args.port, 115200, timeout=0.1, exclusive=True) as stream:
        reply(stream, "pins", "PINS READY")
        log.seek(0, 2)
        samples(log, 0.3)
        try:
            for pin in pins:
                phases = []
                local_levels = []
                for pull in [2, 1, 2, 1]:
                    response = reply(stream, f"pull {pin} {pull}", f"PULL {pin} {pull} ")
                    local_levels.append(int(response.split()[3]))
                    # Discard records captured before the resistor settled.
                    time.sleep(0.1)
                    log.seek(0, 2)
                    phases.append(samples(log, 0.25))
                matches = []
                for esp in ESP_PINS:
                    if all(all(((sample >> esp) & 1) == level for sample in phase)
                           for phase, level in zip(phases, [0, 1, 0, 1])):
                        matches.append(esp)
                expected = [expected_map[pin]] if pin in expected_map else []
                passed = matches == expected and (pin not in expected_map or local_levels == [0, 1, 0, 1])
                report["pins"][pin] = {"expected": expected, "observed": matches,
                                        "pico_levels": local_levels, "samples": phases,
                                        "pass": passed}
                report["pass"] &= passed
                print(f"GP{pin}: expected ESP{expected}, observed ESP{matches}: {'PASS' if passed else 'FAIL'}", flush=True)
        finally:
            reply(stream, "pins", "PINS READY")
            with open(args.output, "w") as output:
                json.dump(report, output, indent=2)
                output.write("\n")
    if not report["pass"]:
        raise SystemExit(1)
    print("PASS: all 14 signal wires; RUN not yet tested")


if __name__ == "__main__":
    main()
