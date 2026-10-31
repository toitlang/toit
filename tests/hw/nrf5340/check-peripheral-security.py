# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Coordinate an nRF secure GATT server with the independent ESP32 central."""
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
    parser.add_argument("--policy", choices=["BOND", "NO_BOND", "KEEP", "DISABLED"], default="BOND")
    parser.add_argument("--notifications", action="store_true",
                        help="Test per-mode notification security (requires NO_BOND)")
    args = parser.parse_args()
    if args.notifications and args.policy != "NO_BOND":
        parser.error("--notifications requires --policy NO_BOND")
    suite = "NOTIFY SECURITY" if args.notifications else "SERVER SECURITY"
    out = args.log_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    peer = serial.Serial(None, 115200, timeout=.2)
    peer.dtr = False
    peer.rts = False
    peer.port = args.esp_serial
    peer.open()
    stop = threading.Event()
    peer_lines, nrf_lines, errors = [], [], []

    def read_peer(log):
        try:
            while not stop.is_set():
                line = peer.readline().decode(errors="replace")
                if line:
                    log.write(line)
                    log.flush()
                    peer_lines.append(line)
        except Exception as error:
            errors.append(error)

    def wait(lines, marker, start=0, seconds=20):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if errors:
                raise errors[0]
            if marker in "".join(lines[start:]):
                return
            time.sleep(.05)
        raise RuntimeError("Missing marker: " + marker)

    def command(value, marker):
        start = len(peer_lines)
        peer.write((value + "\n").encode())
        wait(peer_lines, marker, start)

    def read_nrf(process, log):
        for line in process.stdout:
            log.write(line)
            log.flush()
            nrf_lines.append(line)

    process = None
    nrf_thread = None
    with (out / "peer.log").open("w") as peer_log, (out / "run.log").open("w") as nrf_log:
        thread = threading.Thread(target=read_peer, args=(peer_log,))
        thread.start()
        try:
            time.sleep(2)
            if args.policy != "KEEP":
                command("CLEAR", "CEN CLEARED")
                policy = "BOND" if args.policy == "DISABLED" else args.policy
                command(policy, "CEN MODE " + policy)
            command("STATUS", "CEN STATUS")
            process = subprocess.Popen([
                sys.executable, "-u", str(ROOT / "tools/nrf5340/flash.py"), str(args.image.resolve()),
                "--serial", args.nrf_serial, "--adapter-speed", "250", "--log-dir", str(out),
                "--expect", f"NRF5340 BLE {suite} PASS", "--stop-after", "VM teardown complete",
                "--seconds", "200",
            ], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            nrf_thread = threading.Thread(target=read_nrf, args=(process, nrf_log))
            nrf_thread.start()
            for cycle in range(4):
                wait(nrf_lines, f"NRF5340 BLE {suite} READY cycle={cycle}", seconds=150 if not cycle else 20)
                if args.policy == "DISABLED":
                    command("RUN_REJECT", f"CEN REJECT PASS connections={2 * (cycle + 1)} ")
                else:
                    command("RUN_NOTIFY" if args.notifications else "RUN", f"CEN PASS connections={cycle + 1} ")
            assert process.wait(timeout=20) == 0
            nrf_thread.join()
            command("STATUS", "CEN STATUS")
            transcript = "".join(peer_lines)
            if args.policy == "DISABLED":
                assert "bonds=0 connections=8 disconnections=8 auth=0" in transcript
            else:
                bonds = 0 if args.policy == "NO_BOND" else 1
                assert f"bonds={bonds} connections=4 disconnections=4 auth=4" in transcript
                if args.policy == "NO_BOND":
                    assert transcript.count("CEN AUTH success=1 mode=0x08") == 4
                    assert transcript.count("CEN KEY type=0x01") == 4
                    assert transcript.count("CEN VOLATILE PEER CLEARED") == 4
            assert f"NRF5340 BLE {suite} PASS" in "".join(nrf_lines)
            assert "VM teardown complete" in "".join(nrf_lines)
            if args.notifications:
                assert transcript.count("CEN NOTIFY PLAINTEXT PASS") == 4
                assert transcript.count("CEN NOTIFY REJECT index=") == 16
                for step in range(6):
                    assert transcript.count(f"CEN NOTIFY step={step} ") == 4
            if args.policy == "KEEP":
                assert "initial bonds=1 cycle=0" in "".join(nrf_lines)
                assert "bonds=1 connections=4 disconnections=4 auth=4 keys=0" in transcript
            if args.policy == "DISABLED":
                print("NRF5340 BLE PAIRING DISABLED PASS: four refusals, plaintext recovery, VM teardown")
            elif args.notifications:
                print("NRF5340 BLE NOTIFY SECURITY PASS: plaintext and encrypted modes, four lifetimes, VM teardown")
            else:
                print("NRF5340 BLE SERVER SECURITY PASS: encrypted reads/writes, peer checks, VM teardown")
        finally:
            # Let the bounded flash operation finish rather than orphaning
            # OpenOCD on a host-side test error. Afterwards it only monitors.
            if process and process.poll() is None:
                try:
                    process.wait(timeout=140)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=5)
            if nrf_thread:
                nrf_thread.join()
            stop.set()
            thread.join()
            peer.close()
    if errors:
        raise errors[0]


if __name__ == "__main__":
    main()
