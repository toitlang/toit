# Copyright (C) 2026 Toit contributors.
"""Check the linked scavenge survivor transfer and outgoing spare."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def transfer(body, set_owner, target, has_old):
    # Distinct addresses represent exclusive objects. Only identity, pointer
    # copying and constant field offsets matter here. Exercise both shapes of
    # the outgoing ring; the temporary semispace always has one live chunk.
    source, temp, old, live = 0x1000, 0x2000, 0x3000, 0x4000
    a, b = source + 8, temp + 8
    regs = {4: temp, 6: source, 8: b}
    mem = {a: old if has_old else a, a+4: old if has_old else a,
           b: live, b+4: live, live: b, live+4: b, live+8: temp,
           source+16: "old-top", source+20: "old-limit", temp+16: "top", temp+20: "limit"}
    if has_old:
        mem.update({old: a, old+4: a, old+8: source})
    expected = dict(mem)
    expected.update({a: live, a+4: live, live: a, live+4: a, live+8: source,
                     b: b, b+4: b, source+16: "top", source+20: "limit", temp+16: 0, temp+20: 0})
    if has_old:
        expected.update({old: old, old+4: old, old+8: 0})
    calls = []
    pc = 0x70
    # r6=from, r4=to at the end of watermark selection.
    match_block(body, pc, "4633|f853 5f08|429d|d00a")
    match_block(body, 0x8e, "e000|2500|68a3|4628|4543|bf0f|2300|e9d3 1200|604a|6011|bf18|e9c3 3300")
    regs[3] = a
    regs[5] = mem[a]
    pc = 0x90 if regs[5] == a else 0x7a
    while pc < 0xc6:
        op = tuple(int(x, 16) for x in body[pc][0].split())
        h = op[0]
        following = pc + 2 * len(op)
        if pc == 0x8a:
            match_branch(body, pc, "bl", set_owner, target)
            if not has_old or (regs[0], regs[1]) != (old, 0):
                raise ValueError("swap clears the wrong owner")
            calls.append(old)
            mem[old+8] = 0  # checked set_owner(null) also declassifies its pages
            for reg in (0, 1, 2, 3):
                regs.pop(reg, None)
        elif op == (0xe000,):
            following = pc + 4
        elif op == (0x4543,):
            if pc != 0x96 or regs[3] == regs[8]:
                raise ValueError("survivor chunk missing")
        elif op == (0xbf0f,):
            # The comparison above took NE: skip MOVEQ, run three NEs.
            match_block(body, following, "2300")
            following += 2
        elif op == (0xbf18,):
            pass  # IT NE, flags unchanged
        elif h & 0xff00 == 0x4600:
            regs[(h & 7) | ((h >> 4) & 8)] = regs[(h >> 3) & 15]
        elif h & 0xf800 == 0x2000:
            regs[(h >> 8) & 7] = h & 255
        elif h & 0xf800 in (0x6000, 0x6800):
            addr = regs[(h >> 3) & 7] + 4 * ((h >> 6) & 31)
            if h & 0x800:
                regs[h & 7] = mem[addr]
            else:
                mem[addr] = regs[h & 7]
        elif h & 0xfff0 in (0xe9c0, 0xe9d0):
            addr = regs[h & 15] + 4 * (op[1] & 255)
            r1, r2 = op[1] >> 12, (op[1] >> 8) & 15
            if h & 0x10:
                regs[r1], regs[r2] = mem[addr], mem[addr+4]
            else:
                mem[addr], mem[addr+4] = regs[r1], regs[r2]
        else:
            raise ValueError(f"unsupported semispace transfer instruction at {pc:#x}")
        pc = following
    match_block(body, 0xc6, "e8bd 81f0")
    if mem != expected or regs[0] != (old if has_old else 0) or calls != ([old] if has_old else []):
        raise ValueError("swap changes live metadata, ring links, spare or allocation bounds")


def check_semispace_swap(objdump, slot, singleton, set_owner, owner_entry):
    swap = "_ZN4toit12TwoSpaceHeap16swap_semi_spacesERNS_9SemiSpaceES2_"
    entry, body = instructions(objdump, slot, swap)
    if entry % 4 or int(body[0xcc][0], 16) != singleton:
        raise ValueError("swap reads the wrong heuristics")
    match_block(body, 0, "e92d 41f0|4614|6913|6902|f8c0 3094|f100 0310|429a|4b2d|bf08|"
                "f890 70a8|6c9b|bf14|2700|f087 0701|2b27|4605|460e|f104 0808|dc0e|"
                "6823|4620|691b|4798|b14f|f5b0 6f00|d206|68a3|4543|bf08|2300|68db|f8c5 3094")
    match_block(body, 0x50, "686b|f8d3 20c8|b15a|f8d3 30c0|f5b3 5f80|d806|68a3|4543|"
                "bf08|2300|68db|f8c5 3094")
    used_entry, used = instructions(objdump, slot, "_ZNK4toit9SemiSpace4usedEv")
    match_block(used, 0, "6881|f100 0308|4299|bf0c|2300|68c3|6902|68d8|1a10|4770")
    with open(slot, "rb") as stream:
        elf = ELFFile(stream)
        symbols = elf.get_section_by_name(".symtab")
        table, = symbols.get_symbol_by_name("_ZTVN4toit9SemiSpaceE")
        spare, = symbols.get_symbol_by_name("_ZN4toit12ObjectMemory12spare_chunk_E")
        section = elf.get_section(table["st_shndx"])
        offset = table["st_value"] - section["sh_addr"] + 8 + 16
        if table["st_size"] < 28 or not 0 <= offset <= section["sh_size"] - 4:
            raise ValueError("semispace used-method slot outside vtable")
        stream.seek(section["sh_offset"] + offset)
        if int.from_bytes(stream.read(4), "little") != used_entry + 1:
            raise ValueError("swap calls a different used method")
    for has_old in (False, True):
        transfer(body, set_owner, owner_entry, has_old)

    # The two successful collection paths publish the returned spare in
    # different storage, then destroy the now-empty temporary space.
    caller, collect = instructions(objdump, slot, "_ZN4toit12TwoSpaceHeap17collect_new_spaceEb")
    if caller % 4 or int(collect[0x1e0][0], 16) != spare["st_value"]:
        raise ValueError("shared spare literal does not name ObjectMemory's spare")
    if int(collect[0x1e4][0], 16) != table["st_value"] + 8:
        raise ValueError("unexpected temporary semispace vtable")
    destroy = "_ZN4toit5SpaceD1Ev"
    destroy_entry, destructor = instructions(objdump, slot, destroy)
    match_block(collect, 0x10a, "4641|aa0e|4607|4620|f89d b058")
    match_branch(collect, 0x116, "bl", swap, entry)
    match_block(collect, 0x11a, "4b31|f8cd a020|6018|4b30|a80e|930e")
    match_branch(collect, 0x128, "bl", destroy, destroy_entry)
    match_block(collect, 0x12c, "a805")
    leave = "_ZN4toit6Locker5leaveEv"
    match_branch(collect, 0x12e, "bl", leave, instructions(objdump, slot, leave)[0])
    match_block(collect, 0x186, "4641|4607|aa0e|4620|f89d b058")
    match_branch(collect, 0x192, "bl", swap, entry)
    match_block(collect, 0x196, "4b13|f8c4 0090|a80e|f8cd a020|930e")
    match_branch(collect, 0x1a4, "bl", destroy, destroy_entry)
    cleanup = "_ZN4toit5Space15free_all_chunksEv"
    cleanup_entry, free_all = instructions(objdump, slot, cleanup)
    match_block(destructor, 0, "b510|4604|4b02|6003")
    match_branch(destructor, 8, "bl", cleanup, cleanup_entry)
    match_block(destructor, 0xc, "4620|bd10")
    match_block(free_all, 0, "b538|4604|f100 0508|68a0|42a8|d009")
    match_block(free_all, 0x22, "2300|e9c4 3304|bd38")
