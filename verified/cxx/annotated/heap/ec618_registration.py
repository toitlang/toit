# Copyright (C) 2026 Toit contributors.
"""Check the release allocator's linker-arena registration and bounds readback."""

import re

from ec618_fragments import check_fragments
from ec618_thumb import instructions, match_block, match_branch, match_global_address


def check_registration(objdump, base, first, limit, memset_address):
    _, ensure = instructions(objdump, base, "ensure_heap_initialized")
    register_entry, register = instructions(objdump, base, "cmpct_register_impl")
    init_entry, init = instructions(objdump, base, "cmpct_init")

    # Decode each linked MOVW/MOVT pair by checking its actual operand and opcode.
    def immediate(pc, op, reg):
        m = re.fullmatch(op + r"\s+" + reg + r", #(\d+)(?:\s+@.*)?", ensure[pc][1])
        if not m:
            raise ValueError(f"unexpected arena address instruction at {pc:#x}")
        return int(m[1])

    match_block(ensure, 0, "b508")
    match_global_address(ensure, 2, 3, base, "heap_initialized")
    match_block(ensure, 0xa, "681a|b98a")
    arena = immediate(0x12, "movw", "r0") | immediate(0x18, "movt", "r0") << 16
    end = immediate(0xe, "movw", "r1") | immediate(0x1c, "movt", "r1") << 16
    if (arena, end) != (first, limit) or end - arena < 364:
        raise ValueError("registration uses an unexpected or undersized arena")
    match_block(ensure, 0x16, "2201")
    match_block(ensure, 0x20, "1a09|601a")
    match_branch(ensure, 0x24, "bl", "cmpct_register_impl", register_entry)
    match_global_address(ensure, 0x28, 3, base, "heap")
    match_block(ensure, 0x30, "6018|bd08")

    # Fixed-input computation in the linked image. Check the widened additions
    # before using host integers to model the corresponding 32-bit operations.
    match_block(register, 0, "f5b1 7fb6|e92d 47f0|d34b|2300|1dc6|f026 0607|0b0c|eb06 04c4|"
                "f504 74b4|f604 75ff|f425 657f|180f|f025 050f|42af|bf32|f04f 0a00|1b79|"
                "ea4f 3a11|46b1|4619|e9c6 a554|6134")
    header = (arena + 7) & ~7
    low = header + 8 * ((end - arena) >> 12) + 360
    page_base = (low + 4095) & ~4095
    if not arena <= header < low <= page_base < end <= 0xfffff000:
        raise ValueError("linked heap registration would wrap or have no page region")
    pages = (end - page_base) >> 12

    # The loop advances the descriptor pointer by eight and writes two zero
    # words at its previous address. Its equality exit writes the sentinel.
    match_block(register, 0x42, "f506 72ae|4553|f102 0208|d003|e942 1102|3301|e7f7|2101|"
                "2200|eb06 03c3|e9c3 1257|4630|f8c6 7158")
    if header + 348 + 8 * (pages + 1) > low:
        raise ValueError("descriptor initialization exceeds the reserved header")
    match_branch(register, 0x68, "bl", "cmpct_init", init_entry)
    match_block(init, 0, "b510|4604|f44f 7290|2100|301c")
    match_branch(init, 0xc, "bl", "memset", memset_address)
    # memset covers [28,316). The other writes are at 0..15, 20..27,
    # and 316..335. Both arena bounds (+16 and +344) survive initialization.
    match_block(init, 0x10, "f8d4 2150|2300|0312|e9c4 2200|2201|e9c4 3305|e9c4 2302|"
                "f8c4 313c|f8c4 3140|f8c4 3144|f504 73a4|e9c4 3352|bd10")

    # For this arena both non-page-aligned fragments go to add_to_heap.
    tail = (end & ~7) - (page_base + pages * 4096)
    if min(page_base - low, tail) <= 40:
        raise ValueError("release registration takes a different fragment path")
    match_block(register, 0x6c, "42af|f027 0807|d805")
    match_block(register, 0x80, "1b2a|2a28|dd03|4621|4630")
    page_end = page_base + pages * 4096
    add_entry = check_fragments(objdump, base, header, page_base, page_end,
                                [(low, page_base), (page_end, end & ~7)])
    match_branch(register, 0x8a, "bl", "add_to_heap.constprop.0", add_entry)
    match_block(register, 0x8e, "eb05 310a|eba8 0201|2a28|dd05|4630")
    match_branch(register, 0x9c, "bl", "add_to_heap.constprop.0", add_entry)
    match_block(register, 0xa0, "e001")
    match_block(register, 0xa6, "4648|e8bd 87f0")
    return low


def check_collector(objdump, base, body):
    # On normal return all control flow from the statistics scan must reach
    # the epilogue with r5=heap and r4=result. Calls obey the ARM ABI.
    match_block(body, 0, "b5f8|4605|460c")
    lock, _ = instructions(objdump, base, "lock.constprop.0")
    match_branch(body, 6, "bl", "lock.constprop.0", lock)
    for pc, (encoding, assembly) in body.items():
        if not 0xa <= pc < 0xc2:
            continue
        op, operands = assembly.split(None, 1)
        if op == "bl":
            if not re.fullmatch(r"[0-9a-f]+ <(find_nonempty_bucket|__aeabi_ui2d|__aeabi_dmul|__aeabi_d2uiz)>", operands):
                raise ValueError("unexpected collector call")
        elif op in ("b.n", "bne.n", "beq.n", "bcs.n", "bls.n", "cbz", "cbnz"):
            target = re.search(r"<cmpct_get_info_impl\+0x([0-9a-f]+)>$", operands)
            if not target or int(target[1], 16) not in body or not 0xa <= int(target[1], 16) <= 0xc2:
                raise ValueError("collector branch bypasses bounds publication")
        elif op in ("str", "strd"):
            if not re.fullmatch(r"r\d+, (?:r\d+, )?\[r4, #(0|4|8|12|16|20)\](?:\s+@.*)?", operands):
                raise ValueError("collector scan store outside its statistics fields")
        elif op in ("ldr", "ldr.w", "ldrh", "movs", "mov", "mov.w", "movw", "movt", "adds",
                    "subs", "add.w", "negs", "adcs", "bic.w", "cmp"):
            if operands.split(",")[0] not in ("r0", "r1", "r2", "r3", "r6", "r7", "lr") or "!" in operands or "]," in operands:
                raise ValueError("collector scan changed an address register")
        else:
            raise ValueError(f"unexpected collector instruction {encoding}: {assembly}")
    match_block(body, 0xc2, "e9d4 2304|4413|61a3|692b|61e3|f8d5 3158|6223|e8bd 40f8")
    unlock, _ = instructions(objdump, base, "unlock.constprop.0")
    match_branch(body, 0xd8, "b.w", "unlock.constprop.0", unlock)
