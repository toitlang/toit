#!/usr/bin/env python3
"""Splice two EC618 link passes into a single dual-slot AP image.

Takes ap_a.bin (VM in slot A, slot B reserved) and ap_b.bin (VM in slot B,
slot A reserved) produced by the EC618 build with and without
TOIT_VM_SLOT_B=1. The output is ap_a.bin with the slot-B region
overwritten by ap_b.bin's slot-B content, and slot B's DromData
patched with the same extension address that the firmware envelope
tool already wrote into slot A's DromData. Both slots end up booting
the same embedded program.

The dual-link binaries are byte-identical outside the slot regions
except for a small block of slot-specific pointers in PLAT's
`.load_dram_shared` (~700 bytes of static const tables that reference
VM constructors); those references are not used after slot dispatch,
so keeping ap_a.bin's PLAT works for slot-B activation in practice.
"""

import argparse
import struct
import sys
from pathlib import Path

AP_LOAD_ADDR = 0x00824000     # XIP base + AP offset (binary byte 0 = this XIP addr).
VM_A_ORIGIN  = 0x00991000
VM_B_ORIGIN  = 0x009F1000
VM_SLOT_SIZE = 0x00060000
SLOT_MARKER_ORIGIN = 0x00A51000

DROM_MAGIC_1 = 0x7017DA7A     # "toitdata"
DROM_MAGIC_2 = 0x00C09F19     # "config"
UUID_SIZE = 16
# Layout per src/embedded_data.cc DromData (packed):
#   uint32 magic1
#   uint32 extension       <- patch target
#   uint8  uuid[UUID_SIZE] <- patch target
#   uint32 magic2
DROM_HEADER = struct.Struct("<II")        # magic1 + extension
DROM_FULL_SIZE = 4 + 4 + UUID_SIZE + 4    # magic1, extension, uuid, magic2


def find_drom_markers(image: bytes):
    """Return file offsets of every DromData (offset of magic1)."""
    offsets = []
    for off in range(0, len(image) - DROM_FULL_SIZE, 4):
        m1, _ = DROM_HEADER.unpack_from(image, off)
        if m1 != DROM_MAGIC_1:
            continue
        magic2_off = off + 4 + 4 + UUID_SIZE
        (m2,) = struct.unpack_from("<I", image, magic2_off)
        if m2 == DROM_MAGIC_2:
            offsets.append(off)
    return offsets


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slot-a", required=True, help="ap_a.bin (VM in slot A; PLAT side patched)")
    parser.add_argument("--slot-b", required=True, help="ap_b.bin (VM in slot B)")
    parser.add_argument("--output", required=True, help="output dual-slot binary")
    parser.add_argument("--active-slot", default="A", choices=["A", "B"],
                        help="initial active-slot byte (default A)")
    args = parser.parse_args()

    a_bytes = Path(args.slot_a).read_bytes()
    b_bytes = Path(args.slot_b).read_bytes()
    # ap_a may be the envelope-extracted binary (has extension + SHA trailer
    # appended after the slot region); ap_b is the raw xmake output. Only
    # the slot B region needs to match.

    out = bytearray(a_bytes)

    # Splice slot B region from ap_b.bin into the output.
    slot_b_off = VM_B_ORIGIN - AP_LOAD_ADDR
    out[slot_b_off:slot_b_off + VM_SLOT_SIZE] = b_bytes[slot_b_off:slot_b_off + VM_SLOT_SIZE]

    # Patch slot B's DromData. ap_a.bin had only slot A's DromData patched
    # by the envelope tool; we copy that patched record into the matching
    # field inside the slot B region.
    a_drom_offsets = find_drom_markers(a_bytes)
    out_drom_offsets = find_drom_markers(out)
    if not a_drom_offsets:
        sys.exit("no DromData magic markers in slot-A binary; envelope tool didn't patch?")
    # Pick the patched DromData in slot A (the one inside the slot A address range).
    slot_a_off = VM_A_ORIGIN - AP_LOAD_ADDR
    a_drom = None
    for off in a_drom_offsets:
        if slot_a_off <= off < slot_a_off + VM_SLOT_SIZE:
            a_drom = off
            break
    if a_drom is None:
        sys.exit(f"no DromData inside slot-A region (offsets found: {[hex(o) for o in a_drom_offsets]})")

    # Find slot B's DromData in the new (spliced) image.
    slot_b_drom = None
    for off in out_drom_offsets:
        if slot_b_off <= off < slot_b_off + VM_SLOT_SIZE:
            slot_b_drom = off
            break
    if slot_b_drom is None:
        sys.exit(f"no DromData inside slot-B region (offsets found: {[hex(o) for o in out_drom_offsets]})")

    # Copy the patched extension address + uuid from slot A's DromData into slot B's.
    # Skip magic1 (4 bytes), copy 4 bytes extension + 16 bytes uuid.
    patch_src = a_drom + 4
    patch_dst = slot_b_drom + 4
    out[patch_dst:patch_dst + 4 + UUID_SIZE] = a_bytes[patch_src:patch_src + 4 + UUID_SIZE]

    # Set the active-slot byte.
    marker_off = SLOT_MARKER_ORIGIN - AP_LOAD_ADDR
    out[marker_off] = ord(args.active_slot)

    Path(args.output).write_bytes(bytes(out))
    print(f"Wrote {args.output} ({len(out)} bytes)")
    print(f"  Slot A DromData @ 0x{a_drom:08x}, slot B DromData @ 0x{slot_b_drom:08x}")
    print(f"  Extension addr: 0x{struct.unpack_from('<I', a_bytes, a_drom + 4)[0]:08x}")
    print(f"  Active slot: {args.active_slot}")


if __name__ == "__main__":
    main()
