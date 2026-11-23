#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
"""Verify the allocator entry points in a linked EC618 base ELF with CBMC."""

import argparse
from pathlib import Path
import subprocess
import tempfile

from elftools.elf.elffile import ELFFile


def extract(elf, out):
    if (elf.elfclass, elf.little_endian, elf["e_machine"], elf["e_type"]) != (
        32, True, "EM_ARM", "ET_EXEC"
    ):
        raise ValueError("expected a linked little-endian ARM executable")
    symbols = elf.get_section_by_name(".symtab")
    if symbols is None:
        raise ValueError("missing ELF symbol table")

    def symbol(name):
        matches = symbols.get_symbol_by_name(name) or []
        if len(matches) != 1:
            raise ValueError(f"expected one defined {name} symbol")
        return matches[0]

    def function(name):
        sym = symbol(name)
        section = elf.get_section(sym["st_shndx"])
        if not (sym["st_info"]["type"] == "STT_FUNC" and sym["st_value"] & 1
                and section["sh_flags"] & 4 and section["sh_flags"] & 2):
            raise ValueError(f"{name} must be executable Thumb code")
        return sym["st_value"] - 1, sym["st_size"], section

    gates = ["aligned_alloc", "__wrap__memalign_r", "malloc", "free", "realloc"]
    targets = ["pvPortMemalign", "pvPortMallocEC", "vPortFree", "pvPortReallocEC"]
    words = {}
    for name in gates + targets:
        address, size, section = function(name)
        print(f"#define ADDR_{name} 0x{address:08x}u", file=out)
        if name in targets:
            continue
        start = address - section["sh_addr"]
        data = section.data()[start:start + size]
        if start < 0 or len(data) != size or size == 0 or size % 2:
            raise ValueError(f"incomplete {name} body")
        for i in range(0, size, 2):
            words[address + i] = int.from_bytes(data[i:i + 2], "little")
    ptr = symbol("_impure_ptr")
    section = elf.get_section(ptr["st_shndx"])
    if not (section["sh_flags"] & 2 and ptr["st_size"] == 4 and
            section["sh_addr"] <= ptr["st_value"] <= section["sh_addr"] + section["sh_size"] - 4):
        raise ValueError("expected an allocated four-byte _impure_ptr")
    print(f"#define ADDR_impure_ptr 0x{ptr['st_value']:08x}u", file=out)
    print("static unsigned halfword(unsigned address) {\n  switch (address) {", file=out)
    for address, word in sorted(words.items()):
        print(f"    case 0x{address:08x}u: return 0x{word:04x}u;", file=out)
    print('    default: __CPROVER_assert(0, "read within extracted firmware"); return 0;\n  }\n}', file=out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf", type=Path)
    parser.add_argument("--cbmc", default="cbmc")
    args = parser.parse_args()
    harness = Path(__file__).with_name("ec618_allocator_abi.c")
    with tempfile.TemporaryDirectory() as tmp:
        with args.elf.open("rb") as stream, (Path(tmp) / "allocator_abi.inc").open("w") as out:
            extract(ELFFile(stream), out)
        subprocess.run([args.cbmc, str(harness), "-I", tmp, "--32", "--unwind", "12",
                        "--unwinding-assertions"], check=True)


if __name__ == "__main__":
    main()
