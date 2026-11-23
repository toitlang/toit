# Copyright (C) 2026 Toit contributors.
"""Check the linked scheduler and thread completion protocol across base and slots."""

import argparse

from ec618_scheduler_lock import check_scheduler_lock
from ec618_semaphore import check_semaphore_base, check_semaphore_callers
from ec618_thumb import check_executable


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("slots", nargs="+")
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    parser.add_argument("--z3", default="z3")
    args = parser.parse_args()
    check_executable(args.objdump, args.base)
    check_scheduler_lock(args.objdump, args.base, args.z3)
    targets = check_semaphore_base(args.objdump, args.base, args.z3)
    for slot in args.slots:
        check_executable(args.objdump, slot)
        check_semaphore_callers(args.objdump, slot, targets)
        print(f"{slot}: verified scheduler and thread completion paths against {args.base}")
