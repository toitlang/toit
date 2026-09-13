#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

"""Relay framed EC618 UART1 control messages to an ESP32 target console.

Run bus-control-esp32.toit on the classic ESP32, flash an envelope containing
bus-target-s3.toit to the S3, and start this coordinator before running
bus-controller-ec618.toit with the EC618 tester. Ports and host addresses are
explicit arguments because USB enumeration and network addresses can change.
"""

import argparse
import binascii
import socket
import time

import serial


def receive_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        data = connection.recv(size - len(result))
        if not data:
            raise EOFError("control bridge disconnected")
        result.extend(data)
    return bytes(result)


def receive_frame(connection):
    marker = b""
    while marker != b"\xa5\x5a":
        marker = (marker + receive_exact(connection, 1))[-2:]
    size = receive_exact(connection, 1)
    payload = receive_exact(connection, size[0])
    checksum = receive_exact(connection, 2)
    if binascii.crc_hqx(size + payload, 0) != int.from_bytes(checksum, "big"):
        raise ValueError("control checksum mismatch")
    return payload


def send_frame(connection, payload):
    checked = bytes([len(payload)]) + payload
    connection.sendall(b"\xa5\x5a" + checked + binascii.crc_hqx(checked, 0).to_bytes(2, "big"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", required=True)
    parser.add_argument("--bridge-port", type=int, default=18561)
    parser.add_argument("--target-port", "--s3-port", dest="target_port", required=True)
    args = parser.parse_args()
    target = serial.Serial()
    target.port = args.target_port
    target.baudrate = 115200
    target.timeout = 0.2
    target.dtr = False
    target.rts = False
    target.open()
    # Opening some USB-UART bridges resets the S3. Wait for the booted
    # fixture, rather than consuming its ROM banner as a protocol reply.
    deadline = time.monotonic() + 15
    next_ping = 0
    while time.monotonic() < deadline:
        if time.monotonic() >= next_ping:
            target.write(b"PING\n")
            next_ping = time.monotonic() + 1
        if target.readline().strip() == b"BUS-REPLY READY":
            break
    else:
        target.close()
        raise TimeoutError("target fixture did not boot")
    with target, socket.create_connection((args.bridge, args.bridge_port), timeout=180) as bridge:
        print("Coordinator ready", flush=True)
        while True:
            command = receive_frame(bridge)
            print("EC618 -> target:", command.decode(), flush=True)
            target.write(command + b"\n")
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                line = target.readline().strip()
                if not line:
                    continue
                print("Target:", line.decode(errors="replace"), flush=True)
                if line.startswith(b"BUS-REPLY "):
                    reply = line.removeprefix(b"BUS-REPLY ")
                    send_frame(bridge, reply)
                    break
            else:
                raise TimeoutError(f"target did not reply to {command!r}")
            if command == b"QUIT":
                return


if __name__ == "__main__":
    main()
