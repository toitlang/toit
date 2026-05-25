#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
# Extract the set of PLAT symbols that the VM reaches in a given EC618
# `toit.elf`. Output is suitable as input to `gen_plat_jt.py`.
#
# Method:
#   1. Walk the linker map and collect every (start, end) range that any
#      `libtoit_vm.a` or `libmbedtls*.a` `.text.*` section contributed.
#   2. Disassemble `.text` and pull every BL instruction.
#   3. For each BL whose source falls inside a VM range and whose target
#      falls outside, record the destination symbol.
#   4. Print one symbol per line, sorted, deduplicated, with a leading
#      call count for at-a-glance triage.
#
# Important: this should be run on a *pre-wrap* ELF (i.e. before the
# PLAT_JT_LDFLAGS block in xmake.lua is populated). Running it on a
# post-wrap ELF surfaces the `__wrap_*` symbols, which is circular: the
# wrappers are the entry points the linker has already redirected to.
# The `--strip-wrap` flag removes that prefix as a best-effort
# convenience for re-checking an already-wrapped build, but the
# canonical workflow is to take a snapshot before wraps are added and
# diff against the version-controlled list.
#
# Usage:
#   tools/extract_plat_jt_symbols.py <toit.elf> <toit_debug.map> [--counts] [--strip-wrap]

import argparse
import bisect
import re
import subprocess
import sys
from collections import Counter

VM_ARCHIVES = (
    "libtoit_vm.a",
    "libmbedcrypto.a",
    "libmbedtls.a",
    "libmbedx509.a",
)

OBJDUMP = "arm-none-eabi-objdump"

# A `.text.<sym>` section line is followed (next non-blank line) by
# `                ADDR  SIZE  /path/to/lib.a(obj.obj)`. We pair them.
SECTION_RE = re.compile(r"^ \.text\.[^ \t]+")
ENTRY_RE = re.compile(r"^\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+(\S+)")


def vm_ranges(map_path):
    ranges = []
    in_text_section = False
    for line in open(map_path):
        if SECTION_RE.match(line):
            in_text_section = True
            continue
        if line.startswith(" ."):
            in_text_section = False
            continue
        if not in_text_section:
            continue
        m = ENTRY_RE.match(line)
        if not m:
            continue
        if not any(arc in m.group(3) for arc in VM_ARCHIVES):
            continue
        addr = int(m.group(1), 16)
        size = int(m.group(2), 16)
        if size > 0:
            ranges.append((addr, addr + size))
    ranges.sort()
    # Merge overlapping/contiguous ranges so the in-VM check is a single
    # binary search.
    merged = []
    for s, e in ranges:
        if merged and s <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], e))
        else:
            merged.append((s, e))
    return merged


def in_range(ranges, addr):
    if not ranges:
        return False
    starts = [r[0] for r in ranges]
    i = bisect.bisect_right(starts, addr) - 1
    return i >= 0 and ranges[i][0] <= addr < ranges[i][1]


# objdump prints lines such as:
#   "  8665e8:\tf0f9 fabc \tbl\t95fb64 <ec_assert_regs>"
# We pull (from_addr, to_addr, target_symbol).
BL_RE = re.compile(
    r"^\s*([0-9a-f]+):\s+[0-9a-f ]+\sbl\s+([0-9a-f]+)(?:\s+<([^>]+)>)?"
)


def bl_calls(elf_path):
    proc = subprocess.run(
        [OBJDUMP, "-d", "-j", ".text", elf_path],
        check=True, capture_output=True, text=True)
    for line in proc.stdout.splitlines():
        m = BL_RE.match(line)
        if m:
            yield (int(m.group(1), 16),
                   int(m.group(2), 16),
                   m.group(3) or "")


def main():
    ap = argparse.ArgumentParser(
        description="Extract PLAT symbols the EC618 VM reaches.")
    ap.add_argument("elf")
    ap.add_argument("mapfile")
    ap.add_argument("--counts", action="store_true",
                    help="prefix each symbol with its call count")
    ap.add_argument("--strip-wrap", action="store_true",
                    help="strip leading __wrap_ from symbols (best-effort, see header)")
    args = ap.parse_args()

    ranges = vm_ranges(args.mapfile)
    if not ranges:
        sys.stderr.write(f"no VM .text ranges found in {args.mapfile}\n")
        return 1

    counts = Counter()
    for fa, ta, sym in bl_calls(args.elf):
        if not sym:
            continue
        if in_range(ranges, fa) and not in_range(ranges, ta):
            counts[sym] += 1

    if args.strip_wrap:
        stripped = Counter()
        for sym, cnt in counts.items():
            stripped[sym[len("__wrap_"):] if sym.startswith("__wrap_") else sym] += cnt
        counts = stripped

    for sym in sorted(counts):
        if args.counts:
            print(f"{counts[sym]:5d}  {sym}")
        else:
            print(sym)
    return 0


if __name__ == "__main__":
    sys.exit(main())
