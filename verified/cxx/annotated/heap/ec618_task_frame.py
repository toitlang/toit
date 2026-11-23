# Copyright (C) 2026 Toit contributors.
"""Check the linked task stack setup, saved PSP and first exception frame."""

import subprocess

from ec618_thumb import match_block, match_branch


def check_task_frame(code, literal, symbols, z3):
    # Dynamic task creation requests the stack first, then a separate TCB.
    # On success it passes the original depth and entry arguments through.
    create = code["xTaskCreate"][1]

    def call(offset, target):
        match_branch(create, offset, "bl", target, code[target][0])

    match_block(create, 0, "e92d 43f0|4607|4688|b085|2100|0090|4616|4699")
    call(0x12, "pvPortMallocEC")
    match_block(create, 0x16, "4605|b1e0|2100|20c8")
    call(0x1e, "pvPortMallocEC")
    match_block(create, 0x22, "4604|b198|2300|f880 30c5|9b0d|6305|9301|9b0c|4632|"
                "4641|9002|9300|4638|464b")
    call(0x40, "prvInitialiseNewTask.constprop.0")
    match_block(create, 0x44, "4620")
    call(0x46, "prvAddNewTaskToReadyList")
    match_block(create, 0x4a, "2001|e004|4628")
    call(0x50, "vPortFree")
    match_block(create, 0x54, "f04f 30ff|b005|e8bd 83f0")

    wrapper = "__wrap_pxPortInitialiseStack"
    init = "pxPortInitialiseStack"
    match_block(code[wrapper][1], 0, "f020 0007")
    match_branch(code[wrapper][1], 4, "b.w", init, code[init][0])
    _, body = code[init]
    match_block(body, 0, "f04f 7380")
    match_block(body, 8, "4b05|f021 0101")
    literal(init, 8, 20, "prvTaskExitError")
    exit_fn, = symbols.get_symbol_by_name("prvTaskExitError")
    if not exit_fn["st_value"] & 1:
        raise ValueError("task exit handler must be a Thumb function")
    saved = int(body[0x1a][0], 16)
    if saved & 0xff00 != 0x3800:
        raise ValueError("expected saved stack pointer in r0")
    match_block(body, 0x1c, "4770")
    restore = code["SVC_Handler"][1]
    literal("SVC_Handler", 0, 28, "pxCurrentTCB")
    match_block(restore, 0, "4b07|6819|6808|e8b0 0ff0|f380 8809|f3bf 8f6f|f04f 0000|"
                "f380 8811|f04e 0e0d|4770")

    # Constructor computes the last word, then aligns it down. The wrapper
    # aligns to eight. No assumption about incoming contents of the task stack.
    smt = ["""
(set-logic QF_AUFBV)
(define-sort W () (_ BitVec 32))
(define-sort Mem () (Array W W))
(declare-const memory Mem)
(declare-const base W)
(declare-const words W)
(declare-const entry W)
(declare-const arg W)
(assert (= (bvand base #x00000003) #x00000000))
(assert (and (bvuge words #x00000012) (bvule words #x0000ffff)))
(define-fun bytes () W (bvshl words #x00000002))
(define-fun end64 () (_ BitVec 64) (bvadd ((_ zero_extend 32) base) ((_ zero_extend 32) bytes)))
(assert (bvule end64 #x0000000100000000))
(define-fun top () W (bvand (bvadd base (bvsub bytes #x00000004)) #xfffffff8))
(define-fun pc () W (bvand entry #xfffffffe))
(define-fun inside ((addr W)) Bool (and (bvuge addr base)
  (bvule (bvadd ((_ zero_extend 32) addr) #x0000000000000004) end64)))
"""]
    lr = f"#x{exit_fn['st_value']:08x}"
    regs = {1: "pc", 2: "arg", 3: "#x01000000"}
    mem = "memory"
    checks = []
    for offset in (4, 0xe, 0x12, 0x16):
        if offset == 0xe:
            regs[3] = lr
        first, second = (int(x, 16) for x in body[offset][0].split())
        if first != 0xf840 or second & 0xf00 != 0xc00:
            raise ValueError("unexpected task frame store addressing mode")
        addr = f"(bvsub top #x{second & 255:08x})"
        checks.append(f"(and (inside {addr}) (= (bvand {addr} #x00000003) #x00000000))")
        new_mem = f"m{offset}"
        smt.append(f"(define-fun {new_mem} () Mem (store {mem} {addr} {regs[second >> 12]}))")
        mem = new_mem
    smt.append(f"(define-fun saved () W (bvsub top #x{saved & 255:08x}))")
    smt.append("(define-fun hw () W (bvadd saved #x00000020))")
    checks += ["(inside saved)", "(= (bvand saved #x00000007) #x00000000)",
               "(= ((_ zero_extend 32) top) (bvadd ((_ zero_extend 32) saved) #x0000000000000040))"]
    expected = "memory"
    # r0, lr, pc and xPSR in the Cortex-M basic exception frame, after the
    # software restore has consumed r4-r11. All other memory is preserved.
    for offset, value in ((0, "arg"), (20, lr), (24, "pc"), (28, "#x01000000")):
        expected = f"(store {expected} (bvadd hw #x{offset:08x}) {value})"
    checks.append(f"(= {mem} {expected})")
    smt.extend(["(check-sat)", f"(assert (not (and {' '.join(checks)})))", "(check-sat)"])
    result = subprocess.check_output([z3, "-in"], input="\n".join(smt), text=True).splitlines()
    if result != ["sat", "unsat"]:
        raise ValueError(f"initial task frame proof failed: {result}")
