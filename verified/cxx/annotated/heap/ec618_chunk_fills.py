# Copyright (C) 2026 Toit contributors.
"""Symbolically execute the GC chunk initializer and mark-bit helper."""

import re


def initialization_obligations(initialize, clear, memset_address, singleton):
    # Every table is writable, suitably sized, and disjoint from the stack,
    # live descriptor, singleton and other tables. Biases are 32-bit words.
    smt = [
        "(set-logic QF_LIA)",
        "(define-fun wrap ((x Int)) Int (mod x 4294967296))",
        "(declare-const low Int)", "(declare-const extent Int)",
        "(declare-const start Int)", "(declare-const end Int)",
        "(assert (and (<= 0 low start) (< start end 4294967296) (<= end (+ low extent) 4294967296)))",
        "(assert (and (= (mod low 4096) 0) (= (mod extent 4096) 0)"
        " (= (mod start 4096) 0) (= (mod end 4096) 0)))",
    ]
    tables = [("marks", 32, 0), ("overflow", 1024, 0), ("starts", 128, 2), ("remembered", 128, 0)]
    for name, scale, _ in tables:
        smt.extend([
            f"(declare-const {name} Int)",
            f"(assert (and (<= 0 {name}) (<= (+ {name} (div extent {scale})) 4294967296)))",
            f"(define-fun {name}_bias () Int (wrap (- {name} (div low {scale}))))",
        ])
    loads = {("chunk", 12): "start", ("chunk", 16): "end",
             ("metadata", 52): "starts_bias", ("metadata", 56): "remembered_bias",
             ("metadata", 60): "marks_bias", ("metadata", 64): "overflow_bias"}
    r = {0: "chunk", 3: "initial-r3", 4: "initial-r4", 5: "initial-r5", 14: "return"}
    fills = 0
    conditions = []

    def call_memset():
        nonlocal fills
        name, scale, value = tables[fills]
        first = f"(div (- start low) {scale})"
        last = f"(div (- end low) {scale})"
        conditions.append(f"(and (= {r[0]} (+ {name} {first})) (= (mod {r[1]} 256) {value})"
                          f" (= (+ {r[0]} {r[2]}) (+ {name} {last})))")
        fills += 1
        # The proved base memset preserves r0, r1, r4, r5 and lr. Forget
        # caller-saved values that the C ABI permits this callee to clobber.
        for reg in (0, 1, 2, 3):
            r.pop(reg, None)

    def walk(function, is_helper):
        entry, body = function
        preserved = {k: r[k] for k in (4, 5, 14)}
        pc = 0
        saved = None
        while pc in body:
            encoding, asm = body[pc]
            ins = tuple(int(h, 16) for h in encoding.split())
            h = ins[0]
            following = pc + 2 * len(ins)
            if ins == (0xb538,) and saved is None:
                saved = {k: r[k] for k in (3, 4, 5, 14)}
            elif ins == (0x4604,):
                r[4] = r[0]
            elif len(ins) == 1 and h & 0xf800 == 0x4800:
                offset = ((entry + pc + 4) & ~3) + 4 * (h & 255) - entry
                if int(body[offset][0], 16) != singleton:
                    raise ValueError("incorrect singleton literal")
                r[(h >> 8) & 7] = "metadata"
            elif ins == (0xe9d0, 0x3203) and r[0] == "chunk":
                r[3], r[2] = "start", "end"
            elif len(ins) == 1 and h & 0xf800 == 0x6800:
                r[h & 7] = loads[(r[(h >> 3) & 7], 4 * ((h >> 6) & 31))]
            elif len(ins) == 1 and h & 0xf800 == 0x2000:
                r[(h >> 8) & 7] = str(h & 255)
            elif len(ins) == 1 and h & 0xfe00 == 0x1a00:
                r[h & 7] = f"(wrap (- {r[(h >> 3) & 7]} {r[(h >> 6) & 7]}))"
            elif len(ins) == 1 and h & 0xf800 == 0x0800:
                shift = ((h >> 6) & 31) or 32
                r[h & 7] = f"(div {r[(h >> 3) & 7]} {1 << shift})"
            elif len(ins) == 2 and h & 0xfff0 in (0xeb00, 0xeba0) and ins[1] & 0x8030 == 0x10:
                second = ins[1]
                shift = ((((second >> 12) & 7) << 2) | ((second >> 6) & 3)) or 32
                op = "+" if h & 0xfff0 == 0xeb00 else "-"
                r[(second >> 8) & 15] = f"(wrap ({op} {r[h & 15]} (div {r[second & 15]} {1 << shift})))"
            elif ins in ((0xb14a,), (0xb14b,), (0xb15b,)):
                # CBZ. Prove the fall-through edge from the live chunk bounds.
                conditions.append(f"(distinct {r[h & 7]} 0)")
            elif ins == (0xe8bd, 0x4038) and saved is not None:
                r.update(saved)
                saved = None
            elif match := re.fullmatch(r"(bl|b\.w)\s+([0-9a-f]+) <[^>]+>", asm):
                target = int(match[2], 16)
                if match[1] == "bl":
                    r[14] = str(entry + following + 1)
                if target == memset_address:
                    call_memset()
                elif target == clear[0] and not is_helper and match[1] == "bl" and r[0] == "chunk":
                    walk(clear, True)
                else:
                    raise ValueError(f"unexpected call at {entry + pc:#x}")
                if match[1] == "b.w":
                    if saved is not None or any(r[k] != v for k, v in preserved.items()):
                        raise ValueError("tail call with outstanding frame or changed return state")
                    return
            else:
                raise ValueError(f"unsupported initializer instruction at {entry + pc:#x}: {asm}")
            pc = following
        raise ValueError("initializer path ended without returning")

    walk(initialize, False)
    if fills != len(tables) or any(r[k] != v for k, v in ((4, "initial-r4"), (5, "initial-r5"), (14, "return"))):
        raise ValueError("incomplete metadata initialization or invalid return state")
    for condition in conditions:
        smt.extend(["(push)", f"(assert (not {condition}))", "(check-sat)", "(pop)"])
    return "\n".join(smt), len(conditions)


def setup_bias_obligations(function, memset_address, epilogue=(0xb002, "e8bd 81f0")):
    # At return from the page-type memset, r4 points to the live metadata
    # object. Its six table bases and heap lower bound are already installed.
    _, body = function
    call, = [pc for pc, (_, asm) in body.items()
             if re.fullmatch(r"bl\s+0*" + f"{memset_address:x} <memset>", asm)]
    pc = call + 4
    inputs = {0: "low", 28: "remembered", 32: "starts", 36: "marks", 40: "overflow", 48: "counts"}
    expected = {52: ("starts", 128), 56: ("remembered", 128), 60: ("marks", 32),
                64: ("overflow", 1024), 68: ("counts", 32)}
    registers = {}
    writes = {}
    while pc in body:
        encoding, _ = body[pc]
        ins = tuple(int(h, 16) for h in encoding.split())
        h = ins[0]
        if len(ins) == 1 and h & 0xf800 == 0x6800 and (h >> 3) & 7 == 4 and h & 7 != 4:
            registers[h & 7] = inputs[4 * ((h >> 6) & 31)]
        elif len(ins) == 2 and h & 0xfff0 == 0xeba0 and ins[1] & 0x8030 == 0x10:
            second = ins[1]
            dst = (second >> 8) & 15
            if dst not in (0, 1, 2, 3):
                raise ValueError("unexpected setup subtraction destination")
            shift = ((((second >> 12) & 7) << 2) | ((second >> 6) & 3)) or 32
            registers[dst] = f"(mod (- {registers[h & 15]} (div {registers[second & 15]} {1 << shift})) 4294967296)"
        elif len(ins) == 1 and h & 0xf800 == 0x6000 and (h >> 3) & 7 == 4:
            offset = 4 * ((h >> 6) & 31)
            if offset in writes or offset not in expected:
                raise ValueError("unexpected or repeated metadata field store")
            writes[offset] = registers[h & 7]
        elif ins == (epilogue[0],) and body[pc + 2][0] == epilogue[1]:
            break
        else:
            raise ValueError(f"unsupported metadata setup instruction: {encoding}")
        pc += 2 * len(ins)
    else:
        raise ValueError("missing setup return")
    if writes.keys() != expected.keys():
        raise ValueError("incomplete bias publication")
    smt = ["(set-logic QF_LIA)"]
    for name in inputs.values():
        smt.extend([f"(declare-const {name} Int)", f"(assert (and (<= 0 {name}) (< {name} 4294967296)))"])
    for offset, (table, scale) in expected.items():
        smt.extend(["(push)", f"(assert (distinct (mod (+ {writes[offset]} (div low {scale})) 4294967296) {table}))",
                    "(check-sat)", "(pop)"])
    return "\n".join(smt), len(expected)


def check_classification(slot, target, entry, body, singleton):
    # The only variable-width values are the linked tail branch, checked by
    # the caller, and the address of the metadata singleton in the literal pool.
    code = {0: "b430", 2: "4c09", 4: "68c5", 6: "6823", 8: "6862", 10: "1aeb",
            12: "429a", 14: "d908", 16: "6902", 18: "6ae0", 20: "1b52", 22: "0b12",
            24: "eb00 3013", 28: "bc30", 34: "bc30", 36: "4770"}
    if any(body.get(offset, (None,))[0] != encoding for offset, encoding in code.items()):
        raise ValueError(f"{slot}: page-classification instructions changed")
    if not re.fullmatch(r"b\.w\s+0*" + f"{target:x} <memset>", body[30][1]) or entry % 4:
        raise ValueError(f"{slot}: unexpected classification tail branch or literal alignment")
    if int(body[40][0], 16) != singleton:
        raise ValueError(f"{slot}: wrong metadata singleton literal")
