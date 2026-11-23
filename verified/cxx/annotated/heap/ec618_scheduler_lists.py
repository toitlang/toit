# Copyright (C) 2026 Toit contributors.
"""Prove the linked FreeRTOS list splices on arbitrary aligned word memory."""

import subprocess


def splice_obligations(function, remove):
    _, body = function
    smt = [
        "(set-logic QF_AUFBV)", "(define-sort W () (_ BitVec 32))",
        "(define-sort Mem () (Array W W))", "(declare-const initial Mem)",
        "(declare-const list W)", "(declare-const item W)",
    ]

    def word(x):
        return f"#x{x:08x}"

    def field(ptr, offset):
        return f"(bvadd {ptr} {word(offset)})"

    def initial(ptr, offset):
        return f"(select initial {field(ptr, offset)})"

    cursor = initial("list", 4)
    prev = initial("item", 8) if remove else initial(cursor, 8)
    after = initial("item", 4) if remove else cursor
    left, right = field(prev, 4), field(after, 8)
    count, index = field("list", 0), field("list", 4)
    nxt, back, container = [field("item", off) for off in (4, 8, 16)]
    accessible = [count, index, nxt, back, container, left, right]
    for name in accessible:
        smt.append(f"(assert (= ((_ extract 1 0) {name}) #b00))")
    # Separate the actual words, allowing the predecessor and successor to
    # coincide (including the embedded sentinel of an empty/singleton list).
    smt.append(f"(assert (distinct {' '.join(accessible)}))")
    smt.append("(assert (distinct list #x00000000))")
    if remove:
        smt.extend([f"(assert (= {initial('item', 16)} list))",
                    f"(assert (distinct {initial('list', 0)} #x00000000))",
                    f"(assert (= (select initial {left}) item))",
                    f"(assert (= (select initial {right}) item))"])
        expected_cursor = f"(ite (= {cursor} item) {prev} {cursor})"
        new_count = f"(bvsub {initial('list', 0)} #x00000001)"
        edits = [(left, after), (right, prev), (index, expected_cursor),
                 (container, word(0)), (count, new_count)]
        regs = {0: "item"}
    else:
        smt.extend([f"(assert (= {initial('item', 16)} #x00000000))",
                    f"(assert (distinct {initial('list', 0)} #xffffffff))",
                    f"(assert (= (select initial {left}) {after}))"])
        new_count = f"(bvadd {initial('list', 0)} #x00000001)"
        edits = [(nxt, after), (back, prev), (left, "item"), (right, "item"),
                 (container, "list"), (count, new_count)]
        regs = {0: "list", 1: "item"}

    preserved = {r: f"saved{r}" for r in range(4, 12)}
    for reg in preserved.values():
        smt.append(f"(declare-const {reg} W)")
    regs.update(preserved)
    mem = "initial"
    expected = "initial"
    for address, value in edits:
        expected = f"(store {expected} {address} {value})"
    checks = []
    guard = None
    equality = None
    pc = 0
    while pc in body:
        ins = tuple(int(h, 16) for h in body[pc][0].split())
        h = ins[0]
        if guard and h & 0xf800 != 0x6000:
            raise ValueError("expected a conditional list store")
        if len(ins) == 2 and h & 0xfff0 == 0xe9d0:
            second = ins[1]
            if max(second >> 12, (second >> 8) & 15) >= 13 or second >> 12 == (second >> 8) & 15:
                raise ValueError("unexpected list double-load registers")
            ptr = regs[h & 15]
            offset = (second & 255) * 4
            reads = [(second >> 12, field(ptr, offset)), ((second >> 8) & 15, field(ptr, offset + 4))]
        elif len(ins) == 1 and h & 0xf800 == 0x6800:
            reads = [(h & 7, field(regs[(h >> 3) & 7], 4 * ((h >> 6) & 31)))]
        else:
            reads = []
            if len(ins) != 1:
                raise ValueError(f"unsupported list operation {ins}")
            if h & 0xf800 == 0x6000:
                addr = field(regs[(h >> 3) & 7], 4 * ((h >> 6) & 31))
                writable = [a for a, _ in edits]
                valid = "(or " + " ".join(f"(= {addr} {a})" for a in writable) + ")"
                checks.append(f"(=> {guard} {valid})" if guard else valid)
                update = f"(store {mem} {addr} {regs[h & 7]})"
                if guard:
                    update = f"(ite {guard} {update} {mem})"
                    guard = None
                mem = f"m{pc}"
                smt.append(f"(define-fun {mem} () Mem {update})")
            elif h & 0xffc0 == 0x4280:
                equality = f"(= {regs[h & 7]} {regs[(h >> 3) & 7]})"
            elif h == 0xbf08 and equality:
                guard = equality
            elif h & 0xf800 == 0x2000:
                regs[(h >> 8) & 7] = word(h & 255)
                equality = None
            elif h & 0xf800 in (0x3000, 0x3800):
                dst = (h >> 8) & 7
                op = "bvsub" if h & 0x800 else "bvadd"
                regs[dst] = f"({op} {regs[dst]} {word(h & 255)})"
                equality = None
            elif h == 0x4770:
                break
            else:
                raise ValueError(f"unsupported list instruction {h:#x}")
        for dst, addr in reads:
            checks.append("(or " + " ".join(f"(= {addr} {a})" for a in accessible) + ")")
            regs[dst] = f"r{dst}_{pc}"
            smt.append(f"(define-fun {regs[dst]} () W (select {mem} {addr}))")
        pc += 2 * len(ins)
    else:
        raise ValueError("list splice has no return")
    checks.extend(f"(= {regs[r]} {value})" for r, value in preserved.items())
    checks.append(f"(= {mem} {expected})")
    if remove:
        checks.append(f"(= {regs[0]} {new_count})")
    # First check satisfiability so inconsistent layout assumptions fail closed.
    # Require witnesses for the actual embedded sentinel layout and both
    # cursor branches, including singleton deletion and insertion into empty.
    sentinel = field("list", 8)
    sole = word(1 if remove else 0)
    cursor_cases = ("item", sentinel) if remove else (sentinel,)
    for value in cursor_cases:
        smt.extend(["(push)", f"(assert (= {cursor} {value}))",
                    f"(assert (= {prev} {sentinel}))", f"(assert (= {after} {sentinel}))",
                    f"(assert (= {initial('list', 0)} {sole}))", "(check-sat)", "(pop)"])
    smt.extend([f"(assert (not (and {' '.join(checks)})))", "(check-sat)"])
    return "\n".join(smt)


def check_scheduler_lists(code, z3):
    for name, remove in (("uxListRemove", True), ("vListInsertEnd", False)):
        query = splice_obligations(code[name], remove)
        results = subprocess.check_output([z3, "-in"], input=query, text=True).splitlines()
        if results != ["sat"] * (2 if remove else 1) + ["unsat"]:
            raise ValueError(f"{name}: linked list memory proof failed: {results}")
