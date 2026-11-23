# Copyright (C) 2026 Toit contributors.
"""Check the linked fragment insertion paths taken by release heap registration."""

from ec618_thumb import instructions, match_block, match_branch


def check_fragments(objdump, base, heap, page_start, page_end, fragments):
    add = "add_to_heap.constprop.0"
    header = "create_allocation_header"
    free = "create_free_area.constprop.0"
    index = "size_to_index_freeing"
    helper = "size_to_index_helper"
    bit = "set_free_list_bit"
    functions = {name: instructions(objdump, base, name) for name in
                 (add, header, free, index, helper, bit, "untag", "tag_as_free")}

    def block(fn, pc, codes):
        match_block(functions[fn][1], pc, codes)

    def call(fn, pc, target, op="bl"):
        match_branch(functions[fn][1], pc, op, target, functions[target][0])

    # No indirect calls. Check the operands that select the store addresses,
    # including the actual callees' preservation of live caller-scratch registers.
    block(add, 0, "f8d0 314c|e92d 41f0|4616|f500 72a4|460c|604b|600a|f8c0 114c|6019|"
          "2300|2108|4605|461a|1860")
    call(add, 0x24, header)
    block(add, 0x28, "682b|f1a6 0718|443b|4628|602b|f104 0110|463b|2208")
    call(add, 0x3c, free)
    block(add, 0x40, "2300|f1a6 0008|463a|4420|4619|e8bd 41f0")
    call(add, 0x50, header, "b.w")

    block(header, 0, "b510|4604|4610")
    call(header, 6, "untag")
    block("untag", 0, "f020 0001|4770")
    block(header, 0xa, "b280|ea40 4101|e9c4 1300|f104 0008|bd10")

    block(free, 0, "b5f8|4605|4610")
    call(free, 6, "tag_as_free")
    block("tag_as_free", 0, "f040 0001|4770")
    block(free, 0xa, "880c|461f|ea44 4403|0c22|0412|4302|600a|f1a3 0008|460e")
    call(free, 0x20, index)
    block(index, 0, "2300|b507|461a|a901")
    call(index, 8, helper)
    block(index, 0xc, "b003|f85d fb04")
    # Both payloads take the >128 path. Its only store on a valid index
    # goes to the stack word allocated by size_to_index_freeing.
    block(helper, 0, "2880|b510|d803")
    block(helper, 0xe, "4402|fab2 f482|f1c4 041c|40e2|f002 0007|ea40 00c4|4418|f000 0307|"
          "10c2|3308|3811|4093|2847|600b|dd08")
    block(helper, 0x48, "bd10")
    block(free, 0x24, "4602|4601|eb05 0282|4628")
    call(free, 0x2e, bit)
    block(bit, 0, "114b|43c9|eb00 0083|2301|f001 011f|fa03 f101|f8d0 313c|430b|f8c0 313c|4770")
    block(free, 0x32, "69d3|b103|60de|60b3|2300|60f3|68ab|61d6|3301|60ab|686b|443b|606b|bdf8")

    # cmpct_init established the empty arena ring, buckets and bitmap. Track
    # every non-stack store of the checked blocks across both insertions.
    root = heap + 328
    ring_head = root
    buckets = [0] * 72
    for start, end in fragments:
        span = end - start
        payload = span - 32
        if not (128 < payload < 4096 and start % 8 == end % 8 == 0):
            raise ValueError("unexpected registration fragment size")
        # r4 = 28 - clz(payload); r3 = 0 for the freeing specialization.
        shift = payload.bit_length() - 4
        bucket = ((shift << 3) | ((payload >> shift) & 7)) - 17
        if not 0 <= bucket < len(buckets):
            raise ValueError("registration fragment selects invalid bucket")
        node = start + 16
        writes = [
            (start, 8), (root + 4, 4), (ring_head, 4),  # arena ring
            (start + 8, 8), (end - 8, 8),             # allocation headers
            (node, 4), (node + 8, 8),                  # free header and links
            (heap + 28 + 4 * bucket, 4), (heap + 316 + 4 * (bucket >> 5), 4),
            (heap, 4), (heap + 4, 4), (heap + 8, 4),   # accounting
        ]
        if buckets[bucket]:
            writes.append((buckets[bucket] + 12, 4))
        # Header accounting, buckets, bitmaps and arena ring are writable.
        # All other header words, the descriptors and whole pages stay intact.
        allowed = [(heap, heap + 12), (heap + 28, heap + 336), *fragments]
        for address, size in writes:
            if not any(lo <= address and address + size <= hi for lo, hi in allowed):
                raise ValueError("registration write outside allocator bookkeeping and fragments")
            if address < page_end and page_start < address + size:
                raise ValueError("registration write overlaps a whole heap page")
        ring_head = start
        buckets[bucket] = node
    return functions[add][0]
