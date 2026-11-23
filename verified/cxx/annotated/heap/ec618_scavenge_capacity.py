# Copyright (C) 2026 Toit contributors.
"""Bind the source and destination of the capacity proof to each linked visitor."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def check_scavenge_capacity(objdump, slot):
    def local(name):
        return instructions(objdump, slot, name)

    def call(body, offset, name):
        match_branch(body, offset, "bl", name, local(name)[0])

    allocate = "_ZN4toit12ObjectMemory14allocate_chunkEPNS_5SpaceEj"
    free = "_ZN4toit12ObjectMemory10free_chunkEPNS_5ChunkE"
    take = "_ZN4toit12ObjectMemory16take_spare_chunkERNS_6LockerE"
    ctor = "_ZN4toit9SemiSpaceC1EPNS_7ProgramEPNS_5ChunkE"
    run = "_ZN4toit12TwoSpaceHeap11do_scavengeEPNS_15ScavengeVisitorE"
    with open(slot, "rb") as stream:
        symbols = ELFFile(stream).get_section_by_name(".symtab")
        spare, = symbols.get_symbol_by_name("_ZN4toit12ObjectMemory12spare_chunk_E")
        visitor, = symbols.get_symbol_by_name("_ZTVN4toit15ScavengeVisitorE")
        lock, = symbols.get_symbol_by_name("_ZN4toit12ObjectMemory18spare_chunk_mutex_E")

    _, initial = local("_ZN4toit20InitialMemoryManager8allocateEv")
    match_block(initial, 0, "b510|f44f 5180|4604|2000")
    call(initial, 0xa, allocate)
    match_block(initial, 0xe, "6020|b138")

    # The object heap passes its chunk argument through to the resident
    # semispace and starts with no private spare.
    heap_ctor = "_ZN4toit12TwoSpaceHeapC1EPNS_7ProgramEPNS_10ObjectHeapEPNS_5ChunkE"
    _, heap = local("_ZN4toit10ObjectHeapC1EPNS_7ProgramEPNS_7ProcessEPNS_5ChunkEPPNS_6ObjectEPNS_5MutexE")
    match_block(heap, 0, "b570|2500|4604|6082|6001|4602|8085|3010|461e")
    call(heap, 0x12, heap_ctor)
    _, spaces = local(heap_ctor)
    match_block(spaces, 0, "b570|4604|461d|460e|e9c0 1200|4602|3008")
    call(spaces, 0x10, "_ZN4toit8OldSpaceC1EPNS_7ProgramEPNS_12TwoSpaceHeapE")
    match_block(spaces, 0x14, "4631|462a|f104 0074")
    call(spaces, 0x1c, ctor)
    match_block(spaces, 0x20, "2300|2000|2100|f8c4 3090")

    setup_pc, setup = local("_ZN4toit12ObjectMemory6set_upEv")
    take_pc, pick = local(take)
    pc, collect = local("_ZN4toit12TwoSpaceHeap17collect_new_spaceEb")
    if int(collect[0x1dc][0], 16) != visitor["st_value"] + 8:
        raise ValueError("wrong scavenger visitor vtable")
    for start, body, offset, symbol in ((setup_pc, setup, 0x6c, spare),
                                        (setup_pc, setup, 0x54, lock),
                                        (take_pc, pick, 0x34, spare),
                                        (pc, collect, 0x1d0, lock)):
        if start % 4 or int(body[offset][0], 16) != symbol["st_value"]:
            raise ValueError("wrong spare chunk or mutex literal")

    # Successful setup publishes the first one-page spare. A failed attempt
    # to replace it later keeps the old page; success frees only the loser.
    match_block(setup, 0, "b538|4d14|682c|b10c|4813|e011|4b13|f3bf 8f5b|601c|f3bf 8f5b")
    call(setup, 0x18, "_ZN4toit10GcMetadata6set_upEv")
    match_block(setup, 0x1c, "4620|f44f 5180")
    call(setup, 0x22, allocate)
    match_block(setup, 0x26, "4604|b920")
    match_block(setup, 0x34, "2007|490b")
    call(setup, 0x38, "_ZN4toit2OS14allocate_mutexEiPKc")
    match_block(setup, 0x3c, "b930")
    match_block(setup, 0x4c, "4b07|6028|601c|bd38")
    match_block(pick, 0, "2000|b538|4b0b|f44f 5180|681d|6018")
    call(pick, 0xe, allocate)
    match_block(pick, 0x12, "4604|b908|462c|e00a|68c2|68eb|429a|d203|4628")
    call(pick, 0x24, free)
    match_block(pick, 0x28, "e002")
    call(pick, 0x2a, free)
    match_block(pick, 0x2e, "e7f2|4620|bd38")

    # r4 is the heap, r7 the from-space ring sentinel. The private fast
    # path uses r5. On the shared path take_spare_chunk returns the grant.
    match_block(collect, 0, "e92d 4ff0|2500|f100 0874|4604|b09b")
    match_block(collect, 0x28, "6fe3|f104 077c|429f|bf08|462b|f8d4 2084|68db|429a|d102")
    match_block(collect, 0x6a, "f8df b164|f8db 3000|b913")
    match_block(collect, 0x7a, "4b57|6c9b|2b3c|dd08|f8d4 0090|b928|f44f 5180")
    call(collect, 0x8c, allocate)
    match_block(collect, 0x90, "f8c4 0090|f8d4 5090|f8df a140|2d00|d149|"
                "f8db 3000|a805|e9cd 3505|f88d 501c")
    call(collect, 0xae, "_ZN4toit6Locker5enterEv")
    match_block(collect, 0xb2, "a805")
    call(collect, 0xb4, take)
    # Both visitor initializers save (start,end-start) for the actual spare
    # and first source chunk, and pass that same spare to the checked ctor.
    match_block(collect, 0xb8, "4602|68c0|6913|900a|1a1b|930b|6fe3|6821|429f|bf18|"
                "461d|68e8|692b|900c|1a1b|a80e|e9cd a108|930d")
    match_block(collect, 0x134, "68ea|692b|920a|1a9b|930b|6fe3|6821|429f|bf08|"
                "2300|68da|691b|920c|1a9b|a80e|462a|e9cd a108|930d")
    for offset in (0xde, 0x15a):
        call(collect, offset, ctor)
        match_block(collect, offset + 4, "2300|f88d 3058|ab18|9317|f8d4 3094|"
                    "a908|4620|9319|9615")
        call(collect, offset + 0x1a, run)
