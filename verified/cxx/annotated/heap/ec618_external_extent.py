# Copyright (C) 2026 Toit contributors.
"""Check external constructors, finalizer flag, resize and detach on EC618."""

from ec618_thumb import instructions, match_block, match_branch


def check_external_extent(objdump, slot, base):
    def local(name):
        return instructions(objdump, slot, name)

    def call(body, pc, name):
        match_branch(body, pc, "bl", name, local(name)[0])

    heap = "_ZN4toit10ObjectHeap"
    allocate = "_ZN4toit12TwoSpaceHeap8allocateEj"
    header = "_ZN4toit10HeapObject11_set_headerEPNS_7ProgramEPNS_3SmiE"
    finalizer = heap + "16add_vm_finalizerEPNS_10HeapObjectE"
    byte_array = "_ZN4toit9ByteArray"
    raw_length = "_ZNK4toit9ByteArray10raw_lengthEv"
    unregister = heap + "30unregister_external_allocationEi"

    _, blob = local(heap + "28allocate_external_byte_arrayEiPhbb")
    match_block(blob, 0, "e92d 43f8|460f|2110|4606|4408|4615|4698|f89d 9020")
    call(blob, 0x14, allocate)
    match_block(blob, 0x18, "4604|b1f0|6831|43ff|f8d1 2168")
    call(blob, 0x24, header)
    match_block(blob, 0x28, "f8c4 5007|fab5 f585|096d|f8c4 7003|f8c4 500b|f1b9 0f00|d002|4620")
    call(blob, 0x42, byte_array + "6_clearEv")
    match_block(blob, 0x46, "f1b8 0f00|d007|4621|4630")
    call(blob, 0x50, finalizer)
    match_block(blob, 0x54, "b910|2302|7173|2400|4620|e8bd 83f8")

    _, string = local(heap + "24allocate_external_stringEiPhb")
    match_block(string, 0, "e92d 41f3|460e|2110|4605|4408|4617|4698")
    call(string, 0x10, allocate)
    match_block(string, 0x14, "4604|b310|6829|f8d1 2160")
    call(string, 0x1e, header)
    match_block(string, 0x22, "f64f 72ff|f8c4 6007|f8a4 2005|f8a4 2003|f8c4 700b|"
                "5dbb|b13b|4621|4668")
    call(string, 0x3e, "_ZN4toit6String12MutableBytesC1EPS0_")
    match_block(string, 0x42, "e9dd 2300|2100|54d1|f1b8 0f00|d007|4621|4628")
    call(string, 0x54, finalizer)
    match_block(string, 0x58, "b910|2302|716b|2400|4620|b002|e8bd 81f0")

    # Registration only changes the object's header, given separate storage
    # for the new node, the heap and the existing queue links.
    _, register = local(finalizer)
    match_block(register, 0, "b538|4604|460d|2010|4911")
    new = "_ZnwjRKSt9nothrow_t"
    match_branch(register, 0xa, "bl", new, instructions(objdump, base, new)[0])
    match_block(register, 0xe, "4601|b1e0|2300|e9c0 3501|4b0e|60c4|6003|f8d4 30f8|b923|f104 00f4")
    prepend = "_ZN10LinkedFifoIN4toit13FinalizerNodeELi1EE7prependEPS1_"
    call(register, 0x28, prepend)
    match_block(local(prepend)[1], 0, "6803|b92b|b111|1d0a|6042|e004|6043|e000|b909|2100|e000|3104|600b|6001|4770")
    match_block(register, 0x2c, "e005|1d02|6818|6048|601a|f8c4 20f8|2001|f855 3c01|"
                "f023 0301|f043 0320|f845 3c01|bd38")

    # On the process heap the accounting helpers write the current counter
    # at +204 and the cumulative counter at +208. The latter is a 64-bit
    # update in a single-core interrupt-masked critical section.
    match_block(local(unregister)[1], 0, "b159|f3bf 8f5b|30cc|e850 3f00|1a5b|e840 3200|"
                "2a00|d1f8|f3bf 8f5b|4770")
    _, charge = local(heap + "28register_external_allocationEi")
    match_block(charge, 0, "b507|460a|b191|f3bf 8f5b|f100 03cc|e853 cf00|4494|"
                "e843 c100|2900|d1f8|2300|f3bf 8f5b|30d0|9300|17d3")
    call(charge, 0x28, "__atomic_fetch_add_8")
    match_block(charge, 0x2c, "b003|f85d fb04")
    match_block(local("__atomic_fetch_add_8")[1], 0, "b5f0|4604|f3ef 8510|b672|f3bf 8f5f|"
                "c803|1886|eb43 0701|e9c4 6700|f3bf 8f5f|f385 8810|bdf0")

    _, resize = local(byte_array + "15resize_externalEPNS_7ProcessEi")
    match_block(resize, 0, "b570|460e|4615|4604")
    call(resize, 8, raw_length)
    match_block(resize, 0xc, "3658|43c1|4630")
    call(resize, 0x12, unregister)
    match_block(resize, 0x16, "4629|4630")
    call(resize, 0x1a, heap + "28register_external_allocationEi")
    match_block(resize, 0x1e, "43eb|4629|f8c4 3003|f8d4 0007|3c01")
    match_branch(resize, 0x2c, "bl", "realloc", instructions(objdump, base, "realloc")[0])
    match_block(resize, 0x30, "b108|60a0|e001|b905|60a5|bd70")

    _, detach = local(byte_array + "6neuterEPNS_7ProcessE")
    match_block(detach, 0, "b537|460d|4604|4601|4668")
    view = byte_array + "5BytesC1EPS0_"
    call(detach, 0xa, view)
    _, bytes_view = local(view)
    match_block(bytes_view, 0, "b538|4605|4608|460c")
    call(bytes_view, 8, raw_length)
    match_block(bytes_view, 0xc, "2800|bfba|43c0|f8d4 4007|3407|e9c5 4000|4628|bd38")
    match_block(detach, 0xe, "f105 0058|9901")
    call(detach, 0x14, unregister)
    match_block(detach, 0x18, "2300|f8c4 3007|f04f 33ff|9800|f8c4 3003|b003|bd30")

    # ec618_object_extent checks both branches to this shared return.
    _, size = local("_ZNK4toit10HeapObject4sizeEPNS_7ProgramE")
    match_block(size, 0x7e, "2010|bd10")
