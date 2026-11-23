# Copyright (C) 2026 Toit contributors.
"""Check the exclusive-access loops in a Cortex-M3 EC618 event source build."""

import argparse
import subprocess

from ec618_thumb import instructions, match_block
from ec618_mailbox_callers import check_callers


def check_loop(body, start, base, old, mask_reg, store_reg, status, expected):
    """Decode one LDREX/optional ALU/STREX attempt and its retry branch."""
    def words(pc):
        return [int(h, 16) for h in body[pc][0].split()]

    if words(start) != [0xe850 | base, (old << 12) | 0xf00]:
        raise ValueError("unexpected exclusive load address or result register")
    regs = {old: "sample"}
    pc = start + 4
    if expected == "zero":
        regs[8] = "#x00000000"  # entry initializes r8 and calls preserve it
    else:
        regs[mask_reg] = "(bvnot mask)" if expected == "clear" else "mask"
        op, operands = words(pc)
        operation = {0xea00: "bvand", 0xea40: "bvor", 0xea80: "bvxor"}.get(op & 0xfff0)
        if operation is None or operands & 0xf0f0 or ((operands >> 8) & 15) != store_reg:
            raise ValueError("unexpected bit operation or shifted operand")
        result = f"({operation} {regs[op & 15]} {regs[operands & 15]})"
        regs[(operands >> 8) & 15] = result
        pc += 4
    store, operands = words(pc)
    if store != (0xe840 | base) or operands != ((store_reg << 12) | (status << 8)):
        raise ValueError("exclusive store does not match load address and status register")
    value = regs[operands >> 12]
    pc += 4
    if status < 8:
        match_block(body, pc, f"{0x2800 | status << 8:04x}")
        pc += 2
    else:
        match_block(body, pc, f"{0xf1b0 | status:04x} 0f00")
        pc += 4
    branch, = words(pc)
    displacement = ((branch & 255) ^ 128) - 128
    if branch >> 12 != 13 or pc + 4 + 2 * displacement != start:
        raise ValueError("exclusive-store retry target changed")
    retry = {0: "success", 1: "(not success)"}.get((branch >> 8) & 15)
    if retry is None:
        raise ValueError("unexpected retry condition")
    spec = {"set": "(bvor current mask)", "clear": "(bvand current (bvnot mask))",
            "zero": "#x00000000"}[expected]
    # A failed STREX never writes. An intervening writer may have changed
    # any bits. A successful reservation still names the sampled value.
    return f"""
(push)
(assert (=> success (= sample current)))
(assert (or (distinct {retry} (not success))
            (distinct (ite success {value} current) (ite success {spec} current))))
(check-sat)
(pop)"""


def check(objdump, obj, z3):
    check_callers(objdump, obj)
    _, pub = instructions(objdump, obj, "_ZN4toit17Ec618EventMailbox7publishENS_5Event4TypeEi")
    _, drain = instructions(objdump, obj, "_ZN4toit16Ec618EventSource5entryEv")
    # Fields and barriers around the four loops. Completion publication
    # stores the generation before setting its bit. Drain reads the
    # generation after successfully clearing and testing the old bit.
    match_block(pub, 0, "1e4b|2b02|b570|4604|460d|4616|d810|2201|f3bf 8f5b|40b2|eb00 0383")
    match_block(pub, 0x2a, "f3bf 8f5b|e01a")
    match_block(pub, 0x38, "3d24|eb04 0385|f3bf 8f5b|60de|2301|f3bf 8f5b|40ab|3434")
    match_block(pub, 0x5e, "f3bf 8f5b|ea03 0002|fab0 f080|0940|e000|2001|bd70")
    match_block(drain, 4, "4604|f04f 0800")
    match_block(drain, 0x4a, "2501|46a9|f104 072c|f3bf 8f5b")
    match_block(drain, 0x62, "f3bf 8f5b|2600|fa09 f306|ea13 0f0a")
    match_block(drain, 0x84, "3501|2d04|f107 0704|d1e1|2500|f04f 0901|f104 0638|"
                "f104 0760|fa09 f305|43d9|f3bf 8f5b")
    match_block(drain, 0xb8, "4213|f3bf 8f5b|d008|6833|f3bf 8f5b")
    match_block(drain, 0xd2, "3501|2d0a|f106 0604|d1df")
    smt = ["(set-logic QF_BV)", "(define-sort W () (_ BitVec 32))",
           "(declare-const sample W)", "(declare-const current W)",
           "(declare-const mask W)", "(declare-const success Bool)"]
    for args in ((pub, 0x1a, 3, 0, 2, 1, 4, "set"), (pub, 0x4e, 4, 2, 3, 1, 0, "set"),
                 (drain, 0x56, 7, 10, None, 8, 3, "zero"), (drain, 0xa6, 7, 2, 1, 0, 12, "clear")):
        smt.append(check_loop(*args))
    results = subprocess.check_output([z3, "-in"], input="\n".join(smt), text=True)
    if results.splitlines() != ["unsat"] * 4:
        raise ValueError("mailbox attempt violates retry or atomic word update")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", nargs="+", help="EC618 uart_ec618.cc object or linked slot ELFs")
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    parser.add_argument("--z3", default="z3")
    args = parser.parse_args()
    for image in args.images:
        check(args.objdump, image, args.z3)
        print(f"{image}: verified mailbox producer calls, queue retirement and four exclusive-access loops.")
