#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
#
# Extract the set of PLAT symbols the VM *calls* into, for the EC618 jump
# table (see tools/gen_plat_jt.py and README.ec618.md "PLAT jump-table
# regeneration").
#
# Method (robust to the dual-slot split and to existing --wrap flags):
#   1. Read the VM archives' object RELOCATIONS (R_ARM_*_CALL / JUMP24).
#      Relocations carry the *referenced* symbol name from the object — the
#      name the compiler emitted (e.g. `printf`, `snprintf`, `__aeabi_dadd`),
#      NOT the link-time-resolved alias (`iprintf`, ...). Only the referenced
#      name can be wrapped with `-Wl,--wrap=`, so this is what we must list.
#      (The old disassembly-of-the-linked-elf method recorded resolved aliases
#      and silently produced wraps that never fired.)
#   2. Drop targets the VM archives define themselves (intra-VM calls).
#   3. Drop an EXCLUDE set of references with no PLAT definition (e.g. host-
#      only OS methods that survive only as dead, GC'd refs — a table entry
#      for them would emit an undefined `__real_*` and fail the link).
#   4. Route the manually-wrapped libc time helpers through the table via
#      their `__wrap_*` name: the manual `-Wl,--wrap=time` in xmake.lua already
#      rewrites the VM's `time` to `__wrap_time`, which the table then routes.
#
# Output: one symbol per line, sorted — input to gen_plat_jt.py.
#
# Usage:
#   tools/extract_plat_jt_symbols.py <final.elf> <vm-archive>... \
#       [--nm PATH] [--objdump PATH] [--exclude SYM]...
# Example:
#   tools/extract_plat_jt_symbols.py \
#       third_party/luatos-soc-ec618/build/toit/toit.elf \
#       build/ec618/src/libtoit_vm.a build/ec618/mbedtls/library/*.a

import argparse
import re
import subprocess
import sys

# Manually wrapped (custom RTC-backed) libc helpers (see __wrap.c +
# xmake.lua): the VM's `time` is rewritten to `__wrap_time` by the manual
# `-Wl,--wrap=time`, so the jump table routes `__wrap_time`, not `time`.
MANUAL_WRAP = {"clock", "localtime", "gmtime", "time"}

# References with no PLAT definition — present only as dead, GC'd refs. A
# table entry would emit an undefined `__real_*`. Add here if a build fails
# with "undefined reference to ..." from plat_jt.o(.jt_data).
DEFAULT_EXCLUDE = {
    # toit::OS::set_writable — only defined for host (os_linux/win/darwin),
    # dead on embedded.
    "_ZN4toit2OS12set_writableEPNS_12ProgramBlockEb",
}

CALL_RELOC = re.compile(
    r"R_ARM_(?:THM_CALL|CALL|THM_JUMP24|JUMP24|THM_PC22|PLT32)\s+(\S+)")


def call_targets(objdump, archives):
    targets = set()
    for arc in archives:
        out = subprocess.run([objdump, "-r", arc],
                             capture_output=True, text=True).stdout
        for m in CALL_RELOC.finditer(out):
            targets.add(re.split(r"[-+]", m.group(1))[0])
    return targets


def defined_symbols(nm, files):
    defined = set()
    for f in files:
        out = subprocess.run([nm, "--defined-only", f],
                             capture_output=True, text=True).stdout
        for line in out.splitlines():
            p = line.split()
            if len(p) >= 3:
                defined.add(p[2])
    return defined


def main(argv):
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf", help="final linked toit.elf (used only to drop "
                    "C++ references that resolve to nothing)")
    ap.add_argument("archives", nargs="+",
                    help="VM archives (libtoit_vm.a, libmbed*.a)")
    ap.add_argument("--nm", default="arm-none-eabi-nm")
    ap.add_argument("--objdump", default="arm-none-eabi-objdump")
    ap.add_argument("--exclude", action="append", default=[],
                    help="extra symbol to exclude (repeatable)")
    args = ap.parse_args(argv)

    targets = call_targets(args.objdump, args.archives)
    vm_defined = defined_symbols(args.nm, args.archives)
    elf_defined = defined_symbols(args.nm, [args.elf])
    exclude = DEFAULT_EXCLUDE | set(args.exclude)

    result = set()
    for s in targets - vm_defined - exclude:
        # A mangled C++ reference that resolves to nothing in the final elf is
        # dead VM code; skip it (avoids an undefined __real_*). Plain-C
        # libc/libgcc refs may be GC'd here but the table's KEEP pulls them
        # back, so don't filter those.
        if s.startswith("_Z") and s not in elf_defined:
            continue
        result.add("__wrap_" + s if s in MANUAL_WRAP else s)

    for s in sorted(result):
        print(s)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
