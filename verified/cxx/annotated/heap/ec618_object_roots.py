# Copyright (C) 2026 Toit contributors.
"""Bind young-space traversal and its root callbacks to the linked slot."""

from struct import unpack

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def check_object_roots(objdump, slot, singleton):
    def local(name):
        return instructions(objdump, slot, name)

    def branch(body, offset, name, op="bl"):
        match_branch(body, offset, op, name, local(name)[0])

    visit = "_ZN4toit10HeapObject8roots_doEPNS_7ProgramEPNS_12RootCallbackE"
    array = "_ZN4toit5Array8roots_doEPNS_12RootCallbackE"
    instance = "_ZN4toit8Instance17instance_roots_doEiPNS_12RootCallbackE"
    stack = "_ZN4toit5Stack8roots_doEPNS_7ProgramEPNS_12RootCallbackE"
    skip = "_ZNK4toit12RootCallback12skip_markingEPNS_10HeapObjectE"
    shrink = "_ZNK4toit12RootCallback13shrink_stacksEv"
    roots = "_ZN4toit15ScavengeVisitor8do_rootsEPPNS_6ObjectEi"

    # Constructor in ec618_scavenge_capacity installs this address point.
    # The first entry consumes a root range. Neither policy skips any
    # instance fields or changes the layout of a surviving stack.
    with open(slot, "rb") as stream:
        elf = ELFFile(stream)
        vt, = elf.get_section_by_name(".symtab").get_symbol_by_name("_ZTVN4toit15ScavengeVisitorE")
        section = elf.get_section(vt["st_shndx"])
        offset = vt["st_value"] - section["sh_addr"] + 8
        if vt["st_size"] < 20 or not 0 <= offset <= section["sh_size"] - 12:
            raise ValueError("scavenger callback slots outside vtable")
        stream.seek(section["sh_offset"] + offset)
        if unpack("<III", stream.read(12)) != tuple(local(name)[0] + 1 for name in (roots, shrink, skip)):
            raise ValueError("unexpected scavenger callback or policy")
    for name in (shrink, skip):
        match_block(local(name)[1], 0, "2000|4770")

    _, scan = local("_ZN4toit9SemiSpace17complete_scavengeEPNS_15ScavengeVisitorE")
    match_block(scan, 0, "e92d 4ff7|4681|4607|460e|f04f 0800|f101 0340|f859 5f08|63cb|"
                "45a9|d019|f8d5 a014|f8d7 b004|4654|6823|b15b|1c60|4632|4659|9001")
    branch(scan, 0x32, visit)
    match_block(scan, 0x36, "4659|9801")
    branch(scan, 0x3a, "_ZNK4toit10HeapObject4sizeEPNS_7ProgramE")
    match_block(scan, 0x3e, "4404|e7f1|616c|45a2|bf18|f048 0801|682d|e7e3|4640|b003|e8bd 8ff0")

    # The old-space pass scans a detached chain of tracks. Each track
    # begins with a three-word descriptor followed by its promoted objects.
    # Set the card for the current object before traversing any fields.
    young_pass = "_ZN4toit9SemiSpace17complete_scavengeEPNS_15ScavengeVisitorE"
    old_pass = "_ZN4toit8OldSpace17complete_scavengeEPNS_15ScavengeVisitorE"
    old_entry, old = local(old_pass)
    if old_entry % 4 or int(old[0x78][0], 16) != singleton:
        raise ValueError("promoted scan reads the wrong remembered-set table")
    match_block(old, 0, "e92d 4ff0|4605|2400|6803|b085|695b|f8df b068|460f|4798|6d6e|656c|"
                "b34e|686b|f8d6 a003|9301|f106 030b|4698|f106 39ff|45c2|d013|f8db 2038|"
                "f108 0001|eb02 12d0|9901|63fa|463a|9303|9002")
    branch(old, 0x48, visit)
    match_block(old, 0x4c, "e9dd 1001")
    branch(old, 0x50, "_ZNK4toit10HeapObject4sizeEPNS_7ProgramE")
    match_block(old, 0x54, "9b03|4480|e7e9|f8d9 8008|4630|4553|bf18|f044 0401|4646")
    zap = "_ZN4toit13PromotedTrack3zapEv"
    branch(old, 0x6a, zap)
    match_block(old, 0x6e, "e7d4|4620|b005|e8bd 8ff0")
    match_block(local(zap)[1], 0, "1e43|f100 020b|429a|bf34|2201|2204|3805|eb00 0082|"
                "f06f 026b|4283|d002|f843 2b04|e7fa|4770")

    _, drain = local("_ZN4toit15ScavengeVisitor17complete_scavengeEv")
    match_block(drain, 0, "b570|4604|f100 0618|4621|4630")
    branch(drain, 0xc, young_pass)
    match_block(drain, 0x10, "4605|4621|6b60")
    branch(drain, 0x16, old_pass)
    match_block(drain, 0x1a, "2d00|d1f4|2800|d1f2|bd70")

    _, dispatch = local(visit)
    match_block(dispatch, 0, "b5f8|f850 3c01|4604|f013 0f1e|460e|4615|f3c3 0743|d012|"
                "1e7b|2b0a|d81f|2301|f640 6c7a|40bb|ea13 0f0c|d11b|f413 7f82|d10a|"
                "2f07|d113|e8bd 40f8")
    branch(dispatch, 0x38, stack, "b.w")
    match_block(dispatch, 0x3c, "4611|e8bd 40f8")
    branch(dispatch, 0x42, array, "b.w")
    match_block(dispatch, 0x46, "4601|4630")
    branch(dispatch, 0x4a, "_ZN4toit7Program17instance_size_forEPKNS_10HeapObjectE")
    match_block(dispatch, 0x4e, "462a|4601|4620|e8bd 40f8")
    branch(dispatch, 0x58, instance, "b.w")
    match_block(dispatch, 0x5c, "4801")
    branch(dispatch, 0x5e, "_ZN4toit4failEPKcz")
    match_block(dispatch, 0x62, "bdf8")
    match_block(local(array)[1], 0, "4603|680a|b410|6814|4608|f8d3 2003|1dd9|4623|bc10|4718")
    match_block(local(instance)[1], 0, "f850 3c01|b570|4614|f003 0203|2a01|bf18|4603|"
                "f853 3c01|460d|069b|f100 36ff|d40b|1f2a|6823|bf48|f105 32ff|4620|"
                "1d31|681b|1092|e8bd 4070|4718|6823|4601|689b|4620|4798|2800|d0ec|bd70")

    # Both formats join at +0xba. The guard loop reads four words. Format
    # 2 passes aggressive=false; format 1 and the format-2 helper consult
    # the checked shrink_stacks slot before entering any move/fill block.
    _, body = local(stack)
    match_block(body, 0, "e92d 4ff7|4604|4689|493a|4616|f100 0313|f100 0223|"
                "f853 0f04|4288|d164|4293|d1f9|e9d9 8718|4648")
    if int(body[0xf4][0], 16) != 0xcaadabe7:
        raise ValueError("unexpected stack guard")
    branch(body, 0x26, "_ZNK4toit7Program10is_format2Ev")
    match_block(body, 0x2a, "1e65|f8d9 2078|4447|f104 0927|f8d5 a00c|b138|4620|2300|4651|9600")
    reduce = "_ZN4toit5Stack16shrink_v2_for_gcEiibPNS_12RootCallbackE"
    branch(body, 0x44, reduce)
    match_block(body, 0x48, "4604|e036|1d54|ea4f 73e2|f143 0300|ea4f 72ea|4554|"
                "4193|da0d|6833|4630|685b|4798|b140")
    match_block(body, 0x7c, "4654|e01c")
    match_block(local(reduce)[1], 0, "e92d 43f8|1e16|4607|460d|9808|da01|46a9|e044|"
                "f04f 0c02|2105|2200|fbc6 120c|f8b7 400f|f107 38ff|1864|f142 0200|"
                "340d|f142 0200|17e9|42ac|418a|dae9|b113")
    match_block(local(reduce)[1], 0x42, "6803|685b|4798|2800|d0e0")
    match_block(local(reduce)[1], 0x9c, "4648|e8bd 83f8")
    match_block(body, 0xba, "68ab|2500|eba3 0a04|eb09 0484|45aa|dd10|6823|4598|d801|"
                "429f|d805|6833|2201|4621|4630|681b|4798|3501|3404|e7ef")
    match_block(body, 0xe6, "4804")
    branch(body, 0xe8, "_ZN4toit4failEPKcz")
    match_block(body, 0xec, "b003|e8bd 8ff0")
