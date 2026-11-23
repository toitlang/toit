# Copyright (C) 2026 Toit contributors.
"""Check the linked success path of EC618 GC metadata setup."""

import re

from ec618_page_grant import METADATA_GRANT_BYTES


def layout_obligations(function, memset_address, use_memory, heap_contract):
    entry, body = function
    pc = 0

    def block(encodings):
        nonlocal pc
        for encoding in encodings.split("|"):
            if body[pc][0] != encoding:
                raise ValueError(f"metadata layout instruction changed at {entry + pc:#x}")
            pc += 2 * len(encoding.split())

    def call(symbol, address=None):
        nonlocal pc
        target = re.fullmatch(r"bl\s+([0-9a-f]+) <" + re.escape(symbol) + ">", body[pc][1])
        if not target or (address is not None and int(target[1], 16) != address):
            raise ValueError(f"unexpected call at {entry + pc:#x}")
        pc += 4

    smt = [
        "(set-logic QF_LIA)",
        "(define-fun word ((x Int)) Int (mod x 4294967296))",
        "(define-fun down ((x Int) (n Int)) Int (- x (mod x n)))",
        "(declare-const start Int)", "(declare-const length Int)", "(declare-const base Int)",
        "(assert (and (<= 0 start) (< 0 length) (<= (+ start length) 4294963200)))",
    ]

    def define(name, expression):
        smt.append(f"(define-fun {name} () Int {expression})")

    # The range getter returns its two words into the stack frame.
    block("e92d 41f3|4604|4668")
    call("_ZN4toit2OS21get_heap_memory_rangeEv")
    block("9b01|4939|9800")
    if entry % 4 or body[0xf4][0] != "fffff000":
        raise ValueError("unexpected setup alignment mask")
    block("f603 73ff|ea00 0201|4403|1a9b|400b|6022")
    define("low", "(down start 4096)")
    define("extent", "(down (word (- (word (+ (word (+ length 4095)) start)) low)) 4096)")
    block("0a9e|0b1d|0852|f042 4200|361f|351f|60a2|f026 061f|085a|f025 051f|60e2")
    define("r6", "(down (word (+ (div extent 1024) 31)) 32)")
    define("r5", "(down (word (+ (div extent 4096) 31)) 32)")
    block("19aa|09d8|f602 72ff|eb02 0240|6063|095f|eb02 1313|400b|6163|6120")
    define("cards", "(div extent 128)")
    define("r7", "(div extent 32)")
    define("partial", "(word (+ (word (+ (word (+ r5 r6)) 4095)) (* 2 cards)))")
    define("request", "(down (word (+ partial (div extent 16))) 4096)")
    call("_ZN4toit2OS12get_heap_tagEv")
    block("4680|f06f 005f")
    call("_ZN4toit2OS12set_heap_tagEi")
    block("6961|2000")
    call("_ZN4toit2OS19grab_virtual_memoryEPvj")
    block("61a0|4640")
    call("_ZN4toit2OS12set_heap_tagEi")
    block("69a0|b920")  # Nonzero reservation branches to +0x84.
    pc = 0x84

    # Independent geometry in whole pages, with unbounded specification arithmetic.
    define("pages", "(- (div (+ start length 4095) 4096) (div start 4096))")
    define("markBytes", "(* 128 pages)")
    define("cardBytes", "(* 32 pages)")
    define("overflowBytes", "(* 32 (div (+ pages 7) 8))")
    define("typeBytes", "(* 32 (div (+ pages 31) 32))")
    define("used", "(+ (* 2 markBytes) (* 2 cardBytes) overflowBytes typeBytes)")
    define("reserved", "(* 4096 (div (+ used 4095) 4096))")
    obligations = 0

    def prove(condition):
        nonlocal obligations
        smt.extend(["(push)", f"(assert (not {condition}))", "(check-sat)", "(pop)",
                    f"(assert {condition})"])
        obligations += 1

    prove("(= extent (* 4096 pages))")
    prove("(and (< 0 pages) (<= pages 1048575))")
    prove("(= r7 markBytes)")
    prove("(= cards cardBytes)")
    prove("(= r6 overflowBytes)")
    prove("(= r5 typeBytes)")
    prove("(= partial (+ 4095 typeBytes overflowBytes (* 2 cardBytes)))")
    prove("(= request reserved)")
    _, _, fallback, limit, registered = heap_contract
    prove(f"(=> (and (or (= start {fallback}) (= start {registered})) (= (+ start length) {limit}))"
          f" (= request {METADATA_GRANT_BYTES}))")
    smt.append("(assert (and (< 0 base) (<= (+ base request) 4294967296)))")

    block("6921|6260|4438|6320|4438|1843|6223|440b|62a3|4433|62e3|61e0")
    define("counts", "(word (+ base r7))")
    define("remembered", "(word (+ counts r7))")
    define("starts", "(word (+ remembered cards))")
    define("overflow", "(word (+ starts cards))")
    define("types", "(word (+ overflow r6))")

    symbol = "_ZN4toit2OS18use_virtual_memoryEPvj"
    use_entry, use_body = use_memory
    if {k: v[0] for k, v in use_body.items()} != {0: "2001", 2: "4770"}:
        raise ValueError("EC618 memory commit no longer returns true unconditionally")
    call(symbol, use_entry)  # r0=remembered, r1=cards
    for args in ("6921|6a20", "4631|6aa0", "4629|6ae0"):
        block(args)
        call(symbol, use_entry)
    block("462a|2100|6ae0")
    call("memset", memset_address)
    smt.extend(["(assert (not (and (< 0 pages) (= counts (+ base markBytes))",
                "(= remembered (+ counts markBytes)) (= starts (+ remembered cardBytes))",
                "(= overflow (+ starts cardBytes)) (= types (+ overflow overflowBytes))",
                "(= cards cardBytes) (= r6 overflowBytes) (= r5 typeBytes)",
                "(<= (+ types typeBytes) (+ base request)))))", "(check-sat)"])
    return "\n".join(smt), obligations + 1
