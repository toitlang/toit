# Copyright (C) 2026 Toit contributors.
"""Check FreeRTOS wait accounting in the linked EC618 base firmware."""

import subprocess

from ec618_thumb import match_block, match_branch


def check_timeout(code, literal, z3):
    snapshot = "vTaskSetTimeOutState"
    check = "xTaskCheckForTimeOut"
    body = code[check][1]

    # The receive path calls the snapshot under its critical section.
    # xTaskCheckForTimeOut takes its own critical section on every path.
    match_block(code[snapshot][1], 0, "b513|4604|b950")
    match_block(code[snapshot][1], 0x1c, "4b04|681b|6003|4b04|681b|6043|b002|bd10")
    literal(snapshot, 0x1c, 16, "xNumOfOverflows")
    literal(snapshot, 0x22, 16, "xTickCount")
    match_block(body, 0, "b573|460d|4604|b950")
    match_block(body, 0x1e, "b951")
    match_branch(body, 0x36, "bl", "vPortEnterCritical", code["vPortEnterCritical"][0])
    literal(check, 0x3a, 64, "xTickCount")
    literal(check, 0x44, 56, "xNumOfOverflows")
    match_block(body, 0x3a, "4b10|6819|682b")
    # ADDS r2,r3,#imm3 sets Z for the infinite-delay branch.
    add = int(body[0x40][0], 16)
    if add & ~0x1c0 != 0x1c1a:
        raise ValueError("unexpected timeout sentinel instruction")
    match_block(body, 0x42, "d010|4a0e|6810|e9d4 6200|4286|d001|4291|d20a|1a88|4283|d907")
    match_block(body, 0x5a, "1a5b|4413|4620|602b")
    match_branch(body, 0x62, "bl", snapshot, code[snapshot][0])
    match_block(body, 0x66, "2400|e000|2401")
    match_branch(body, 0x6c, "bl", "vPortExitCritical", code["vPortExitCritical"][0])
    match_block(body, 0x70, "4620|b002|bd70")

    # Compare the matched unsigned branches and word arithmetic with
    # elapsed time on a widened clock. For finite waits, adjacent samples
    # can straddle one wrap. Infinite waits branch before any epoch read.
    smt = f"""
(set-logic QF_BV)
(define-sort W () (_ BitVec 32))
(declare-const delay W)
(declare-const old W)
(declare-const now W)
(declare-const wrap Bool)
(define-fun forever () Bool (= (bvadd delay (_ bv{(add >> 6) & 7} 32)) #x00000000))
(assert (distinct forever (= delay #xffffffff)))
(check-sat)
(reset-assertions)
(assert (or wrap (bvuge now old)))
(define-fun elapsed () (_ BitVec 33)
  (bvsub (concat (ite wrap #b1 #b0) now) (concat #b0 old)))
(define-fun expired () Bool
  (and (not forever) (or (and wrap (bvuge now old)) (bvule delay (bvsub now old)))))
(define-fun due () Bool
  (and (distinct delay #xffffffff) (bvuge elapsed (concat #b0 delay))))
(define-fun remaining () W (bvadd (bvsub delay now) old))
(assert (or (distinct expired due)
            (and (not forever) (not expired)
                 (distinct (concat #b0 remaining) (bvsub (concat #b0 delay) elapsed)))))
(check-sat)
"""
    if subprocess.check_output([z3, "-in"], text=True, input=smt).splitlines() != ["unsat", "unsat"]:
        raise ValueError("linked timeout differs from indefinite or finite wait accounting")
