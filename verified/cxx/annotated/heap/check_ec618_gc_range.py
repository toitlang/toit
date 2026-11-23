# Copyright (C) 2026 Toit contributors.
"""Check the current EC618 slot's linker-derived GC range and metadata request."""

import argparse
import subprocess
from pathlib import Path

from elftools.elf.elffile import ELFFile

from ec618_chunk_fills import setup_bias_obligations
from ec618_chunk_lifetime import check_chunk_lifetime
from ec618_page_grant import check_page_grant
from ec618_page_release import check_object_memory_lifecycle, check_page_release, check_teardown
from ec618_scheduler_lock import check_scheduler_lock
from ec618_small_release import check_small_release
from ec618_registration import check_registration
from ec618_tag_update import check_tag_updates
from ec618_thumb import check_executable, instructions, match_block, match_branch


def check_tables(objdump, base, slot, init_addr, init, start, end, overflow, pages, request, z3):
    size = end - start
    card = size >> 7
    mark = size >> 5
    # The size-calculation prefix leaves fp=mark, r5=2*mark+card,
    # r9=r5+card and sl=r9+overflow across the ABI calls.
    match_block(init, 0x86, "61a0|4630")
    tag = "_ZN4toit2OS12set_heap_tagEi"
    match_branch(init, 0x8a, "bl", tag, instructions(objdump, slot, tag)[0])
    match_block(init, 0x8e, "69a6|b926")
    match_block(init, 0x9c, "eb06 000b|4435|eb06 0309")
    # Register values expressed as byte offsets from the non-null malloc result.
    registers = {0: mark, 3: (size >> 4) + 2 * card, 5: (size >> 4) + card, 6: 0}
    offsets = {}
    def store(pc):
        op = int(init[pc][0], 16)
        if op & 0xf838 != 0x6020:
            raise ValueError("expected a GC descriptor store")
        field = ((op >> 6) & 31) * 4
        offsets[field] = registers[op & 7]

    store(0xa6)
    store(0xa8)
    match_block(init, 0xaa, "4456|4458|6921")
    registers[6] += (size >> 4) + 2 * card + overflow
    registers[0] += mark
    for pc in (0xb0, 0xb2, 0xb4, 0xb6):
        store(pc)

    cursor = 0
    # Descriptor offset, reservation length, lookup divisor, access width.
    tables = [(36, mark, 32, 4), (48, mark, 32, 4), (28, card, 128, 1),
              (32, card, 128, 1), (40, overflow, 1024, 1), (44, pages, 4096, 1)]
    bounds = ["(set-logic QF_LIA)", "(declare-const grant Int)", "(declare-const addr Int)",
              f"(assert (and (< 0 grant) (<= (+ grant {request}) 4294967296) (= (mod grant 4) 0)))",
              f"(assert (and (<= {start} addr) (< addr {end})))", "(check-sat)"]
    for field, length, divisor, width in tables:
        if offsets.get(field) != cursor or cursor + length > request:
            raise ValueError(f"GC table at field {field} outside its expected reservation")
        first = f"(+ grant {cursor})"
        if field == 44:
            lookup = f"(+ {first} (div (- addr {start}) 4096))"
        else:
            bias = f"(mod (- {first} {start // divisor}) 4294967296)"
            lookup = f"(mod (+ {bias} (div addr {divisor})) 4294967296)"
        access = f"(* {width} (div {lookup} {width}))"
        bounds.extend(["(push)", f"(assert (not (and (<= {first} {access})"
                       f" (<= (+ {access} {width}) (+ {first} {length})))))", "(check-sat)", "(pop)"])
        cursor += length
    if subprocess.check_output([z3, "-in"], input="\n".join(bounds), text=True).splitlines() != ["sat"] + ["unsat"] * 6:
        raise ValueError("GC metadata lookup bounds failed")

    use = "_ZN4toit2OS18use_virtual_memoryEPvj"
    entry, body = instructions(objdump, slot, use)
    match_block(body, 0, "2001|4770")
    for pc in (0xb8, 0xc2, 0xcc, 0xd6):
        match_branch(init, pc, "bl", use, entry)
    match_block(init, 0xbc, "b358|6921|6a20")
    match_block(init, 0xc6, "b330|4641|6aa0")
    match_block(init, 0xd0, "b308|4639|6ae0")
    match_block(init, 0xda, "b1e0|463a|2100|6ae0")
    memset, fill = instructions(objdump, base, "memset")
    match_branch(init, 0xe2, "bl", "memset", memset)
    match_block(fill, 0, "4603|4402|4293|d100|4770|f803 1b01|e7f9")
    fill_proof = Path(__file__).with_name("ec618_memset.smt2")
    if subprocess.check_output([z3, str(fill_proof)], text=True).splitlines() != ["unsat"] * 4:
        raise ValueError("page-type memset proof failed")
    biases, count = setup_bias_obligations((init_addr, init), memset, (0xb003, "e8bd 8ff0"))
    if subprocess.check_output([z3, "-in"], input=biases, text=True).splitlines() != ["unsat"] * count:
        raise ValueError("GC metadata bias proof failed")
    return cursor


def check(objdump, base, slot, z3):
    check_executable(objdump, base)
    check_executable(objdump, slot)
    check_tag_updates(objdump, base, slot)
    with open(base, "rb") as stream:
        symbols = ELFFile(stream).get_section_by_name(".symtab")
        first, = symbols.get_symbol_by_name("end_ap_data")
        limit, = symbols.get_symbol_by_name("start_up_buffer")
        first, limit = first["st_value"], limit["st_value"]
        ranges = [(first, limit)]
        for name in ("tag_map", "heap", "heap_initialized", "pxCurrentTCB"):
            obj, = symbols.get_symbol_by_name(name)
            lo = obj["st_value"]
            hi = lo + obj["st_size"]
            if hi > 2**32 or any(lo < end and start < hi for start, end in ranges):
                raise ValueError(f"overlapping linked allocator storage for {name}")
            ranges.append((lo, hi))
    getter = "_ZN4toit2OS21get_heap_memory_rangeEv"
    address, get = instructions(objdump, slot, getter)
    if address % 4:
        raise ValueError("GC range literal alignment changed")
    match_block(get, 0, "4b0d|490e|b510|428b|d210|1ac9|1e4a|189a|bf2c|2201|2200|d209|425c")
    match_block(get, 0x1a, "f3c4 040b|42a1|d906|1b0a|4423")
    # Decode the BFC width used to round the remaining byte count down.
    a, b = (int(x, 16) for x in get[0x26][0].split())
    if a != 0xf36f or b & ~31 != 0x0200:
        raise ValueError("expected low-bit clear in r2")
    mask = (0xffffffff << ((b & 31) + 1)) & 0xffffffff
    match_block(get, 0x2a, "e001|2300|461a|e9c0 3200|bd10")
    match_block(get, 0x38, f"{first:08x}")
    match_block(get, 0x3c, f"{limit:08x}")

    # Compare the 32-bit instructions with independently rounded, widened
    # endpoints. An ordered but sub-page interval may retain its original
    # start when its size is zero, as specified by OSPageExtent::contained.
    smt = f"""
(set-logic QF_BV)
(define-sort W () (_ BitVec 32))
(declare-const lo W)
(declare-const hi W)
(define-fun n () W (bvsub hi lo))
(define-fun skip () W (bvand (bvneg lo) #x00000fff))
(define-fun bad () Bool (or (bvuge lo hi) (bvult (bvadd lo (bvsub n #x00000001)) lo)))
(define-fun fits () Bool (bvugt n skip))
(define-fun start () W (ite bad #x00000000 (ite fits (bvadd lo skip) lo)))
(define-fun size () W (ite (or bad (not fits)) #x00000000 (bvand (bvsub n skip) #x{mask:08x})))
(define-fun ceilLo () (_ BitVec 33)
  (bvand (bvadd (concat #b0 lo) (_ bv4095 33)) (_ bv8589930496 33)))
(define-fun floorHi () (_ BitVec 33) (concat #b0 (bvand hi #xfffff000)))
(assert (or (distinct (concat #b0 size)
                      (ite (bvult ceilLo floorHi) (bvsub floorHi ceilLo) (_ bv0 33)))
            (and (distinct size #x00000000) (distinct (concat #b0 start) ceilLo))
            (and (bvuge lo hi) (distinct start #x00000000))))
(check-sat)
"""
    if subprocess.check_output([z3, "-in"], input=smt, text=True).splitlines() != ["unsat"]:
        raise ValueError("GC page interval differs from contained whole pages")

    initialize = "_ZN4toit10GcMetadata10initializeEv"
    init_addr, init = instructions(objdump, slot, initialize)
    setup_addr, setup = instructions(objdump, slot, "_ZN4toit10GcMetadata6set_upEv")
    with open(slot, "rb") as stream:
        elf = ELFFile(stream)
        table = elf.get_section_by_name(".symtab")
        singleton, = table.get_symbol_by_name("_ZN4toit10GcMetadata10singleton_E")
        if setup_addr % 4 or singleton["st_size"] != 76:
            raise ValueError("unexpected GC setup alignment or singleton extent")
        match_block(setup, 0x90, f"{singleton['st_value']:08x}")
        globals_ = []
        for name, size_bytes in (("_ZN4toit10GcMetadata10singleton_E", 76),
                                 ("_ZN4toit12ObjectMemory18spare_chunk_mutex_E", 4),
                                 ("_ZN4toit12ObjectMemory12spare_chunk_E", 4),
                                 ("_ZN4toit12ObjectMemory10allocated_E", 4)):
            symbol, = table.get_symbol_by_name(name)
            section = elf.get_section(symbol["st_shndx"])
            lo = symbol["st_value"]
            hi = lo + size_bytes
            if (lo % 4 or symbol["st_size"] != size_bytes or section["sh_flags"] & 3 != 3
                    or not section["sh_addr"] <= lo < hi <= section["sh_addr"] + section["sh_size"]
                    or any(lo < end and start < hi for start, end in ranges)):
                raise ValueError(f"invalid object memory global {name}")
            ranges.append((lo, hi))
            globals_.append(lo)
    check_object_memory_lifecycle(objdump, slot, globals_[1:])
    match_block(setup, 0, "b510|4c23|b094|69a3|b113|4822")
    fail = "_ZN4toit4failEPKcz"
    fail_addr, _ = instructions(objdump, slot, fail)
    match_branch(setup, 0xc, "bl", fail, fail_addr)
    match_block(setup, 0x10, "6ca2|a801")
    for index in range(9):
        match_block(setup, 0x14 + 4 * index, f"e9cd {0x3301 + 2 * index:04x}")
    match_block(setup, 0x38, "9213")
    match_branch(setup, 0x3a, "bl", initialize, init_addr)
    # After initialize returns, copy every word from the private descriptor
    # to the matching singleton field. No singleton store precedes the call.
    for index in range(19):
        match_block(setup, 0x3e + 4 * index, f"{0x9b01 + index:04x}|{0x6023 + 64 * index:04x}")
    match_block(setup, 0x8a, "b014|bd10")
    match_block(init, 0, "e92d 4ff7|4604|4668")
    match_branch(init, 8, "bl", getter, address)
    match_block(init, 0xc, "e9dd 2300|2b00|d040|3b01|18d3|d23d|4e43|4032|4033|1a9b|42b3|"
                "d237|f503 5380|18d1|d233|e9c4 2300|0852|f042 4200|60a2|085a|60e2")
    if init_addr % 4 or init[0x128][0] != "fffff000":
        raise ValueError("invalid metadata page mask literal")
    match_block(init, 0x3e, "ea4f 2893|09da|0b1f|eb02 1513|f108 081f|371f|eb05 0902|"
                "f028 081f|f027 071f|ea4f 1b53|eb09 0a08|f607 73ff|4453|4033|6122|6163")
    for pc, name in ((0x70, "_ZN4toit2OS12get_heap_tagEv"), (0x7a, "_ZN4toit2OS12set_heap_tagEi")):
        entry, _ = instructions(objdump, slot, name)
        match_branch(init, pc, "bl", name, entry)
    grab = "_ZN4toit2OS19grab_virtual_memoryEPvj"
    entry, body = instructions(objdump, slot, grab)
    match_branch(init, 0x82, "bl", grab, entry)
    match_block(init, 0x74, "4606|f06f 005f")
    match_block(init, 0x7e, "6961|2000")
    match_block(body, 0, "4608")
    malloc, _ = instructions(objdump, base, "malloc")
    match_branch(body, 2, "b.w", "malloc", malloc)

    start = (first + 4095) & ~4095
    end = limit & ~4095
    if not 0 < start < end <= 0xfffff000:
        raise ValueError("no representable nonempty metadata arena for this build")
    size = end - start
    # The matched instructions combine two size/32 maps, two size/128
    # maps, plus a 32-byte-aligned overflow map and page-type table.
    overflow = ((size >> 10) + 31) & ~31
    pages = ((size >> 12) + 31) & ~31
    unrounded = (size >> 4) + 2 * (size >> 7) + overflow + pages
    if unrounded + 4095 > 0xffffffff:
        raise ValueError("metadata request wraps")
    request = (unrounded + 4095) & ~4095
    memset, _ = instructions(objdump, base, "memset")
    registered = check_registration(objdump, base, first, limit, memset)
    first_page = (registered + 4095) & ~4095
    if not start <= first_page < end or end - first_page < request:
        raise ValueError("registered allocator pages cannot supply an in-range metadata grant")
    check_page_grant(objdump, base, (first + 7) & ~7, registered, limit, z3, request)
    free = check_page_release(objdump, base, (first + 7) & ~7, registered, limit)
    check_chunk_lifetime(objdump, slot, base, singleton["st_value"], globals_[-1], free, z3)
    check_teardown(objdump, slot, singleton["st_value"], free, clear_descriptor=True)
    used = check_tables(objdump, base, slot, init_addr, init, start, end, overflow, pages, request, z3)
    print(f"{slot}: [{start:#x}, {end:#x}), {size // 4096} pages, metadata malloc({request}), six tables use {used} bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("slots", nargs="+")
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    parser.add_argument("--z3", default="z3")
    args = parser.parse_args()
    check_scheduler_lock(args.objdump, args.base, args.z3)
    check_small_release(args.objdump, args.base, args.z3)
    for slot in args.slots:
        check(args.objdump, args.base, slot, args.z3)
