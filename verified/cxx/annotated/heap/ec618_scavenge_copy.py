# Copyright (C) 2026 Toit contributors.
"""Check the linked scavenger's copy, forwarding and alias-reuse paths."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def check_scavenge_copy(objdump, base, slot):
    def local(name):
        return instructions(objdump, slot, name)

    memcpy, copy = instructions(objdump, base, "memcpy")
    match_block(copy, 0, "4684|ea41 0300|f013 0303|d149|3a40|d323")
    for pc, words in ((0x10, 16), (0x5c, 4)):
        for i in range(words):
            match_block(copy, pc + 4*i, f"{0x680b + 64*i:04x}|{0x6003 + 64*i:04x}")
    match_block(copy, 0x50, "3040|3140|3a40|d2db|3230|d30b")
    match_block(copy, 0x6c, "3010|3110|3a10|d2f3|320c|d305|f851 3b04|f840 3b04|3a04|d2f9|3204|d008")
    match_block(copy, 0x9a, "4660|4770")

    size = "_ZNK4toit10HeapObject4sizeEPNS_7ProgramE"
    size_entry, _ = local(size)
    new_alloc = "_ZN4toit9SemiSpace8allocateEj"
    alloc_entry, alloc = local(new_alloc)
    match_block(alloc, 0, "b510|e9d0 2404|1aa4|428c|4603|d904|1850|6118|2300|5053|e00a|"
                "6881|f100 0208|4291|d101|2200|e003|6803|695b|4798|e7f9|4610|bd10")
    flush, flush_body = local("_ZN4toit9SemiSpace5flushEv")
    match_block(flush_body, 0, "6882|f100 0308|429a|bf1e|2200|6903|601a|4770")
    with open(slot, "rb") as stream:
        elf = ELFFile(stream)
        table, = elf.get_section_by_name(".symtab").get_symbol_by_name("_ZTVN4toit9SemiSpaceE")
        section = elf.get_section(table["st_shndx"])
        offset = table["st_value"] - section["sh_addr"] + 8 + 20
        if table["st_size"] < 32 or not 0 <= offset <= section["sh_size"] - 4:
            raise ValueError("semispace flush slot outside vtable")
        stream.seek(section["sh_offset"] + offset)
        if int.from_bytes(stream.read(4), "little") != flush + 1:
            raise ValueError("semispace allocation calls an unexpected flush method")

    clone = "_ZN4toit15ScavengeVisitor16clone_into_spaceINS_9SemiSpaceEEEPNS_10HeapObjectEPNS_7ProgramES4_PT_"
    clone_entry, body = local(clone)
    match_block(body, 0, "b570|460d|4601|4628|4614")
    match_branch(body, 0xa, "bl", size, size_entry)
    match_block(body, 0xe, "4601|4606|4620")
    match_branch(body, 0x14, "bl", new_alloc, alloc_entry)
    match_block(body, 0x18, "4604|b130|4632|3401|1e69")
    match_branch(body, 0x22, "bl", "memcpy", memcpy)
    match_block(body, 0x26, "f845 4c01|4620|bd70")

    _, roots = local("_ZN4toit15ScavengeVisitor8do_rootsEPPNS_6ObjectEi")
    match_block(roots, 0, "e92d 4ff7|4604|460e|f04f 0a01|eb01 0882|f100 0918|4546|d24c|"
                "6837|07fb|d547|6923|6962|1afb|4293|d242|f857 3c01|f107 3bff|f003 0203|"
                "2a01|d108|68a1|6033|1a5b|68e1|428b|d234|6be3|701a|e031|6c63|6860|459b|d225|"
                "4601|4638|6b65")
    match_branch(roots, 0x58, "bl", size, size_entry)
    match_block(roots, 0x5c, "4601|9001|4628")
    old_alloc = "_ZN4toit8OldSpace8allocateEj"
    match_branch(roots, 0x62, "bl", old_alloc, local(old_alloc)[0])
    match_block(roots, 0x66, "9a01|4605|b970|f04f 0b01|4639|6860|f884 b038|f104 0218")
    match_branch(roots, 0x7c, "bl", clone, clone_entry)
    match_block(roots, 0x80, "6be3|4605|f883 b000|e007|4659|3501")
    match_branch(roots, 0x8e, "bl", "memcpy", memcpy)
    match_block(roots, 0x92, "f847 5c01|2d00|d0e8|6035|e007|464a|4639")
    match_branch(roots, 0xa2, "bl", clone, clone_entry)
    match_block(roots, 0xa6, "6be3|6030|f883 a000|3604|e7b0|b003|e8bd 8ff0")
