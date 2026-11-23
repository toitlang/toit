# Copyright (C) 2026 Toit contributors.
"""Check the EC618 remembered-set consumer and instance-field write barrier."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def check_remembered_scan(objdump, slot, singleton):
    def local(name):
        return instructions(objdump, slot, name)

    barrier_entry, barrier = local("_ZN4toit8Instance6at_putEiPNS_6ObjectE")
    entry, scan = local("_ZN4toit8OldSpace20visit_remembered_setEPNS_15ScavengeVisitorE")
    if barrier_entry % 4 or entry % 4 or int(scan[0xdc][0], 16) != singleton or int(barrier[0x20][0], 16) != singleton:
        raise ValueError("barrier and card scan require the same GC metadata")
    match_block(barrier, 0, "b530|2501|4c06|4429|0089|6ba4|bf48|3103|09c3|f021 0103|"
                "54e5|4408|f840 2c01|bd30")

    # A successful old-space bump records the low address byte of its
    # pre-increment top in the very starts table used by backtracking.
    alloc_entry, alloc = local("_ZN4toit8OldSpace8allocateEj")
    if alloc_entry % 4 or int(alloc[0x48][0], 16) != singleton:
        raise ValueError("old-space bump writes a different starts table")
    match_block(alloc, 0, "b538|4604|e9d4 0304|1a1b|428b|460d|d306|4a0d|4405|"
                "6b52|09c3|6125|5498|e012")
    match_block(alloc, 0x44, "bd38")

    # The scan flushes old-space before reading the ring of allocated chunks.
    flush = local("_ZN4toit8OldSpace5flushEv")[0]
    with open(slot, "rb") as stream:
        elf = ELFFile(stream)
        vt, = elf.get_section_by_name(".symtab").get_symbol_by_name("_ZTVN4toit8OldSpaceE")
        section = elf.get_section(vt["st_shndx"])
        offset = vt["st_value"] + 8 + 20 - section["sh_addr"]
        if vt["st_size"] < 32 or not 0 <= offset <= section["sh_size"] - 4:
            raise ValueError("old-space flush slot outside vtable")
        stream.seek(section["sh_offset"] + offset)
        if int.from_bytes(stream.read(4), "little") != flush + 1:
            raise ValueError("unexpected old-space flush method")

    # r6 is card start, r5 its byte, r4 the earliest safe object boundary.
    # At a word-aligned metadata address a zero word skips four cards.
    match_block(scan, 0, "e92d 4ff7|4607|46ba|6803|4689|695b|4798|f8df b0c8|f85a 8f08|"
                "45c2|d05c|f8d8 400c|f8db 5038|4626|eb05 15d4|f8d8 3010|429e|d24e|"
                "07aa|d10b|682a|b94a|f506 7600|429e|f105 0504|d2f1|682a|2a00|d0f6|e7ed")
    # Empty start entries contain 2. A real entry is the object's low
    # address byte, including bit 7. The lower bound wins before a load.
    match_block(scan, 0x4e, "782b|2b00|d03a|f8db 3034|f8d8 100c|eb03 12d6|eb03 13d1|"
                "429a|d016|4633|3b80|429c|f102 32ff|d20d|7811|2902|d0f7|f023 03ff|18cc|e006")
    size = "_ZNK4toit10HeapObject4sizeEPNS_7ProgramE"
    visit = "_ZN4toit10HeapObject8roots_doEPNS_7ProgramEPNS_12RootCallbackE"
    match_block(scan, 0x82, "6823|b143|1c60|6879")
    match_branch(scan, 0x8a, "bl", size, local(size)[0])
    match_block(scan, 0x8e, "4404|42a6|d8f6|e000|4634|f04f 0300|702b|f8c9 503c|"
                "f106 0380|42a3|d90f|6822|9301|b162|1c60|464a|6879|9000")
    match_branch(scan, 0xb8, "bl", visit, local(visit)[0])
    match_block(scan, 0xbc, "6879|9800")
    match_branch(scan, 0xc0, "bl", size, local(size)[0])
    match_block(scan, 0xc4, "9b01|4404|e7ed|3680|3501|e7ac|f8d8 8000|e7a0|b003|e8bd 8ff0")
