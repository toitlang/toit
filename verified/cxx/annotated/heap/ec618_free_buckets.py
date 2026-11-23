# Copyright (C) 2026 Toit contributors.
"""Check EC618 free-list bucket selection and neighbor link updates."""

from bisect import bisect_right
from itertools import product

from ec618_thumb import instructions, match_block, match_branch


def check_unlink_links(body, clear):
    # These pointers represent distinct live nodes. The suffix compares only
    # pointer equality with the head and null, so address renaming is immaterial.
    for at_head, has_next in product((False, True), repeat=2):
        node = 0x1000
        head = node if at_head else 0x2000
        prev = 0 if at_head else 0x3000
        nxt = 0x4000 if has_next else 0
        # r3 is the selected bucket field's base, r4 the removed node.
        regs = {2: head, 3: 0x5000, 4: node, 5: nxt, 6: prev}
        writes = {}
        clears = 0
        pc = 0x36  # cmp r2,r4 following the bucket-head load
        zero = None
        for _ in range(24):
            ins = int(body[pc][0].split()[0], 16)
            following = pc + 2
            if ins == 0xbd70:
                break
            if ins == 0x42a2:
                zero = regs[2] == regs[4]
            elif ins == 0x2e00:
                zero = regs[6] == 0
            elif ins & 0xff00 == 0xd100:  # bne
                if not zero:
                    displacement = ins & 255
                    following = pc + 4 + 2 * (displacement - (256 if displacement >= 128 else 0))
            elif ins & 0xf500 == 0xb100:  # cbz / cbnz
                nonzero = bool(ins & 0x800)
                if bool(regs[ins & 7]) == nonzero:
                    following = pc + 4 + ((ins >> 3) & 31) * 2 + ((ins >> 9) & 1) * 64
            elif ins & 0xf800 == 0xe000:
                displacement = ins & 2047
                following = pc + 4 + 2 * (displacement - (2048 if displacement >= 1024 else 0))
            elif ins & 0xf800 == 0x6000:  # str immediate
                address = regs[(ins >> 3) & 7] + 4 * ((ins >> 6) & 31)
                if address in writes:
                    raise ValueError("duplicate unlink store")
                writes[address] = regs[ins & 7]
            elif pc == 0x3e:
                match_branch(body, pc, "bl", "clear_free_list_bit", clear)
                clears += 1
                # This routine modifies r0, r1 and r3.
                regs.pop(3)
                following = pc + 4
            else:
                raise ValueError(f"unexpected unlink instruction at {pc:#x}")
            pc = following
        else:
            raise ValueError("unlink did not return")
        expected = {}
        if at_head:
            expected[0x5000 + 28] = nxt
        if prev:
            expected[prev + 8] = nxt
        if nxt:
            expected[nxt + 12] = prev
        if writes != expected or clears != int(at_head and not nxt):
            raise ValueError("unlink corrupted bucket head, occupancy or neighbor links")


def check_insert_links(body):
    # r2 points 28 bytes below the bucket field. r6 is a disjoint new node.
    # Accounting uses a single ADD on each field, so comparing symbolic
    # addends also covers every initial counter and block size (modulo 2^32).
    for head in (0, 0x3000):
        heap, bucket, node = 0x1000, 0x1040, 0x2000
        regs = {2: bucket, 5: heap, 6: node, 7: "size"}
        memory = {bucket + 28: head, heap + 8: "count", heap + 4: "bytes"}
        expected = {bucket + 28: node, node + 8: head, node + 12: 0,
                    heap + 8: ("count", 1), heap + 4: ("bytes", "size")}
        if head:
            expected[head + 12] = node
        pc = 0x32
        while pc <= 0x4c:
            op = int(body[pc][0], 16)
            if op == 0xbdf8:
                break
            if op & 0xf800 in (0x6000, 0x6800):
                address = regs[(op >> 3) & 7] + 4 * ((op >> 6) & 31)
                if op & 0x800:
                    regs[op & 7] = memory[address]
                else:
                    memory[address] = regs[op & 7]
            elif op == 0xb103:
                if regs[3] == 0:
                    pc += 2
            elif op == 0x2300:
                regs[3] = 0
            elif op == 0x3301:
                regs[3] = (regs[3], 1)
            elif op == 0x443b:
                regs[3] = (regs[3], regs[7])
            else:
                raise ValueError(f"unexpected insertion instruction at {pc:#x}")
            pc += 2
        if pc != 0x4c or memory != expected:
            raise ValueError("insertion corrupted bucket head, accounting or neighbor links")


def bucket_lower_bounds():
    bounds = list(range(8, 129, 8))
    for step in (16, 32, 64, 128, 256, 512, 1024):
        bounds.extend(range(8 * step + step, 16 * step + 1, step))
    return bounds


def check_free_buckets(objdump, base):
    def code(name):
        return instructions(objdump, base, name)

    index, size = code("size_to_index_freeing")
    helper, body = code("size_to_index_helper")
    match_block(size, 0, "2300|b507|461a|a901")
    match_branch(size, 8, "bl", "size_to_index_helper", helper)
    match_block(size, 0xc, "b003|f85d fb04")
    match_block(body, 0, "2880|b510|d803|6008|08c0|3801|e01c|4402|fab2 f482|f1c4 041c|"
                "40e2|f002 0007|ea40 00c4|4418|f000 0307|10c2|3308|3811|4093|2847|600b|dd08")
    match_block(body, 0x48, "bd10")
    # Independent sorted lower bounds: 8-byte classes through 128, then
    # eight classes per doubling. Compare every aligned free-block payload.
    bounds = bucket_lower_bounds()
    for total in range(16, 16384, 8):
        payload = total - 8
        if payload <= 128:
            bucket = (payload >> 3) - 1
        else:
            shift = payload.bit_length() - 4
            bucket = ((shift << 3) | ((payload >> shift) & 7)) - 17
        if bucket != bisect_right(bounds, payload) - 1 or not 0 <= bucket < 72:
            raise ValueError("free block selects wrong bucket")

    for name, operation in (("set_free_list_bit", "430b"), ("clear_free_list_bit", "ea23 0301")):
        _, bitmap = code(name)
        match_block(bitmap, 0, "114b|43c9|eb00 0083|2301|f001 011f|fa03 f101|f8d0 313c|"
                    + operation + "|f8c0 313c|4770")
    for i in range(72):
        if (i >> 5, (~i) & 31) != (i // 32, 31 - i % 32):
            raise ValueError("bitmap does not address selected bucket")

    _, unknown = code("unlink_free_unknown_bucket")
    match_block(unknown, 0, "b538|4605|8848|460c|3808")
    match_branch(unknown, 0xa, "bl", "size_to_index_freeing", index)
    match_block(unknown, 0xe, "4621|4602|4628|e8bd 4038")
    entry, unlink = code("unlink_free")
    match_branch(unknown, 0x18, "b.w", "unlink_free", entry)
    match_block(unlink, 0, "b570|460c|8865|4611|f5b5 4f80|d308")
    match_block(unlink, 0x20, "6842|eb00 0381|1b52|6042|6882|e9d4 5602|3a01|6082|69da")
    check_unlink_links(unlink, code("clear_free_list_bit")[0])

    _, insert = code("create_free_area.constprop.0")
    match_block(insert, 0, "b5f8|4605|4610")
    match_branch(insert, 6, "bl", "tag_as_free", code("tag_as_free")[0])
    match_block(insert, 0xa, "880c|461f|ea44 4403|0c22|0412|4302|600a|f1a3 0008|460e")
    match_branch(insert, 0x20, "bl", "size_to_index_freeing", index)
    match_block(insert, 0x24, "4602|4601|eb05 0282|4628")
    match_branch(insert, 0x2e, "bl", "set_free_list_bit", code("set_free_list_bit")[0])
    check_insert_links(insert)
