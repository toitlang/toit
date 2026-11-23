# Copyright (C) 2026 Toit contributors.
"""Check the release of a live ordinary page allocation in the linked v5 base."""

from itertools import product

from ec618_thumb import instructions, match_block, match_branch, match_global_address


def check_teardown(objdump, slot, singleton, free, *, clear_descriptor=False):
    name = "_ZN4toit2OS21ungrab_virtual_memoryEPvj"
    wrapper, body = instructions(objdump, slot, name)
    match_branch(body, 0, "b.w", "free", free)
    entry, body = instructions(objdump, slot, "_ZN4toit10GcMetadata9tear_downEv")
    if clear_descriptor:
        # r0/r1 retain the pointer and size across the paired zero stores.
        # A null pointer branches straight to the return at +0x32.
        if entry % 4 or int(body[0x34][0], 16) != singleton:
            raise ValueError("metadata teardown loads an unexpected singleton")
        match_block(body, 0, "4b0c|6998|b1a8|2200|6959")
        for word in range(0, 18, 2):
            match_block(body, 0xa + word * 2, f"e9c3 {0x2200 + word:04x}")
        match_branch(body, 0x2e, "b.w", name, wrapper)
        match_block(body, 0x32, "4770")
        return
    match_block(body, 0, "4b02|e9d3 1005")
    if entry % 4 or int(body[12][0], 16) != singleton:
        raise ValueError("metadata teardown loads an unexpected singleton")
    match_branch(body, 6, "b.w", name, wrapper)


def check_object_memory_lifecycle(objdump, slot, globals_):
    prefix = "_ZN4toit12ObjectMemory"
    setup_addr, setup = instructions(objdump, slot, prefix + "6set_upEv")
    down_addr, down = instructions(objdump, slot, prefix + "9tear_downEv")
    if (setup_addr | down_addr) & 3:
        raise ValueError("unexpected object memory literal alignment")

    def call(body, pc, name, opcode="bl"):
        match_branch(body, pc, opcode, name, instructions(objdump, slot, name)[0])

    mutex, spare, allocated = globals_
    for body, pc, address in ((setup, 0x54, mutex), (setup, 0x5c, allocated),
                              (setup, 0x6c, spare), (down, 0x28, mutex), (down, 0x30, spare)):
        match_block(body, pc, f"{address:08x}")

    release = "_ZN4toit10GcMetadata9tear_downEv"
    free_chunk = prefix + "10free_chunkEPNS_5ChunkE"
    fail = "_ZN4toit4failEPKcz"
    match_block(setup, 0, "b538|4d14|682c|b10c|4813|e011|4b13|f3bf 8f5b|601c|f3bf 8f5b")
    call(setup, 0x18, "_ZN4toit10GcMetadata6set_upEv")
    match_block(setup, 0x1c, "4620|f44f 5180")
    call(setup, 0x22, prefix + "14allocate_chunkEPNS_5SpaceEj")
    match_block(setup, 0x26, "4604|b920")
    call(setup, 0x2a, release)
    match_block(setup, 0x2e, "480c")
    call(setup, 0x30, fail)
    match_block(setup, 0x34, "2007|490b")
    call(setup, 0x38, "_ZN4toit2OS14allocate_mutexEiPKc")
    match_block(setup, 0x3c, "b930|4620")
    call(setup, 0x40, free_chunk)
    call(setup, 0x44, release)
    match_block(setup, 0x48, "4807|e7f1|4b07|6028|601c|bd38")

    match_block(down, 0, "b538|4c09|6820|b910|4808")
    call(down, 0xa, fail)
    match_block(down, 0xe, "2500")
    call(down, 0x10, "_ZN4toit2OS7disposeEPNS_5MutexE")
    match_block(down, 0x14, "6025|4c06|6820")
    call(down, 0x1a, free_chunk)
    match_block(down, 0x1e, "6025|e8bd 4038")
    call(down, 0x24, release, "b.w")


def check_page_release(objdump, base, heap, low, limit):
    def routine(name):
        return instructions(objdump, base, name)

    free, body = routine("free")
    port, port_body = routine("vPortFree")
    match_block(body, 0, "b108")
    match_branch(body, 2, "b.w", "vPortFree", port)
    match_block(body, 6, "4770")
    match_block(port_body, 0, "b510|4604|b158")
    match_branch(port_body, 6, "bl", "ensure_heap_initialized", routine("ensure_heap_initialized")[0])
    match_global_address(port_body, 0xa, 3, base, "heap")
    match_block(port_body, 0x12, "4621|e8bd 4010|6818")
    dispatch, dispatch_body = routine("cmpct_free_impl")
    match_branch(port_body, 0x1a, "b.w", "cmpct_free_impl", dispatch)
    match_block(port_body, 0x1e, "bd10")

    predicate, pred = routine("is_page_allocated")
    number, num = routine("page_number.isra.0")
    match_block(num, 0, "1a08|0b00|4770")
    match_block(pred, 0, "4602|b508|4608|b1c1|f3c1 000b|b9a0|f8d2 0154")
    match_branch(pred, 0x12, "bl", "page_number.isra.0", number)
    match_block(pred, 0x16, "eb02 02c0|f8d2 015c|b938")
    # For status 1, subtracting one gives zero, negation sets carry,
    # and ADC returns one. The ordinary page release path then takes the lock.
    match_block(pred, 0x30, "1e43|4258|4158|e000")
    match_block(pred, 0x3a, "bd08")
    match_block(dispatch_body, 0, "b538|4604|460d")
    match_branch(dispatch_body, 6, "bl", "is_page_allocated", predicate)
    match_block(dispatch_body, 0xa, "b150")
    match_branch(dispatch_body, 0xc, "bl", "lock.constprop.0", routine("lock.constprop.0")[0])
    match_block(dispatch_body, 0x10, "4629|4620|2200")
    release, body = routine("page_free.constprop.0")
    match_branch(dispatch_body, 0x16, "bl", "page_free.constprop.0", release)
    match_block(dispatch_body, 0x1a, "e8bd 4038")
    match_branch(dispatch_body, 0x1e, "b.w", "unlock.constprop.0", routine("unlock.constprop.0")[0])

    match_block(body, 0, "b5f8|4603|f8d0 0154")
    match_branch(body, 8, "bl", "page_number.isra.0", number)
    match_block(body, 0xc, "b138|eb03 01c0|f8d1 1154|fab1 f181|0949|e000|4601|f8d3 4150|"
                "2a00|bf14|2202|2201|42a0|d205|eb03 04c0|f8d4 515c|4295|d008")
    match_block(body, 0x4e, "4622|2602|2501|f04f 0c00|f8d2 7164|3208|2f03|d104|4635|"
                "f8c2 c15c|3601|e7f5")
    match_block(body, 0x6c, "685a|4428|eb02 3205|eb03 00c0|605a|f8d0 215c|b919|b132|"
                "689a|3201|e002|b912|689a|3a01|609a|2300|f8c4 315c|bdf8")

    # CMP r2,#0; ITE NE; MOVNE r2,#imm; MOVEQ r2,#imm.
    release_status = {True: int(body[0x28][0], 16) & 255,
                      False: int(body[0x2a][0], 16) & 255}
    page_base = (low + 4095) & ~4095
    count = (limit - page_base) >> 12
    table = heap + 348
    if not count or table + (count + 1) * 8 > low:
        raise ValueError("release requires mapped descriptors and an allocated sentinel")
    for head in range(count):
        ptr = page_base + (head << 12)
        index = ((ptr - page_base) & 0xffffffff) >> 12
        if ptr == 0 or ptr & 4095 or index != head or index >= count:
            raise ValueError("page head fails release dispatch")
        for stop in range(head + 1, count + 1):
            # Only these status words can be read. A missing entry detects an
            # out-of-extent load. Both tags and payload remain outside all stores.
            # At stop a well-formed extent has a non-continuation. Status 1
            # represents all occupied neighbors: the left test distinguishes
            # zero only, and the right tests distinguish 3, zero and other.
            boundary = table + stop * 8
            for arena, left_free, right_free in product((False, True), repeat=3):
                if (head == 0 and left_free) or (stop == count and right_free):
                    continue
                # Direct free passes r2=0; free_to_page_allocator passes
                # r2=1. The CMP/ITE selects the corresponding head status.
                head_status = 2 if arena else 1
                states = {table + head * 8: head_status, boundary: 0 if right_free else 1}
                if head:
                    states[table + (head - 1) * 8] = 0 if left_free else 1
                for i in range(head + 1, stop):
                    states[table + i * 8] = 3
                initial = states.copy()
                if states[heap + (index << 3) + 348] != release_status[arena]:
                    raise ValueError("release dispatch missed its owned head")
                previous_free = bool(index and states[heap + (index << 3) + 340] == 0)
                cursor = heap + (index << 3)
                pages, following = 1, 2
                while states[cursor + 356] == 3:
                    cursor += 8
                    states[cursor + 348] = 0
                    pages = following
                    following += 1
                next_status = states[heap + ((index + pages) << 3) + 348]
                if previous_free:
                    run_delta = -1 if next_status == 0 else 0
                else:
                    run_delta = 1 if next_status != 0 else 0
                states[heap + (index << 3) + 348] = 0
                if (pages << 12 != (stop - head) * 4096 or
                        run_delta != 1 - int(left_free) - int(right_free) or
                        any(value != (0 if table + head * 8 <= addr < boundary else initial[addr])
                            for addr, value in states.items())):
                    raise ValueError("page release changes a neighbor or miscounts the freed run")
    return free
