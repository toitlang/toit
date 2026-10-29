# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Run one nRF pairing qualification image against the Bluedroid security peer."""
import argparse
from pathlib import Path
import subprocess
import sys
import threading
import time

import serial

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--esp-serial", required=True)
    parser.add_argument("--nrf-serial", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--policy", choices=["ACCEPT", "REJECT", "NO_BOND", "LEGACY", "HOLD", "KEEP"], required=True,
                        help="KEEP preserves ESP bonds; all other policies clear them first")
    parser.add_argument("--adapter-speed", type=int, default=250)
    args = parser.parse_args()
    out = args.log_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    peer = serial.Serial(None, 115200, timeout=.2)
    peer.dtr = False
    peer.rts = False
    peer.port = args.esp_serial
    peer.open()
    stop = threading.Event()
    captured = []
    errors = []

    def read(log):
        try:
            while not stop.is_set():
                line = peer.readline().decode(errors="replace")
                if line:
                    log.write(line)
                    log.flush()
                    captured.append(line)
        except Exception as error:
            errors.append(error)

    def wait_for(expected, start=0):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if errors:
                raise errors[0]
            if expected in "".join(captured[start:]):
                return
            time.sleep(.05)
        raise RuntimeError("Missing peer acknowledgement: " + expected)

    def command(value, expected):
        start = len(captured)
        peer.write((value + "\n").encode())
        wait_for(expected, start)

    with (out / "peer.log").open("w") as log:
        thread = threading.Thread(target=read, args=(log,))
        thread.start()
        try:
            # USB control-line transitions can reset this ESP32 devkit.
            time.sleep(2)
            if args.policy != "KEEP":
                command("CLEAR", "SEC CLEARED")
                policy = ["ACCEPT", "REJECT", "NO_BOND", "LEGACY", "HOLD"].index(args.policy)
                command(args.policy, f"SEC MODE {policy}")
            command("STATUS", "SEC STATUS")
            before_test = len(captured)
            marker = "NRF5340 BLE PAIRING PASS"
            if args.policy == "HOLD":
                marker = "NRF5340 BLE PAIRING CANCELLATION PASS"
            elif args.policy in ("REJECT", "NO_BOND", "LEGACY"):
                marker = "NRF5340 BLE PAIRING REJECTION PASS"
            with (out / "run.log").open("w") as run_log:
                subprocess.run([
                    sys.executable, "-u", str(ROOT / "tools/nrf5340/flash.py"), str(args.image.resolve()),
                    "--serial", args.nrf_serial, "--adapter-speed", str(args.adapter_speed),
                    "--log-dir", str(out), "--expect", marker,
                    "--stop-after", "VM teardown complete", "--seconds", "90",
                ], stdout=run_log, stderr=subprocess.STDOUT, check=True, timeout=220)
            cycles = 3 if args.policy in ("REJECT", "NO_BOND", "LEGACY") else 4
            # The peer's disconnect callback can lag behind local VM teardown.
            wait_for(f"SEC DISCONNECT count={cycles} ", before_test)
            command("STATUS", "SEC STATUS")
            transcript = "".join(captured)
            if args.policy == "HOLD":
                assert transcript.count("SEC REQUEST held") == 4
                assert "bonds=0 connections=4 disconnections=4 auth=0" in transcript
            elif args.policy in ("ACCEPT", "KEEP"):
                assert transcript.count("SEC AUTH success=1 auth=0x09") == 4
                assert "bonds=1 connections=4 disconnections=4 auth=4" in transcript
            else:
                assert "bonds=0 connections=3 disconnections=3 auth=0" in transcript
            assert "VM teardown complete" in (out / "run.log").read_text()
            print(marker)
            print("Peer checks and VM teardown PASS")
        finally:
            stop.set()
            thread.join()
            peer.close()
    if errors:
        raise errors[0]


if __name__ == "__main__":
    main()
