# Copyright (C) 2026 Toit contributors.
"""Check linked FreeRTOS ordered insertion and indefinite waiter registration."""

import subprocess

from ec618_thumb import match_block, match_branch


def check_event_wait(code, literal, z3):
    place = "vTaskPlaceOnEventList"
    delay = "prvAddCurrentTaskToDelayedList"
    insert = "vListInsert"

    def block(name, pc, enc):
        match_block(code[name][1], pc, enc)

    def call(name, pc, dest, op="bl"):
        match_branch(code[name][1], pc, op, dest, code[dest][0])

    # Scheduler suspended, live nonempty TCB, receive list in r0,
    # join's UINT32_MAX wait in r1. Event and state items are distinct.
    block(place, 0, "b537|460d|4604|b950")
    literal(place, 0x1e, 28, "pxCurrentTCB")
    block(place, 0x1e, "4b07|6819|3118")
    call(place, 0x24, insert)
    block(place, 0x28, "2101|4628|b003|e8bd 4030")
    call(place, 0x32, delay, "b.w")
    for pc, disp, sym in ((4, 80, "xTickCount"), (6, 84, "pxCurrentTCB"),
                          (0x1c, 64, "xSuspendedTaskList")):
        literal(delay, pc, disp, sym)
    block(delay, 0, "b5f8|4606|4b14|4d15|681c|6828|460f|3004")
    call(delay, 0x10, "uxListRemove")
    block(delay, 0x14, "1c73|d107|b137|6829|4810|3104|e8bd 40f8")
    call(delay, 0x24, "vListInsertEnd", "b.w")

    body = code[insert][1]
    block(insert, 0, "b530|680c|1c63|d101|6903|e006|f100 0208|4613|6852|6815|42a5")
    # Conditional backwards branch consumes one existing item. At a finite
    # key, the maximal sentinel always stops the scan; a maximal new key
    # takes the direct tail path, including on an empty list.
    branch = int(body[0x18][0], 16)
    cmp = {0xd9fa: "bvule", 0xd3fa: "bvult"}.get(branch)
    if cmp is None:
        raise ValueError("unexpected ordered-list scan branch")
    smt = [f"""
(set-logic QF_AUFBV)
(define-sort W () (_ BitVec 32))
(define-sort M () (Array W W))
(declare-const key W)
(declare-const nextKey W)
(push)
(assert (distinct key #xffffffff))
(assert (or (distinct ({cmp} nextKey key) (bvule nextKey key))
            ({cmp} #xffffffff key)))
(check-sat)
(pop)
(declare-const mem M)
(declare-const list W)
(declare-const item W)
(declare-const prev W)
(define-fun addr ((p W) (o W)) W (bvadd p o))
(define-fun next () W (select mem (addr prev #x00000004)))
"""]
    # Decode the loads and stores of the actual straight-line splice and
    # compare the entire resulting word memory, permitting prev == next.
    regs = {0: "list", 1: "item", 3: "prev"}
    mem = "mem"
    for pc in range(0x1a, 0x2c, 2):
        h = int(body[pc][0], 16)
        dst = h & 7
        if h >> 11 in (12, 13):
            address = f"(addr {regs[(h >> 3) & 7]} (_ bv{4 * ((h >> 6) & 31)} 32))"
            if h >> 11 == 13:
                regs[dst] = f"(select {mem} {address})"
            else:
                new = f"m{pc}"
                smt.append(f"(define-fun {new} () M (store {mem} {address} {regs[dst]}))")
                mem = new
        elif h >> 11 == 6:
            dst = (h >> 8) & 7
            regs[dst] = f"(bvadd {regs[dst]} (_ bv{h & 255} 32))"
        else:
            raise ValueError("unexpected ordered-list splice instruction")
    block(insert, 0x2c, "bd30")
    edits = (("item", 4, "next"), ("next", 8, "item"), ("item", 8, "prev"),
             ("prev", 4, "item"), ("item", 16, "list"),
             ("list", 0, "(bvadd (select mem list) #x00000001)"))
    addresses = [f"(addr {ptr} (_ bv{offset} 32))" for ptr, offset, _ in edits]
    expected = "mem"
    for address, (_, _, value) in zip(addresses, edits):
        expected = f"(store {expected} {address} {value})"
    smt.extend([f"(assert (distinct {' '.join(addresses)}))", "(check-sat)",
                f"(assert (distinct {mem} {expected}))", "(check-sat)"])
    if subprocess.check_output([z3, "-in"], input="\n".join(smt), text=True).splitlines() != [
            "unsat", "sat", "unsat"]:
        raise ValueError("ordered waiter insertion violates scan or splice specification")
