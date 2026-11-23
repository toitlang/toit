# Copyright (C) 2026 Toit contributors.
"""Check the option-1 EC618 task-tag setter's two scans and store footprint."""

from ec618_thumb import instructions, match_block, match_branch, match_global_address


def check_set_scans(body):
    # Each scan branches solely on equality. Enumerate the location of its
    # first success, with 16 meaning that all reads failed. The two scans
    # may observe different data. Addresses below are relative to tag_map.
    for match in range(17):
        for vacant in range(17) if match == 16 else (16,):
            regs = {0: "task", 2: 0, 3: 0, 4: "value"}
            reads, writes = [], []
            equal = False
            pc = 0x16
            for _ in range(256):
                ins = tuple(int(x, 16) for x in body[pc][0].split())
                following = pc + 2 * len(ins)
                op = ins[0]
                if ins == (0xbd10,):
                    break
                if op == 0xf853 and len(ins) == 2 and ins[1] & 0xfc0 == 0:
                    arg = ins[1]
                    dst, index = arg >> 12, arg & 15
                    offset = regs[3] + (regs[index] << ((arg >> 4) & 3))
                    reads.append(offset)
                    if pc == 0x16:
                        regs[dst] = "task" if offset == match * 8 else "other"
                    elif pc == 0x2c:
                        regs[dst] = int(offset != vacant * 8)
                    else:
                        raise ValueError("unexpected task-tag read")
                elif ins == (0x4281,):
                    equal = regs[1] == regs[0]
                elif op & 0xf800 == 0x2800:
                    equal = regs[(op >> 8) & 7] == (op & 255)
                elif op & 0xf800 == 0x3000:
                    dst = (op >> 8) & 7
                    regs[dst] = (regs[dst] + (op & 255)) & 0xffffffff
                    equal = regs[dst] == 0
                elif op & 0xf800 == 0x2000:
                    regs[(op >> 8) & 7] = op & 255
                    equal = (op & 255) == 0
                elif op & 0xff00 == 0xd100:
                    if not equal:
                        following = pc + 4 + 2 * (((op & 255) ^ 128) - 128)
                elif op & 0xfd00 == 0xb900:
                    if regs[op & 7]:
                        following = pc + 4 + 2 * ((op >> 3) & 31) + ((op >> 9) & 1) * 64
                elif op & 0xf800 == 0xe000:
                    following = pc + 4 + 2 * (((op & 2047) ^ 1024) - 1024)
                elif op == 0xeb03 and len(ins) == 2:
                    arg = ins[1]
                    if arg not in (0x03c1, 0x03c2):
                        raise ValueError("unexpected task-tag address calculation")
                    regs[3] += regs[arg & 15] << 3
                elif ins == (0xf843, 0x0031):
                    writes.append((regs[3] + 8 * regs[1], regs[0]))
                elif op & 0xf800 == 0x6000:
                    writes.append((regs[(op >> 3) & 7] + 4 * ((op >> 6) & 31), regs[op & 7]))
                else:
                    raise ValueError(f"unsupported task-tag instruction at {pc:#x}")
                pc = following
            else:
                raise ValueError("task-tag setter failed to return")
            expected_reads = list(range(0, min(match + 1, 16) * 8, 8))
            expected_writes = []
            if match < 16:
                expected_writes.append((8 * match + 4, "value"))
            else:
                expected_reads.extend(range(0, min(vacant + 1, 16) * 8, 8))
                if vacant < 16:
                    expected_writes = [(8 * vacant, "task"), (8 * vacant + 4, "value")]
            if pc != 0x4a or reads != expected_reads or writes != expected_writes:
                raise ValueError("task-tag accesses differ from the two bounded scans")


def check_tag_updates(objdump, base, slot):
    for operation in ("Get", "Set"):
        port = "vPort" + operation + "HeapTag"
        port_entry, wrapper = instructions(objdump, base, port)
        vm = "_ZN4toit2OS12" + operation.lower() + "_heap_tag" + ("Ev" if operation == "Get" else "Ei")
        match_branch(instructions(objdump, slot, vm)[1], 0, "b.w", port, port_entry)
        target = "cmpct_" + operation.lower() + "_option"
        entry, body = instructions(objdump, base, target)
        current = "xTaskGetCurrentTaskHandle"
        if operation == "Get":
            match_block(wrapper, 0, "2001")
            match_branch(wrapper, 2, "b.w", target, entry)
            match_block(body, 0, "2801|b508|d111")
            match_branch(body, 6, "bl", current, instructions(objdump, base, current)[0])
            match_block(body, 0xe, "2200")
            match_global_address(body, 0xa, 3, base, "tag_map", size=128, high_pc=0x10)
            match_block(body, 0x14, "f853 1032|4281|d103|eb03 03c2|6858|e003|3201|2a10|d1f4|2000|bd08")
        else:
            match_global_address(wrapper, 0, 3, base, "heap_initialized")
            match_block(wrapper, 8, "681b|4602|b13b")
            match_global_address(wrapper, 0xe, 3, base, "heap")
            match_block(wrapper, 0x16, "2101|6818")
            match_branch(wrapper, 0x1a, "b.w", target, entry)
            match_block(wrapper, 0x1e, "4770")
            match_block(body, 0, "2901|b510|4614|d11e")
            match_branch(body, 8, "bl", current, instructions(objdump, base, current)[0])
            match_global_address(body, 0xc, 3, base, "tag_map", size=128, high_pc=0x12)
            match_block(body, 0x10, "2200")
            check_set_scans(body)
