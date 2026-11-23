# Copyright (C) 2026 Toit contributors.
"""Check construction of the scheduler's initial list headers and task items."""

from ec618_thumb import match_block, match_branch


def check_scheduler_init(code, symbols, literal):
    def block(name, pc, encoding):
        match_block(code[name][1], pc, encoding)

    def call(name, pc, target):
        match_branch(code[name][1], pc, "bl", target, code[target][0])

    init = "vListInitialise"
    item_init = "vListInitialiseItem"
    add = "prvAddNewTaskToReadyList"
    task = "prvInitialiseNewTask.constprop.0"
    # Fields filled by vListInitialise. Resolve the single and double stores
    # from their encoded destinations so an incorrect link or offset fails.
    block(init, 0, "f04f 32ff|f100 0308")
    block(init, 0x10, "2300")
    block(init, 0x14, "4770")
    block(item_init, 0, "2300|6103|4770")
    lists = ("pxReadyTasksLists", "xDelayedTaskList1", "xDelayedTaskList2",
             "xPendingReadyList", "xTasksWaitingTermination", "xSuspendedTaskList")
    headers = []
    for name in lists:
        sym, = symbols.get_symbol_by_name(name)
        count = 56 if name == lists[0] else 1
        start = sym["st_value"]
        if sym["st_size"] != 20 * count or start & 3 or start + sym["st_size"] > 2**32:
            raise ValueError(f"invalid scheduler list storage: {name}")
        headers.extend(start + 20 * i for i in range(count))
    words = {}
    for header in headers:
        sentinel = header + 8
        regs = {0: header, 2: 0xffffffff, 3: sentinel}
        for pc in (8, 12, 14, 18):
            ins = tuple(int(h, 16) for h in code[init][1][pc][0].split())
            h = ins[0]
            if pc == 18:
                regs[3] = 0
            if len(ins) == 2 and h & 0xfff0 == 0xe9c0:
                second = ins[1]
                dest = regs[h & 15] + 4 * (second & 255)
                data = [regs[second >> 12], regs[(second >> 8) & 15]]
            elif len(ins) == 1 and h & 0xf800 == 0x6000:
                dest = regs[(h >> 3) & 7] + 4 * ((h >> 6) & 31)
                data = [regs[h & 7]]
            else:
                raise ValueError("unexpected list initialization store")
            for i, value in enumerate(data):
                addr = dest + 4 * i
                if not header <= addr < header + 20 or addr in words:
                    raise ValueError("overlapping or out-of-range scheduler header store")
                words[addr] = value
        if [words.get(header + n) for n in (0, 4, 8, 12, 16)] != [0, sentinel, 0xffffffff, sentinel, sentinel]:
            raise ValueError("list initialization did not establish an empty ring")

    # First task: old count and current TCB are zero. r5 starts at zero.
    # r8 walks the 56 consecutive 20-byte headers, followed by five singletons.
    for pc, displacement, target in (
        (10, 192, "uxCurrentNumberOfTasks"), (12, 192, "pxCurrentTCB"), (16, 192, lists[0]),
        (0x34, 160, lists[1]), (0x38, 160, lists[2]), (0x46, 152, lists[3]),
        (0x4c, 148, lists[4]), (0x52, 148, lists[5]), (0x58, 144, "pxDelayedTaskList"),
        (0x5e, 144, "pxOverflowDelayedTaskList"), (0x76, 128, "uxTaskNumber"),
        (0x88, 112, "uxTopReadyPriority"),
    ):
        literal(add, pc, displacement, target)
    block(add, 0, "e92d 41f0|4604")
    call(add, 6, "vPortEnterCritical")
    block(add, 10, "4b30|4e30|681a|4f30|3201|601a|6835|bb25|6034|681b|2b01|d129|46b8|4640|3501")
    call(add, 0x28, init)
    block(add, 0x2c, "2d38|f108 0814|d1f7|f8df 80a0|4d28|4640")
    for pc, arg in ((0x3c, "4628"), (0x42, "4826"), (0x48, "4825"), (0x4e, "4825")):
        call(add, pc, init)
        block(add, pc + 4, arg)
    call(add, 0x54, init)
    block(add, 0x58, "4b24|f8c3 8000|4b24|601d|e008")
    block(add, 0x76, "4a20|4620|6813|3301|64e3|6013")
    call(add, 0x82, "ecTraceTaskCreate")
    block(add, 0x86, "2014|4a1c|6ae3|6811|fb00 7003|428b|f104 0104|bf88|6013")
    call(add, 0x9c, "vListInsertEnd")
    call(add, 0xa0, "vPortExitCritical")

    # The constructor loads the TCB pointer from the caller's stack and
    # fills the separate task stack before copying at most 16 task-name bytes.
    block(task, 0, "e92d 47f0|460d|e9dd 9409|4616|ea4f 0a82|4652|4607|21a5|6b20|4698")
    call(task, 0x1a, "memset")
    block(task, 0x1e, "6b22|f1aa 0a04|4452|e9c4 2611|f022 0a03|1e6b|f104 0234|350f|"
          "f813 1f01|f802 1b01|b109|42ab|d1f8")
    # The unsigned clamp gives [0,55] for every word. Both container stores
    # precede the owner stores; neither item overlaps the priority field.
    block(task, 0x44, "9d08|2600|2d37|bf28|2537|1d20|e9c4 5615|62e5|f884 6043")
    call(task, 0x5a, item_init)
    block(task, 0x5e, "f104 0018")
    call(task, 0x62, item_init)
    block(task, 0x66, "2260|f1c5 0538|4631|f8c4 60c0|18a0|6124|61a5|6264")
    block(task, 0x7a, "65e6|f884 60c4")
    call(task, 0x80, "memset")  # r0=TCB+96, r1=0, r2=96
    block(task, 0x84, "4b09|4642|6663|4b09|4639|66a3|4b08|4650|66e3")
    call(task, 0x96, "__wrap_pxPortInitialiseStack")
    block(task, 0x9a, "6020|f1b9 0f00|d001|f8c9 4000|e8bd 87f0")
