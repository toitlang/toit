# Copyright (C) 2026 Toit contributors.
"""Check task-switch deferral across the linked EC618 heap lock."""

from pathlib import Path
import subprocess

from elftools.elf.elffile import ELFFile

from ec618_scheduler_port import check_scheduler_port
from ec618_event_wake import check_event_wake
from ec618_event_wait import check_event_wait
from ec618_scheduler_init import check_scheduler_init
from ec618_scheduler_lists import check_scheduler_lists
from ec618_scheduler_tick import check_scheduler_tick
from ec618_timeout import check_timeout
from ec618_task_frame import check_task_frame
from ec618_thumb import instructions, match_block, match_branch


def check_scheduler_lock(objdump, base, z3):
    names = ("lock.constprop.0", "unlock.constprop.0", "multi_heap_lock", "multi_heap_unlock",
             "xTaskGetSchedulerState", "vTaskSuspendAll", "xTaskResumeAll", "vTaskSwitchContext",
             "PendSV_Handler", "vPortEnterCritical", "vPortExitCritical", "uxListRemove",
             "vListInsertEnd", "xTaskIncrementTick", "prvResetNextTaskUnblockTime", "vListInitialise",
             "vListInitialiseItem", "prvAddNewTaskToReadyList", "prvInitialiseNewTask.constprop.0",
             "ecTraceTaskCreate", "memset", "__wrap_pxPortInitialiseStack", "pxPortInitialiseStack", "SVC_Handler",
             "xTaskCreate", "pvPortMallocEC", "vPortFree", "vTaskSetTimeOutState", "xTaskCheckForTimeOut",
             "xTaskRemoveFromEventList", "prvUnlockQueue", "vTaskMissedYield",
             "vTaskPlaceOnEventList", "prvAddCurrentTaskToDelayedList", "vListInsert",
             "vTaskStartScheduler", "xPortStartScheduler", "vPortSetupTimerInterrupt", "tcocStartTick",
             "prvPortStartFirstTask", "SysTick_Handler", "xPortSysTickHandler", "GPR_switchSystickClk",
             "vApplicationGetIdleTaskMemory", "xTaskCreateStatic", "xTimerCreateTimerTask")
    code = {name: instructions(objdump, base, name) for name in names}

    def block(name, pc, encoded):
        match_block(code[name][1], pc, encoded)

    def branch(name, pc, op, target):
        match_branch(code[name][1], pc, op, target, code[target][0])

    # Bind PC-relative loads to the actual linked data, including the PendSV
    # literal which has its own ELF symbol outside the disassembled routine.
    with open(base, "rb") as stream:
        elf = ELFFile(stream)
        symbols = elf.get_section_by_name(".symtab")

        vector, = symbols.get_symbol_by_name("__isr_vector")
        section = elf.get_section(vector["st_shndx"])
        first = vector["st_value"] - section["sh_addr"]
        stack_top, = symbols.get_symbol_by_name("__StackTop")
        if not 0 <= first <= section["sh_size"] - 64 or stack_top["st_value"] % 8:
            raise ValueError("invalid application vector extent or initial MSP alignment")
        stream.seek(section["sh_offset"] + first)
        if int.from_bytes(stream.read(4), "little") != stack_top["st_value"]:
            raise ValueError("application vector does not select the linked exception stack")
        for number, handler_name in ((11, "SVC_Handler"), (14, "PendSV_Handler"), (15, "SysTick_Handler")):
            offset = vector["st_value"] - section["sh_addr"] + number * 4
            if not 0 <= offset <= section["sh_size"] - 4:
                raise ValueError(f"{handler_name} entry outside the application vector table")
            stream.seek(section["sh_offset"] + offset)
            if int.from_bytes(stream.read(4), "little") != code[handler_name][0] + 1:
                raise ValueError(f"application vector table selects a different {handler_name}")

        def literal(name, pc, immediate, expected):
            fn, = symbols.get_symbol_by_name(name)
            value = expected
            if isinstance(expected, str):
                sym, = symbols.get_symbol_by_name(expected)
                value = sym["st_value"]
            sect = elf.get_section(fn["st_shndx"])
            addr = ((code[name][0] + pc + 4) & ~3) + immediate
            offset = addr - sect["sh_addr"]
            if not 0 <= offset <= sect["sh_size"] - 4:
                raise ValueError(f"{name}: literal outside section")
            stream.seek(sect["sh_offset"] + offset)
            if int.from_bytes(stream.read(4), "little") != value:
                raise ValueError(f"{name}: expected literal for {expected}")

        literal("xTaskGetSchedulerState", 0, 20, "xSchedulerRunning")
        literal("xTaskGetSchedulerState", 6, 20, "uxSchedulerSuspended")
        literal("vTaskSuspendAll", 0, 8, "uxSchedulerSuspended")
        literal("xTaskResumeAll", 4, 196, "uxSchedulerSuspended")
        resume = "xTaskResumeAll"
        for pc, displacement, target in (
            (0x32, 160, "uxCurrentNumberOfTasks"), (0x3a, 156, "xPendingReadyList"),
            (0x3c, 156, "uxTopReadyPriority"), (0x3e, 160, "pxReadyTasksLists"),
            (0x70, 112, "pxCurrentTCB"), (0x7e, 104, "xYieldPending"),
            (0x8a, 96, "uxPendedTicks"), (0x92, 84, "xYieldPending"),
            (0xa2, 68, "xYieldPending"),
        ):
            literal(resume, pc, displacement, target)
        literal("prvResetNextTaskUnblockTime", 0, 24, "pxDelayedTaskList")
        literal("prvResetNextTaskUnblockTime", 6, 24, "xNextTaskUnblockTime")
        ready, = symbols.get_symbol_by_name("pxReadyTasksLists")
        # v5 has 56 priorities, each with a 20-byte list header.
        if ready["st_size"] != 56 * 20 or ready["st_value"] + ready["st_size"] > 2**32:
            raise ValueError("unexpected ready list extent")
        literal("vTaskSwitchContext", 0, 188, "uxSchedulerSuspended")
        literal("vTaskSwitchContext", 6, 188, "xYieldPending")
        literal("PendSV_Handler", 8, 52, "pxCurrentTCB")
        literal("vPortEnterCritical", 0x12, 52, "uxCriticalNesting")
        literal("vPortExitCritical", 0, 40, "uxCriticalNesting")
        check_scheduler_port(code, literal, z3)
        check_scheduler_init(code, symbols, literal)
        check_task_frame(code, literal, symbols, z3)
        check_scheduler_tick(code, literal, z3)
        check_timeout(code, literal, z3)
        check_event_wake(code, literal, z3)
        check_event_wait(code, literal, z3)

    get = "xTaskGetSchedulerState"
    block(get, 0, "4b05|681b|b133|4b05|681b|2b00|bf0c|2002|2000|4770|2001|4770")
    for wrapper, gate, action in (("lock.constprop.0", "multi_heap_lock", "vTaskSuspendAll"),
                                  ("unlock.constprop.0", "multi_heap_unlock", "xTaskResumeAll")):
        branch(wrapper, 0, "b.w", gate)
        block(gate, 0, "b508")
        branch(gate, 2, "bl", get)
        block(gate, 6, "2801|d003|e8bd 4008")
        branch(gate, 0xe, "b.w", action)
        block(gate, 0x12, "bd08")

    block("vTaskSuspendAll", 0, "4a02|6813|3301|6013|4770")
    switch = "vTaskSwitchContext"
    block(switch, 0, "4b2f|b573|681a|4b2f|b112|2201|601a|e054")
    block(switch, 0xba, "b002|bd70")
    handler = "PendSV_Handler"
    block(handler, 0, "f3ef 8009|f3bf 8f6f|4b0d|681a|e920 0ff0|6010|e92d 4008|f04f 0020|f380 8811")
    branch(handler, 0x1e, "bl", switch)
    block(handler, 0x22, "f04f 0000|f380 8811|e8bd 4008|6819|6808|e8b0 0ff0|f380 8809|f3bf 8f6f|4770")

    resume = "xTaskResumeAll"
    block(resume, 0, "e92d 41f3|4c31|6825|b955")
    branch(resume, 0x20, "bl", "vPortEnterCritical")
    block(resume, 0x24, "6823|3b01|6023|6824|b10c|2400|e046")
    # Outermost resume with active tasks drains the event list before ticks.
    block(resume, 0x32, "4b28|681b|2b00|d0f9|4d27|4e27|f8df 80a0|682b|b1f3|"
          "68eb|68dc|1d27|f104 0018")
    branch(resume, 0x50, "bl", "uxListRemove")
    block(resume, 0x54, "4638")
    branch(resume, 0x56, "bl", "uxListRemove")
    block(resume, 0x5a, "2014|6ae3|6832|fb00 8003|4293|4639|bf88|6033")
    branch(resume, 0x6c, "bl", "vListInsertEnd")
    block(resume, 0x70, "4b1c|6ae2|681b|6adb|429a|d3e2|2201|4b1a|601a|e7de|b10c")
    branch(resume, 0x86, "bl", "prvResetNextTaskUnblockTime")
    check_scheduler_lists(code, z3)
    block("prvResetNextTaskUnblockTime", 0, "4a06|6813|6819|4b06|b911|f04f 32ff|e003|6812|68d2|68d2|6852|601a|4770")
    block(resume, 0x8a, "4d18|682c|b144|2701|4e15")
    branch(resume, 0x94, "bl", "xTaskIncrementTick")
    block(resume, 0x98, "b100|6037|3c01|d1f9|602c|4b11|681b|2b00|d0c1|"
          "f04f 23e0|f04f 5280|f8c3 2d04|f3bf 8f4f|f3bf 8f6f|2401")
    branch(resume, 0xc0, "bl", "vPortExitCritical")
    block(resume, 0xc4, "4620|b002|e8bd 81f0")
    # From task context IPSR/VECTACTIVE is zero on the outermost entry.
    block("vPortEnterCritical", 0, "b507|f04f 0320|f383 8811|f3bf 8f6f|f3bf 8f4f|"
          "4a0d|6813|3301|2b01|6013|d110|f04f 23e0|f8d3 3d04|b2db|b153")
    block("vPortEnterCritical", 0x40, "b003|f85d fb04")
    block("vPortExitCritical", 0, "4b0a|b513|681c|b954")
    block("vPortExitCritical", 0x1e, "3c01|601c|b90c|f384 8811|b002|bd10")

    # Compose the checked branches for arbitrary 32-bit nesting values. The
    # scheduler-running flag stays fixed through this balanced pair. A nested
    # critical section starts with BASEPRI=32; outermost task entry uses zero.
    smt = """
(set-logic QF_BV)
(declare-const running Bool)
(declare-const depth (_ BitVec 32))
(declare-const critical (_ BitVec 32))
(assert (distinct critical #xffffffff))
(assert (=> running (distinct depth #xffffffff)))
(define-fun state ((d (_ BitVec 32))) (_ BitVec 32)
  (ite running (ite (= d #x00000000) #x00000002 #x00000000) #x00000001))
(define-fun held () (_ BitVec 32)
  (ite (= (state depth) #x00000001) depth (bvadd depth #x00000001)))
(define-fun released () (_ BitVec 32)
  (ite (= (state held) #x00000001) held (bvsub held #x00000001)))
(define-fun entered () (_ BitVec 32) (bvadd critical #x00000001))
(define-fun left () (_ BitVec 32) (bvsub entered #x00000001))
(assert (not (and (=> running (distinct held #x00000000)) (= released depth)
  (=> (not running) (= held depth)) (distinct entered #x00000000) (= left critical)
  (= (ite (= left #x00000000) #x00 #x20) (ite (= critical #x00000000) #x00 #x20)))))
(check-sat)
"""
    if subprocess.check_output([z3, "-in"], input=smt, text=True).splitlines() != ["unsat"]:
        raise ValueError("scheduler suspension nesting proof failed")
    proof = Path(__file__).with_name("ec618_scheduler_resume.smt2")
    if subprocess.check_output([z3, str(proof)], text=True).splitlines() != ["unsat"] * 4:
        raise ValueError("outermost scheduler resume proof failed")
