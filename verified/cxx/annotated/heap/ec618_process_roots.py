# Copyright (C) 2026 Toit contributors.
"""Bind the young collection's root sources and ordinary finalizer transitions."""

from elftools.elf.elffile import ELFFile

from ec618_thumb import instructions, match_block, match_branch


def check_process_roots(objdump, slot):
    def local(name):
        return instructions(objdump, slot, name)

    def call(body, pc, name):
        match_branch(body, pc, "bl", name, local(name)[0])

    heap = "_ZN4toit10ObjectHeap"
    semi = "_ZN4toit9SemiSpace"
    old = "_ZN4toit8OldSpace"
    callback = "EPNS_12RootCallbackE"
    visit = heap + "13iterate_roots" + callback
    one = "_ZN4toit12RootCallback7do_rootEPPNS_6ObjectE"
    drain = "_ZN4toit15ScavengeVisitor17complete_scavengeEv"
    oracle = "PNS_14LivenessOracleE"
    registered = heap + "38process_registered_callback_finalizers" + callback + oracle
    runnable = heap + "23process_finalizer_queue" + callback + oracle
    vm = heap + "32process_registered_vm_finalizers" + callback + oracle
    helper = (heap + "36process_registered_finalizers_helperEP10LinkedFifoINS_13FinalizerNodeELi1EE"
              + "PNS_12RootCallbackE" + oracle + "b")

    # Same visitor throughout; r7 is from-space, r6 old-space, r8 to-space.
    _, phase = local("_ZN4toit12TwoSpaceHeap11do_scavengeEPNS_15ScavengeVisitorE")
    match_block(phase, 0, "e92d 41f3|4605|460c|f101 0818|f100 0774|f105 0608|4640")
    call(phase, 0x16, semi + "14start_scavengeEv")
    match_block(phase, 0x1a, "4630")
    call(phase, 0x1c, old + "14start_scavengeEv")
    match_block(phase, 0x20, "4621|6868")
    call(phase, 0x24, visit)
    match_block(phase, 0x28, "4621|4630")
    call(phase, 0x2c, old + "20visit_remembered_setEPNS_15ScavengeVisitorE")
    for pc in (0x30, 0x4a, 0x5a):
        match_block(phase, pc, "4620")
        call(phase, pc + 2, drain)
    for pc, name in ((0x36, registered), (0x40, runnable), (0x50, vm)):
        match_block(phase, pc, "463a|4621|6868")
        call(phase, pc + 6, name)
    match_block(phase, 0x60, "4630")
    call(phase, 0x62, old + "12end_scavengeEv")

    # Initialize every survivor scan cursor before publishing any task root.
    # The empty and singleton rings share the same sentinel test.
    match_block(local(semi + "14start_scavengeEv")[1], 0, "b510|4604|6803|695b|4798|4620|"
                "f850 3f08|4298|d003|68da|615a|681b|e7f9|bd10")
    track = old + "26start_tracking_allocationsEv"
    match_branch(local(old + "14start_scavengeEv")[1], 0, "b.w", track, local(track)[0])
    match_block(local(old + "12end_scavengeEv")[1], 0, "2300|f880 3050|4770")

    _, roots = local(visit)
    match_block(roots, 0, "b5f8|460d|4604|f100 01d8|4628")
    call(roots, 0xc, one)
    match_block(roots, 0x10, "6822|682b|4628|681b|6b52|f8d4 110c|4798|f8d4 6110|"
                "f504 7788|42b7|d008|682b|f106 0108|2201|4628|681b|4798|6836|e7f4|"
                "f854 6fdc|42a6|d006|f106 010c|4628")
    call(roots, 0x4c, one)
    match_block(roots, 0x50, "6836|e7f6|bdf8")
    match_block(local(one)[1], 0, "6803|2201|681b|4718")

    # Current node has a link at +4. The helper saves its successor and
    # detaches it before allowing the callback to delete or requeue it.
    for name, flag, offset in ((registered, "2200", "01ec"), (runnable, "2201", "01e4"), (vm, "2200", "01f4")):
        _, wrapper = local(name)
        match_block(wrapper, 0, "b507|4613|" + flag + "|9200|460a|f100 " + offset)
        call(wrapper, 0xe, helper)
        match_block(wrapper, 0x12, "b003|f85d fb04")
    match_block(local(helper)[1], 0, "e92d 4ff8|460e|4690|4699|460f|f04f 0a00|f89d b028|"
                "680c|b1bc|4620|f854 3c04|6825|691b|4642|469c|4659|464b|f840 a904|"
                "47e0|b130|b115|462c|603d|e7ee|6077|603d|e003|4627|6025|462c|e7e6|e8bd 8ff8")

    node = "_ZN4toit17ToitFinalizerNode"
    weak = node + "15weak_processingEbPNS_12RootCallbackE" + oracle
    fields = node + "8roots_do" + callback
    alive = semi + "8is_aliveEPNS_10HeapObjectE"
    active = semi + "20has_active_finalizerEPNS_10HeapObjectE"
    # Validate the virtual calls used for ordinary callbacks and the actual
    # liveness oracle. Header lookup follows a previously forwarded key.
    with open(slot, "rb") as stream:
        elf = ELFFile(stream)
        symbols = elf.get_section_by_name(".symtab")
        for table, methods in (("_ZTVN4toit17ToitFinalizerNodeE", ((1, node + "D0Ev"), (2, fields), (4, weak))),
                               ("_ZTVN4toit9SemiSpaceE", ((0, alive), (1, active)))):
            vt, = symbols.get_symbol_by_name(table)
            section = elf.get_section(vt["st_shndx"])
            for index, method in methods:
                member = 8 + 4 * index
                offset = vt["st_value"] - section["sh_addr"] + member
                if member + 4 > vt["st_size"] or not 0 <= offset <= section["sh_size"] - 4:
                    raise ValueError("finalizer method outside vtable")
                stream.seek(section["sh_offset"] + offset)
                if int.from_bytes(stream.read(4), "little") != local(method)[0] + 1:
                    raise ValueError("unexpected finalizer method " + method)
    match_block(local(active)[1], 0, "f851 3c01|f003 0203|2a01|bf18|460b|f813 0c01|f3c0 1040|4770")
    _, live = local(alive)
    match_block(live, 0, "b510|460c|3901")
    includes = "_ZN4toit5Space8includesEj"
    call(live, 6, includes)
    match_block(live, 0xa, "b138|f854 0c01|f000 0003|1e43|4258|4158|e000|2001|bd10")
    match_block(local(includes)[1], 0, "f850 3f08|4298|d007|68da|4291|d302|691a|4291|d303|"
                "681b|e7f5|2000|4770|2001|4770")
    _, process = local(weak)
    match_block(process, 0, "b570|4604|4616|461d|b119|6803|4611|689b|e014|681b|6881|"
                "685b|4628|4798|b920|6823|4620|685b|4798|e022|682b|4628|681b|68a1|"
                "4798|b130|4631|4620|6823|689b|4798|2000|e016|68a2|4630|f852 3c01|"
                "f104 0110|f023 0321|f842 3c01|68e3|681b|f8d3 30d4|60a3")
    call(process, 0x60, one)
    match_block(process, 0x64, "68e0|4621|30e4")
    append = "_ZN10LinkedFifoIN4toit13FinalizerNodeELi1EE6appendEPS1_"
    call(process, 0x6a, append)
    match_block(process, 0x6e, "2001|bd70")
    match_block(local(append)[1], 0, "6843|b953|6803|b91b|b121|1d0a|6042|e000|b101|3104|"
                "600b|6001|4770|b101|3104|681a|600a|6019|6041|4770")
    _, payload = local(fields)
    match_block(payload, 0, "b538|460c|4605|f100 0108|4620")
    call(payload, 0xc, one)
    match_block(payload, 0x10, "4620|f105 0110")
    call(payload, 0x16, one)
    match_block(payload, 0x1a, "bd38")
