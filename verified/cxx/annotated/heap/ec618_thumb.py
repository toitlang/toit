# Copyright (C) 2026 Toit contributors.
"""Read linked EC618 Thumb instructions using ARM GNU objdump."""

import re
import subprocess

from elftools.elf.elffile import ELFFile


def check_executable(objdump, elf):
    info = subprocess.check_output([objdump, "-f", elf], text=True)
    if "file format elf32-littlearm" not in info or "EXEC_P" not in info:
        raise ValueError(f"expected a linked little-endian ARM executable: {elf}")


def instructions(objdump, elf, symbol):
    listing = subprocess.check_output([objdump, "-d", "--disassemble=" + symbol, elf], text=True)
    header = re.search(r"^([0-9a-f]+) <" + re.escape(symbol) + r">:$", listing, re.M)
    if not header:
        raise ValueError(f"missing {symbol} in {elf}")
    start = int(header[1], 16)
    result = {}
    for line in listing[header.end():].splitlines():
        match = re.match(r"\s*([0-9a-f]+):\t([0-9a-f ]+)\t(.+)", line)
        if match:
            result[int(match[1], 16) - start] = (" ".join(match[2].split()), match[3])
    return start, result


def match_block(body, pc, encodings):
    for encoding in encodings.split("|"):
        if body[pc][0] != encoding:
            raise ValueError(f"unexpected heap range instruction at offset {pc:#x}")
        pc += 2 * len(encoding.split())


def match_branch(body, pc, opcode, symbol, address):
    if not re.fullmatch(re.escape(opcode) + r"\s+0*" + f"{address:x} <{re.escape(symbol)}>", body[pc][1]):
        raise ValueError(f"expected {opcode} to {symbol} at offset {pc:#x}")

def match_global_address(body, pc, reg, elf, name, *, size=4, high_pc=None):
    """Bind a linked MOVW/MOVT pair to an allocated writable object."""
    with open(elf, "rb") as stream:
        image = ELFFile(stream)
        sym, = image.get_section_by_name(".symtab").get_symbol_by_name(name)
        section = image.get_section(sym["st_shndx"])
        address = sym["st_value"]
        if (sym["st_size"] != size or address % 4 or section["sh_flags"] & 3 != 3 or
                not section["sh_addr"] <= address <= section["sh_addr"] + section["sh_size"] - size):
            raise ValueError(f"invalid allocator global {name}")
    if high_pc is None:
        high_pc = pc + 4
    for offset, opcode, half in ((pc, 0xf240, address & 65535), (high_pc, 0xf2c0, address >> 16)):
        first = opcode | ((half >> 1) & 0x400) | (half >> 12)
        second = ((half & 0x700) << 4) | (reg << 8) | (half & 255)
        match_block(body, offset, f"{first:04x} {second:04x}")
