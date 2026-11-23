# Copyright (C) 2026 Toit contributors.
"""Check EC618 event producer admission, call destinations and queue retirement."""

import re

from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection

from ec618_thumb import instructions, match_block


def check_callers(objdump, path):
    source = "_ZN4toit16Ec618EventSource"
    mailbox = "_ZN4toit17Ec618EventMailbox"
    args = "ENS_5Event4TypeEi"
    publish = mailbox + "7publish" + args
    retains = mailbox + "7retainsENS_5Event4TypeE"
    instance = source + "9instance_E"
    with open(path, "rb") as stream:
        elf = ELFFile(stream)
        symbols = elf.get_section_by_name(".symtab")
        relocatable = elf["e_type"] == "ET_REL"
        if elf["e_machine"] != "EM_ARM" or elf["e_type"] not in ("ET_REL", "ET_EXEC") or not elf.little_endian:
            raise ValueError("expected a little-endian ARM object or executable")

        def routine(name, end, calls, singleton=None):
            address, body = instructions(objdump, path, name)
            sym, = symbols.get_symbol_by_name(name)
            section = elf.get_section(sym["st_shndx"])
            if relocatable:
                # Relocatable BL operands name placeholders. Check both the
                # implicit addend and the ELF relocation's symbol and kind.
                # Reject any extra relocation in the checked instructions.
                expected = {}
                for pc, destination in calls.items():
                    tail = destination == "vPortExitCritical"
                    expected[pc] = (30 if tail else 10, destination)
                    match_block(body, pc, "f7ff bffe" if tail else "f7ff fffe")
                if singleton is not None:
                    expected[singleton] = (2, instance)
                for rels in elf.iter_sections():
                    if not isinstance(rels, RelocationSection) or rels["sh_info"] != sym["st_shndx"]:
                        continue
                    table = elf.get_section(rels["sh_link"])
                    for rel in rels.iter_relocations():
                        pc = rel["r_offset"] - address
                        if 0 <= pc < end or pc == singleton:
                            actual = (rel["r_info_type"], table.get_symbol(rel["r_info_sym"]).name)
                            if rel.is_RELA() or expected.pop(pc, None) != actual:
                                raise ValueError(f"unexpected relocation in {name} at {pc:#x}")
                if expected:
                    raise ValueError(f"missing relocations in {name}: {expected}")
            else:
                for pc, destination in calls.items():
                    target, = symbols.get_symbol_by_name(destination)
                    op = r"b\.w" if destination == "vPortExitCritical" else "bl"
                    if not re.fullmatch(op + rf"\s+0*{target['st_value'] & ~1:x} <[^>]+>", body[pc][1]):
                        raise ValueError(f"unexpected linked call in {name} at {pc:#x}")
            if singleton is not None:
                if address % 4:
                    raise ValueError(f"changed PC-relative literal alignment in {name}")
                offset = address + singleton - section["sh_addr"]
                data = section.data()[offset:offset + 4]
                target, = symbols.get_symbol_by_name(instance)
                if len(data) != 4 or int.from_bytes(data, "little") != (0 if relocatable else target["st_value"]):
                    raise ValueError(f"incorrect singleton pointer or relocation addend in {name}")
            return body

        classifier = routine(retains, 0x1e, {})
        match_block(classifier, 0, "1e42|2a02|4603|d908|3824|2809|bf8c|2000|2001|2b26|bf08|2000|4770|2001|4770")
        pub = routine(publish, 0x72, {0x32: retains})
        match_block(pub, 0x30, "4608")
        match_block(pub, 0x36, "b1d0")

        create = routine(source + "C1Ev", 0x6c,
                         {0xc: "_ZN4toit11EventSourceC2EPKci", 0x14: "_ZN4toit6ThreadC2EPKc",
                          0x26: "xQueueGenericCreate", 0x3e: "memset", 0x54: "_ZN4toit6Thread5spawnEii",
                          0x5c: "_ZN4toit4failEPKcz"}, 0x80)
        match_block(create, 0, "b5f8|4604|2201|4919|f104 0718")
        match_block(create, 0x10, "4917|4638")
        match_block(create, 0x18, "4b16|2200|6023|3320|2108|61a3|2020")
        match_block(create, 0x2a, "2500|4606|62a0|2228|4629|e9c4 550b|6365|f104 0038")
        match_block(create, 0x42, "6625|b90e|480c|e008|f04f 32ff|f44f 5180|4638")
        match_block(create, 0x58, "b910|4808")
        match_block(create, 0x60, "4b07|f3bf 8f5b|601c|4620|bdf8")

        task = routine(source + "10send_event" + args, 0x3c,
                       {6: "vPortEnterCritical", 0x1c: publish, 0x2e: "xQueueGenericSend",
                        0x38: "vPortExitCritical"}, 0x3c)
        match_block(task, 0, "b573|4605|460c")
        match_block(task, 0xa, "4b0c|681e|f3bf 8f5b|b176|4622|4629|f106 002c")
        match_block(task, 0x20, "b138|2300|4669|461a|6ab0|e9cd 5400")
        match_block(task, 0x32, "b002|e8bd 4070")
        isr = routine(source + "19send_event_from_isr" + args, 0x4c,
                      {0x18: publish, 0x2c: "xQueueGenericSendFromISR"}, 0x4c)
        match_block(isr, 0, "b57f|4605|460c|4b11|681e|f3bf 8f5b|b1de|460a|4601|f106 002c")
        match_block(isr, 0x1c, "b1a0|2300|6ab0|aa01|a902|9301|e9cd 5402")
        match_block(isr, 0x30, "9b01|b14b|f04f 23e0|f04f 5280|f8c3 2d04|f3bf 8f4f|f3bf 8f6f|b004|bd70")

        dispatch = source + "14dispatch_eventERNS_6LockerENS_5Event4TypeEi"
        entry = routine(source + "5entryEv", 0xea,
                        {0x16: "xQueueGenericReceive", 0x30: "_ZN4toit6Locker5enterEv", 0x38: retains,
                         0x46: dispatch, 0x7a: dispatch, 0xce: dispatch, 0xde: "_ZN4toit6Locker5leaveEv"})
        match_block(entry, 0, "e92d 47f0|4604|f04f 0800|b086|2300|f04f 32ff|6aa0|a901")
        match_block(entry, 0x1a, "2801|d1f6|9b01|2b00|d05f|68a3|a803|e9cd 3803|f88d 8014")
        match_block(entry, 0x34, "9d01|4628")
        match_block(entry, 0x3c, "b928|462a|4620|9b02|a903")
        match_block(entry, 0x70, "d005|4633|462a|4620|a903")
        match_block(entry, 0x7e, "3601|2e04|d1f1")
        match_block(entry, 0xc6, "4620|f105 0224|a903")
        match_block(entry, 0xdc, "a803")
        match_block(entry, 0xe2, "e793|b006|e8bd 87f0")

        destroy = routine(source + "D1Ev", 0x4a,
                          {0x22: "xQueueGenericSend", 0x2c: "_ZN4toit4failEPKcz", 0x34: "_ZN4toit6Thread4joinEv",
                           0x3a: "vQueueDelete", 0x40: "_ZN4toit11EventSourceD2Ev"}, 0x50)
        match_block(destroy, 0, "4b12|b513|6003|3320|4604|6183|2300|4a10|f3bf 8f5b|6013|"
                    "f04f 32ff|4669|6a80|e9cd 3300")
        match_block(destroy, 0x26, "2801|d002|480a")
        match_block(destroy, 0x30, "f104 0018")
        match_block(destroy, 0x38, "6aa0")
        match_block(destroy, 0x3e, "4620")
        match_block(destroy, 0x44, "4620|b002|bd10")
