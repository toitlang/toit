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

//! Opcode numbers and instruction lengths, transcribed from
//! `src/bytecodes.h`. `tests/opcode_table.rs` cross-checks this file against
//! the header at test time.

use vstd::prelude::*;

verus! {

pub const LOAD_LOCAL: u8 = 0;
pub const LOAD_LOCAL_WIDE: u8 = 1;
pub const POP_LOAD_LOCAL: u8 = 2;
pub const STORE_LOCAL: u8 = 3;
pub const STORE_LOCAL_POP: u8 = 4;
pub const LOAD_OUTER: u8 = 5;
pub const STORE_OUTER: u8 = 6;
pub const LOAD_FIELD: u8 = 7;
pub const LOAD_FIELD_WIDE: u8 = 8;
pub const LOAD_FIELD_LOCAL: u8 = 9;
pub const POP_LOAD_FIELD_LOCAL: u8 = 10;
pub const STORE_FIELD: u8 = 11;
pub const STORE_FIELD_WIDE: u8 = 12;
pub const STORE_FIELD_POP: u8 = 13;
pub const LOAD_LOCAL_0: u8 = 14;
pub const LOAD_LOCAL_1: u8 = 15;
pub const LOAD_LOCAL_2: u8 = 16;
pub const LOAD_LOCAL_3: u8 = 17;
pub const LOAD_LOCAL_4: u8 = 18;
pub const LOAD_LOCAL_5: u8 = 19;
pub const LOAD_LITERAL: u8 = 20;
pub const LOAD_LITERAL_WIDE: u8 = 21;
pub const LOAD_NULL: u8 = 22;
pub const LOAD_SMI_0: u8 = 23;
pub const LOAD_SMIS_0: u8 = 24;
pub const LOAD_SMI_1: u8 = 25;
pub const LOAD_SMI_U8: u8 = 26;
pub const LOAD_SMI_U16: u8 = 27;
pub const LOAD_SMI_U32: u8 = 28;
pub const LOAD_METHOD: u8 = 29;
pub const LOAD_GLOBAL_VAR: u8 = 30;
pub const LOAD_GLOBAL_VAR_WIDE: u8 = 31;
pub const LOAD_GLOBAL_VAR_LAZY: u8 = 32;
pub const LOAD_GLOBAL_VAR_LAZY_WIDE: u8 = 33;
pub const LOAD_GLOBAL_VAR_DYNAMIC: u8 = 34;
pub const STORE_GLOBAL_VAR: u8 = 35;
pub const STORE_GLOBAL_VAR_WIDE: u8 = 36;
pub const STORE_GLOBAL_VAR_DYNAMIC: u8 = 37;
pub const LOAD_BLOCK: u8 = 38;
pub const LOAD_OUTER_BLOCK: u8 = 39;
pub const POP: u8 = 40;
pub const POP_1: u8 = 41;
pub const ALLOCATE: u8 = 42;
pub const ALLOCATE_WIDE: u8 = 43;
pub const IS_CLASS: u8 = 44;
pub const IS_CLASS_WIDE: u8 = 45;
pub const IS_INTERFACE: u8 = 46;
pub const IS_INTERFACE_WIDE: u8 = 47;
pub const AS_CLASS: u8 = 48;
pub const AS_CLASS_WIDE: u8 = 49;
pub const AS_INTERFACE: u8 = 50;
pub const AS_INTERFACE_WIDE: u8 = 51;
pub const AS_LOCAL: u8 = 52;
pub const INVOKE_STATIC: u8 = 53;
pub const INVOKE_STATIC_TAIL: u8 = 54;
pub const INVOKE_BLOCK: u8 = 55;
pub const INVOKE_LAMBDA_TAIL: u8 = 56;
pub const INVOKE_INITIALIZER_TAIL: u8 = 57;
pub const INVOKE_VIRTUAL: u8 = 58;
pub const INVOKE_VIRTUAL_WIDE: u8 = 59;
pub const INVOKE_VIRTUAL_GET: u8 = 60;
pub const INVOKE_VIRTUAL_SET: u8 = 61;
pub const INVOKE_EQ: u8 = 62;
pub const INVOKE_LT: u8 = 63;
pub const INVOKE_GT: u8 = 64;
pub const INVOKE_LTE: u8 = 65;
pub const INVOKE_GTE: u8 = 66;
pub const INVOKE_BIT_OR: u8 = 67;
pub const INVOKE_BIT_XOR: u8 = 68;
pub const INVOKE_BIT_AND: u8 = 69;
pub const INVOKE_BIT_SHL: u8 = 70;
pub const INVOKE_BIT_SHR: u8 = 71;
pub const INVOKE_BIT_USHR: u8 = 72;
pub const INVOKE_ADD: u8 = 73;
pub const INVOKE_SUB: u8 = 74;
pub const INVOKE_MUL: u8 = 75;
pub const INVOKE_DIV: u8 = 76;
pub const INVOKE_MOD: u8 = 77;
pub const INVOKE_AT: u8 = 78;
pub const INVOKE_AT_PUT: u8 = 79;
pub const INVOKE_SIZE: u8 = 80;
pub const BRANCH: u8 = 81;
pub const BRANCH_IF_TRUE: u8 = 82;
pub const BRANCH_IF_FALSE: u8 = 83;
pub const BRANCH_IF_NOT_NULL: u8 = 84;
pub const BRANCH_BACK: u8 = 85;
pub const BRANCH_BACK_IF_TRUE: u8 = 86;
pub const BRANCH_BACK_IF_FALSE: u8 = 87;
pub const BRANCH_BACK_IF_NOT_NULL: u8 = 88;
pub const PRIMITIVE: u8 = 89;
pub const THROW: u8 = 90;
pub const RETURN: u8 = 91;
pub const RETURN_NULL: u8 = 92;
pub const NON_LOCAL_RETURN: u8 = 93;
pub const NON_LOCAL_RETURN_WIDE: u8 = 94;
pub const NON_LOCAL_BRANCH: u8 = 95;
pub const IDENTICAL: u8 = 96;
pub const LINK: u8 = 97;
pub const UNLINK: u8 = 98;
pub const UNWIND: u8 = 99;
pub const HALT: u8 = 100;
pub const INTRINSIC_SMI_REPEAT: u8 = 101;
pub const INTRINSIC_ARRAY_DO: u8 = 102;
pub const INTRINSIC_HASH_FIND: u8 = 103;
pub const INTRINSIC_HASH_DO: u8 = 104;

/// Number of opcodes (`ILLEGAL_END`).
pub const OPCODE_COUNT: u8 = 105;

/// Instruction length in bytes, including the opcode (`*_LENGTH`).
pub open spec fn opcode_length(op: u8) -> int {
    if op == 1 || op == 8 || op == 12 || op == 21 || op == 27 || op == 31 || op == 33
        || op == 36 || op == 43 || op == 45 || op == 47 || op == 49 || op == 51
        || op == 53 || op == 57 || op == 60 || op == 61 || op == 80
        || (81 <= op && op <= 84) || op == 91 || op == 92 {
        3
    } else if op == 28 || op == 29 || op == 54 || op == 59 || (85 <= op && op <= 88)
        || op == 94 {
        5
    } else if op == 58 || op == 89 {
        4
    } else if op == 95 {
        6
    } else if (14 <= op && op <= 19) || op == 22 || op == 23 || op == 25 || op == 34
        || op == 37 || op == 41 || (62 <= op && op <= 79) || op == 96 || op == 99
        || (101 <= op && op <= 104) {
        1
    } else {
        2
    }
}

pub fn exec_opcode_length(op: u8) -> (r: usize)
    ensures r == opcode_length(op), 1 <= r <= 6,
{
    if op == 1 || op == 8 || op == 12 || op == 21 || op == 27 || op == 31 || op == 33
        || op == 36 || op == 43 || op == 45 || op == 47 || op == 49 || op == 51
        || op == 53 || op == 57 || op == 60 || op == 61 || op == 80
        || (81 <= op && op <= 84) || op == 91 || op == 92 {
        3
    } else if op == 28 || op == 29 || op == 54 || op == 59 || (85 <= op && op <= 88)
        || op == 94 {
        5
    } else if op == 58 || op == 89 {
        4
    } else if op == 95 {
        6
    } else if (14 <= op && op <= 19) || op == 22 || op == 23 || op == 25 || op == 34
        || op == 37 || op == 41 || (62 <= op && op <= 79) || op == 96 || op == 99
        || (101 <= op && op <= 104) {
        1
    } else {
        2
    }
}

} // verus!

/// Opcode names, in opcode order (for tracing and the table test).
pub const OPCODE_NAMES: [&str; 105] = [
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
    "THROW", "RETURN", "RETURN_NULL", "NON_LOCAL_RETURN", "NON_LOCAL_RETURN_WIDE",
    "NON_LOCAL_BRANCH", "IDENTICAL", "LINK", "UNLINK", "UNWIND", "HALT",
    "INTRINSIC_SMI_REPEAT", "INTRINSIC_ARRAY_DO", "INTRINSIC_HASH_FIND", "INTRINSIC_HASH_DO",
];

/// Lengths in opcode order, for the exec interpreter and the table test.
pub const OPCODE_LENGTHS: [u8; 105] = [
    2, 3, 2, 2, 2, 2, 2, 2, 3, 2, 2, 2, 3, 2, // 0..13
    1, 1, 1, 1, 1, 1, // LOAD_LOCAL_0..5
    2, 3, 1, 1, 2, 1, 2, 3, 5, 5, // 20..29
    2, 3, 2, 3, 1, 2, 3, 1, 2, 2, // 30..39
    2, 1, // POP, POP_1
    2, 3, // ALLOCATE
    2, 3, 2, 3, 2, 3, 2, 3, 2, // 44..52
    3, 5, 2, 2, 3, // 53..57
    4, 5, 3, 3, // 58..61
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, // 62..80
    3, 3, 3, 3, 5, 5, 5, 5, // 81..88
    4, 2, 3, 3, 2, 5, 6, 1, 2, 2, 1, 2, // 89..100
    1, 1, 1, 1, // 101..104
];
