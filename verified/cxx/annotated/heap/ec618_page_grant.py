# Copyright (C) 2026 Toit contributors.
"""Check the release metadata reservation's first-fit page allocation."""

import subprocess

from ec618_thumb import instructions, match_block, match_branch, match_global_address


METADATA_GRANT_BYTES = 7 * 4096


def check_first_fit(z3, count, needed):
    # Work backwards from exhaustion. The firmware skips to the page after a
    # failed probe. The reference tries each candidate in consecutive order.
    smt = ["(set-logic QF_LIA)"]
    for page in range(count):
        smt.append(f"(declare-const free{page} Bool)")
    last = count - needed
    for i in range(count, -1, -1):
        scan = ref = "(- 1)"
        if i <= last:
            probes = list(range(i, i + needed))
            scan = str(i)
            for j in reversed(probes):
                scan = f"(ite free{j} {scan} scan{j + 1})"
            available = " ".join(f"free{j}" for j in probes)
            ref = f"(ite (and {available}) {i} ref{i + 1})"
        for name, expression in (("scan", scan), ("ref", ref)):
            smt.extend([f"(declare-const {name}{i} Int)", f"(assert (= {name}{i} {expression}))"])
        if i <= last:
            smt.extend(["(push)", f"(assert (distinct scan{i} ref{i}))", "(check-sat)", "(pop)",
                        f"(assert (= scan{i} ref{i}))"])
    results = subprocess.check_output([z3, "-in"], input="\n".join(smt), text=True).splitlines()
    if results != ["unsat"] * (last + 1):
        raise ValueError(f"first-fit proof failed: {results}")


def check_page_grant(objdump, base, heap, registered_start, limit, z3, request=METADATA_GRANT_BYTES):
    def routine(name):
        return instructions(objdump, base, name)

    malloc, body = routine("malloc")
    match_block(body, 0, "b500|2800|4671|bf08|2004|f85d eb04")
    port, port_body = routine("pvPortMallocEC")
    match_branch(body, 0xe, "b.w", "pvPortMallocEC", port)
    match_block(port_body, 0, "b510|4604")
    match_branch(port_body, 4, "bl", "ensure_heap_initialized", routine("ensure_heap_initialized")[0])
    match_global_address(port_body, 8, 3, base, "heap")
    match_block(port_body, 0x10, "4621|e8bd 4010|6818")
    alloc, body = routine("cmpct_malloc_impl")
    match_branch(port_body, 0x18, "b.w", "cmpct_malloc_impl", alloc)
    match_block(body, 0, "f5b1 6f40|b537|4605|460c|d305|f5a1 5380|3b01|f5b3 6f00|d206")
    if request < 3072 or ((request - 4097) & 0xffffffff) < 2048:
        raise ValueError("metadata request takes the small allocation path")
    match_branch(body, 0x26, "bl", "lock.constprop.0", routine("lock.constprop.0")[0])
    match_branch(body, 0x2a, "bl", "get_thread_tag", routine("get_thread_tag")[0])
    match_block(body, 0x2e, "2200|f604 71ff|4603|9200|0b09|f44f 5280|4628")
    page_alloc, page = routine("page_alloc")
    match_branch(body, 0x40, "bl", "page_alloc", page_alloc)
    match_block(body, 0x44, "4604")
    match_branch(body, 0x46, "bl", "unlock.constprop.0", routine("unlock.constprop.0")[0])
    match_block(body, 0x4a, "4620|b003|bd30")

    # Use the bounds installed by the checked registration and an arbitrary
    # stable status word for every page. Zero denotes an exclusively free page.
    page_base = (registered_start + 4095) & ~4095
    count = (limit - page_base) >> 12
    needed = ((request + 4095) & 0xffffffff) >> 12
    if not (0 < needed <= count and request == needed * 4096 < 2**31):
        raise ValueError("unexpected metadata page count")
    table = heap + 348
    if table + 8 * (count + 1) > registered_start:
        raise ValueError("unmapped page descriptor sentinel")
    match_block(page, 0, "e92d 4ff0|4605|469b|2900|d054|2400|f8d0 0150|f102 3eff|"
                "eba0 0801|f505 79aa|45a0|db47|f8d5 7154|eb05 02c4|f8d2 215c|"
                "eb07 3004|ea00 060e|ea56 0302|ea4f 3c04|d136")
    match_block(page, 0x40, "1c62|190e|42b2|d007|4692|3201|f859 3032|2b00|d0f7|4654|e02a")
    match_block(page, 0x58, "f89d 2024|eb05 04c4|2a00|bf14|2202|2201|e9c4 2b57|2203|"
                "eb05 03c6|3408|429c|d002|f8c4 215c|e7f9")
    match_block(page, 0x7e, "2200|4613|0309|4291|dd06|f022 0403|443c|f844 300c|3204|e7f6")
    match_block(page, 0x96, "eb05 03c6|f8d3 315c|b113|68aa|3a01|60aa|686b|1a5b|606b|e004")
    match_block(page, 0xae, "3401|e7b5|2000|e000|4608|e8bd 8ff0")

    # Exhaust the candidate positions and each possible first occupied word.
    # Earlier probes were zero. A rejected probe rules out every skipped start,
    # so repeated rejection reaches null exactly when no free run exists.
    for candidate in range(count - needed + 1):
        stop = candidate + needed
        start = page_base + (candidate << 12)
        if start & 4095 or start + request > limit:
            raise ValueError("invalid page alignment or extent")
        for occupied in range(candidate, stop):
            load = (heap + (candidate << 3) + 348 if occupied == candidate else
                    heap + 340 + ((occupied + 1) << 3))
            if load != table + occupied * 8:
                raise ValueError("page scan probes the wrong status")
            next_candidate = occupied + 1
            if any(not (skipped <= occupied < skipped + needed)
                   for skipped in range(candidate, next_candidate)):
                raise ValueError("page scan skips a possible allocation")

        # Success writes a head (status 1 and tag), status 3 in each following
        # descriptor, then request bytes of zeros. r0 retains the aligned start.
        desc = heap + (candidate << 3)
        if desc + 348 != table + 8 * candidate:
            raise ValueError("incorrect allocation head")
        for continuation in range(candidate + 1, stop):
            desc += 8
            if desc + 348 != table + 8 * continuation:
                raise ValueError("incorrect continuation address")
        for offset in range(0, request, 4):
            address = page_base + (offset & ~3) + (candidate << 12)
            if address != start + offset or address + 4 > start + request:
                raise ValueError("page clearing exceeds the selected run")
        # The accounting epilogue reads the next status (possibly the sentinel)
        # and only writes the free-block count and remaining-byte fields.
        if heap + (stop << 3) + 348 > table + 8 * count:
            raise ValueError("accounting reads past the sentinel")
    check_first_fit(z3, count, needed)
    return malloc
