#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import hashlib
import pathlib
import struct
import subprocess
import sys


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def main() -> None:
    if len(sys.argv) != 3:
        fail(f"usage: {sys.argv[0]} PARSER_TEST IMAGE.bin")
    parser = pathlib.Path(sys.argv[1])
    image_path = pathlib.Path(sys.argv[2])
    image = bytearray(image_path.read_bytes())

    inspection = subprocess.check_output(
        [str(parser), "--inspect", str(image_path)], text=True
    ).split()
    values = [int(value) for value in inspection]
    if len(values) < 5 or len(values) % 2 == 0:
        fail("malformed parser inspection output")
    block_offset, block_size, digest_offset = values[:3]
    ranges = list(zip(values[3::2], values[4::2]))

    stored_digest = bytes(image[digest_offset : digest_offset + 32])
    if len(stored_digest) != 32:
        fail("digest is outside the image")

    terminal = bytearray(image[block_offset : block_offset + block_size])
    image_type = struct.unpack_from("<I", terminal, 4)[0]
    if image_type != 0x90210142:
        fail("unexpected terminal IMAGE_TYPE")
    struct.pack_into("<I", terminal, 4, image_type & ~0x80000000)

    sha = hashlib.sha256()
    for offset, size in ranges:
        sha.update(image[offset : offset + size])
    sha.update(terminal)
    if sha.digest() != stored_digest:
        fail("Python SHA-256 does not match the picotool digest")

    unmasked = hashlib.sha256()
    for offset, size in ranges:
        unmasked.update(image[offset : offset + size])
    unmasked.update(image[block_offset : block_offset + block_size])
    if unmasked.digest() == stored_digest:
        fail("terminal TBYB unexpectedly participated in the digest")

    no_terminal_tbyb = bytearray(image)
    struct.pack_into("<I", no_terminal_tbyb, block_offset + 4,
                     image_type & ~0x80000000)
    sha = hashlib.sha256()
    for offset, size in ranges:
        sha.update(no_terminal_tbyb[offset : offset + size])
    sha.update(no_terminal_tbyb[block_offset : block_offset + block_size])
    if sha.digest() != stored_digest:
        fail("removing terminal TBYB should leave the digest valid")

    unpublished = bytearray(image)
    unpublished[:4096] = b"\xff" * 4096
    sha = hashlib.sha256()
    for offset, size in ranges:
        if offset < 4096:
            overlay_size = min(size, 4096 - offset)
            sha.update(image[offset : offset + overlay_size])
            offset += overlay_size
            size -= overlay_size
        sha.update(unpublished[offset : offset + size])
    sha.update(terminal)
    if sha.digest() != stored_digest:
        fail("SRAM first-sector overlay does not reconstruct the digest")

    sha = hashlib.sha256()
    for offset, size in ranges:
        sha.update(unpublished[offset : offset + size])
    sha.update(terminal)
    if sha.digest() == stored_digest:
        fail("erased physical first sector unexpectedly matches the digest")

    first_tbyb = bytearray(image)
    root = first_tbyb.find(struct.pack("<I", 0xFFFFDED3), 0, 4096)
    if root < 0:
        fail("first block marker not found")
    first_type = struct.unpack_from("<I", first_tbyb, root + 4)[0]
    struct.pack_into("<I", first_tbyb, root + 4,
                     first_type & ~0x80000000)
    sha = hashlib.sha256()
    for offset, size in ranges:
        sha.update(first_tbyb[offset : offset + size])
    sha.update(terminal)
    if sha.digest() == stored_digest:
        fail("removing first-block TBYB should change the digest")

    corrupted = bytearray(image)
    corrupted[root + 64] ^= 0x80
    sha = hashlib.sha256()
    for offset, size in ranges:
        sha.update(corrupted[offset : offset + size])
    sha.update(terminal)
    if sha.digest() == stored_digest:
        fail("body corruption was not detected by SHA-256")

    print("ota_image_hash_test: PASS picotool digest and TBYB masking")


if __name__ == "__main__":
    main()
