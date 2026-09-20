#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

"""Destructive-to-the-inactive-slot RP2350 OTA rejection tests.

The running image is never rebooted or replaced.  Every upload is malformed,
and the console INFO command verifies that the confirmed boot partition remains
active after each rejection.
"""

import argparse
import dataclasses
import hashlib
import pathlib
import struct
import sys
import time
from typing import List, Optional, Tuple, Union

import serial


CHUNK_SIZE = 4096
CONTROL_TIMEOUT = 5.0
TRANSFER_TIMEOUT = 60.0
COMMIT_TIMEOUT = 30.0
MAXIMUM_LINE_LENGTH = 1024

BLOCK_MARKER_START = 0xFFFFDED3
BLOCK_MARKER_END = 0xAB123579
BLOCK_ITEM_LAST = 0xFF
IMAGE_TYPE_TBYB = 0x90210142
TBYB_FLAG = 0x80000000


class TestFailure(Exception):
    pass


@dataclasses.dataclass(frozen=True)
class DeviceInfo:
    partition: int
    trial: bool
    slot_size: int


@dataclasses.dataclass(frozen=True)
class ImageInfo:
    terminal: int
    block_hash_size: int
    digest_offset: int
    ranges: Tuple[Tuple[int, int], ...]


def remaining(deadline: float) -> float:
    result = deadline - time.monotonic()
    if result <= 0:
        raise TimeoutError("deadline expired")
    return result


def word_at(image: Union[bytes, bytearray], offset: int) -> int:
    if offset < 0 or offset + 4 > len(image):
        raise TestFailure(f"image word at {offset} is out of bounds")
    return struct.unpack_from("<I", image, offset)[0]


def signed_word_at(image: Union[bytes, bytearray], offset: int) -> int:
    if offset < 0 or offset + 4 > len(image):
        raise TestFailure(f"image word at {offset} is out of bounds")
    return struct.unpack_from("<i", image, offset)[0]


def item_words(header: int) -> int:
    tag = header & 0xFF
    return (header >> 8) & (0xFFFF if tag & 0x80 else 0xFF)


def find_block_end_and_link(image: bytes, start: int) -> Tuple[int, int]:
    if word_at(image, start) != BLOCK_MARKER_START:
        raise TestFailure(f"missing block marker at {start}")
    at = start + 8
    while at + 12 <= len(image) and at - start < 1024:
        header = word_at(image, at)
        tag = header & 0xFF
        words = item_words(header)
        if tag == BLOCK_ITEM_LAST:
            if words != (at - start - 4) // 4:
                raise TestFailure("malformed LAST item length")
            if word_at(image, at + 8) != BLOCK_MARKER_END:
                raise TestFailure("malformed block end marker")
            return at + 12, start + signed_word_at(image, at + 4)
        if words == 0 or at + 4 * words > len(image):
            raise TestFailure("malformed image-definition item")
        at += 4 * words
    raise TestFailure("image-definition block has no LAST item")


def inspect_image(image: bytes) -> ImageInfo:
    if len(image) < CHUNK_SIZE or len(image) % 4 != 0:
        raise TestFailure("image must be at least 4096 bytes and word aligned")
    roots = [
        offset
        for offset in range(0, CHUNK_SIZE, 4)
        if word_at(image, offset) == BLOCK_MARKER_START
    ]
    if len(roots) != 1:
        raise TestFailure(f"expected one root block marker, found {len(roots)}")
    root = roots[0]
    if word_at(image, root + 4) != IMAGE_TYPE_TBYB:
        raise TestFailure("root image definition is not Arm Secure TBYB")
    _, terminal = find_block_end_and_link(image, root)
    if terminal < CHUNK_SIZE or terminal >= len(image):
        raise TestFailure(f"root link points outside the terminal area: {terminal}")
    if word_at(image, terminal) != BLOCK_MARKER_START:
        raise TestFailure("root link does not point to a terminal block")
    if word_at(image, terminal + 4) != IMAGE_TYPE_TBYB:
        raise TestFailure("terminal image definition is not Arm Secure TBYB")

    ranges: Optional[List[Tuple[int, int]]] = None
    block_hash_size: Optional[int] = None
    digest_offset: Optional[int] = None
    at = terminal + 8
    while at + 12 <= len(image):
        header = word_at(image, at)
        tag = header & 0xFF
        words = item_words(header)
        if tag == BLOCK_ITEM_LAST:
            end, link = find_block_end_and_link(image, terminal)
            if end != len(image) or link != root:
                raise TestFailure("terminal block does not close the image")
            break
        if words == 0 or at + 4 * words > len(image):
            raise TestFailure("malformed terminal item")
        if tag == 0x06:  # PICOBIN_BLOCK_ITEM_LOAD_MAP.
            count = header >> 24
            if count == 0 or words != 1 + 3 * count or ranges is not None:
                raise TestFailure("malformed terminal load map")
            parsed = []
            for index in range(count):
                entry = at + 4 + 12 * index
                offset = at + signed_word_at(image, entry)
                size = word_at(image, entry + 8)
                if offset < 0 or size == 0 or offset + size > terminal:
                    raise TestFailure("load-map range is outside the image body")
                parsed.append((offset, size))
            ranges = parsed
        elif tag == 0x47:  # PICOBIN_BLOCK_ITEM_1BS_HASH_DEF.
            if header != 0x01000247 or block_hash_size is not None:
                raise TestFailure("unexpected HASH_DEF item")
            block_hash_size = word_at(image, at + 4) * 4
        elif tag == 0x4B:  # PICOBIN_BLOCK_ITEM_HASH_VALUE.
            if header != 0x94B or digest_offset is not None:
                raise TestFailure("unexpected HASH_VALUE item")
            digest_offset = at + 4
        at += 4 * words
    else:
        raise TestFailure("terminal block has no LAST item")

    if ranges is None or block_hash_size is None or digest_offset is None:
        raise TestFailure("terminal block lacks load-map or SHA-256 metadata")
    if block_hash_size < 8 or terminal + block_hash_size + 4 != digest_offset:
        raise TestFailure("unexpected terminal SHA-256 layout")
    if digest_offset + 32 > len(image):
        raise TestFailure("embedded SHA-256 extends beyond the image")
    return ImageInfo(terminal, block_hash_size, digest_offset, tuple(ranges))


def embedded_digest(image: Union[bytes, bytearray], info: ImageInfo) -> bytes:
    digest = hashlib.sha256()
    for offset, size in info.ranges:
        digest.update(image[offset : offset + size])
    terminal = bytearray(
        image[info.terminal : info.terminal + info.block_hash_size]
    )
    # RP2350 ROM hashing excludes the mutable terminal TBYB bit.
    terminal[7] &= 0x7F
    digest.update(terminal)
    return digest.digest()


def stored_digest(image: Union[bytes, bytearray], info: ImageInfo) -> bytes:
    return bytes(image[info.digest_offset : info.digest_offset + 32])


def choose_body_offset(info: ImageInfo) -> int:
    preferred = 8192
    for offset, size in info.ranges:
        if offset <= preferred < offset + size:
            return preferred
    for offset, size in info.ranges:
        candidate = max(offset, CHUNK_SIZE)
        if candidate < offset + size:
            return candidate
    raise TestFailure("image has no hashed body byte at or above offset 4096")


class OtaConsole:
    def __init__(self, path: str):
        self.serial = serial.Serial(
            port=path,
            baudrate=115200,
            timeout=0.1,
            write_timeout=CONTROL_TIMEOUT,
        )
        self.serial.dtr = True
        self.serial.reset_input_buffer()

    def close(self) -> None:
        self.serial.close()

    def write(self, data: bytes, deadline: float) -> None:
        offset = 0
        while offset < len(data):
            remaining(deadline)
            self.serial.write_timeout = min(CONTROL_TIMEOUT, remaining(deadline))
            count = self.serial.write(data[offset:])
            if count == 0:
                raise TimeoutError("serial write made no progress")
            offset += count

    def command(self, line: str) -> None:
        self.write((line + "\n").encode(), time.monotonic() + CONTROL_TIMEOUT)

    def read_line(self, deadline: float) -> str:
        result = bytearray()
        while True:
            remaining(deadline)
            data = self.serial.read(1)
            if not data:
                continue
            if data == b"\n":
                if result.endswith(b"\r"):
                    result.pop()
                return result.decode("utf-8", errors="replace")
            result.extend(data)
            if len(result) > MAXIMUM_LINE_LENGTH:
                raise TestFailure("device sent an overlong line")

    def protocol_line(self, deadline: float) -> str:
        while True:
            line = self.read_line(deadline)
            if line.startswith("TOIT-OTA "):
                return line

    def info(self) -> DeviceInfo:
        self.command("TOIT-OTA INFO")
        deadline = time.monotonic() + CONTROL_TIMEOUT
        while True:
            line = self.protocol_line(deadline)
            if line.startswith("TOIT-OTA ERROR"):
                raise TestFailure(f"INFO rejected: {line}")
            if line.startswith("TOIT-OTA INFO "):
                break
        words = line.split()
        if len(words) != 6 or words[:3] != ["TOIT-OTA", "INFO", "1"]:
            raise TestFailure(f"malformed INFO response: {line}")
        try:
            partition = int(words[3])
            trial_value = int(words[4])
            slot_size = int(words[5])
        except ValueError as error:
            raise TestFailure(f"malformed INFO response: {line}") from error
        if trial_value not in (0, 1) or partition not in (0, 1) or slot_size <= 0:
            raise TestFailure(f"invalid INFO values: {line}")
        return DeviceInfo(partition, bool(trial_value), slot_size)

    def start_upload(self, size: int, digest: bytes) -> None:
        self.command(f"TOIT-OTA WRITE {size} {digest.hex()}")
        line = self.protocol_line(time.monotonic() + CONTROL_TIMEOUT)
        if line.startswith("TOIT-OTA ERROR"):
            raise TestFailure(f"upload rejected before READY: {line}")
        if line != f"TOIT-OTA READY {CHUNK_SIZE}":
            raise TestFailure(f"unexpected READY response: {line}")

    def send_chunks(self, image: bytes, limit: Optional[int] = None) -> int:
        end = len(image) if limit is None else min(limit, len(image))
        if end <= 0:
            raise TestFailure("upload limit is empty")
        deadline = time.monotonic() + TRANSFER_TIMEOUT
        offset = 0
        while offset < end:
            count = min(CHUNK_SIZE, end - offset)
            self.write(image[offset : offset + count], deadline)
            offset += count
            line = self.protocol_line(deadline)
            if line.startswith("TOIT-OTA ERROR"):
                raise TestFailure(f"upload rejected before ACK {offset}: {line}")
            if line != f"TOIT-OTA ACK {offset}":
                raise TestFailure(f"unexpected ACK at {offset}: {line}")
        return offset

    def expect_error(self, expected: str) -> str:
        line = self.protocol_line(time.monotonic() + COMMIT_TIMEOUT)
        if line == "TOIT-OTA COMMITTED":
            raise TestFailure("malformed image was committed")
        if not line.startswith("TOIT-OTA ERROR "):
            raise TestFailure(f"expected rejection, received: {line}")
        actual = line[len("TOIT-OTA ERROR ") :]
        if actual != expected:
            raise TestFailure(
                f"expected rejection {expected!r}, received {actual!r}"
            )
        return actual


def verify_recovery(console: OtaConsole, baseline: DeviceInfo) -> DeviceInfo:
    # The error handler clears its Reader before accepting the next command.
    time.sleep(0.05)
    current = console.info()
    if current.partition != baseline.partition or current.trial:
        raise TestFailure(
            "device state changed after rejection: "
            f"partition={current.partition} trial={int(current.trial)}"
        )
    if current.slot_size != baseline.slot_size:
        raise TestFailure("OTA slot size changed after rejection")
    return current


def print_pass(name: str, error: str, info: DeviceInfo) -> None:
    print(
        f"{name}: PASS error={error!r} "
        f"INFO=partition{info.partition}/trial{int(info.trial)}"
    )


def rejected_full_upload(
    console: OtaConsole,
    baseline: DeviceInfo,
    name: str,
    image: bytes,
    digest: bytes,
    expected_error: str,
) -> None:
    console.start_upload(len(image), digest)
    console.send_chunks(image)
    error = console.expect_error(expected_error)
    print_pass(name, error, verify_recovery(console, baseline))


def run(port: str, image_path: pathlib.Path) -> None:
    good = image_path.read_bytes()
    image_info = inspect_image(good)
    if embedded_digest(good, image_info) != stored_digest(good, image_info):
        raise TestFailure("input image's embedded RP2350 SHA-256 is invalid")

    body_offset = choose_body_offset(image_info)
    corrupt_body = bytearray(good)
    corrupt_body[body_offset] ^= 0x01
    if embedded_digest(corrupt_body, image_info) == stored_digest(
        corrupt_body, image_info
    ):
        raise TestFailure("body mutation did not invalidate the embedded SHA-256")

    no_terminal_tbyb = bytearray(good)
    terminal_type = word_at(no_terminal_tbyb, image_info.terminal + 4)
    struct.pack_into(
        "<I",
        no_terminal_tbyb,
        image_info.terminal + 4,
        terminal_type & ~TBYB_FLAG,
    )
    if embedded_digest(no_terminal_tbyb, image_info) != stored_digest(
        no_terminal_tbyb, image_info
    ):
        raise TestFailure("clearing terminal TBYB unexpectedly changed the embedded hash")

    console = OtaConsole(port)
    try:
        baseline = console.info()
        if baseline.trial:
            raise TestFailure("refusing negative OTA tests while validation is pending")
        if len(good) > baseline.slot_size:
            raise TestFailure(
                f"image is {len(good)} bytes, slot is {baseline.slot_size} bytes"
            )
        print(
            f"baseline: partition={baseline.partition} trial=0 "
            f"slot={baseline.slot_size} image={len(good)}"
        )

        wrong_digest = bytearray(hashlib.sha256(good).digest())
        wrong_digest[0] ^= 0x01
        rejected_full_upload(
            console,
            baseline,
            "wrong-transport-sha",
            good,
            bytes(wrong_digest),
            "firmware: checksum mismatch",
        )

        rejected_full_upload(
            console,
            baseline,
            f"bad-rom-image-sha@{body_offset}",
            bytes(corrupt_body),
            hashlib.sha256(corrupt_body).digest(),
            "INVALID_ARGUMENT",
        )

        rejected_full_upload(
            console,
            baseline,
            f"terminal-tbyb-cleared@{image_info.terminal + 4}",
            bytes(no_terminal_tbyb),
            hashlib.sha256(no_terminal_tbyb).digest(),
            "INVALID_ARGUMENT",
        )

        console.start_upload(len(good), hashlib.sha256(good).digest())
        sent = console.send_chunks(good, limit=2 * CHUNK_SIZE)
        if sent != 2 * CHUNK_SIZE or sent >= len(good):
            raise TestFailure("input image is too short for the truncated-upload test")
        error = console.expect_error("DEADLINE_EXCEEDED")
        print_pass(
            f"truncated-timeout@{sent}/{len(good)}",
            error,
            verify_recovery(console, baseline),
        )
    finally:
        console.close()
    print("ota-negative-test: PASS")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Exercise RP2350 OTA rejection and console recovery"
    )
    parser.add_argument("--port", required=True, help="stable USB serial path")
    parser.add_argument("--image", required=True, type=pathlib.Path, help="known-good .bin")
    arguments = parser.parse_args()
    try:
        run(arguments.port, arguments.image)
    except (OSError, serial.SerialException, TestFailure, TimeoutError) as error:
        print(f"ota-negative-test: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
