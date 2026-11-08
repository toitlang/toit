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
//!   INTRINSIC_ARRAY_DO, INTRINSIC_HASH_FIND, INTRINSIC_HASH_DO.

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

pub const OPCODE_COUNT2: u8 = 101;

/// Instruction length in bytes, including the opcode.
pub open spec fn opcode_length2(op: u8) -> int {
    if op == 1 || op == 8 || op == 12 || op == 21 || op == 27 || op == 31 || op == 33
        || op == 36 || op == 43 || op == 45 || op == 47 || op == 49 || op == 51
        || op == 53 || op == 54 || op == 60 || op == 61 || op == 80
        || (81 <= op && op <= 88) {
        3
    } else if op == 28 || op == 29 || op == 59 {
        5
    } else if op == 58 || op == 89 {
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
    if op == 1 || op == 8 || op == 12 || op == 21 || op == 27 || op == 31 || op == 33
        || op == 36 || op == 43 || op == 45 || op == 47 || op == 49 || op == 51
        || op == 53 || op == 54 || op == 60 || op == 61 || op == 80
        || (81 <= op && op <= 88) {
        3
    } else if op == 28 || op == 29 || op == 59 {
        5
    } else if op == 58 || op == 89 {
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

} // verus!

/// Opcode names of format 2, in opcode order.
pub const OPCODE_NAMES2: [&str; 101] = [
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
];

/// Lengths of format 2 in opcode order.
pub const OPCODE_LENGTHS2: [u8; 101] = [
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
];
