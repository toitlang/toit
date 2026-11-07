#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
"""Test the native uploader against a fragmented, rebooting PTY recovery peer."""
import argparse
import errno
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time
import zlib

ID = "50443405886E0B1C"


def case(binary, root, data, scenario):
    path = root / "port"
    master, slave = pty.openpty()
    path.symlink_to(os.ttyname(slave))
    image = root / "application.bin"
    image.write_bytes(data)
    command = [str(binary), "--port", str(path), "--id", ID, str(image)]
    if scenario in {"application", "silent-ack", "missing-ready"}:
        command.insert(1, "--verbose")
    if scenario == "explicit":
        command[1:1] = ["--version", "90"]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    buffer = bytearray()
    received = bytearray()
    pending = None
    committed = False
    rebooted = False
    recovery = scenario != "application"
    version = None
    deadline = time.monotonic() + (38 if scenario == "missing-ready" else 18)
    heartbeat = 0

    def send(line):
        encoded = (line + "\n").encode()
        # Split responses, including their CR/LF-independent framing.
        os.write(master, encoded[:3])
        os.write(master, encoded[3:])

    try:
        while process.poll() is None and time.monotonic() < deadline:
            configured = termios.tcgetattr(slave)[4] == termios.B1200
            if not recovery and configured:
                # Observe the actual termios control change. An application
                # must receive no text commands before it is reset.
                assert not select.select([master], [], [], 0)[0]
                os.close(master)
                os.close(slave)
                master, slave = pty.openpty()
                path.unlink()
                path.symlink_to(os.ttyname(slave))
                recovery = rebooted = True
                buffer.clear()
                continue
            if recovery and not committed and configured and time.monotonic() >= heartbeat:
                if scenario == "stale-ready" and heartbeat == 0:
                    # An earlier client may leave a READY in the device TX
                    # queue. It does not acknowledge this client's hello.
                    send(f"READY RP2040 1 983040 {ID}")
                send(f"RP2040-UPDATER 1 id={ID} app=52 size=300 crc=00000001")
                heartbeat = time.monotonic() + .1
            if committed and time.monotonic() >= heartbeat:
                identity = "0000000000000000" if scenario == "changed-id" else ID
                crc = zlib.crc32(data) ^ (1 if scenario == "wrong-crc" else 0)
                send(f"RP2040-UPDATER 1 id={identity} app={version} size={len(data)} crc={crc:08x}")
                heartbeat = time.monotonic() + .1
            readable, _, _ = select.select([master], [], [], .02)
            if not readable:
                continue
            try:
                buffer.extend(os.read(master, 8192))
            except OSError as error:
                if error.errno == errno.EIO:
                    continue
                raise
            while True:
                if pending:
                    offset, size, crc = pending
                    if len(buffer) < size:
                        break
                    block = buffer[:size]
                    del buffer[:size]
                    assert offset == len(received)
                    assert zlib.crc32(block) == crc
                    received.extend(block)
                    pending = None
                    if scenario == "bad-ack":
                        send(f"OK block {len(received) + 1}")
                    elif scenario == "device-error":
                        send("ERR flash")
                    elif scenario == "silent-ack":
                        # Keep sending heartbeats, but never acknowledge the
                        # block. Unrelated output must not extend its deadline.
                        pass
                    else:
                        send(f"OK block {len(received)}")
                    continue
                if b"\n" not in buffer:
                    break
                raw, _, remainder = buffer.partition(b"\n")
                buffer = bytearray(remainder)
                fields = raw.decode().strip().split()
                if not fields:
                    continue
                if fields == ["hello"]:
                    if recovery and scenario != "missing-ready":
                        family = "RP2350" if scenario == "wrong-protocol" else "RP2040"
                        send(f"READY {family} 1 983040 {ID}")
                        send(f"RP2040-UPDATER 1 id={ID} app=52 size=300 crc=00000001")
                elif fields[0] == "begin":
                    assert int(fields[1]) == len(data)
                    assert int(fields[2], 16) == zlib.crc32(data)
                    version = int(fields[3])
                    assert version == (90 if scenario == "explicit" else 53)
                    send("OK begin")
                elif fields[0] == "block":
                    pending = int(fields[1]), int(fields[2]), int(fields[3], 16)
                    send("READY block")
                elif fields == ["commit"]:
                    assert received == data
                    send("OK commit")
                    committed = True
                    heartbeat = time.monotonic() + .1
                else:
                    raise AssertionError(fields)
        stdout, stderr = process.communicate(timeout=2)
        failures = {"bad-ack": "expected 'OK block", "device-error": "ERR flash",
                    "changed-id": "board identity changed", "wrong-crc": "does not match",
                    "wrong-protocol": "unsupported recovery protocol",
                    "silent-ack": "timed out waiting for 'OK block 4096'",
                    "missing-ready": "recovery unavailable on the selected serial port"}
        if scenario in failures:
            assert process.returncode != 0, stdout
            assert failures[scenario] in stderr, stderr
        else:
            assert process.returncode == 0, stderr
            assert f"installed version {version}" in stdout, stdout
            assert committed and received == data
        if scenario == "application":
            assert rebooted
            stages = ["requesting recovery at 1200 baud", "received recovery heartbeat; sending hello",
                      "recovery identity verified", "begin acknowledged", "requesting block at offset 0",
                      "block written; waiting for acknowledgement", "all blocks acknowledged; sending commit",
                      "commit acknowledged; waiting for verified reboot",
                      "installed version, size and CRC verified after reboot"]
            positions = [stderr.index(stage) for stage in stages]
            assert positions == sorted(positions), stderr
        if scenario == "missing-ready":
            assert "recovery handshake timed out: heartbeat=yes ready=no" in stderr, stderr
            assert "sending begin" not in stderr and not received, stderr
        if scenario == "silent-ack":
            assert "block written; waiting for acknowledgement" in stderr, stderr
            assert "sending commit" not in stderr, stderr
        if scenario in {"bad-ack", "device-error", "wrong-protocol", "silent-ack", "missing-ready"}:
            assert not committed
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
        path.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    data = bytearray((i * 37 + 11) % 256 for i in range(10004))
    struct.pack_into("<II", data, 256, 0x20041000, 0x10020109)
    with tempfile.TemporaryDirectory(prefix="rp2040-uploader-") as directory:
        root = Path(directory)
        for scenario in ["ready", "explicit", "application", "bad-ack", "device-error",
                         "changed-id", "wrong-crc", "wrong-protocol", "silent-ack", "missing-ready",
                         "stale-ready"]:
            case(args.binary.resolve(), root, data, scenario)
        bad = root / "invalid.bin"
        bad.write_bytes(bytes(300))
        result = subprocess.run([str(args.binary.resolve()), "--port", "nonexistent", str(bad)],
                                capture_output=True, text=True)
        assert result.returncode != 0 and "vectors" in result.stderr
    print("PASS: native RP2040 uploader, reconnect, framing, CRC, identity and rejection tests")


if __name__ == "__main__":
    main()
