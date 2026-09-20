#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import json
import hashlib
import pathlib
import struct
import sys


START = 0xFFFFDED3
TBYB = 0x80000000
UF2_MAGIC_START_0 = 0x0A324655
UF2_MAGIC_START_1 = 0x9E5D5157
UF2_MAGIC_END = 0x0AB16F30
UF2_FAMILY_ABSOLUTE = 0xE48BFF57
XIP_BASE = 0x10000000
SLOT_A_OFFSET = 0x2000
SLOT_A_END = 0x402000
REGISTRY_OFFSET = 0x802000


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def word(data: bytearray, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def put_word(data: bytearray, offset: int, value: int) -> None:
    struct.pack_into("<I", data, offset, value)


def root_and_terminal(data: bytearray) -> tuple[int, int]:
    roots = [
        offset
        for offset in range(0, min(4096, len(data)), 4)
        if word(data, offset) == START
    ]
    if len(roots) != 1:
        fail("base does not have exactly one root image definition")
    root = roots[0]
    offset = root + 8
    while offset + 12 <= len(data):
        header = word(data, offset)
        tag = header & 0xFF
        words = (header >> 8) & (0xFFFF if tag & 0x80 else 0xFF)
        if tag == 0xFF:
            relative = struct.unpack_from("<i", data, offset + 4)[0]
            return root, root + relative
        if words == 0:
            fail("malformed root image definition")
        offset += words * 4
    fail("root image definition has no footer")


def verify_rom_hash(data: bytearray, terminal: int) -> None:
    offset = terminal + 8
    ranges: list[tuple[int, int]] = []
    hash_size = None
    digest_offset = None
    while offset + 12 <= len(data):
        header = word(data, offset)
        tag = header & 0xFF
        words = (header >> 8) & (0xFFFF if tag & 0x80 else 0xFF)
        if tag == 0xFF:
            break
        if words == 0 or offset + words * 4 > len(data):
            fail("malformed terminal image definition")
        if tag == 0x06:
            count = header >> 24
            if words != 1 + 3 * count:
                fail("malformed recovery LOAD_MAP")
            for index in range(count):
                entry = offset + 4 + index * 12
                relative = struct.unpack_from("<i", data, entry)[0]
                ranges.append((offset + relative, word(data, entry + 8)))
        elif tag == 0x47:
            hash_size = word(data, offset + 4) * 4
        elif tag == 0x4B:
            digest_offset = offset + 4
        offset += words * 4
    if not ranges or hash_size is None or digest_offset is None:
        fail("recovery image is missing hash metadata")
    digest = hashlib.sha256()
    for start, size in ranges:
        digest.update(data[start : start + size])
    definition = bytearray(data[terminal : terminal + hash_size])
    definition[7] &= 0x7F
    digest.update(definition)
    if digest.digest() != data[digest_offset : digest_offset + 32]:
        fail("recovery image ROM hash is invalid")


def mutate(mode: str, source: pathlib.Path, output: pathlib.Path) -> None:
    data = bytearray(source.read_bytes())
    if mode == "partition-hash":
        if len(data) != 512:
            fail("partition-table UF2 is not one block")
        data[32 + 0x70] ^= 0x80
        output.write_bytes(data)
        return
    if mode == "partition-layout":
        if len(data) != 512:
            fail("partition-table UF2 is not one block")
        # Move partition A's first sector while retaining a valid table hash.
        put_word(data, 32 + 0x0C, word(data, 32 + 0x0C) ^ 1)
        payload = data[32 : 32 + 256]
        payload[0x70:0x90] = hashlib.sha256(payload[:0x6C]).digest()
        data[32 : 32 + 256] = payload
        output.write_bytes(data)
        return
    root, terminal = root_and_terminal(data)
    if mode == "hash":
        # The digest immediately precedes the 12-byte terminal footer.
        data[-13] ^= 0x80
    elif mode == "root-tbyb":
        put_word(data, root + 4, word(data, root + 4) & ~TBYB)
    elif mode == "terminal-tbyb":
        put_word(data, terminal + 4, word(data, terminal + 4) & ~TBYB)
    else:
        fail(f"unknown mutation: {mode}")
    output.write_bytes(data)


def verify_show(path: pathlib.Path, assets_path: pathlib.Path) -> None:
    document = json.loads(path.read_text())
    if document.get("envelope-format-version") != 1001:
        fail("wrong envelope format version")
    if document.get("kind") != "rp2350":
        fail("wrong envelope kind")
    containers = document.get("containers", {})
    for name in ("system", "child"):
        if containers.get(name, {}).get("flags") != ["trigger=boot", "critical"]:
            fail(f"{name} flags were not preserved")
    child = containers["child"]
    if child.get("assets", {}).get("size") != assets_path.stat().st_size:
        fail("child assets were not preserved")


def uf2_header(data: bytes, index: int) -> tuple[int, ...]:
    start = index * 512
    block = data[start : start + 512]
    if len(block) != 512:
        fail("truncated UF2 block")
    values = struct.unpack_from("<8I", block)
    if values[0] != UF2_MAGIC_START_0 or values[1] != UF2_MAGIC_START_1:
        fail("bad UF2 start magic")
    if struct.unpack_from("<I", block, 508)[0] != UF2_MAGIC_END:
        fail("bad UF2 end magic")
    return values


def verify_uf2(
    path: pathlib.Path, firmware_path: pathlib.Path, partition_path: pathlib.Path
) -> None:
    data = path.read_bytes()
    firmware = firmware_path.read_bytes()
    partition = partition_path.read_bytes()
    firmware_blocks = (len(firmware) + 255) // 256
    main_blocks = 1 + firmware_blocks
    if len(data) != (main_blocks + 1) * 512:
        fail("recovery UF2 has the wrong number of blocks")

    absolute = uf2_header(data, 0)
    if absolute[2:] != (
        0xA000,
        0x10FFFF00,
        256,
        0,
        2,
        UF2_FAMILY_ABSOLUTE,
    ):
        fail("bad RP2350-E10 absolute block")
    if data[32:288] != b"\xef" * 256:
        fail("bad RP2350-E10 payload")
    if struct.unpack_from("<I", data, 288)[0] != 0x9957E304:
        fail("absolute block is not marked ignored")

    reconstructed = bytearray()
    for index in range(main_blocks):
        values = uf2_header(data, index + 1)
        expected_target = XIP_BASE if index == 0 else XIP_BASE + SLOT_A_OFFSET + (index - 1) * 256
        if values[2:] != (
            0x2000,
            expected_target,
            256,
            index,
            main_blocks,
            UF2_FAMILY_ABSOLUTE,
        ):
            fail(f"bad main UF2 block {index}")
        payload = data[(index + 1) * 512 + 32 : (index + 1) * 512 + 288]
        if index == 0:
            if payload != partition[32:288]:
                fail("partition-table payload changed")
        else:
            reconstructed.extend(payload)

    recovery = reconstructed[: len(firmware)]
    expected = bytearray(firmware)
    root, terminal = root_and_terminal(expected)
    if word(expected, root + 4) & TBYB == 0 or word(expected, terminal + 4) & TBYB == 0:
        fail("OTA input is not a trial image")
    put_word(expected, terminal + 4, word(expected, terminal + 4) & ~TBYB)
    if recovery != expected:
        fail("slot-A UF2 payload is not the confirmed form of the firmware")
    if word(recovery, root + 4) & TBYB == 0:
        fail("recovery image unexpectedly changed the root TBYB flag")
    if word(recovery, terminal + 4) & TBYB:
        fail("recovery image retained the terminal TBYB flag")
    verify_rom_hash(recovery, terminal)
    if any(reconstructed[len(firmware) :]):
        fail("last slot-A UF2 page has nonzero padding")
    last_written = SLOT_A_OFFSET + firmware_blocks * 256
    if last_written > SLOT_A_END or last_written >= REGISTRY_OFFSET:
        fail("recovery UF2 reaches outside physical slot A")


def main() -> None:
    if len(sys.argv) == 5 and sys.argv[1] == "mutate":
        mutate(sys.argv[2], pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4]))
        return
    if len(sys.argv) == 4 and sys.argv[1] == "verify-show":
        verify_show(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))
        return
    if len(sys.argv) == 5 and sys.argv[1] == "verify-uf2":
        verify_uf2(
            pathlib.Path(sys.argv[2]),
            pathlib.Path(sys.argv[3]),
            pathlib.Path(sys.argv[4]),
        )
        return
    fail(
        "usage: envelope_fixture.py mutate MODE INPUT OUTPUT | "
        "verify-show SHOW.json ASSETS | verify-uf2 IMAGE.uf2 FIRMWARE.bin "
        "PARTITIONS.uf2"
    )


if __name__ == "__main__":
    main()
