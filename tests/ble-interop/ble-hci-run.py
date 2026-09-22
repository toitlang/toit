#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Run a command with one authorized Linux adapter reserved for HCI user access."""

import argparse
import fcntl
import os
import re
import signal
import stat
import subprocess
import time
from contextlib import contextmanager


@contextmanager
def adapter_lock(path):
    # Read-only flock works on Linux and never truncates a pre-existing file.
    # Open existing files without O_CREAT so a root launch can reuse the lock
    # left by an unprivileged attempt under Linux's protected_regular policy.
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK
    try:
        fd = os.open(path, flags)
    except FileNotFoundError:
        try:
            fd = os.open(path, flags | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            fd = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError("Adapter lock is not a regular file")
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        os.close(fd)


def info(index, expected_address):
    result = subprocess.run(
        ["btmgmt", "--index", str(index), "info"],
        check=True, capture_output=True, text=True, timeout=10,
    ).stdout
    address = re.search(r"\baddr ([0-9A-F:]{17})\b", result, re.IGNORECASE)
    settings = re.search(r"current settings:([^\n]*)", result)
    if not address or address.group(1).lower() != expected_address.lower() or not settings:
        raise RuntimeError(f"Adapter identity mismatch or unavailable: {result.strip()}")
    return "powered" in settings.group(1).split()


def power(index, enabled, sudo=False, bluez=False):
    command = ["/usr/bin/btmgmt", "--index", str(index), "power", "on" if enabled else "off"]
    if bluez:
        command = ["busctl", "--system", "set-property", "org.bluez", f"/org/bluez/hci{index}",
                   "org.bluez.Adapter1", "Powered", "b", "true" if enabled else "false"]
    elif sudo:
        command = ["sudo", "-n"] + command
    subprocess.run(
        command,
        check=True, timeout=10,
    )


def restore_power(index, address, enabled, sudo=False, bluez=False):
    # Closing a user-channel socket can leave controller teardown in progress.
    # btmgmt may report Busy with exit status zero; verify the actual state.
    deadline = time.monotonic() + 5
    while info(index, address) != enabled:
        try:
            power(index, enabled, sudo, bluez)
        except subprocess.CalledProcessError:
            # BlueZ may not have recreated Adapter1 yet after user-channel close.
            if not bluez or time.monotonic() >= deadline:
                raise
        if info(index, address) == enabled:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("Adapter state restoration failed")
        time.sleep(0.2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", type=int, required=True)
    parser.add_argument("--address", required=True, help="Expected controller address")
    power_options = parser.add_mutually_exclusive_group()
    power_options.add_argument("--sudo-power", action="store_true",
                        help="Use noninteractive sudo only for adapter power changes")
    power_options.add_argument("--bluez-power", action="store_true",
                               help="Set adapter power through the caller's BlueZ D-Bus access")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command or args.adapter < 0:
        parser.error("Provide an adapter index and a command after --")
    if not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", args.address):
        parser.error("Invalid Bluetooth address")

    def terminate(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    lock_name = f"/tmp/toit-hci-{args.address.replace(':', '').lower()}.lock"
    with adapter_lock(lock_name):
        powered = info(args.adapter, args.address)
        try:
            if powered:
                power(args.adapter, False, args.sudo_power, args.bluez_power)
            if info(args.adapter, args.address):
                raise RuntimeError("Adapter did not power down")
            code = subprocess.run(command, check=False).returncode
            if code:
                # Capture state before restoration changes it. Preserve the
                # child's failure even if the diagnostic query also fails.
                try:
                    current = info(args.adapter, args.address)
                    print(f"HCI runner: child exited {code}; powered before restoration={current}", flush=True)
                except Exception as error:
                    print(f"HCI runner: child exited {code}; state query failed: {error}", flush=True)
            return code
        finally:
            # Only restore this controller; never stop the global BlueZ service.
            restore_power(args.adapter, args.address, powered, args.sudo_power, args.bluez_power)


if __name__ == "__main__":
    raise SystemExit(main())
