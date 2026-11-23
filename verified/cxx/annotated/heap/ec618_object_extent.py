# Copyright (C) 2026 Toit contributors.
"""Bind object construction and the collector's size reads to linked Thumb code."""

from ec618_thumb import instructions, match_block, match_branch


def check_instance_allocation(body):
    # Both slot generations contain a strict semispace bump and write the
    # trailing sentinel before filling fields and publishing the header.
    if body[2][0] == "6807":
        match_block(body, 0, "b5f0|6807|1049|6dbb|f833 3011|115c|f003 020f|e9d0 3525|1aed|"
                    "ebb5 0f84|ea4f 0684|d801|2000|e015|18f5|f8c0 5094|2000|f843 0024|2b00|"
                    "d0f5|2004|f8d7 40d4|42b0|da02|50c4|3004|e7fa|4618|ea42 1341|005b|"
                    "f840 3b01|bdf0")
    else:
        # r7 is the class size in words, r4 in bytes. Sizes smaller than
        # the header return before changing top. r0 walks from base + 4
        # to base + size, advancing by one word on each null store.
        match_block(body, 0, "b5f0|6806|1049|6db3|f833 2011|1157|00bc|2c03|dc02|2301|7143|"
                    "e004|e9d0 3525|1aed|42ac|d301|2000|e018|18e5|f8c0 5094|2000|f843 0027|"
                    "2b00|d0f5|f8d6 50d4|1d18|441c|42a0|d002|f840 5b04|e7fa|4618|f002 020f|"
                    "ea42 1241|0052|f840 2b01|bdf0")


def check_object_extent(objdump, slot, memset):
    def local(symbol):
        return instructions(objdump, slot, symbol)

    def call(body, offset, symbol):
        match_branch(body, offset, "bl", symbol, local(symbol)[0])

    heap = "_ZN4toit10ObjectHeap"
    allocate = "_ZN4toit12TwoSpaceHeap8allocateEj"
    header = "_ZN4toit10HeapObject11_set_headerEPNS_7ProgramEPNS_3SmiE"
    lookup = "_ZN4toit7Program17instance_size_forEPKNS_10HeapObjectE"
    length = "_ZNK4toit9ByteArray10raw_lengthEv"
    clear = "_ZN4toit9ByteArray6_clearEv"

    check_instance_allocation(local(heap + "17allocate_instanceEPNS_3SmiE")[1])

    # The young path of the common allocator forwards the byte count to
    # SemiSpace::allocate and tags the returned raw address on success.
    _, grant = local(allocate)
    match_block(grant, 0, "b538|4604|3074|460d")
    call(grant, 8, "_ZN4toit9SemiSpace8allocateEj")
    match_block(grant, 0xc, "b928|4629|4620|e8bd 4038")
    fail = "_ZN4toit12TwoSpaceHeap28new_space_allocation_failureEj"
    match_branch(grant, 0x16, "b.w", fail, local(fail)[0])
    match_block(grant, 0x1a, "3001|bd38")

    # Array constructors request space before writing the header and length.
    _, array = local(heap + "14allocate_arrayEiPNS_6ObjectE")
    match_block(array, 0, "b5f8|f240 33e6|4299|4606|460c|4617|d901|2500|e017|0089|3108|3010")
    call(array, 0x1a, allocate)
    match_block(array, 0x1e, "4605|2800|d0f5|6831|f8d1 2164")
    call(array, 0x2a, header)
    match_block(array, 0x2e, "462b|f843 4f03|eb05 0484|3403|42a3|d002|f843 7f04|e7fa|4628|bdf8")
    _, blob = local(heap + "28allocate_internal_byte_arrayEi")
    match_block(blob, 0, "f640 7398|4299|b570|4606|460d|d812|310b|f021 0103|3010")
    call(blob, 0x16, allocate)
    match_block(blob, 0x1a, "4604|b158|6831|f8d1 2168")
    call(blob, 0x24, header)
    match_block(blob, 0x28, "4620|f8c4 5003")
    call(blob, 0x2e, clear)
    match_block(blob, 0x32, "e000|2400|4620|bd70")
    _, zero = local(clear)
    match_block(zero, 0, "f8d0 2003|1e43|2a00|bfb8|43d2|f04f 0100|bfb4|6898|3007")
    match_branch(zero, 0x16, "b.w", "memset", memset)

    _, stack = local(heap + "14allocate_stackEi")
    match_block(stack, 0, "b570|460d|0089|4606|3128|3010")
    call(stack, 0xc, allocate)
    match_block(stack, 0x10, "4604|b1b0|6831|f8d1 218c")
    call(stack, 0x1a, header)
    match_block(stack, 0x1e, "2200|4b09|f8c4 5007|f8c4 500b|f8c4 500f|f8c4 2013|"
                "f8c4 3017|f8c4 301b|f8c4 301f|f8c4 3023|4620|bd70")

    for name, registers, class_field, stores in (
            ("15allocate_doubleEd", "4616|461f", "f8d1 21a0", "f8c4 6003|f8c4 7007"),
            ("22allocate_large_integerEx", "4617|461e", "f8d1 21a4", "f8c4 7003|f8c4 6007")):
        _, number = local(heap + name)
        match_block(number, 0, "b5f8|210c|4605|3010|" + registers)
        call(number, 0xc, allocate)
        match_block(number, 0x10, "4604|b140|6829|" + class_field)
        call(number, 0x1a, header)
        match_block(number, 0x1e, stores + "|4620|bdf8")

    # The internal string stores two halfwords (length and hash), then
    # writes the terminator at raw+8+length via its mutable byte view.
    _, string = local(heap + "24allocate_internal_stringEi")
    match_block(string, 0, "b573|460d|310c|4606|f021 0103|3010")
    call(string, 0xe, allocate)
    match_block(string, 0x12, "4604|b1d8|6833|4601|f8d3 2160|6d9b|1052|f833 3012|"
                "f8a0 5005|f003 030f|ea43 1342|005b|f840 3c01|f64f 73ff|f8a0 3003|4668")
    view = "_ZN4toit6String12MutableBytesC1EPS0_"
    call(string, 0x42, view)
    match_block(string, 0x46, "e9dd 2300|2100|54d1|4620|b002|bd70")
    match_block(local(view)[1], 0, "f64f 72ff|f8b1 3005|4293|bf09|f8d1 300b|3107|6003|"
                "f8d1 3007|bf18|6001|6043|4770")

    _, write = local(header)
    match_block(write, 0, "6d8b|1052|f833 3012|f003 030f|ea43 1342|005b|f840 3c01|4770")
    _, read = local(lookup)
    match_block(read, 0, "f851 3c01|119b|d504|3302|bf14|2000|2001|e003|6d82|f832 0013|1140|0080|4770")
    _, size = local("_ZNK4toit10HeapObject4sizeEPNS_7ProgramE")
    match_block(size, 0, "b510|4604|4608|4621")
    call(size, 8, lookup)
    match_block(size, 0xc, "2800|d137|f854 2c01|1e63|f3c2 0143|290b|d82a|e8df f001")
    # TBB uses byte entries relative to 0x22. Tag 0 enters at 0x2e,
    # tag 5 at 0x36. Binutils prints this inline table in little endian.
    match_block(size, 0x22, "1506")
    if (size[0x24][0], size[0x28][0]) != ("0a2c2929", "1f29112c"):
        raise ValueError("unexpected variable object size dispatch")
    match_block(size, 0x2e, "6858|0080|3008|e024|4620")
    call(size, 0x38, length)
    match_block(local(length)[1], 0, "f8d0 0003|4770")
    match_block(size, 0x3c, "2800|db1e|300b|e00a")
    match_block(size, 0x44, "6898|0080|3028|e019|f64f 73ff|f8b4 0005|4298|d012|300c")
    match_block(size, 0x7a, "200c|e000")
    match_block(size, 0x5a, "f020 0003|e00f")
    match_block(size, 0x80, "bd10")
