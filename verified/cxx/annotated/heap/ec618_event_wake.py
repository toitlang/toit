# Copyright (C) 2026 Toit contributors.
"""Check waking an EC618 event-list waiter and replaying queue lock counts."""

import subprocess

from ec618_thumb import match_block, match_branch


def check_event_wake(code, literal, z3):
    name = "xTaskRemoveFromEventList"
    _, wake = code[name]
    for pc, displacement, target in (
        (0x28, 76, "uxSchedulerSuspended"), (0x38, 64, "uxTopReadyPriority"),
        (0x44, 56, "pxReadyTasksLists"), (0x50, 48, "xPendingReadyList"),
        (0x56, 48, "pxCurrentTCB"), (0x64, 36, "xYieldPending"),
    ):
        literal(name, pc, displacement, target)

    def call(body, pc, target, op="bl"):
        match_branch(body, pc, op, target, code[target][0])

    # A nonempty event list's first item belongs to the TCB at item.owner.
    # The two list items embedded in that TCB have different lifetimes:
    # the suspended path leaves the state item in its original list.
    match_block(wake, 0, "68c3|b537|68dc|b954")
    match_block(wake, 0x1e, "f104 0518|4628")
    call(wake, 0x24, "uxListRemove")
    match_block(wake, 0x28, "4b13|681b|b97b|1d25|4628")
    call(wake, 0x32, "uxListRemove")
    match_block(wake, 0x38, "4a10|6ae3|6811|428b|bf88|6013|4a0e|4629|fb00 2003|e001")
    match_block(wake, 0x4e, "4629|480c")
    call(wake, 0x52, "vListInsertEnd")
    match_block(wake, 0x56, "4b0c|6ae2|681b|6adb|429a")
    match_block(wake, 0x62, "2001|4b09|2000|6018")
    call(wake, 0x6a, "prvResetNextTaskUnblockTime")
    # The reset helper's linked body, checked in ec618_scheduler_lock,
    # preserves r0. The caller uses it as the immediate-yield decision.
    match_block(wake, 0x6e, "b003|bd30")

    stride = int(wake[0x36][0], 16)
    pred = int(wake[0x60][0], 16)
    if stride >> 8 != 0x20 or pred & 0xff0f != 0xbf05:
        raise ValueError("unexpected ready-list stride or conditional yield instructions")
    compare = {8: "bvugt", 2: "bvuge"}.get((pred >> 4) & 15)
    if compare is None:
        raise ValueError("unexpected ready-task priority condition")

    unlock = code["prvUnlockQueue"][1]
    match_block(unlock, 0, "b570|4604")
    steps = []
    for start, offset, header, load in (
        (4, "45", "24", "6a63"), (0x36, "44", "10", "6923"),
    ):
        call(unlock, start, "vPortEnterCritical")
        match_block(unlock, start + 4, f"f894 50{offset}|f104 06{header}|b26d|2d00|dd0a|{load}|b143|4630")
        call(unlock, start + 0x18, name)
        match_block(unlock, start + 0x1c, "b108")
        call(unlock, start + 0x1e, "vTaskMissedYield")
        sub = int(unlock[start + 0x22][0], 16)
        if sub >> 8 != 0x3d:
            raise ValueError("unexpected queue unlock counter instruction")
        steps.append(sub & 255)
        match_block(unlock, start + 0x24, f"b26d|e7f2|23ff|f884 30{offset}")
    call(unlock, 0x32, "vPortExitCritical")
    match_block(unlock, 0x64, "e8bd 4070")
    call(unlock, 0x68, "vPortExitCritical", "b.w")
    match_block(code["vTaskMissedYield"][1], 0, "2201|4b01|601a|4770")
    literal("vTaskMissedYield", 2, 4, "xYieldPending")

    # For a positive signed-byte budget and any nonempty 32-bit list, one
    # splice consumes one unit of min(budget, waiters). Either zero stops
    # before the splice. This is an induction over at most 127 removals.
    smt = [f"""
(set-logic QF_BV)
(define-sort W () (_ BitVec 32))
(declare-const p W)
(declare-const current W)
(declare-const n W)
(declare-const b (_ BitVec 8))
(define-fun umin ((a W) (b W)) W (ite (bvult a b) a b))
(push)
(assert (and (bvult p #x00000038) (bvult current #x00000038)))
(assert (or (distinct (bvmul p (_ bv{stride & 255} 32)) (bvmul p #x00000014))
            (distinct ({compare} p current) (bvugt p current))))
(check-sat)
(pop)
(assert (and (bvsgt b #x00) (distinct n #x00000000)))
"""]
    for step in steps:
        smt.append(f"""
(push)
(assert (distinct (umin ((_ zero_extend 24) (bvsub b (_ bv{step} 8))) (bvsub n #x00000001))
                  (bvsub (umin ((_ zero_extend 24) b) n) #x00000001)))
(check-sat)
(pop)
""")
    result = subprocess.check_output([z3, "-in"], input="\n".join(smt), text=True)
    if result.splitlines() != ["unsat"] * 3:
        raise ValueError("ready list selection, yield decision or queue unlock count failed")
