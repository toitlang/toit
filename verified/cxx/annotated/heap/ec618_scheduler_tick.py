# Copyright (C) 2026 Toit contributors.
"""Check the linked FreeRTOS tick paths reached by the heap unlock."""

import subprocess

from ec618_thumb import match_block, match_branch


def check_scheduler_tick(code, literal, z3):
    name = "xTaskIncrementTick"
    entry, body = code[name]
    for pc, displacement, target in (
        (0, 248, "uxSchedulerSuspended"), (0xc, 240, "xTickCount"),
        (0x16, 236, "pxDelayedTaskList"), (0x34, 212, "pxOverflowDelayedTaskList"),
        (0x3e, 208, "xNumOfOverflows"), (0x4a, 200, "xNextTaskUnblockTime"),
        (0x50, 196, "pxReadyTasksLists"), (0x56, 172, "pxDelayedTaskList"),
        (0x5a, 192, "uxTopReadyPriority"), (0xb8, 100, "pxCurrentTCB"),
        (0xcc, 80, "pxCurrentTCB"), (0xe0, 64, "uxPendedTicks"), (0xe8, 60, "xYieldPending"),
    ):
        literal(name, pc, displacement, target)

    def block(pc, encoding):
        match_block(body, pc, encoding)

    def call(pc, target):
        match_branch(body, pc, "bl", target, code[target][0])

    # Running tick and rollover. The retiring delay list must be empty at wrap.
    block(0, "4b3e|e92d 4ff7|681b|2b00|d168|4b3c|681c|3401|601c|b9cc|4b3b|681a|6812|b152")
    block(0x34, "4a35|6819|6810|6018|6011|4a34|6813|3301|6013")
    call(0x46, "prvResetNextTaskUnblockTime")
    block(0x4a, "4e32|2500|6833|4f31|42a3")
    block(0x56, "f8df 90ac|f8df a0c0|f8d9 3000|681b|b91b|f04f 33ff|6033|e02d|"
          "f8d9 3000|68db|f8d3 b00c|f8db 2004|4294")
    block(0x80, "6032|e022|f10b 0804|4640")
    call(0x8a, "uxListRemove")
    block(0x8e, "f8db 2028|b11a|f10b 0018")
    call(0x98, "uxListRemove")
    block(0x9c, "2314|f8db 002c|f8da 2000|4641|4290|bf88|f8ca 0000|fb03 7000")
    call(0xb4, "vListInsertEnd")
    block(0xb8, "4b19|f8db 202c|6819|6acb|429a")
    block(0xc6, "2501|e7c9|2214|4b14|681b|6adb|4353|58fb|2b02")
    block(0xda, "2501|e004|2500|4a10|6813|3301|6013|4b0f|681b|2b00|bf0c|4628|"
          "2001|b003|e8bd 8ff0")

    # Decode the actual comparison conditions rather than assuming the C
    # deadline and priority predicates. A change of strictness must fail even
    # when it affects only one tick at equality.
    def predicate(pc, left, right, target=None):
        h = int(body[pc][0], 16)
        if target is None:
            if h & 0xff0f != 0xbf08:
                raise ValueError("expected a single Thumb IT instruction")
            cond = (h >> 4) & 15
        else:
            displacement = ((h & 255) ^ 128) - 128
            if h >> 12 != 13 or entry + pc + 4 + 2 * displacement != entry + target:
                raise ValueError("unexpected conditional tick branch")
            cond = (h >> 8) & 15
        comparison = {0: "=", 1: "distinct", 2: "bvuge", 3: "bvult", 8: "bvugt", 9: "bvule",
                      10: "bvsge", 11: "bvslt", 12: "bvsgt", 13: "bvsle"}.get(cond)
        if comparison is None:
            raise ValueError("unsupported tick comparison")
        return f"({comparison} {left} {right})"

    skip = predicate(0x54, "deadline", "now", 0xca)
    wake = predicate(0x7e, "now", "deadline", 0x84)
    preempt = predicate(0xc4, "priority", "current")
    share = predicate(0xd8, "readyCount", "#x00000002")
    smt = f"""
(set-logic QF_BV)
(define-sort W () (_ BitVec 32))
(declare-const old W)
(define-fun now () W (bvadd old #x00000001))
(declare-const deadline W)
(declare-const later W)
(declare-const priority W)
(declare-const current W)
(declare-const readyCount W)
(declare-const priorWake Bool)
(declare-const pending Bool)
; At rollover the pointer exchange precedes timeout lookup. After the exchange
; comparisons are against keys of the newly active tick epoch.
(push)
(assert (distinct (= now #x00000000) (= old #xffffffff)))
(check-sat)
(pop)
; Loop entry and step: the cached minimum can skip only an all-future suffix.
; In a sorted delay list the first future head ends the entire due prefix.
(push)
(assert (bvule deadline later))
(assert (not (and (= {skip} (bvugt deadline now)) (= {wake} (bvule deadline now))
                  (=> {skip} (bvugt later now))
                  (=> (not {wake}) (bvugt later now)))))
(check-sat)
(pop)
; Accumulation over one removal, followed by the timeslice and pending tests.
(push)
(assert (and (bvult priority #x00000038) (bvult current #x00000038)))
(assert (distinct (or pending priorWake {preempt} {share})
                  (or pending priorWake (bvuge priority current) (bvugt readyCount #x00000001))))
(check-sat)
(pop)
"""
    if subprocess.check_output([z3, "-in"], input=smt, text=True).splitlines() != ["unsat"] * 3:
        raise ValueError("tick rollover, due-prefix or yield proof failed")
