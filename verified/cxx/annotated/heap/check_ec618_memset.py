#!/usr/bin/env python3
# Copyright (C) 2026 Toit contributors.
"""Check the metadata fill routine in an EC618 base ELF and its VM callers."""

import argparse
from pathlib import Path
import re
import subprocess

from ec618_chunk_fills import check_classification, initialization_obligations, setup_bias_obligations
from ec618_semaphore import check_semaphore_base, check_semaphore_callers
from ec618_scheduler_lock import check_scheduler_lock
from ec618_page_release import check_page_release, check_teardown
from ec618_heap_range import base_contract, range_obligations
from ec618_setup_layout import layout_obligations
from ec618_thumb import check_executable, instructions


def metadata_layout(slot, entries):
    from elftools.elf.elffile import ELFFile

    with open(slot, "rb") as stream:
        elf = ELFFile(stream)
        singleton, = elf.get_section_by_name(".symtab").get_symbol_by_name("_ZN4toit10GcMetadata10singleton_E")
        dwarf = elf.get_dwarf_info(relocate_dwarf_sections=False)
        ranges = dwarf.get_aranges()
        for offset in {ranges.cu_offset_at_addr(entry) for entry in entries}:
            check_fields(slot, dwarf.get_CU_at(offset))
        return singleton["st_value"]


def check_fields(slot, cu):
    fields = {b"Chunk": {b"start_": 12, b"end_": 16},
              b"GcMetadata": {b"lowest_address_": 0, b"heap_extent_": 4, b"heap_start_munged_": 8,
                              b"heap_extent_munged_": 12, b"number_of_cards_": 16, b"metadata_size_": 20,
                              b"metadata_": 24, b"remembered_set_": 28,
                              b"object_starts_": 32, b"mark_bits_": 36, b"mark_stack_overflow_bits_": 40,
                              b"page_type_bytes_": 44, b"cumulative_mark_bit_counts_": 48,
                              b"starts_bias_": 52, b"remembered_set_bias_": 56, b"mark_bits_bias_": 60,
                              b"overflow_bits_bias_": 64, b"cumulative_mark_bits_bias_": 68}}
    seen = set()
    for die in cu.iter_DIEs():
        if die.tag not in ("DW_TAG_class_type", "DW_TAG_structure_type") or not die.has_children:
            continue
        name = die.attributes.get("DW_AT_name")
        parent = die.get_parent()
        if not name or name.value not in fields or parent.tag != "DW_TAG_namespace":
            continue
        namespace = parent.attributes.get("DW_AT_name")
        if not namespace or namespace.value != b"toit":
            continue
        for child in die.iter_children():
            member = child.attributes.get("DW_AT_name")
            if child.tag != "DW_TAG_member" or not member or member.value not in fields[name.value]:
                continue
            offset = fields[name.value][member.value]
            location = child.attributes["DW_AT_data_member_location"].value
            # Constant offset or DW_OP_plus_uconst with a one-byte ULEB operand.
            if location != offset and location != [0x23, offset]:
                raise ValueError(f"{slot}: unexpected field offset for {member.value!r}")
            seen.add((name.value, member.value))
    if len(seen) != sum(map(len, fields.values())):
        raise ValueError(f"{slot}: missing DWARF metadata fields")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("slots", nargs="+")
    parser.add_argument("--objdump", default="arm-none-eabi-objdump")
    parser.add_argument("--z3", default="z3")
    args = parser.parse_args()
    check_executable(args.objdump, args.base)
    target, body = instructions(args.objdump, args.base, "memset")
    expected = {0: "4603", 2: "4402", 4: "4293", 6: "d100", 8: "4770",
                10: "f803 1b01", 14: "e7f9"}
    if {offset: data for offset, (data, _) in body.items()} != expected:
        raise ValueError("memset differs from the proved Thumb body")

    classify = "_ZN4toit10GcMetadata20mark_pages_for_chunkEPNS_5ChunkENS_8PageTypeE"
    clear = "_ZN4toit10GcMetadata25clear_mark_bits_for_chunkEPKNS_5ChunkE"
    initialize = "_ZNK4toit5Chunk19initialize_metadataEv"
    setup = "_ZN4toit10GcMetadata16set_up_singletonEv"
    destroy = "_ZN4toit5ChunkD1Ev"
    check_scheduler_lock(args.objdump, args.base, args.z3)
    semaphores = check_semaphore_base(args.objdump, args.base, args.z3)
    contract = base_contract(args.objdump, args.base, target, args.z3)
    _, _, first, limit, low = contract
    free = check_page_release(args.objdump, args.base, (first + 7) & ~7, low, limit)
    for slot in args.slots:
        check_executable(args.objdump, slot)
        functions = {name: instructions(args.objdump, slot, name)
                     for name in (classify, clear, initialize, destroy, setup)}
        singleton = metadata_layout(slot, [functions[name][0] for name in (classify, clear, initialize, setup)])
        check_semaphore_callers(args.objdump, slot, semaphores)
        check_teardown(args.objdump, slot, singleton, free)
        check_classification(slot, target, *functions[classify], singleton)
        for name, (smt, obligations) in (
            ("heap range", range_obligations(args.objdump, slot, functions[setup], contract)),
            ("setup layout", layout_obligations(functions[setup], target, instructions(
                args.objdump, slot, "_ZN4toit2OS18use_virtual_memoryEPvj"), contract)),
            ("setup bias", setup_bias_obligations(functions[setup], target)),
            ("chunk initialization", initialization_obligations(functions[initialize], functions[clear], target, singleton)),
        ):
            results = subprocess.check_output([args.z3, "-in"], text=True, input=smt).splitlines()
            if results != ["unsat"] * obligations:
                raise ValueError(f"{slot}: {name} proof failed: {results}")
        # Three direct table fills plus the mark-bit helper at initialization.
        # Destruction calls the classification helper, which tail-calls memset.
        for caller, callee, address, count in (
            (initialize, "memset", target, 3), (initialize, clear, functions[clear][0], 1),
            (clear, "memset", target, 1), (destroy, classify, functions[classify][0], 1),
            (classify, "memset", target, 1),
        ):
            branch = re.compile(r"(?:bl|b\.w)\s+0*" + f"{address:x} <{callee}>")
            if sum(bool(branch.fullmatch(asm)) for _, asm in functions[caller][1].values()) != count:
                raise ValueError(f"{slot}: unexpected branches from {caller} to {callee}")

    proof = Path(__file__).with_name("ec618_memset.smt2")
    verdicts = subprocess.check_output([args.z3, str(proof)], text=True).splitlines()
    if verdicts != ["unsat"] * 4:
        raise ValueError(f"byte-fill induction failed: {verdicts}")
    proof = Path(__file__).with_name("ec618_page_classify.smt2")
    verdicts = subprocess.check_output([args.z3, str(proof)], text=True).splitlines()
    if verdicts != ["unsat"] * 3:
        raise ValueError(f"page-classification proof failed: {verdicts}")
    print(f"Matched {len(args.slots)} slot(s); completion semaphore, scheduler lock, heap range, fill, classification, layout, bias, initialization and release obligations proved.")


if __name__ == "__main__":
    main()
