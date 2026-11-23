# Copyright (C) 2026 Toit contributors.
"""Bind scheduler startup and the hardware tick vector to the checked kernel."""

import subprocess

from ec618_thumb import match_block, match_branch


def check_scheduler_port(code, literal, z3):
    def block(name, pc, encoded):
        match_block(code[name][1], pc, encoded)

    def call(name, pc, target, op="bl"):
        match_branch(code[name][1], pc, op, target, code[target][0])

    # Normal startup after timer-task creation succeeds with pdPASS (r0=1)
    # and the idle-task path has left r4=0.
    start = "vTaskStartScheduler"
    block(start, 0, "b510|2400|b088|aa07|a906|a805|e9cd 4405")
    call(start, 0x10, "vApplicationGetIdleTaskMemory")
    block(start, 0x14, "9b05|9a07|9302|9b06|491b|9301|2301|481b|9300|4623")
    call(start, 0x28, "xTaskCreateStatic")
    block(start, 0x2c, "b358")
    call(start, 0x2e, "xTimerCreateTimerTask")
    block(start, 0x32, "2801|d11a|f04f 0320|f383 8811|f3bf 8f6f|f3bf 8f4f|4b13|4a13|681b|"
          "3360|6013|f04f 32ff|4b11|601a|4b11|6018|4b11|601c|681b|b008|e8bd 4010")
    for pc, displacement, name in ((0x46, 76, "pxCurrentTCB"), (0x48, 76, "_impure_ptr"),
                                   (0x54, 68, "xNextTaskUnblockTime"), (0x58, 68, "xSchedulerRunning"),
                                   (0x5c, 68, "xTickCount")):
        literal(start, pc, displacement, name)
    port = "xPortStartScheduler"
    call(start, 0x68, port, "b.w")
    block(port, 0, "b508|f04f 23e0|f8d3 2d20|f442 0260|f8c3 2d20|f8d3 2d20|"
          "f042 4260|f8c3 2d20")
    call(port, 0x1e, "vPortSetupTimerInterrupt")
    block(port, 0x22, "2200|4b02|601a")
    literal(port, 0x24, 8, "uxCriticalNesting")
    call(port, 0x28, "prvPortStartFirstTask")
    timer = "vPortSetupTimerInterrupt"
    block(timer, 0, "b508")
    call(timer, 2, "GPR_switchSystickClk")
    block(timer, 6, "f04f 23e0|f640 42b1|615a|2200|619a|2203|611a")
    call(timer, 0x18, "tcocStartTick")
    block("tcocStartTick", 0, "4770")
    block(timer, 0x1c, "bd08")
    first = "prvPortStartFirstTask"
    block(first, 0, "4806|6800|6800|f380 8808|b662|b661|f3bf 8f4f|f3bf 8f6f|df00")
    literal(first, 0, 24, 0xe000ed08)  # VTOR; first vector word supplies MSP.

    handler = "xPortSysTickHandler"
    block("SysTick_Handler", 0, "f04f 23e0|691b")
    call("SysTick_Handler", 6, handler, "b.w")
    block(handler, 0, "b508|f04f 0320|f383 8811|f3bf 8f6f|f3bf 8f4f")
    call(handler, 0x12, "xTaskIncrementTick")
    block(handler, 0x16, "b128|f04f 23e0|f04f 5280|f8c3 2d04|2300|f383 8811|bd08")

    # The two SHPR3 read/modify/writes and the ICSR write-one-to-set path.
    # Hardware implements the upper three bits of each priority byte.
    smt = """
(set-logic QF_BV)
(declare-const original (_ BitVec 32))
(declare-const pending Bool)
(declare-const tickResult (_ BitVec 32))
(define-fun priority () (_ BitVec 32) (bvor original #x00e00000 #xe0000000))
(define-fun request () (_ BitVec 32) (ite (= tickResult #x00000000) #x00000000 #x10000000))
(define-fun after () Bool (or pending (= ((_ extract 28 28) request) #b1)))
(assert (or (distinct (bvand priority #x1f1fffff) (bvand original #x1f1fffff))
            (bvult (bvand ((_ extract 23 16) priority) #xe0) #x20)
            (bvult (bvand ((_ extract 31 24) priority) #xe0) #x20)
            (distinct ((_ extract 23 21) priority) #b111)
            (distinct ((_ extract 31 29) priority) #b111)
            (distinct after (or pending (distinct tickResult #x00000000)))))
(check-sat)
"""
    if subprocess.check_output([z3, "-in"], input=smt, text=True).splitlines() != ["unsat"]:
        raise ValueError("scheduler port priority or deferred yield proof failed")
