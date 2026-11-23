# Copyright (C) 2026 Toit contributors.
"""Check the linked chunk admission, page classification and destruction paths."""

from pathlib import Path
import subprocess

from ec618_external_extent import check_external_extent
from ec618_remembered_scan import check_remembered_scan
from ec618_process_roots import check_process_roots
from ec618_object_roots import check_object_roots
from ec618_object_extent import check_object_extent
from ec618_scavenge_capacity import check_scavenge_capacity
from ec618_scavenge_copy import check_scavenge_copy
from ec618_semispace_swap import check_semispace_swap
from ec618_chunk_append import check_space_append
from ec618_chunk_fills import check_classification, initialization_obligations
from ec618_thumb import instructions, match_block, match_branch


def check_chunk_lifetime(objdump, slot, base, singleton, allocated, free, z3):
    def local(name):
        return instructions(objdump, slot, name)

    release_pages = "_ZN4toit2OS10free_pagesEPvj"
    release, wrapper = local(release_pages)
    match_branch(wrapper, 0, "b.w", "free", free)
    admit, body = local("_ZN4toit12ObjectMemory14allocate_chunkEPNS_5SpaceEj")
    if admit % 4 or int(body[0x84][0], 16) != singleton:
        raise ValueError("chunk admission reads the wrong heap extent")
    match_block(body, 0, "e92d 47f0|1e4b|f513 5f80|4607|b0b2|d234|46e9|46e8|2600|"
                "f601 74ff|f8df a068|f36f 040b|4620")
    pages = "_ZN4toit2OS14allocate_pagesEj"
    page_entry, page_body = local(pages)
    match_branch(body, 0x24, "bl", pages, page_entry)
    match_block(page_body, 0, "b538|4604")
    get_tag = instructions(objdump, base, "vPortGetHeapTag")[0]
    set_tag = instructions(objdump, base, "vPortSetHeapTag")[0]
    match_branch(page_body, 4, "bl", "vPortGetHeapTag", get_tag)
    match_block(page_body, 8, "4605|f06f 005f")
    match_branch(page_body, 0xe, "bl", "vPortSetHeapTag", set_tag)
    match_block(page_body, 0x12, "f604 71ff|f36f 010b|f44f 5080")
    match_branch(page_body, 0x1e, "bl", "aligned_alloc", instructions(objdump, base, "aligned_alloc")[0])
    match_block(page_body, 0x22, "4604|4628")
    match_branch(page_body, 0x26, "bl", "vPortSetHeapTag", set_tag)
    match_block(page_body, 0x2a, "4620|bd38")
    match_block(body, 0x28, "4605|b188|f8da 2000|4290|d307|f8da 3004|429c|d803|"
                "1a82|1b1b|429a|d905")
    # Each rejection appends the grant before testing the loop back edge.
    # The 50th entry ends the search. Cleanup visits the recorded prefix
    # in insertion order, passing the same rounded size each time.
    match_block(body, 0x44, "3601|2e32|f848 5b04|d1e9|2500|f04f 0800|45b0|d007|4621|f859 0b04")
    match_branch(body, 0x5e, "bl", release_pages, release)
    match_block(body, 0x62, "f108 0801|e7f5|b13d|462a|4621|4638|b032|e8bd 47f0")
    helper = "_ZN4toit12ObjectMemory21allocate_chunk_helperEPNS_5SpaceEjPv"
    helper_entry, build = local(helper)
    match_branch(body, 0x76, "b.w", helper, helper_entry)
    match_block(body, 0x7a, "2000|b032|e8bd 87f0")

    # ObjectMemory::set_up passes a null Space. Follow that branch from
    # descriptor allocation through publication of the accounted chunk.
    if helper_entry % 4 or (int(build[0x9c][0], 16), int(build[0xa4][0], 16)) != (singleton, allocated):
        raise ValueError("unexpected chunk construction globals")
    match_block(build, 0, "e92d 41f0|4606|460d|4617|b3a2|201c|4922")
    new = "_ZnwjRKSt9nothrow_t"
    match_branch(build, 0x10, "bl", new, instructions(objdump, base, new)[0])
    match_block(build, 0x14, "4604|b350|462b|463a|4631")
    ctor = "_ZN4toit5ChunkC1EPNS_5SpaceEjj"
    entry, construct = local(ctor)
    match_branch(build, 0x1e, "bl", ctor, entry)
    if entry % 4 or int(construct[0x2c][0], 16) != singleton:
        raise ValueError("chunk constructor reads the wrong metadata bounds")
    match_block(construct, 0, "b510|e9c0 1202|4909|4413|e9c0 3204|680b|e9c0 0000|"
                "429a|d303|6849|440b|429a|d903|4611|4803")
    fail = "_ZN4toit4failEPKcz"
    match_branch(construct, 0x24, "bl", fail, local(fail)[0])
    match_block(construct, 0x28, "bd10")
    use = "_ZN4toit2OS18use_virtual_memoryEPvj"
    use_entry, use_body = local(use)
    match_block(use_body, 0, "2001|4770")
    match_block(build, 0x22, "f8df 8078|68e3|6921|f8d8 003c|1ac9|0949|3101|eb00 1053|095f")
    match_branch(build, 0x3a, "bl", use, use_entry)
    match_block(build, 0x3e, "b910")
    match_block(build, 0x46, "f8d8 0044|e9d4 3103|1ac9|0949|4438")
    match_branch(build, 0x54, "bl", use, use_entry)
    match_block(build, 0x58, "2800|d0f1|b16e")
    match_block(build, 0x6e, "4629|4638")
    match_branch(build, 0x72, "bl", release_pages, release)
    match_block(build, 0x76, "2400|e00b|f3bf 8f5b|4b09|e853 1f00|4429|e843 1200|"
                "2a00|d1f8|f3bf 8f5b|4620|e8bd 81f0")

    free_chunk, body = local("_ZN4toit12ObjectMemory10free_chunkEPNS_5ChunkE")
    if free_chunk % 4 or int(body[0x34][0], 16) != allocated:
        raise ValueError("chunk release subtracts from the wrong counter")
    match_block(body, 0, "b510|e9d0 1303|4604|f3bf 8f5b|4a09|1a5b|e852 cf00|"
                "ebac 0c03|e842 c100|2900|d1f7|f3bf 8f5b")
    destroy = "_ZN4toit5ChunkD1Ev"
    entry, destructor = local(destroy)
    match_branch(body, 0x24, "bl", destroy, entry)
    match_block(body, 0x28, "4620|e8bd 4010")
    delete, delete_body = instructions(objdump, base, "_ZdlPv")
    match_branch(body, 0x2e, "b.w", "_ZdlPv", delete)
    match_branch(delete_body, 0, "b.w", "free", free)
    mark = "_ZN4toit10GcMetadata20mark_pages_for_chunkEPNS_5ChunkENS_8PageTypeE"
    entry, classify = local(mark)
    match_block(destructor, 0, "b510|4604|2100")
    match_branch(destructor, 6, "bl", mark, entry)
    match_block(destructor, 0xa, "e9d4 0103|1a09")
    match_branch(destructor, 0x10, "bl", release_pages, release)
    match_block(destructor, 0x14, "4620|bd10")
    memset, _ = instructions(objdump, base, "memset")
    check_classification(slot, memset, entry, classify, singleton)
    initialize = "_ZNK4toit5Chunk19initialize_metadataEv"
    clear = "_ZN4toit10GcMetadata25clear_mark_bits_for_chunkEPKNS_5ChunkE"
    initialize_code = local(initialize)
    match_block(build, 0x5e, "4620|7e31")
    match_branch(build, 0x62, "bl", mark, entry)
    match_block(build, 0x66, "4620")
    match_branch(build, 0x68, "bl", initialize, initialize_code[0])
    match_block(build, 0x6c, "e005")

    set_owner = "_ZN4toit5Chunk9set_ownerEPNS_5SpaceE"
    owner_entry, owner = local(set_owner)
    match_block(owner, 0, "b538|4605|460c|6081|b101|7e09|4628")
    match_branch(owner, 0xe, "bl", mark, entry)
    match_block(owner, 0x12, "b124|4628|e8bd 4038")
    match_branch(owner, 0x1a, "b.w", initialize, initialize_code[0])
    match_block(owner, 0x1e, "bd38")
    smt, count = initialization_obligations(initialize_code, local(clear), memset, singleton)
    if subprocess.check_output([z3, "-in"], input=smt, text=True).splitlines() != ["unsat"] * count:
        raise ValueError("chunk metadata writes differ from the owned table slices")

    check_external_extent(objdump, slot, base)
    check_remembered_scan(objdump, slot, singleton)
    check_process_roots(objdump, slot)
    check_object_roots(objdump, slot, singleton)
    check_object_extent(objdump, slot, memset)
    check_scavenge_capacity(objdump, slot)
    check_scavenge_copy(objdump, base, slot)
    check_semispace_swap(objdump, slot, singleton, set_owner, owner_entry)
    check_space_append(objdump, slot, singleton, memset, set_owner, owner_entry)
    for filename, count in (("ec618_page_classify.smt2", 3), ("ec618_chunk_admission.smt2", 3),
                            ("ec618_chunk_append.smt2", 4), ("ec618_survivor_watermark.smt2", 1),
                            ("ec618_remembered_scan.smt2", 11),
                            ("ec618_process_roots.smt2", 8), ("ec618_object_roots.smt2", 9), ("ec618_object_extent.smt2", 10), ("ec618_external_extent.smt2", 4),
                            ("ec618_scavenge_capacity.smt2", 3), ("ec618_scavenge_copy.smt2", 10)):
        result = subprocess.check_output([z3, str(Path(__file__).with_name(filename))], text=True)
        if result.splitlines() != ["unsat"] * count:
            raise ValueError(f"failed chunk proof {filename}: {result}")
