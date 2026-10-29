# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
"""Run a paired test with GPIO acknowledgements between the nRF and ESP32."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("wiring_fixture", Path(__file__).with_name("check-wiring.py"))
wiring = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wiring)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--esp-serial", required=True)
    parser.add_argument("--nrf-serial", required=True)
    parser.add_argument("--image", type=Path, default=ROOT / "build/zephyr-nrf5340/zephyr/zephyr.bin")
    parser.add_argument("--log-dir", type=Path, default=ROOT / "build/nrf5340-gpio")
    parser.add_argument("--expect", default="NRF5340 GPIO PASS")
    parser.add_argument("--require-marker", action="append", default=[],
                        help="Additional console evidence required for success")
    parser.add_argument("--native", action="store_true", help="Run a native probe without VM teardown")
    parser.add_argument("--release-pin", type=int, default=13)
    parser.add_argument("--seconds", type=int, default=45)
    parser.add_argument("--allow-reboots", action="store_true",
                        help="Reset handshake sequence at VM boot; capture final teardown after PASS")
    parser.add_argument("--boot-marker", default="[toit] Zephyr VM starting")
    parser.add_argument("--expected-vm-error", action="append", type=int, default=[],
                        help="Intentional VM error codes, in order; each must occur before final PASS")
    parser.add_argument("--error-release-pin", action="append", type=int, default=[],
                        help="Fixture pins that must be released during error restart backoff")
    parser.add_argument("--wake-on", action="append", nargs=2, default=[],
                        metavar=("MARKER", "COMMAND"),
                        help="After a sleep marker, delay 500 ms then issue a fixture wake command")
    parser.add_argument("--sleep-release-pin", action="append", type=int, default=[],
                        help="Fixture pins that must be released before System ON/OFF sleep")
    parser.add_argument("--min-sleep-ms", type=int, default=0,
                        help="Minimum observed System ON sleep before a new boot")
    parser.add_argument("--cleanup-command", action="append", default=[],
                        help="Fixture command after target completion, before checking pin release")
    args = parser.parse_args()
    fixture = wiring.Fixture(args.esp_serial)
    child = None
    passed = False
    teardown = False
    expected_sequence = 1
    requests = 0
    boots = 0
    missing_markers = set(args.require_marker)
    expected_errors = list(args.expected_vm_error)
    error_pending = False
    restart_at = None
    wake_commands = list(args.wake_on)
    sleep_at = None
    try:
        fixture.command("IDLE")
        if args.allow_reboots:
            # Three fixture outputs retain the test phase across nRF resets.
            for pin in (13, 32, 33):
                fixture.command(f"CONFIG {pin} OUT 0")
        fixture.command("CONFIG 27 OUT 0")
        child = subprocess.Popen([
            sys.executable, "-u", str(ROOT / "tools/nrf5340/flash.py"), str(args.image),
            "--serial", args.nrf_serial, "--log-dir", str(args.log_dir),
            "--expect", args.expect, "--seconds", str(args.seconds),
            "--stop-after", args.expect if args.native else "VM teardown complete",
            *(["--stop-after-expected"] if args.allow_reboots else []),
        ], stdout=subprocess.PIPE, text=True)
        for line in child.stdout:
            print(line, end="", flush=True)
            missing_markers = {marker for marker in missing_markers if marker not in line}
            if "Zephyr boot program failed:" in line:
                raise RuntimeError("Target test raised an exception")
            if "[toit] System ON sleep for " in line:
                sleep_at = time.monotonic()
            if "[toit] System ON sleep for " in line or "[toit] System OFF wake-pin=" in line:
                for pin in args.sleep_release_pin:
                    fixture.command(f"CONFIG {pin} DOWN 0")
                if args.sleep_release_pin:
                    reply = fixture.command("READ", "READ")
                    values = dict(item.split("=") for item in reply.split()[2:])
                    if any(values[str(pin)] != "0" for pin in args.sleep_release_pin):
                        raise RuntimeError("VM teardown left a peripheral pin driven before sleep")
                    print("Sleep teardown released peripheral pins PASS", flush=True)
            if wake_commands and wake_commands[0][0] in line:
                _, command = wake_commands.pop(0)
                time.sleep(0.5)
                fixture.command(command)
                print(f"Wake command after 500 ms: {command}", flush=True)
            if "[toit] VM exited: reason=4 value=" in line:
                code = int(line.strip().rsplit("value=", 1)[1])
                if not expected_errors or code != expected_errors.pop(0):
                    raise RuntimeError(f"Unexpected target VM error: {code}")
                error_pending = True
            if "VM teardown complete" in line and error_pending:
                for pin in args.error_release_pin:
                    fixture.command(f"CONFIG {pin} DOWN 0")
                reply = fixture.command("READ", "READ")
                values = dict(item.split("=") for item in reply.split()[2:])
                if any(values[str(pin)] != "0" for pin in args.error_release_pin):
                    raise RuntimeError("VM error teardown left a peripheral pin driven")
                print("Error teardown released peripheral pins PASS", flush=True)
            if "[toit] restarting after VM error in 1000 ms" in line:
                if not error_pending:
                    raise RuntimeError("Restart without an expected VM error")
                restart_at = time.monotonic()
            if args.allow_reboots and args.boot_marker in line:
                if sleep_at is not None:
                    elapsed = time.monotonic() - sleep_at
                    if elapsed * 1000 < args.min_sleep_ms:
                        raise RuntimeError(f"Timed sleep was too short: {elapsed:.3f} s")
                    print(f"Timed sleep before reboot: {elapsed:.3f} s", flush=True)
                    sleep_at = None
                if error_pending:
                    if restart_at is None or time.monotonic() - restart_at < 0.7:
                        raise RuntimeError("Missing VM error restart backoff")
                    error_pending = False
                    restart_at = None
                boots += 1
                expected_sequence = 1
                teardown = False
                fixture.command("CONFIG 27 OUT 0")
            fields = line.strip().split()
            if fields[:2] == ["GPIO", "REQUEST"]:
                sequence = int(fields[2])
                if sequence != expected_sequence:
                    raise RuntimeError(f"Unexpected request sequence: {sequence}")
                expected_sequence += 1
                requests += 1
                command = fields[3:]
                if command[0] == "CHECK":
                    reply = fixture.command("READ", "READ")
                    values = dict(item.split("=") for item in reply.split()[2:])
                    if values[command[1]] != command[2]:
                        raise RuntimeError(f"GPIO mismatch: {command}, ESP reports {reply}")
                else:
                    fixture.command(" ".join(command))
                fixture.command(f"CONFIG 27 OUT {sequence & 1}")
            passed |= args.expect in line
            teardown |= "VM teardown complete" in line
        if child.wait() != 0 or not passed or (not args.native and not teardown):
            raise RuntimeError(f"Missing pass or teardown evidence for {args.expect}")
        if missing_markers:
            raise RuntimeError(f"Missing required console markers: {sorted(missing_markers)}")
        if expected_errors or error_pending:
            raise RuntimeError("Missing expected VM error or recovery boot")
        if wake_commands:
            raise RuntimeError("Missing expected power-off markers")
        if sleep_at is not None:
            raise RuntimeError("Timed sleep did not reboot")
        for command in args.cleanup_command:
            fixture.command(command)
        fixture.command(f"CONFIG {args.release_pin} DOWN 0")
        reply = fixture.command("READ", "READ")
        values = dict(item.split("=") for item in reply.split()[2:])
        if values[str(args.release_pin)] != "0":
            raise RuntimeError("Process teardown left the nRF GPIO output driving high")
        boot_summary = f", {boots} boots observed" if args.allow_reboots else ""
        print(f"Paired test PASS ({requests} fixture requests, output released{boot_summary})")
    finally:
        if child and child.poll() is None:
            # Let the target's bounded handshake time out and release its pins.
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=5)
        fixture.command("IDLE")
        fixture.serial.close()


if __name__ == "__main__":
    main()
