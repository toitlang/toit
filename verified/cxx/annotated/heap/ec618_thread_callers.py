# Copyright (C) 2026 Toit contributors.
"""Check the slot code for the guarded EC618 worker stack and thread lifecycle."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def check_current_thread_callers(objdump, slot, targets, spawn, boot, start_address):
    def call(body, pc, dest, op="bl"):
        match_branch(body, pc, op, dest, targets[dest])

    # Negative input takes the failure exit. Zero selects the default.
    # For nonnegative bytes the adjusted unsigned range test accepts exactly
    # 18 <= ceil(bytes/4) <= UINT16_MAX, before narrowing for xTaskCreate.
    match_block(spawn, 0, "e92d 41f3|2900|4606|d001|da02|e03b|f44f 6100|f64f 73ed|"
                "3103|088d|f1a5 0212|429a|d831")
    call(spawn, 0x22, "vPortGetHeapTag")
    match_block(spawn, 0x26, "4680|f06f 0057")
    call(spawn, 0x2c, "vPortSetHeapTag")
    match_block(spawn, 0x30, "2008|4917")
    call(spawn, 0x34, "_ZnwjRKSt9nothrow_t")
    match_block(spawn, 0x38, "4604|b160|2700|2203|e9c0 7700|4639|2001")
    call(spawn, 0x48, "xQueueGenericCreate")
    match_block(spawn, 0x4c, "6060|b920|4620")
    call(spawn, 0x52, "_ZdlPv")
    match_block(spawn, 0x56, "2400|e011|2302|60b4|9300|9401|4633|6871|480b|b2aa")
    call(spawn, 0x6a, "xTaskCreate")
    match_block(spawn, 0x6e, "2801|d004|6860|60b7")
    call(spawn, 0x76, "vQueueDelete")
    match_block(spawn, 0x7a, "e7e9|4604|4640")
    call(spawn, 0x80, "vPortSetHeapTag")
    match_block(spawn, 0x84, "e000|2400|4620|b002|e8bd 81f0")
    match_block(spawn, 0x94, f"{start_address + 1:08x}")

    setter = "_ZN4toitL18set_current_threadEPNS_6ThreadE"
    getter = "_ZN4toitL18get_current_threadEv"
    set_address, _ = instructions(objdump, slot, setter)
    get_address, _ = instructions(objdump, slot, getter)
    match_block(boot, 0, "b5f8|6886|4605|b91e")
    match_branch(boot, 8, "bl", getter, get_address)
    match_block(boot, 0xc, "4604|e000|2400|4628")
    match_branch(boot, 0x14, "bl", setter, set_address)
    call(boot, 0x18, "vPortGetHeapTag")
    match_block(boot, 0x1c, "4607|f06f 0058")
    call(boot, 0x22, "vPortSetHeapTag")
    match_block(boot, 0x26, "682b|4628|689b|4798|4638")
    call(boot, 0x30, "vPortSetHeapTag")
    match_block(boot, 0x34, "bb0c|f3ef 8510|b672|f3bf 8f5f")
    call(boot, 0x40, "xTaskGetCurrentTaskHandle")
    match_block(boot, 0x44, "b1a0|4623|4a14|f852 1033|eb02 04c3|4288|d109|2100|f842 1033|"
                "4b10|6061|681a|42a2|d104|6019|e002|3301|2b10|d1ec|f3bf 8f5f|f385 8810|e002|4620")
    match_branch(boot, 0x7c, "bl", setter, set_address)
    match_block(boot, 0x80, "b156|2300|6870|461a|4619")
    call(boot, 0x8a, "xQueueGenericSend")
    match_block(boot, 0x8e, "e8bd 40f8|2000")
    call(boot, 0x94, "vTaskDelete", "b.w")
    match_block(boot, 0x98, "bdf8")

    with open(slot, "rb") as stream:
        symbols = ELFFile(stream).get_section_by_name(".symtab")
        table, = symbols.get_symbol_by_name("_ZN4toitL10thread_mapE")
        cached, = symbols.get_symbol_by_name("_ZN4toitL19cached_thread_entryE")
        tag, = symbols.get_symbol_by_name("_ZSt7nothrow")
        if table["st_size"] != 16 * 8 or cached["st_size"] != 4:
            raise ValueError("thread-map scan no longer matches reserved storage")
        for fn in ("_ZN4toit6Thread5spawnEii", "_ZN4toit6Thread5_bootEv"):
            symbol, = symbols.get_symbol_by_name(fn)
            if symbol["st_value"] % 4 != 1:
                raise ValueError("changed alignment for PC-relative thread literals")
        match_block(boot, 0x9c, f"{table['st_value']:08x}")
        match_block(boot, 0xa0, f"{cached['st_value']:08x}")
        match_block(spawn, 0x90, f"{tag['st_value']:08x}")
