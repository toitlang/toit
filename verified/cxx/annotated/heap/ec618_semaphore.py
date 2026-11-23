# Copyright (C) 2026 Toit contributors.
"""Check the linked completion semaphore construction, signaling, receive and deletion paths."""

import subprocess

from ec618_thumb import instructions, match_block, match_branch


def check_semaphore_base(objdump, base, z3):
    names = ("xQueueGenericCreate", "xQueueGenericReset", "vQueueDelete", "vListInitialise",
             "pvPortMallocEC", "vPortFree", "vPortEnterCritical", "vPortExitCritical",
             "xQueueGenericReceive", "xQueueGenericSend", "prvCopyDataToQueue",
             "prvCopyDataFromQueue", "xTaskGetSchedulerState", "xTaskRemoveFromEventList",
             "vTaskSetTimeOutState", "vTaskSuspendAll", "xTaskCheckForTimeOut",
             "prvUnlockQueue", "xTaskResumeAll", "vTaskPlaceOnEventList",
             "vTaskDelete", "_ZdlPv", "vPortSetHeapTag", "vPortGetHeapTag",
             "xTaskGetCurrentTaskHandle", "xTaskCreate", "_ZnwjRKSt9nothrow_t")
    code = {name: instructions(objdump, base, name) for name in names}
    create = code["xQueueGenericCreate"][1]
    reset = code["xQueueGenericReset"][1]
    delete = code["vQueueDelete"][1]

    def call(body, pc, target, op="bl"):
        match_branch(body, pc, op, target, code[target][0])

    # spawn supplies (length=1, itemBytes=0, type=3). The product is zero.
    match_block(create, 0, "b5f7|460e|4617|4605|b950")
    match_block(create, 0x20, "4348|2100|3050")
    call(create, 0x26, "pvPortMallocEC")
    match_block(create, 0x2a, "4604|b180")
    match_block(create, 0x50, "4620|b003|bdf0")  # NULL path returns directly.
    match_block(create, 0x2e, "2300")
    match_block(create, 0x34, "b116")
    match_block(create, 0x3c, "4603|2101|4620")
    call(create, 0x48, "xQueueGenericReset")
    match_block(reset, 0, "b537|460d|4604|b948")
    call(reset, 0x1c, "vPortEnterCritical")
    match_block(reset, 0x20, "e9d4 310f|434b|6822|18d0|1a5b|4413")
    def mov_imm(pc, rd):
        encoding = int(reset[pc][0], 16)
        if encoding >> 8 != 0x20 + rd:
            raise ValueError("expected semaphore field initializer")
        return encoding & 255

    initial_count = mov_imm(0x32, 0)
    unlocked = mov_imm(0x34, 3)
    match_block(reset, 0x42, "b98d")
    match_block(reset, 0x68, "f104 0010")
    call(reset, 0x6c, "vListInitialise")
    match_block(reset, 0x70, "f104 0024")
    call(reset, 0x74, "vListInitialise")
    call(reset, 0x78, "vPortExitCritical")
    match_block(reset, 0x7c, "2001|b003|bd30")

    # Decode the destination, width and value register of every queue store.
    # Queue-relative offsets map to bytes of arbitrary initial memory.
    writes = []

    def store(body, pc, regs, bases):
        ins = [int(x, 16) for x in body[pc][0].split()]
        h = ins[0]
        if len(ins) == 1 and h & 0xf800 == 0x6000:
            off = bases[(h >> 3) & 7] + 4 * ((h >> 6) & 31)
            writes.append((off, 4, regs[h & 7]))
        elif len(ins) == 2 and h & 0xfff0 == 0xf880:
            writes.append((bases[h & 15] + (ins[1] & 4095), 1, regs[ins[1] >> 12]))
        elif len(ins) == 2 and h & 0xfff0 == 0xe9c0:
            off = bases[h & 15] + 4 * (ins[1] & 255)
            writes.extend([(off, 4, regs[ins[1] >> 12]), (off + 4, 4, regs[(ins[1] >> 8) & 15])])
        else:
            raise ValueError(f"unexpected semaphore store at {pc:#x}")

    store(create, 0x30, {3: 0}, {0: 0})
    store(create, 0x42, {5: 1, 6: 0}, {4: 0})
    store(create, 0x46, {3: "base"}, {4: 0})
    # Reset loads (length,itemBytes,head) from the object just constructed.
    # Check this interface before using those values to evaluate its arithmetic.
    if writes[-3:] != [(60, 4, 1), (64, 4, 0), (0, 4, "base")]:
        raise ValueError("semaphore reset inputs differ from the constructor stores")
    for pc, regs in ((0x2e, {0: "base"}), (0x30, {3: "base"}), (0x36, {0: initial_count}),
                     (0x38, {2: "base"}), (0x3a, {3: unlocked}), (0x3e, {3: unlocked})):
        store(reset, pc, regs, {4: 0})
    init = code["vListInitialise"][1]
    match_block(init, 0, "f04f 32ff|f100 0308")
    match_block(init, 0x10, "2300")
    match_block(init, 0x14, "4770")
    expected = [(0, 4, "base"), (4, 4, "base"), (8, 4, "base"), (12, 4, "base"),
                (56, 4, 0), (60, 4, 1), (64, 4, 0), (68, 1, 255), (69, 1, 255),
                (70, 1, 0), (76, 1, 3)]
    for header in (16, 36):
        sentinel = f"(bvadd base #x{header + 8:08x})"
        for pc in (8, 12, 14, 18):
            store(init, pc, {2: 0xffffffff, 3: 0 if pc == 18 else sentinel}, {0: header})
        expected.extend((header + 4 * i, 4, v) for i, v in enumerate((0, sentinel, 0xffffffff, sentinel, sentinel)))
    store(create, 0x4c, {7: 3}, {4: 0})

    # Compare every initialized byte, leaving all other bytes unchanged.
    smt = ["(set-logic QF_BV)", "(declare-const base (_ BitVec 32))",
           "(assert (and (bvugt base #x00000000) (bvule base #xffffffb0) (= ((_ extract 1 0) base) #b00)))"]

    def byte_map(stores):
        result = {}
        for offset, size, value in stores:
            if offset < 0 or offset + size > 80 or (size == 4 and offset % 4):
                raise ValueError("semaphore store outside aligned queue storage")
            expr = f"#x{value:08x}" if isinstance(value, int) else value
            for i in range(size):
                result[offset + i] = f"((_ extract {8 * i + 7} {8 * i}) {expr})"
        return result

    actual, spec = byte_map(writes), byte_map(expected)
    if actual.keys() != spec.keys():
        raise ValueError("incorrect initialized semaphore byte footprint")
    equal = " ".join(f"(= {actual[i]} {spec[i]})" for i in spec)
    smt.extend(["(check-sat)", f"(assert (not (and {equal})))", "(check-sat)"])
    if subprocess.check_output([z3, "-in"], text=True, input="\n".join(smt)).splitlines() != ["sat", "unsat"]:
        raise ValueError("initial semaphore contents differ from binary semaphore specification")

    match_block(delete, 0, "b513|4604|b950")
    match_block(delete, 0x1c, "f890 3046|b923|b002|e8bd 4010")
    call(delete, 0x28, "vPortFree", "b.w")
    check_signal_paths(code, call)
    return {name: code[name][0] for name in
            ("xQueueGenericCreate", "vQueueDelete", "xQueueGenericReceive", "xQueueGenericSend",
             "vTaskDelete", "_ZdlPv", "vPortSetHeapTag", "vPortGetHeapTag",
             "xTaskGetCurrentTaskHandle", "xTaskCreate", "_ZnwjRKSt9nothrow_t")}


def check_signal_paths(code, call):
    # Specialized to the live one-token, zero-item-size, nonmutex queue
    # built above. Both callers use a null data pointer and mode zero.
    send = code["xQueueGenericSend"][1]
    take = code["xQueueGenericReceive"][1]
    put = code["prvCopyDataToQueue"][1]
    get = code["prvCopyDataFromQueue"][1]
    pend = "f04f 23e0|f04f 5280|f8c3 2d04|f3bf 8f4f|f3bf 8f6f"
    ret = "b007|e8bd 83f0"
    match_block(send, 0, "e92d 43f0|b087|460f|4698|4604|9203|b950")
    match_block(send, 0x26, "b961|6c03|b153")
    match_block(send, 0x42, "f1b8 0f02|d10d")
    call(send, 0x64, "xTaskGetSchedulerState")
    match_block(send, 0x68, "4605|b960|9b03|b15b")
    match_block(send, 0x86, "2500|f04f 0900")
    call(send, 0x8c, "vPortEnterCritical")
    # count < capacity branches to put. A full queue and a zero wait
    # take the early failure exit without touching any queue field.
    match_block(send, 0x90, "6ba2|6be3|429a|d302|f1b8 0f02|d119|4642|4639|4620")
    call(send, 0xa4, "prvCopyDataToQueue")
    match_block(put, 0, "b5f8|4615|6c02|4604|6b86|b93a|6807|bb2f")
    match_block(put, 0x5c, "2500|e000")
    match_block(put, 0x64, "4628|63a6|bdf8")
    match_block(send, 0xa8, "6a63|b11b|f104 0024")
    call(send, 0xb0, "xTaskRemoveFromEventList")
    match_block(send, 0xb4, "b148|" + pend)
    call(send, 0xca, "vPortExitCritical")
    match_block(send, 0xce, "2001|e04f|9e03|b916")
    call(send, 0xd6, "vPortExitCritical")
    match_block(send, 0xda, "e049")
    match_block(send, 0x170, "2000|" + ret)

    match_block(take, 0, "e92d 43f0|b087|460e|4698|4604|9203|b950")
    match_block(take, 0x26, "b961|6c03|b153")
    call(take, 0x42, "xTaskGetSchedulerState")
    match_block(take, 0x46, "4605|b960")
    match_block(take, 0x64, "2500|f04f 0900")
    call(take, 0x6a, "vPortEnterCritical")
    match_block(take, 0x6e, "6ba7|b34f|4631|4620|68e5")
    call(take, 0x78, "prvCopyDataFromQueue")
    match_block(get, 0, "4603|6c1a|4608|b410|b162")
    match_block(get, 0x24, "bc10|4770")  # Zero item size bypasses the payload.
    match_block(take, 0x7c, "f1b8 0f00|d10b|6823")
    match_block(take, 0x86, "63a7|b913")
    # Decode Thumb T2 ADDS r6,#imm8 and SUBS r7,#imm8. Enumerate
    # the entire reachable count domain with the matched unsigned guards.
    add = int(put[0x62][0], 16)
    sub = int(take[0x84][0], 16)
    if add >> 8 != 0x36 or sub >> 8 != 0x3f:
        raise ValueError("unexpected semaphore count arithmetic")
    for count in (0, 1):
        after_give = (count + (add & 255)) & 0xffffffff if count < 1 else count
        after_take = (count - (sub & 255)) & 0xffffffff if count else count
        if after_give != 1 or after_take != 0:
            raise ValueError(f"completion token transition fails at count {count}")
    match_block(take, 0x90, "6923|b1a3|f104 0010|e004")
    call(take, 0xa4, "xTaskRemoveFromEventList")
    match_block(take, 0xa8, "b148|" + pend)
    call(take, 0xbe, "vPortExitCritical")
    match_block(take, 0xc2, "2001|e05f")

    # Empty: lock the queue while scheduling is suspended and recheck
    # count under the interrupt mask before registering on the receive list.
    match_block(take, 0xc6, "9b03|b91b")
    call(take, 0xca, "vPortExitCritical")
    match_block(take, 0xce, "2000|e059|b915|a804")
    call(take, 0xd6, "vTaskSetTimeOutState")
    call(take, 0xda, "vPortExitCritical")
    call(take, 0xde, "vTaskSuspendAll")
    call(take, 0xe2, "vPortEnterCritical")
    match_block(take, 0xe6, "f894 3044|2bff|bf08|f884 9044|f894 3045|2bff|bf08|f884 9045")
    call(take, 0xfe, "vPortExitCritical")
    match_block(take, 0x102, "a903|a804")
    call(take, 0x106, "xTaskCheckForTimeOut")
    match_block(take, 0x10a, "bb78")
    call(take, 0x10c, "vPortEnterCritical")
    match_block(take, 0x110, "6ba3|b95b")
    call(take, 0x114, "vPortExitCritical")
    match_block(take, 0x118, "6823|b983")
    call(take, 0x12c, "vPortExitCritical")
    match_block(take, 0x130, "4620")
    call(take, 0x132, "prvUnlockQueue")
    call(take, 0x136, "xTaskResumeAll")
    match_block(take, 0x13a, "2501|e795|9903|f104 0024")
    call(take, 0x144, "vTaskPlaceOnEventList")
    match_block(take, 0x148, "4620")
    call(take, 0x14a, "prvUnlockQueue")
    call(take, 0x14e, "xTaskResumeAll")
    match_block(take, 0x152, "2800|d1f1|" + pend + "|e7e6")
    # A timeout rechecks the count: fail if empty, otherwise retry.
    match_block(take, 0x16c, "4620")
    call(take, 0x16e, "prvUnlockQueue")
    call(take, 0x172, "xTaskResumeAll")
    call(take, 0x176, "vPortEnterCritical")
    match_block(take, 0x17a, "6ba3|2b00|d0a4")
    call(take, 0x180, "vPortExitCritical")
    match_block(take, 0x184, "e7d9|" + ret)


def check_semaphore_callers(objdump, slot, targets):
    _, spawn = instructions(objdump, slot, "_ZN4toit6Thread5spawnEii")
    _, join = instructions(objdump, slot, "_ZN4toit6Thread4joinEv")
    match_block(join, 0, "b538|2300|6885|4604|f04f 32ff|4619|6868")
    match_branch(join, 0x10, "bl", "xQueueGenericReceive", targets["xQueueGenericReceive"])
    match_block(join, 0x14, "2801|d002")
    match_block(join, 0x18, "4805")
    fail_name = "_ZN4toit4failEPKcz"
    fail_address, _ = instructions(objdump, slot, fail_name)
    match_branch(join, 0x1a, "bl", fail_name, fail_address)
    match_block(join, 0x1e, "6868")
    match_branch(join, 0x20, "bl", "vQueueDelete", targets["vQueueDelete"])
    match_block(join, 0x24, "4628")
    match_branch(join, 0x26, "bl", "_ZdlPv", targets["_ZdlPv"])
    match_block(join, 0x2a, "2300|60a3|bd38")
    boot_name = "_ZN4toit6Thread5_bootEv"
    boot_address, boot = instructions(objdump, slot, boot_name)
    start_address, start = instructions(objdump, slot, "_ZN4toitL18ec618_thread_startEPv")
    match_branch(start, 0, "b.w", boot_name, boot_address)
    if spawn[0][0] == "e92d 41f3":
        from ec618_thread_callers import check_current_thread_callers
        check_current_thread_callers(objdump, slot, targets, spawn, boot, start_address)
    else:
        check_legacy_thread_callers(objdump, slot, targets, spawn, boot, start_address)
    check_completion_lifetime()


def check_legacy_thread_callers(objdump, slot, targets, spawn, boot, start_address):
    match_block(spawn, 0x20, "2100|2203|e9c0 1100|2001")
    match_branch(spawn, 0x2a, "bl", "xQueueGenericCreate", targets["xQueueGenericCreate"])
    match_block(spawn, 0x2e, "6060|b920")
    match_block(spawn, 0x5a, "2801|d003|6860")
    match_branch(spawn, 0x60, "bl", "vQueueDelete", targets["vQueueDelete"])
    # Spawn stores the descriptor before making the task runnable and
    # passes this as its argument. The literal is the Thumb entry pointer.
    match_block(spawn, 0, "b5f7|460d|4606")
    match_block(spawn, 0x1c, "4604|b158")
    match_block(spawn, 0x3c, "2d00|f04f 0302|bf08|f44f 6500|60b4|9300|9401|4633|6871|4809|b2aa")
    match_block(spawn, 0x78, f"{start_address + 1:08x}")
    match_branch(spawn, 0x56, "bl", "xTaskCreate", targets["xTaskCreate"])
    match_block(boot, 0, "b570|4604|6886")
    setter = "_ZN4toitL18set_current_threadEPNS_6ThreadE"
    setter_address, _ = instructions(objdump, slot, setter)
    match_branch(boot, 6, "bl", setter, setter_address)
    match_branch(boot, 0xa, "bl", "vPortGetHeapTag", targets["vPortGetHeapTag"])
    match_block(boot, 0xe, "4605|f06f 0058")
    match_branch(boot, 0x14, "bl", "vPortSetHeapTag", targets["vPortSetHeapTag"])
    match_block(boot, 0x18, "6823|4620|689b|4798")
    match_branch(boot, 0x20, "bl", "xTaskGetCurrentTaskHandle", targets["xTaskGetCurrentTaskHandle"])
    match_block(boot, 0x24, "2300|4a11|f852 1033|eb02 04c3|4288|d109|2100|f842 1033|4b0d|"
                "6061|681a|42a2|d104|6019|e002|3301|2b10|d1ec")
    match_block(boot, 0x4e, "2300|6870|461a|4619")
    match_branch(boot, 0x56, "bl", "xQueueGenericSend", targets["xQueueGenericSend"])
    # A joiner may already have freed both objects at this return site.
    # Only task-local registers and stack slots remain in use. Self-delete
    # receives NULL; even its return path uses only the saved scalar tag.
    match_block(boot, 0x5a, "2000")
    match_branch(boot, 0x5c, "bl", "vTaskDelete", targets["vTaskDelete"])
    match_block(boot, 0x60, "4628|e8bd 4070")
    match_branch(boot, 0x66, "b.w", "vPortSetHeapTag", targets["vPortSetHeapTag"])


def check_completion_lifetime():
    # Product of the matched successful-spawn paths, one producer and one
    # joiner. Private stack/register operations are grouped. An empty
    # receive can stutter until it retries: it has no retirement effect.
    # Single-core critical sections exclude a receive from publication
    # through the final access to the embedded receiver list.
    worker = ("read descriptor", "enter", "publish", "wake", "exit", "return from send", "self-delete")
    joiner = ("load queue", "consume", "delete queue", "delete descriptor", "clear handle")
    seen = set()
    pending = [(0, 0, False, False, True, True)]
    while pending:
        state = pending.pop()
        if state in seen:
            continue
        seen.add(state)
        w, j, masked, token, queue_live, descriptor_live = state
        if w < len(worker):
            op = worker[w]
            if op == "read descriptor" and not descriptor_live:
                raise ValueError("worker reads a retired thread descriptor")
            if op in ("publish", "wake") and not queue_live:
                raise ValueError("worker accesses a retired completion queue")
            pending.append((w + 1, j, (masked or op == "enter") and op != "exit",
                            token or op == "publish", queue_live, descriptor_live))
        if j < len(joiner) and not masked:
            op = joiner[j]
            if op == "consume" and not token:
                continue
            if op in ("consume", "delete queue") and not queue_live:
                raise ValueError("join accesses a retired completion queue")
            if op in ("load queue", "delete queue", "delete descriptor") and not descriptor_live:
                raise ValueError("join accesses a retired thread descriptor")
            pending.append((w, j + 1, masked, token and op != "consume",
                            queue_live and op != "delete queue", descriptor_live and op != "delete descriptor"))
    # Require the preemption window as well as normal retirement to be
    # reachable. A model that serializes whole calls would miss this case.
    for w in (worker.index("return from send"), len(worker)):
        if (w, len(joiner), False, False, False, False) not in seen:
            raise ValueError("missing completion retirement schedule")
