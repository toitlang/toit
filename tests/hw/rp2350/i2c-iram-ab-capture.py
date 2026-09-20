#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.
"""Activate a staged RP2350 image and incrementally capture both rig consoles."""

import argparse
import pathlib
import time

import serial


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rp-port", required=True)
    parser.add_argument("--esp-port", required=True)
    parser.add_argument("--rp-log", required=True, type=pathlib.Path)
    parser.add_argument("--esp-log", required=True, type=pathlib.Path)
    parser.add_argument("--seconds", type=float, default=120)
    parser.add_argument("--rp-complete", default="i2c-jaguar-isr-diagnostic: complete")
    parser.add_argument("--esp-complete", default="i2c-target-esp32: complete")
    return parser.parse_args()


def main():
    args = arguments()
    # Exclusive creation protects the first failure capture from an accidental
    # rerun with the same file names.
    with args.rp_log.open("x", encoding="utf-8") as rp_log, \
         args.esp_log.open("x", encoding="utf-8") as esp_log:
        start = time.monotonic()
        streams = {
            "RP": serial.Serial(args.rp_port, 115_200, timeout=0),
            "ESP": serial.Serial(args.esp_port, 115_200, timeout=0),
        }
        logs = {"RP": rp_log, "ESP": esp_log}
        ports = {"RP": args.rp_port, "ESP": args.esp_port}
        pending = {"RP": "", "ESP": ""}
        complete = {"RP": False, "ESP": False}
        reopen_at = {"RP": 0.0, "ESP": 0.0}
        next_info = start + 3
        completed_at = None

        def emit(name, message):
            elapsed = time.monotonic() - start
            line = f"[{elapsed:8.3f}s] {message}"
            print(f"{name}: {line}", flush=True)
            logs[name].write(line + "\n")
            logs[name].flush()
            if name == "RP" and args.rp_complete in message:
                complete[name] = True
            if name == "ESP" and args.esp_complete in message:
                complete[name] = True

        try:
            # Both consoles are open before activation, so no first transaction
            # can precede its corresponding capture.
            streams["RP"].write(b"TOIT-OTA REBOOT\n")
            streams["RP"].flush()
            emit("RP", "capture sent TOIT-OTA REBOOT")
            deadline = start + args.seconds
            while time.monotonic() < deadline:
                now = time.monotonic()
                for name in ("RP", "ESP"):
                    stream = streams[name]
                    if stream is None:
                        if now < reopen_at[name]:
                            continue
                        try:
                            streams[name] = serial.Serial(
                                ports[name], 115_200, timeout=0)
                            emit(name, "capture reopened serial port")
                        except (OSError, serial.SerialException):
                            reopen_at[name] = now + 0.1
                        continue
                    try:
                        data = stream.read(4096)
                    except (OSError, serial.SerialException):
                        if pending[name]:
                            emit(name, pending[name])
                            pending[name] = ""
                        stream.close()
                        streams[name] = None
                        reopen_at[name] = now + 0.1
                        emit(name, "capture observed serial disconnect")
                        continue
                    if not data:
                        continue
                    pending[name] += data.decode(errors="replace")
                    while "\n" in pending[name]:
                        line, pending[name] = pending[name].split("\n", 1)
                        emit(name, line.rstrip("\r"))

                rp = streams["RP"]
                if rp is not None and now >= next_info:
                    try:
                        rp.write(b"TOIT-OTA INFO\n")
                        rp.flush()
                        next_info = now + 2
                    except (OSError, serial.SerialException):
                        rp.close()
                        streams["RP"] = None
                        reopen_at["RP"] = now + 0.1

                if all(complete.values()):
                    if completed_at is None:
                        completed_at = now
                    elif now - completed_at >= 2:
                        return 0
                time.sleep(0.01)
            emit("RP", "capture timed out before both completion markers")
            return 1
        finally:
            for name, stream in streams.items():
                if pending[name]:
                    emit(name, pending[name])
                if stream is not None:
                    stream.close()


if __name__ == "__main__":
    raise SystemExit(main())
