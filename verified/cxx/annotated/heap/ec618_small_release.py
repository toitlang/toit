# Copyright (C) 2026 Toit contributors.
"""Check linked small-block coalescing up to the free-list helper calls."""

from pathlib import Path
import subprocess

from ec618_free_buckets import check_free_buckets
from ec618_small_grant import check_small_grant
from ec618_thumb import instructions, match_block, match_branch


def check_small_release(objdump, base, z3):
    def code(name):
        return instructions(objdump, base, name)

    def call(body, pc, name, op="bl"):
        match_branch(body, pc, op, name, code(name)[0])

    # On this base the nothrow overload tail-calls ordinary operator new.
    # A returning handler leads to another malloc attempt with the same size.
    _, body = code("_ZnwjRKSt9nothrow_t")
    call(body, 0, "_Znwj", "b.w")
    _, body = code("_Znwj")
    match_block(body, 0, "2801|bf38|2001|b510|4604|4620")
    call(body, 0xc, "malloc")
    match_block(body, 0x10, "b930")
    call(body, 0x12, "_ZSt15get_new_handlerv")
    match_block(body, 0x16, "b908")
    call(body, 0x18, "abort")
    match_block(body, 0x1c, "4780|e7f4|bd10")

    _, body = code("cmpct_free_impl")
    match_block(body, 0x22, "4629|4620|e8bd 4038")
    call(body, 0x2a, "cmpct_free", "b.w")
    _, body = code("cmpct_free")
    match_block(body, 0, "2201")
    call(body, 2, "cmpct_free_optionally_locked", "b.w")

    _, body = code("cmpct_free_optionally_locked")
    tagged = "is_tagged_as_free.isra.0"
    unlink = "unlink_free_unknown_bucket"
    match_block(code(tagged)[1], 0, "f000 0001|4770")
    match_block(code("left_header")[1], 0, "6803|f023 0301|041b|0c1b|1ac0|4770")
    match_block(code("right_header")[1], 0, "8843|4418|4770")
    match_block(code("tag_as_free")[1], 0, "f040 0001|4770")
    match_block(body, 0, "e92d 47f0|4604|4691|460d|2900|d063|6982|2a00|d160|"
                "f851 3c08|f1a1 0a08|4618")
    call(body, 0x1e, tagged)
    match_block(body, 0x22, "b138")
    match_block(body, 0x34, "ea4f 4813|f1b9 0f00|d001")
    call(body, 0x3e, "lock.constprop.0")
    match_block(body, 0x42, "68e3|4650|3b01|60e3")
    call(body, 0x4a, "left_header")
    match_block(body, 0x4e, "4607|4650")
    call(body, 0x52, "right_header")
    match_block(body, 0x56, "4606|6838")
    call(body, 0x5a, tagged)
    match_block(body, 0x5e, "b308|f855 1c08|b288")
    call(body, 0x66, "tag_as_free")
    match_block(body, 0x6a, "0c09|0409|4301|f845 1c08|4620|4639")
    call(body, 0x78, unlink)
    match_block(body, 0x7c, "6830")
    call(body, 0x7e, tagged)
    match_block(body, 0x82, "b148|4631|4620")
    call(body, 0x88, unlink)
    match_block(body, 0x8c, "683a|8873|eb03 4312|4443|e002|683a|eb08 4312|4639|b292|e00e|6830")
    call(body, 0xa6, tagged)
    match_block(body, 0xaa, "b130|4631|4620")
    call(body, 0xb0, unlink)
    match_block(body, 0xb4, "8873|4443|e000|4643|4651|f835 2c08|4620")
    call(body, 0xc4, "free_memory")
    match_block(body, 0xc8, "f1b9 0f00|d003|e8bd 47f0")
    call(body, 0xd2, "unlock.constprop.0", "b.w")
    match_block(body, 0xd6, "e8bd 87f0")

    _, body = code("free_memory")
    match_block(body, 0, "e92d 41f0|460d|461e|4607")
    call(body, 0xa, "create_free_area.constprop.0")
    match_block(body, 0xe, "4628")
    call(body, 0x10, "left_header")
    match_block(body, 0x14, "4604|4628")
    call(body, 0x18, "right_header")
    match_block(body, 0x1c, "4629")
    call(body, 0x1e, "fix_left_size")
    match_block(code("fix_left_size")[1], 0, "6803|1a41|f003 0201|0c1b|440a|041b|4313|6003|4770")
    match_block(body, 0x22, "f1a4 0308|f100 0208|4313|f3c3 030b|4680|b9ab|6820")
    first = "is_start_of_page_allocation.isra.0"
    last = "is_end_of_page_allocation.isra.0"
    call(body, 0x36, first)
    match_block(code(first)[1], 0, "b280|fab0 f080|0940|4770")
    match_block(body, 0x3a, "b188|f8d8 0000")
    call(body, 0x40, last)
    match_block(code(last)[1], 0, "0c03|bf0c|2001|2000|4770")
    match_block(body, 0x44, "b160|4629|4638")
    call(body, 0x4a, unlink)
    match_block(body, 0x4e, "8862|3608|4621|4638|4432|e8bd 41f0")
    call(body, 0x5c, "free_to_page_allocator", "b.w")
    match_block(body, 0x60, "e8bd 81f0")

    _, growth = code("heap_grow.constprop.0")
    # The fifth argument selects arena-head status 2 at page allocation.
    match_block(growth, 0, "2301|b573|f44f 5280|9300|2300|460d|4604")
    call(growth, 0x10, "page_alloc")
    match_block(growth, 0x14, "4601|b148|6823|032e|eba3 3305|4632|4620|6023")
    call(growth, 0x26, "add_to_heap.constprop.0")
    match_block(growth, 0x2a, "e001|f04f 36ff|4630|b002|bd70")
    _, arena = code("free_to_page_allocator")
    # LDMDB reads previous and next from the two words before the left
    # sentinel. Neither intervening store modifies flags from the CMN.
    match_block(arena, 0, "b538|460b|0512|f512 0f00|e913 0028|4604|602b|f1a1 0108|605d|d00f")
    match_block(arena, 0x3a, "2201")
    call(arena, 0x3c, "page_free.constprop.0")
    match_block(arena, 0x40, "6823|3318|6023|bd38")

    _, pred = code("is_page_allocated")
    match_block(pred, 0, "4602|b508|4608|b1c1|f3c1 000b|b9a0|f8d2 0154")
    call(pred, 0x12, "page_number.isra.0")
    match_block(code("page_number.isra.0")[1], 0, "1a08|0b00|4770")
    match_block(pred, 0x16, "eb02 02c0|f8d2 015c|b938")
    match_block(pred, 0x30, "1e43|4258|4158|e000|2000|bd08")

    check_free_buckets(objdump, base)
    check_small_grant(objdump, base)
    for filename, expected in (("ec618_small_release.smt2", ["sat"] * 4 + ["unsat"] * 2),
                               ("ec618_small_grant.smt2", ["unsat"] * 4 + ["sat"] * 2),
                               ("ec618_free_buckets.smt2", ["unsat"] * 2),
                               ("ec618_arena_return.smt2", ["unsat"] * 5)):
        proof = Path(__file__).with_name(filename)
        results = subprocess.check_output([z3, str(proof)], text=True).splitlines()
        if results != expected:
            raise ValueError(f"failed {filename}: {results}")
