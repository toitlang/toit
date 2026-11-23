# Copyright (C) 2026 Toit contributors.
"""Check linked space construction, chunk insertion and initial sentinel."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def check_space_append(objdump, slot, singleton, memset, set_owner, owner_entry):
    def local(name):
        return instructions(objdump, slot, name)

    # Both append methods establish ownership before linking the detached chunk.
    for space, push in (("9SemiSpace", "b538"), ("5Space", "b5f8")):
        _, append = local("_ZN4toit" + space + "6appendEPNS_5ChunkE")
        match_block(append, 0, push + "|460c|4605|4601|4620")
        match_branch(append, 0xa, "bl", set_owner, owner_entry)
        if space == "9SemiSpace":
            match_block(append, 0xe, "68eb|681a|601c|6022|6054|6063|bd38")
        else:
            match_block(append, 0xe, "4628|f850 3f08|4298|d00f|e9d3 7103|e9d4 6203|1bc9|1b92|"
                        "4291|d901|685b|e006|42b7|d901|4291|d0f9|681b|e7ed|68eb|"
                        "681a|601c|6022|6054|6063|bdf8")

    semi = "_ZN4toit9SemiSpace"
    ctor_entry, ctor = local(semi + "C1EPNS_7ProgramEPNS_5ChunkE")
    update = semi + "21update_base_and_limitEPNS_5ChunkEj"
    update_entry, body = local(update)
    with open(slot, "rb") as stream:
        vtable, = ELFFile(stream).get_section_by_name(".symtab").get_symbol_by_name("_ZTVN4toit9SemiSpaceE")
        if ctor_entry % 4 or int(ctor[0x3c][0], 16) != vtable["st_value"] + 8:
            raise ValueError("unexpected semispace vtable")
    match_block(ctor, 0, "b538|f100 0308|e9c0 3302|2300|e9c0 3304|2302|7603|4b09|4604|4615|"
                "6041|6003|b15a|4611")
    append_name = semi + "6appendEPNS_5ChunkE"
    match_branch(ctor, 0x22, "bl", append_name, local(append_name)[0])
    match_block(ctor, 0x26, "4629|4620|68ea")
    match_branch(ctor, 0x2c, "bl", update, update_entry)
    match_block(ctor, 0x30, "4621|4628")
    match_branch(ctor, 0x34, "bl", set_owner, owner_entry)
    match_block(ctor, 0x38, "4620|bd38")

    if update_entry % 4 or int(body[0x40][0], 16) != singleton:
        raise ValueError("unexpected semispace metadata singleton")
    match_block(body, 0, "4613|b410|6102|2200|601a|690a|68c9|6142|428b|d112|480a|6801|428b|"
                "d30e|6844|4421|428b|d80a|b14a|6b40|09d2|2102|bc10|eba2 12d3|eb00 10d3")
    match_branch(body, 0x36, "b.w", "memset", memset)
    match_block(body, 0x3a, "bc10|4770")
