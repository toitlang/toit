# Copyright (C) 2026 Toit contributors.
"""Check the linked bucket allocator's allocation header, split and clear."""

from bisect import bisect_left, bisect_right

from elftools.elf.elffile import ELFFile

from ec618_free_buckets import bucket_lower_bounds
from ec618_thumb import instructions, match_block, match_branch, match_global_address


def check_small_grant(objdump, base):
    def code(name):
        return instructions(objdump, base, name)

    def call(body, pc, name, op="bl"):
        match_branch(body, pc, op, name, code(name)[0])

    _, dispatch = code("cmpct_malloc_impl")
    match_block(dispatch, 0x18, "4621|4628|b003|e8bd 4030")
    call(dispatch, 0x22, "cmpct_alloc", "b.w")
    _, alloc = code("cmpct_alloc")
    match_block(alloc, 0, "2901|b57f|bf38|2101|460d|4604|a903|4628")
    call(alloc, 0x10, "size_to_index_allocating")
    match_block(alloc, 0x14, "4606|9b03|3308|9303")
    call(alloc, 0x1c, "lock.constprop.0")
    match_block(alloc, 0x20, "4632|4629|4620")
    call(alloc, 0x26, "get_bucket_for_size")
    match_block(alloc, 0x2a, "1c43|d009|eb04 0180|9000|462a|4620|9b03|69c9")
    call(alloc, 0x3c, "allocation_tail")
    match_block(alloc, 0x40, "e000|2000|b004|bd70")
    _, sizing = code("size_to_index_allocating")
    match_block(sizing, 0, "f06f 0207|3007|2301|4010")
    call(sizing, 0xa, "size_to_index_helper", "b.w")
    # This shared helper is also checked in full by check_free_buckets.
    # The 28-byte descriptor takes its <=128 path: rounded=32, bucket=3.
    match_block(code("size_to_index_helper")[1], 0, "2880|b510|d803|6008|08c0|3801|e01c")

    _, select = code("get_bucket_for_size")
    match_block(select, 0, "b5f8|460c|4611|4606|4617")
    call(select, 0xa, "find_nonempty_bucket")
    match_block(select, 0xe, "1c43|4605|d111|f504 519f|311f|4630|0b09")
    call(select, 0x1e, "heap_grow.constprop.0")
    match_block(select, 0x22, "2800|da02")
    call(select, 0x26, "unlock.constprop.0")
    match_block(select, 0x2a, "e005|4639|4630|e8bd 40f8")
    call(select, 0x34, "find_nonempty_bucket", "b.w")
    match_block(select, 0x38, "4628|bdf8")
    _, scan = code("find_nonempty_bucket")
    match_block(scan, 0, "43cb|f003 021f|2302|4093|114a|eb00 0282|f8d2 213c|3b01|4013|"
                "d004|fab3 f083|f021 011f|e00f|3120|f021 011f|e000|3120|2948|dc0a|"
                "114b|eb00 0383|f8d3 313c|2b00|d0f5|fab3 f083|4408|4770|f04f 30ff|4770")
    # Bitmap words use MSB-first indices. For any fixed first eligible bit
    # all smaller indices after start are zero; earlier and later eligible
    # input bits range freely. The scan masks, then selects the highest set
    # bit of the first nonzero word. Each step is monotone in bitmap inclusion
    # (adding bits can only lower the selected index; 72 represents failure).
    for start in range(72):
        for first in range(start, 73):
            least = (1 << (71 - first)) if first < 72 else 0
            most = ((1 << 72) - (1 << (72 - start))) | (least * 2 - 1 if least else 0)
            for bits in (least, most):
                packed = bits << 24  # unused low bits in the last word are zero
                word = start >> 5
                selected = (packed >> (64 - word * 32)) & 0xffffffff
                selected &= ((2 << ((~start) & 31)) - 1) & 0xffffffff
                while not selected and word < 2:
                    word += 1
                    selected = (packed >> (64 - word * 32)) & 0xffffffff
                index = word * 32 + 32 - selected.bit_length() if selected else 72
                if index != first:
                    raise ValueError("bitmap search skipped the first eligible free bucket")

    # For every small malloc size selected by cmpct_malloc_impl, the
    # candidate bucket's minimum payload fits the request. A fresh arena
    # from the linked growth calculation contains a qualifying free block.
    bounds = bucket_lower_bounds()
    for request in (*range(1, 3072), *range(4097, 6145)):
        aligned = (request + 7) & ~7
        if aligned <= 128:
            bucket, rounded = (aligned >> 3) - 1, aligned
        else:
            adjusted = aligned - 8
            shift = adjusted.bit_length() - 4
            row_column = ((shift << 3) | ((adjusted >> shift) & 7)) + 1
            bucket = row_column - 17
            rounded = (8 + (row_column & 7)) << (row_column >> 3)
        pages = (request + 5088 + 31) >> 12
        arena_payload = (pages << 12) - 32
        if (bucket != bisect_left(bounds, request) or bounds[bucket] != rounded
                or bisect_right(bounds, arena_payload) - 1 < bucket):
            raise ValueError("selected bucket or fresh arena cannot satisfy small malloc")

    _, body = code("allocation_tail")
    match_block(body, 0, "e92d 43f8|884f|4606|eba7 0903|f1b9 0f0f|4610|460d|461c|9a08|"
                "d916|ebb9 1f50|d913|4608")
    call(body, 0x22, "right_header")
    match_block(body, 0x26, "4680|192f|4630")
    call(body, 0x2c, "unlink_free")
    match_block(body, 0x30, "4639|464b|4622|4630")
    call(body, 0x38, "create_free_area.constprop.0")
    match_block(body, 0x3c, "4639|4640")
    call(body, 0x40, "fix_left_size")
    match_block(body, 0x44, "4627|e003|4629|4630")
    call(body, 0x4c, "unlink_free")
    call(body, 0x50, "get_thread_tag")
    match_block(body, 0x54, "882a|4603|4639|4628")
    call(body, 0x5c, "create_allocation_header")
    match_block(body, 0x60, "68f3|4605|3301|60f3|2300|461a|3c08|429c|d904|1099|"
                "f845 2021|3304|e7f8")
    call(body, 0x7c, "unlock.constprop.0")
    match_block(body, 0x80, "4628|e8bd 83f8")
    # get_thread_tag runs under heap suspension. Match all load addresses
    # and both exits, including the pre-scheduler null current task.
    _, lookup = code("get_thread_tag")
    current, load = code("xTaskGetCurrentTaskHandle")
    match_block(lookup, 0, "b508")
    call(lookup, 2, "xTaskGetCurrentTaskHandle")
    match_block(load, 0, "4b01|6818|4770")
    match_block(lookup, 6, "b180")
    match_block(lookup, 0xc, "2200")
    match_block(lookup, 0x12, "f853 1032|4281|d103|eb03 03c2|6858|e003|3201|2a10|d1f4|2000|bd08")
    with open(base, "rb") as stream:
        elf = ELFFile(stream)
        symbols = elf.get_section_by_name(".symtab")
        table, = symbols.get_symbol_by_name("tag_map")
        handle, = symbols.get_symbol_by_name("pxCurrentTCB")
        for symbol, length in ((table, 16 * 8), (handle, 4)):
            section = elf.get_section(symbol["st_shndx"])
            address = symbol["st_value"]
            if (symbol["st_size"] != length or address % 4 or section["sh_flags"] & 3 != 3 or
                    not section["sh_addr"] <= address <= section["sh_addr"] + section["sh_size"] - length):
                raise ValueError("unexpected allocator task-tag storage")
        if current % 4 or int(load[8][0], 16) != handle["st_value"]:
            raise ValueError("task-tag lookup uses an unexpected current task pointer")
    match_global_address(lookup, 8, 3, base, "tag_map", size=128, high_pc=0xe)
    _, header = code("create_allocation_header")
    match_block(header, 0, "b510|4604|4610")
    call(header, 6, "untag")
    match_block(code("untag")[1], 0, "f020 0001|4770")
    match_block(header, 0xa, "b280|ea40 4101|e9c4 1300|f104 0008|bd10")
