# Copyright (C) 2026 Toit contributors.
"""Check how the release firmware supplies the GC setup range and allocation."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch
from ec618_page_grant import check_page_grant
from ec618_registration import check_registration, check_collector


def base_contract(objdump, base, memset_address, z3):
    with open(base, "rb") as stream:
        symtab = ELFFile(stream).get_section_by_name(".symtab")

        def address(name):
            symbol, = symtab.get_symbol_by_name(name)
            return symbol["st_value"]

        first, limit = address("end_ap_data"), address("start_up_buffer")
        if not 0 < first < limit <= 0xfffff000:
            raise ValueError("invalid linker heap range")
        # MOVW/MOVT pairs below address these two globals.
        if (address("heap_initialized"), address("heap")) != (0x41d638, 0x41d634):
            raise ValueError("heap statistics globals moved")

    stats, body = instructions(objdump, base, "vPortGetHeapStats")
    match_block(body, 0, "f24d 6338|b510|f2c0 0341|6819|4604|b08a|b929")
    # Uninitialized: tail-call memset(result, 0, 36) with r1 still zero.
    match_block(body, 0x12, "2224|b00a|e8bd 4010")
    match_branch(body, 0x1a, "b.w", "memset", memset_address)
    # Initialized: call the allocator's statistics collector on a local buffer.
    match_block(body, 0x1e, "f24d 6334|f2c0 0341|6818|a901")
    info, collector = instructions(objdump, base, "cmpct_get_info_impl")
    match_branch(body, 0x2a, "bl", "cmpct_get_info_impl", info)
    # Copy all nine words in order from sp+4 to the caller, including both bounds.
    for index in range(9):
        match_block(body, 0x2e + 4 * index, f"{0x9b01 + index:04x}|{0x6023 + 64 * index:04x}")
    match_block(body, 0x52, "b00a|bd10")
    check_collector(objdump, base, collector)
    registered_start = check_registration(objdump, base, first, limit, memset_address)
    malloc = check_page_grant(objdump, base, (first + 7) & ~7, registered_start, limit, z3)
    return stats, malloc, first, limit, registered_start


def range_obligations(objdump, slot, setup, contract):
    stats, malloc, first, limit, registered_start = contract
    getter = "_ZN4toit2OS21get_heap_memory_rangeEv"
    entry, body = instructions(objdump, slot, getter)
    match_branch(setup[1], 8, "bl", getter, entry)
    if entry % 4 or (int(body[0x28][0], 16), int(body[0x2c][0], 16)) != (first, limit):
        raise ValueError("heap range fallback differs from the base linker arena")
    match_block(body, 0, "b510|b08a|4604|a801")
    match_branch(body, 8, "bl", "vPortGetHeapStats", stats)
    match_block(body, 0xc, "9a08|b11a|9b09|6022|1a9b|e003|4a03|4b04|6022|1a9b|4620|6063|b00a|bd10")

    grab = "_ZN4toit2OS19grab_virtual_memoryEPvj"
    entry, body = instructions(objdump, slot, grab)
    match_branch(setup[1], 0x6a, "bl", grab, entry)
    match_block(body, 0, "4608")  # r0 = r1 (requested byte count).
    match_branch(body, 2, "b.w", "malloc", malloc)

    # Serialized initialization, a live heap and intact registered bounds.
    smt = f"""(set-logic QF_LIA)
(declare-const initialized Bool)
(define-fun reportedStart () Int (ite initialized {registered_start} 0))
(define-fun reportedLimit () Int (ite initialized {limit} 0))
(define-fun start () Int (ite (= reportedStart 0) {first} reportedStart))
(define-fun limit () Int (ite (= reportedStart 0) {limit} reportedLimit))
(define-fun length () Int (mod (- limit start) 4294967296))
(assert (not (and (<= 0 start) (< 0 length) (= start (ite initialized {registered_start} {first}))
                  (= (+ start length) {limit})
                  (<= (+ start length) 4294963200))))
(check-sat)"""
    return smt, 1
