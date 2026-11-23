#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
"""Check the forward memmove path called by an EC618 base firmware ELF."""

import argparse
from pathlib import Path
import re
import subprocess


from ec618_thumb import check_executable, instructions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("elf")
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    parser.add_argument("--z3", default="z3")
    args = parser.parse_args()
    check_executable(args.objdump, args.elf)
    start, body = instructions(args.objdump, args.elf, "memmove")
    _, caller = instructions(args.objdump, args.elf, "page_grow_allocation")
    if not any(re.fullmatch(r"bl\s+0*" + f"{start:x}" + r" <memmove>", asm)
               for _, asm in caller.values()):
        raise ValueError("page_grow_allocation has no direct call to this memmove")
    # All reachable instructions from entry to return for unsigned dst < src.
    # PC-relative branches are pinned at their original function offsets.
    required = {0x00: "4288", 0x02: "b510", 0x04: "eb01 0402", 0x08: "d902",
                0x10: "1e43", 0x12: "42a1", 0x14: "d008", 0x16: "f811 2b01",
                0x1a: "f803 2f01", 0x1e: "e7f8", 0x28: "bd10"}
    for offset, encoding in required.items():
        if body.get(offset, (None,))[0] != encoding:
            raise ValueError(f"unexpected instruction at memmove+{offset:#x}")
    proof = Path(__file__).with_name("ec618_memmove.smt2")
    results = subprocess.check_output([args.z3, str(proof)], text=True).splitlines()
    if results != ["unsat"] * 4:
        raise ValueError(f"forward-copy induction failed: {results}")
    print("EC618 allocator call and forward Thumb path matched; all four obligations proved.")


if __name__ == "__main__":
    main()
