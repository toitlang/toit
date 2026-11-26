// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

//! Opcodes of the revised format (format 2).
//!
//! Format 2 keeps the numbers of the format-1 opcodes it shares (so that
//! the compiler's peephole optimizer keeps working) and has 101 opcodes,
//! 0..=100. Compared to format 1:
//!
//! * changed operands: INVOKE_STATIC_TAIL (dispatch index only),
//!   INVOKE_LAMBDA_TAIL and INVOKE_INITIALIZER_TAIL (none), the four
//!   BRANCH_BACK opcodes (distance only), THROW, RETURN, RETURN_NULL and
//!   NON_LOCAL_RETURN (none), NON_LOCAL_BRANCH (target relative to the
//!   entry of the target frame's method);
//! * new: TRY (97, was LINK), LOAD_FIELD_THIS (98, was UNLINK),
//!   STORE_FIELD_THIS (94, was NON_LOCAL_RETURN_WIDE);
//! * removed: LINK, UNLINK, NON_LOCAL_RETURN_WIDE, INTRINSIC_SMI_REPEAT,
//!   INTRINSIC_ARRAY_DO, INTRINSIC_HASH_FIND, INTRINSIC_HASH_DO;
//! * proposal (branch proposal/builtins, format note 19): LOOP_REPEAT (101)
//!   and LOOP_ARRAY (102), the bounded steps of `repeat` and `Array.do`,
//!   and HASH_FIND (103), one probe of a hashed collection's index;
//! * format 3 (format note 22): the short branches BRANCH_S ..
//!   BRANCH_IF_NOT_NULL_S and BRANCH_BACK_S (114..118), the branches with a
//!   one-byte distance.

use vstd::prelude::*;
pub use crate::bytecodes::{
    LOAD_LOCAL, LOAD_LOCAL_WIDE, POP_LOAD_LOCAL, STORE_LOCAL, STORE_LOCAL_POP, LOAD_OUTER,
    STORE_OUTER, LOAD_FIELD, LOAD_FIELD_WIDE, LOAD_FIELD_LOCAL, POP_LOAD_FIELD_LOCAL,
    STORE_FIELD, STORE_FIELD_WIDE, STORE_FIELD_POP, LOAD_LOCAL_0, LOAD_LOCAL_1, LOAD_LOCAL_2,
    LOAD_LOCAL_3, LOAD_LOCAL_4, LOAD_LOCAL_5, LOAD_LITERAL, LOAD_LITERAL_WIDE, LOAD_NULL,
    LOAD_SMI_0, LOAD_SMIS_0, LOAD_SMI_1, LOAD_SMI_U8, LOAD_SMI_U16, LOAD_SMI_U32, LOAD_METHOD,
    LOAD_GLOBAL_VAR, LOAD_GLOBAL_VAR_WIDE, LOAD_GLOBAL_VAR_LAZY, LOAD_GLOBAL_VAR_LAZY_WIDE,
    LOAD_GLOBAL_VAR_DYNAMIC, STORE_GLOBAL_VAR, STORE_GLOBAL_VAR_WIDE, STORE_GLOBAL_VAR_DYNAMIC,
    LOAD_BLOCK, LOAD_OUTER_BLOCK, POP, POP_1, ALLOCATE, ALLOCATE_WIDE, IS_CLASS, IS_CLASS_WIDE,
    IS_INTERFACE, IS_INTERFACE_WIDE, AS_CLASS, AS_CLASS_WIDE, AS_INTERFACE, AS_INTERFACE_WIDE,
    AS_LOCAL, INVOKE_STATIC, INVOKE_STATIC_TAIL, INVOKE_BLOCK, INVOKE_LAMBDA_TAIL,
    INVOKE_INITIALIZER_TAIL, INVOKE_VIRTUAL, INVOKE_VIRTUAL_WIDE, INVOKE_VIRTUAL_GET,
    INVOKE_VIRTUAL_SET, INVOKE_EQ, INVOKE_LT, INVOKE_GT, INVOKE_LTE, INVOKE_GTE, INVOKE_BIT_OR,
    INVOKE_BIT_XOR, INVOKE_BIT_AND, INVOKE_BIT_SHL, INVOKE_BIT_SHR, INVOKE_BIT_USHR, INVOKE_ADD,
    INVOKE_SUB, INVOKE_MUL, INVOKE_DIV, INVOKE_MOD, INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE,
    BRANCH, BRANCH_IF_TRUE, BRANCH_IF_FALSE, BRANCH_IF_NOT_NULL, BRANCH_BACK,
    BRANCH_BACK_IF_TRUE, BRANCH_BACK_IF_FALSE, BRANCH_BACK_IF_NOT_NULL, PRIMITIVE, THROW,
    RETURN, RETURN_NULL, NON_LOCAL_RETURN, NON_LOCAL_BRANCH, IDENTICAL, UNWIND, HALT,
};

verus! {

/// STORE_FIELD_THIS f: `this.f = top` (the value stays).
pub const STORE_FIELD_THIS: u8 = 94;
/// TRY: calls the try block on top of the stack under a handler.
pub const TRY: u8 = 97;
/// LOAD_FIELD_THIS f: push `this.f`.
pub const LOAD_FIELD_THIS: u8 = 98;

/// LOOP_REPEAT back n (proposal, format note 19): the counter is slot `n`,
/// the block slot `n + 1`, the limit slot `n + 2` (counted from the top
/// before the pop). Pops the top (the previous block result); if the
/// counter and the limit are smis with counter < limit, stores counter + 1,
/// pushes a copy of the block and the old counter and branches back by
/// `back`; otherwise falls through.
pub const LOOP_REPEAT: u8 = 101;
/// LOOP_ARRAY back n (proposal, format note 19): counter slot `n`, block
/// `n + 1`, end `n + 2`, array `n + 3`. Pops the top; if the counter and
/// the end are smis with 0 <= counter < end and the array slot holds an
/// array with more than counter elements, stores counter + 1, pushes a copy
/// of the block and the element at counter and branches back by `back`;
/// otherwise falls through.
pub const LOOP_ARRAY: u8 = 102;
/// HASH_FIND miss n m (proposal, format note 19): one probe of the index of
/// a hashed collection (`find-body_` in lib/core/collections.toit) with
/// the probe state in slots `n` (slot), `n + 1` (step, 0: start) and
/// `n + 2` (first deleted slot + 1, 0: none), the hash in slot `m` and the
/// collection in slot `m + 2`. A key whose stored hash bits match: stores
/// the state, pushes the key and its backing position, falls through.
/// Otherwise pushes a code (`spec::op_hash_find`) and branches forward by
/// `miss`. Reads only; no calls.
pub const HASH_FIND: u8 = 103;

/// The unchecked twins of the field accesses (trusted programs only, format
/// note 20): LOAD_FIELD_U .. STORE_FIELD_THIS_U, opcodes 104..113, the
/// instruction of `base_op` with the same operands, except that a failed
/// field check is a stuck state instead of INVALID_PROGRAM
/// (`spec::unchecked_fail`): the machine does not check. The verifier
/// accepts them only for a program in the unchecked mode
/// (`Program2::unchecked`), which only trusted programs may be in.
pub const LOAD_FIELD_U: u8 = 104;
pub const LOAD_FIELD_WIDE_U: u8 = 105;
pub const LOAD_FIELD_LOCAL_U: u8 = 106;
pub const POP_LOAD_FIELD_LOCAL_U: u8 = 107;
pub const STORE_FIELD_U: u8 = 108;
pub const STORE_FIELD_WIDE_U: u8 = 109;
pub const STORE_FIELD_POP_U: u8 = 110;
pub const INVOKE_VIRTUAL_GET_U: u8 = 111;
pub const INVOKE_VIRTUAL_SET_U: u8 = 112;
pub const STORE_FIELD_THIS_U: u8 = 113;

/// The short branches (format 3, format note 22): BRANCH_S ..
/// BRANCH_IF_NOT_NULL_S (114..117) and BRANCH_BACK_S (118) are BRANCH ..
/// BRANCH_IF_NOT_NULL and BRANCH_BACK with a one-byte distance (2 bytes
/// instead of 3). The backward conditional branches have no short form
/// (the compiler does not emit them).
pub const BRANCH_S: u8 = 114;
pub const BRANCH_IF_TRUE_S: u8 = 115;
pub const BRANCH_IF_FALSE_S: u8 = 116;
pub const BRANCH_IF_NOT_NULL_S: u8 = 117;
pub const BRANCH_BACK_S: u8 = 118;

pub const OPCODE_COUNT2: u8 = 119;

/// An unchecked twin (format note 20).
pub open spec fn is_twin(op: u8) -> bool {
    LOAD_FIELD_U <= op && op <= STORE_FIELD_THIS_U
}

/// The instruction a twin is the unchecked form of; every other opcode is
/// its own.
pub open spec fn base_op(op: u8) -> u8 {
    if LOAD_FIELD_U <= op && op <= STORE_FIELD_POP_U { (op - LOAD_FIELD_U + LOAD_FIELD) as u8 }
    else if op == INVOKE_VIRTUAL_GET_U { INVOKE_VIRTUAL_GET }
    else if op == INVOKE_VIRTUAL_SET_U { INVOKE_VIRTUAL_SET }
    else if op == STORE_FIELD_THIS_U { STORE_FIELD_THIS }
    else { op }
}

pub fn exec_is_twin(op: u8) -> (r: bool)
    ensures r == is_twin(op),
{
    LOAD_FIELD_U <= op && op <= STORE_FIELD_THIS_U
}

pub fn exec_base_op(op: u8) -> (r: u8)
    ensures r == base_op(op),
{
    if LOAD_FIELD_U <= op && op <= STORE_FIELD_POP_U { op - LOAD_FIELD_U + LOAD_FIELD }
    else if op == INVOKE_VIRTUAL_GET_U { INVOKE_VIRTUAL_GET }
    else if op == INVOKE_VIRTUAL_SET_U { INVOKE_VIRTUAL_SET }
    else if op == STORE_FIELD_THIS_U { STORE_FIELD_THIS }
    else { op }
}

/// A twin has the length and the operands of its base.
pub proof fn lemma_base_op(op: u8)
    ensures
        opcode_length2(base_op(op)) == opcode_length2(op),
        base_op(op) < OPCODE_COUNT2 <==> op < OPCODE_COUNT2,
        !is_twin(base_op(op)),
        base_op(base_op(op)) == base_op(op),
        !is_twin(op) ==> base_op(op) == op,
        is_twin(op) ==> (base_op(op) == LOAD_FIELD || base_op(op) == LOAD_FIELD_WIDE
            || base_op(op) == LOAD_FIELD_LOCAL || base_op(op) == POP_LOAD_FIELD_LOCAL
            || base_op(op) == STORE_FIELD || base_op(op) == STORE_FIELD_WIDE || base_op(op) == STORE_FIELD_POP
            || base_op(op) == INVOKE_VIRTUAL_GET || base_op(op) == INVOKE_VIRTUAL_SET
            || base_op(op) == STORE_FIELD_THIS),
{
}

/// Instruction length in bytes, including the opcode.
pub open spec fn opcode_length2(op: u8) -> int {
    if op == 1 || op == 8 || op == 12 || op == 21 || op == 27 || op == 31 || op == 33
        || op == 36 || op == 43 || op == 45 || op == 47 || op == 49 || op == 51
        || op == 53 || op == 54 || op == 60 || op == 61 || op == 80
        || (81 <= op && op <= 88) || op == 105 || op == 109 || op == 111 || op == 112 {
        3
    } else if op == 28 || op == 29 || op == 59 || op == 103 {
        5
    } else if op == 58 || op == 89 || op == 101 || op == 102 {
        4
    } else if op == 95 {
        6
    } else if (14 <= op && op <= 19) || op == 22 || op == 23 || op == 25 || op == 34
        || op == 37 || op == 41 || op == 56 || op == 57 || (62 <= op && op <= 79)
        || (90 <= op && op <= 93) || op == 96 || op == 97 || op == 99 {
        1
    } else {
        2
    }
}

pub fn exec_opcode_length2(op: u8) -> (r: usize)
    ensures r == opcode_length2(op), 1 <= r <= 6,
{
    // One match (a table lookup once compiled; the chain of compares of
    // `opcode_length2` cost the verifier a dozen compares per instruction).
    match op {
        14 | 15 | 16 | 17 | 18 | 19 | 22 | 23 | 25 | 34 | 37 | 41 | 56 | 57 | 62 | 63 | 64 | 65 | 66 | 67 | 68 | 69
            | 70 | 71 | 72 | 73 | 74 | 75 | 76 | 77 | 78 | 79 | 90 | 91 | 92 | 93 | 96 | 97 | 99 => 1,
        1 | 8 | 12 | 21 | 27 | 31 | 33 | 36 | 43 | 45 | 47 | 49 | 51 | 53 | 54 | 60 | 61 | 80 | 81 | 82 | 83 | 84
            | 85 | 86 | 87 | 88 | 105 | 109 | 111 | 112 => 3,
        58 | 89 | 101 | 102 => 4,
        28 | 29 | 59 | 103 => 5,
        95 => 6,
        _ => 2,
    }
}

} // verus!

/// Opcode names of format 2, in opcode order.
pub const OPCODE_NAMES2: [&str; 119] = [
    "LOAD_LOCAL", "LOAD_LOCAL_WIDE", "POP_LOAD_LOCAL", "STORE_LOCAL", "STORE_LOCAL_POP",
    "LOAD_OUTER", "STORE_OUTER", "LOAD_FIELD", "LOAD_FIELD_WIDE", "LOAD_FIELD_LOCAL",
    "POP_LOAD_FIELD_LOCAL", "STORE_FIELD", "STORE_FIELD_WIDE", "STORE_FIELD_POP",
    "LOAD_LOCAL_0", "LOAD_LOCAL_1", "LOAD_LOCAL_2", "LOAD_LOCAL_3", "LOAD_LOCAL_4",
    "LOAD_LOCAL_5", "LOAD_LITERAL", "LOAD_LITERAL_WIDE", "LOAD_NULL", "LOAD_SMI_0",
    "LOAD_SMIS_0", "LOAD_SMI_1", "LOAD_SMI_U8", "LOAD_SMI_U16", "LOAD_SMI_U32",
    "LOAD_METHOD", "LOAD_GLOBAL_VAR", "LOAD_GLOBAL_VAR_WIDE", "LOAD_GLOBAL_VAR_LAZY",
    "LOAD_GLOBAL_VAR_LAZY_WIDE", "LOAD_GLOBAL_VAR_DYNAMIC", "STORE_GLOBAL_VAR",
    "STORE_GLOBAL_VAR_WIDE", "STORE_GLOBAL_VAR_DYNAMIC", "LOAD_BLOCK", "LOAD_OUTER_BLOCK",
    "POP", "POP_1", "ALLOCATE", "ALLOCATE_WIDE", "IS_CLASS", "IS_CLASS_WIDE",
    "IS_INTERFACE", "IS_INTERFACE_WIDE", "AS_CLASS", "AS_CLASS_WIDE", "AS_INTERFACE",
    "AS_INTERFACE_WIDE", "AS_LOCAL", "INVOKE_STATIC", "INVOKE_STATIC_TAIL", "INVOKE_BLOCK",
    "INVOKE_LAMBDA_TAIL", "INVOKE_INITIALIZER_TAIL", "INVOKE_VIRTUAL", "INVOKE_VIRTUAL_WIDE",
    "INVOKE_VIRTUAL_GET", "INVOKE_VIRTUAL_SET", "INVOKE_EQ", "INVOKE_LT", "INVOKE_GT",
    "INVOKE_LTE", "INVOKE_GTE", "INVOKE_BIT_OR", "INVOKE_BIT_XOR", "INVOKE_BIT_AND",
    "INVOKE_BIT_SHL", "INVOKE_BIT_SHR", "INVOKE_BIT_USHR", "INVOKE_ADD", "INVOKE_SUB",
    "INVOKE_MUL", "INVOKE_DIV", "INVOKE_MOD", "INVOKE_AT", "INVOKE_AT_PUT", "INVOKE_SIZE",
    "BRANCH", "BRANCH_IF_TRUE", "BRANCH_IF_FALSE", "BRANCH_IF_NOT_NULL", "BRANCH_BACK",
    "BRANCH_BACK_IF_TRUE", "BRANCH_BACK_IF_FALSE", "BRANCH_BACK_IF_NOT_NULL", "PRIMITIVE",
    "THROW", "RETURN", "RETURN_NULL", "NON_LOCAL_RETURN", "STORE_FIELD_THIS",
    "NON_LOCAL_BRANCH", "IDENTICAL", "TRY", "LOAD_FIELD_THIS", "UNWIND", "HALT",
    "LOOP_REPEAT", "LOOP_ARRAY", "HASH_FIND",
    "LOAD_FIELD_U", "LOAD_FIELD_WIDE_U", "LOAD_FIELD_LOCAL_U", "POP_LOAD_FIELD_LOCAL_U",
    "STORE_FIELD_U", "STORE_FIELD_WIDE_U", "STORE_FIELD_POP_U", "INVOKE_VIRTUAL_GET_U",
    "INVOKE_VIRTUAL_SET_U", "STORE_FIELD_THIS_U",
    "BRANCH_S", "BRANCH_IF_TRUE_S", "BRANCH_IF_FALSE_S", "BRANCH_IF_NOT_NULL_S", "BRANCH_BACK_S",
];

/// Lengths of format 2 in opcode order.
pub const OPCODE_LENGTHS2: [u8; 119] = [
    2, 3, 2, 2, 2, 2, 2, 2, 3, 2, 2, 2, 3, 2, // 0..13
    1, 1, 1, 1, 1, 1, // LOAD_LOCAL_0..5
    2, 3, 1, 1, 2, 1, 2, 3, 5, 5, // 20..29
    2, 3, 2, 3, 1, 2, 3, 1, 2, 2, // 30..39
    2, 1, // POP, POP_1
    2, 3, // ALLOCATE
    2, 3, 2, 3, 2, 3, 2, 3, 2, // 44..52
    3, 3, 2, 1, 1, // 53..57: INVOKE_STATIC, _TAIL, INVOKE_BLOCK, LAMBDA_TAIL, INITIALIZER_TAIL
    4, 5, 3, 3, // 58..61
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, // 62..80
    3, 3, 3, 3, 3, 3, 3, 3, // 81..88: BRANCH*, BRANCH_BACK*
    4, 1, 1, 1, 1, 2, 6, 1, 1, 2, 1, 2, // 89..100
    4, // 101: LOOP_REPEAT
    4, // 102: LOOP_ARRAY
    5, // 103: HASH_FIND
    2, 3, 2, 2, 2, 3, 2, 3, 3, 2, // 104..113: the unchecked twins (note 20)
    2, 2, 2, 2, 2, // 114..118: the short branches (note 22)
];
