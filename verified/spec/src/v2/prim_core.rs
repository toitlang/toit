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

//! Per-primitive contracts of the core primitives the verified core ports
//! to Rust (verified/core/src/prims). Definitions only: `core_contract`
//! is the refinement of `prim::prim_default` each ported primitive is
//! proven against (with `prim::prim_spec` itself). It is meant to become
//! the `else` branch of `prim::prim_refined`; until then the core proves
//! both.
//!
//! The contracts follow the C++ primitives (src/primitive_core.cc),
//! including the order in which `ARGS` decodes the arguments. Results are
//! `PrimRet` values; `OutOfMemory` appears only where the primitive
//! allocates.
//!
//! Note: `prim::array_at_put_spec` fails a program-heap array with
//! PERMISSION_DENIED before looking at the index; the C++ decodes the
//! index first (`ARGS(Array, int, Object)`), so a program-heap array with
//! a non-smi or out-of-range index fails with WRONG_OBJECT_TYPE or
//! OUT_OF_RANGE. `array_at_put_contract` states the C++ order.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::prim::*;

verus! {

// ---------------------------------------------------------------------------
// Indices of the core module (v2::prim_arity::PRIM_TABLE, src/primitive.h).

pub spec const I_STRING_LENGTH: int = 10;
pub spec const I_ARRAY_LENGTH: int = 13;
pub spec const I_ARRAY_AT: int = 14;
pub spec const I_ARRAY_AT_PUT: int = 15;
pub spec const I_SMI_UNARY_MINUS: int = 20;
pub spec const I_SMI_NOT: int = 21;
pub spec const I_SMI_AND: int = 22;
pub spec const I_SMI_OR: int = 23;
pub spec const I_SMI_XOR: int = 24;
pub spec const I_COUNT_LEADING_ZEROS: int = 39;
pub spec const I_POPCOUNT: int = 40;
pub spec const I_SMI_ADD: int = 51;
pub spec const I_SMI_SUBTRACT: int = 52;
pub spec const I_SMI_MULTIPLY: int = 53;
pub spec const I_SMI_DIVIDE: int = 54;
pub spec const I_SMI_LESS_THAN: int = 67;
pub spec const I_SMI_LESS_THAN_OR_EQUAL: int = 68;
pub spec const I_SMI_GREATER_THAN: int = 69;
pub spec const I_SMI_GREATER_THAN_OR_EQUAL: int = 70;
pub spec const I_SMI_MOD: int = 71;
pub spec const I_SMI_EQUALS: int = 82;
pub spec const I_SMI_SHIFT_RIGHT: int = 84;
pub spec const I_SMI_UNSIGNED_SHIFT_RIGHT: int = 85;
pub spec const I_SMI_SHIFT_LEFT: int = 86;
pub spec const I_OBJECT_CLASS_ID: int = 92;
pub spec const I_BYTE_ARRAY_LENGTH: int = 119;
pub spec const I_BYTE_ARRAY_AT: int = 120;
pub spec const I_BYTE_ARRAY_AT_PUT: int = 121;
pub spec const I_LARGE_INTEGER_UNARY_MINUS: int = 136;
pub spec const I_LARGE_INTEGER_NOT: int = 137;
pub spec const I_LARGE_INTEGER_AND: int = 138;
pub spec const I_LARGE_INTEGER_OR: int = 139;
pub spec const I_LARGE_INTEGER_XOR: int = 140;
pub spec const I_LARGE_INTEGER_SHIFT_RIGHT: int = 141;
pub spec const I_LARGE_INTEGER_UNSIGNED_SHIFT_RIGHT: int = 142;
pub spec const I_LARGE_INTEGER_SHIFT_LEFT: int = 143;
pub spec const I_LARGE_INTEGER_ADD: int = 144;
pub spec const I_LARGE_INTEGER_SUBTRACT: int = 145;
pub spec const I_LARGE_INTEGER_MULTIPLY: int = 146;
pub spec const I_LARGE_INTEGER_DIVIDE: int = 147;
pub spec const I_LARGE_INTEGER_MOD: int = 148;
pub spec const I_LARGE_INTEGER_EQUALS: int = 149;
pub spec const I_LARGE_INTEGER_LESS_THAN: int = 150;
pub spec const I_LARGE_INTEGER_LESS_THAN_OR_EQUAL: int = 151;
pub spec const I_LARGE_INTEGER_GREATER_THAN: int = 152;
pub spec const I_LARGE_INTEGER_GREATER_THAN_OR_EQUAL: int = 153;

pub spec const R_INVALID_ARGUMENT: int = 16;
pub spec const R_NEGATIVE_ARGUMENT: int = 19;
pub spec const R_DIVISION_BY_ZERO: int = 11;
pub spec const R_OUT_OF_BOUNDS: int = 20;
pub spec const R_OUT_OF_RANGE: int = 21;
pub spec const R_PERMISSION_DENIED: int = 25;
pub spec const R_WRONG_OBJECT_TYPE: int = 30;
pub spec const B_SMI: int = 18;

// ---------------------------------------------------------------------------
// Values.

/// The integer a value denotes: a smi or a large integer.
pub open spec fn int_val(h: Seq<HeapObj>, v: Value) -> Option<i64> {
    match v {
        Value::Smi(i) => Some(i),
        Value::Obj(id) => if (id as int) < h.len() && h[id as int].body is LargeInt {
            Some(h[id as int].body->LargeInt_0)
        } else {
            None
        },
        _ => None,
    }
}

/// The large integer a value denotes (the receiver of `large_integer_*`).
pub open spec fn large_val(h: Seq<HeapObj>, v: Value) -> Option<i64> {
    match v {
        Value::Obj(_) => int_val(h, v),
        _ => None,
    }
}

pub open spec fn smi_val(v: Value) -> Option<i64> {
    match v {
        Value::Smi(i) => Some(i),
        _ => None,
    }
}

/// The elements of the array a value refers to.
pub open spec fn array_val(h: Seq<HeapObj>, v: Value) -> Option<Seq<Value>> {
    match v {
        Value::Obj(id) => if (id as int) < h.len() && h[id as int].body is Array {
            Some(h[id as int].body->Array_0)
        } else {
            None
        },
        _ => None,
    }
}

/// The bytes of a string or byte array.
pub open spec fn bytes_of(o: HeapObj) -> Seq<u8> {
    match o.body {
        Body::Str(s) => s,
        Body::Bytes(b) => b,
        _ => Seq::empty(),
    }
}

/// A 64-bit smi.
pub open spec fn smi_in(z: i64) -> bool {
    -0x4000_0000_0000_0000 <= z <= 0x3fff_ffff_ffff_ffff
}

pub open spec fn bool_val(p: Program2, b: bool) -> Value {
    if b { p.roots[1] } else { p.roots[2] }
}

/// The primitive failed with root `k` and changed nothing.
pub open spec fn fails(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet, k: int) -> bool {
    h2 == h && r == PrimRet::Failure(p.roots[k])
}

// ---------------------------------------------------------------------------
// Integers.

pub spec const OP_ADD: u8 = 0;
pub spec const OP_SUB: u8 = 1;
pub spec const OP_MUL: u8 = 2;
pub spec const OP_DIV: u8 = 3;
pub spec const OP_MOD: u8 = 4;
pub spec const OP_AND: u8 = 5;
pub spec const OP_OR: u8 = 6;
pub spec const OP_XOR: u8 = 7;
pub spec const OP_SHR: u8 = 8;
pub spec const OP_USHR: u8 = 9;
pub spec const OP_SHL: u8 = 10;

/// The binary integer operations (64-bit, wrapping). `None`: the error
/// `int_err`. Division and modulo are specified only up to their error
/// (`Some(0)` stands for "some integer").
pub open spec fn int_op(op: u8, x: i64, y: i64) -> Option<i64> {
    if op == OP_ADD { Some(x.wrapping_add(y)) }
    else if op == OP_SUB { Some(x.wrapping_sub(y)) }
    else if op == OP_MUL { Some(x.wrapping_mul(y)) }
    else if op == OP_AND { Some(x & y) }
    else if op == OP_OR { Some(x | y) }
    else if op == OP_XOR { Some(x ^ y) }
    else if op == OP_SHR { if y < 0 { None } else if y >= 64 { Some(if x < 0 { -1i64 } else { 0i64 }) } else { Some(x >> (y as u64)) } }
    else if op == OP_USHR { if y < 0 { None } else if y >= 64 { Some(0) } else { Some(((x as u64) >> (y as u64)) as i64) } }
    else if op == OP_SHL { if y < 0 { None } else if y >= 64 { Some(0) } else { Some(((x as u64) << (y as u64)) as i64) } }
    else { if y == 0 { None } else { Some(0) } }
}

pub open spec fn int_err(op: u8) -> int {
    if op == OP_DIV || op == OP_MOD { R_DIVISION_BY_ZERO } else { R_NEGATIVE_ARGUMENT }
}

/// An integer result `z` (`Primitive::integer`): a smi if it fits (heap
/// unchanged), else a new large integer; out of memory only then.
/// `exact == false`: only "some integer" is specified.
pub open spec fn int_result(h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet, z: i64, exact: bool) -> bool {
    match r {
        PrimRet::Success(v) => int_val(h2, v) is Some
            && (exact ==> int_val(h2, v) == Some(z) && (smi_in(z) ==> h2 == h && v == Value::Smi(z))),
        PrimRet::Failure(_) => false,
        PrimRet::OutOfMemory(_) => !exact || !smi_in(z),
    }
}

/// `smi_add` .. `smi_shift_left` (`large == false`, a smi receiver) and
/// `large_integer_add` .. `large_integer_shift_left` (a large-integer
/// receiver): the argument is an integer.
pub open spec fn int_binop_contract(p: Program2, op: u8, large: bool, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> {
        let x = if large { large_val(h, args[0]) } else { smi_val(args[0]) };
        let y = int_val(h, args[1]);
        if x is None || y is None {
            fails(p, h, h2, r, R_WRONG_OBJECT_TYPE)
        } else {
            match int_op(op, x->Some_0, y->Some_0) {
                None => fails(p, h, h2, r, int_err(op)),
                Some(z) => int_result(h, h2, r, z, op != OP_DIV && op != OP_MOD),
            }
        }
    }
}

pub spec const CMP_LT: u8 = 0;
pub spec const CMP_LTE: u8 = 1;
pub spec const CMP_GT: u8 = 2;
pub spec const CMP_GTE: u8 = 3;
pub spec const CMP_EQ: u8 = 4;

pub open spec fn int_cmp(op: u8, x: i64, y: i64) -> bool {
    if op == CMP_LT { x < y } else if op == CMP_LTE { x <= y } else if op == CMP_GT { x > y }
    else if op == CMP_GTE { x >= y } else { x == y }
}

/// The integer comparisons.
pub open spec fn int_cmp_contract(p: Program2, op: u8, large: bool, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> {
        let x = if large { large_val(h, args[0]) } else { smi_val(args[0]) };
        let y = int_val(h, args[1]);
        if x is None || y is None {
            fails(p, h, h2, r, R_WRONG_OBJECT_TYPE)
        } else {
            h2 == h && r == PrimRet::Success(bool_val(p, int_cmp(op, x->Some_0, y->Some_0)))
        }
    }
}

pub spec const UN_NEG: u8 = 0;
pub spec const UN_NOT: u8 = 1;
pub spec const UN_CLZ: u8 = 2;
pub spec const UN_POPCOUNT: u8 = 3;

pub open spec fn popcount(x: u64, n: nat) -> nat
    decreases n,
{
    if n == 0 { 0 } else { (x % 2) as nat + popcount(x / 2, (n - 1) as nat) }
}

/// Negation, complement, population count (`count_leading_zeros` is
/// specified up to the result being an integer).
pub open spec fn unop_spec(op: u8, x: i64) -> i64 {
    if op == UN_NEG { 0i64.wrapping_sub(x) }
    else if op == UN_NOT { !x }
    else if op == UN_POPCOUNT { popcount(x as u64, 64) as i64 }
    else { 0 }
}

/// `smi_unary_minus`, `smi_not` (smi receiver), `large_integer_unary_minus`,
/// `large_integer_not` (large receiver), `count_leading_zeros`, `popcount`
/// (any integer).
pub open spec fn int_unop_contract(p: Program2, op: u8, large: bool, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> {
        let x = if op >= UN_CLZ { int_val(h, args[0]) }
            else if large { large_val(h, args[0]) } else { smi_val(args[0]) };
        match x {
            None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
            Some(x) => int_result(h, h2, r, unop_spec(op, x), op != UN_CLZ),
        }
    }
}

/// `object_class_id`.
pub open spec fn object_class_id_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> h2 == h && match args[0] {
        Value::Smi(_) => r == PrimRet::Success(Value::Smi(p.builtin[B_SMI] as i64)),
        Value::Obj(id) => (id as int) < h.len() ==> r == PrimRet::Success(Value::Smi(h[id as int].class_id as i64)),
        _ => true,
    }
}

// ---------------------------------------------------------------------------
// Arrays.

/// An `int` argument (`_A_T_int`): a smi in 32-bit range.
pub open spec fn int32_val(v: Value) -> Option<i64> {
    match v {
        Value::Smi(i) => if -0x8000_0000 <= i < 0x8000_0000 { Some(i) } else { None },
        _ => None,
    }
}

/// `array_length`.
pub open spec fn array_length_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> match array_val(h, args[0]) {
        None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
        Some(e) => h2 == h && r == PrimRet::Success(Value::Smi(e.len() as i64)),
    }
}

/// `array_at`: a non-array fails with WRONG_OBJECT_TYPE; an index that is
/// not an `int` fails (OUT_OF_RANGE or WRONG_OBJECT_TYPE); then the element
/// or OUT_OF_BOUNDS.
pub open spec fn array_at_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> match array_val(h, args[0]) {
        None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
        Some(e) => match int32_val(args[1]) {
            None => h2 == h && r is Failure,
            Some(i) => if 0 <= i < e.len() {
                h2 == h && r == PrimRet::Success(e[i as int])
            } else {
                fails(p, h, h2, r, R_OUT_OF_BOUNDS)
            },
        },
    }
}

/// `array_at_put` in the C++ order: array, index, program heap, bounds.
pub open spec fn array_at_put_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 3 ==> match args[0] {
        Value::Obj(id) => match array_val(h, args[0]) {
            None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
            Some(e) => match int32_val(args[1]) {
                None => h2 == h && r is Failure,
                Some(i) => if h[id as int].ro {
                    fails(p, h, h2, r, R_PERMISSION_DENIED)
                } else if 0 <= i < e.len() {
                    h2 == h.update(id as int, HeapObj { body: Body::Array(e.update(i as int, args[2])), ..h[id as int] })
                        && r == PrimRet::Success(args[2])
                } else {
                    fails(p, h, h2, r, R_OUT_OF_BOUNDS)
                },
            },
        },
        _ => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
    }
}

// ---------------------------------------------------------------------------
// Byte arrays and strings (only what holds whatever the representation:
// the model does not say which external byte arrays hold raw bytes).

/// `byte_array_at`: on success the byte at the index, heap unchanged.
pub open spec fn byte_array_at_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> match r {
        PrimRet::Success(v) => h2 == h && match (args[0], args[1]) {
            (Value::Obj(id), Value::Smi(i)) => (id as int) < h.len() && h[id as int].body is Bytes
                && 0 <= i < bytes_of(h[id as int]).len()
                && v == Value::Smi(bytes_of(h[id as int])[i as int] as i64),
            _ => false,
        },
        PrimRet::Failure(_) => h2 == h,
        PrimRet::OutOfMemory(_) => false,
    }
}

/// `byte_array_at_put`: on success the byte stored is the low byte of the
/// integer value, which is returned; only that byte changes.
pub open spec fn byte_array_at_put_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 3 ==> match r {
        PrimRet::Success(v) => match (args[0], args[1], int_val(h, args[2])) {
            (Value::Obj(id), Value::Smi(i), Some(x)) => (id as int) < h.len() && h[id as int].body is Bytes
                && !h[id as int].ro
                && 0 <= i < bytes_of(h[id as int]).len()
                && h2 == h.update(id as int, HeapObj {
                    body: Body::Bytes(bytes_of(h[id as int]).update(i as int, x as u8)), ..h[id as int] })
                && v == Value::Smi((x as u8) as i64),
            _ => false,
        },
        PrimRet::Failure(_) => h2 == h,
        PrimRet::OutOfMemory(_) => false,
    }
}

/// `string_length` of a string: its byte count.
pub open spec fn string_length_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> match args[0] {
        Value::Obj(id) => ((id as int) < h.len() && h[id as int].body is Str) ==>
            h2 == h && r == PrimRet::Success(Value::Smi(bytes_of(h[id as int]).len() as i64)),
        _ => true,
    }
}

// ---------------------------------------------------------------------------
// The table.

/// The precise contract of core primitive `index` where one is stated,
/// else `true` (the default contract only).
pub open spec fn core_contract(p: Program2, index: int, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    if index == I_SMI_ADD { int_binop_contract(p, OP_ADD, false, args, h, h2, r) }
    else if index == I_SMI_SUBTRACT { int_binop_contract(p, OP_SUB, false, args, h, h2, r) }
    else if index == I_SMI_MULTIPLY { int_binop_contract(p, OP_MUL, false, args, h, h2, r) }
    else if index == I_SMI_DIVIDE { int_binop_contract(p, OP_DIV, false, args, h, h2, r) }
    else if index == I_SMI_MOD { int_binop_contract(p, OP_MOD, false, args, h, h2, r) }
    else if index == I_SMI_AND { int_binop_contract(p, OP_AND, false, args, h, h2, r) }
    else if index == I_SMI_OR { int_binop_contract(p, OP_OR, false, args, h, h2, r) }
    else if index == I_SMI_XOR { int_binop_contract(p, OP_XOR, false, args, h, h2, r) }
    else if index == I_SMI_SHIFT_RIGHT { int_binop_contract(p, OP_SHR, false, args, h, h2, r) }
    else if index == I_SMI_UNSIGNED_SHIFT_RIGHT { int_binop_contract(p, OP_USHR, false, args, h, h2, r) }
    else if index == I_SMI_SHIFT_LEFT { int_binop_contract(p, OP_SHL, false, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_ADD { int_binop_contract(p, OP_ADD, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_SUBTRACT { int_binop_contract(p, OP_SUB, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_MULTIPLY { int_binop_contract(p, OP_MUL, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_DIVIDE { int_binop_contract(p, OP_DIV, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_MOD { int_binop_contract(p, OP_MOD, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_AND { int_binop_contract(p, OP_AND, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_OR { int_binop_contract(p, OP_OR, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_XOR { int_binop_contract(p, OP_XOR, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_SHIFT_RIGHT { int_binop_contract(p, OP_SHR, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_UNSIGNED_SHIFT_RIGHT { int_binop_contract(p, OP_USHR, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_SHIFT_LEFT { int_binop_contract(p, OP_SHL, true, args, h, h2, r) }
    else if index == I_SMI_LESS_THAN { int_cmp_contract(p, CMP_LT, false, args, h, h2, r) }
    else if index == I_SMI_LESS_THAN_OR_EQUAL { int_cmp_contract(p, CMP_LTE, false, args, h, h2, r) }
    else if index == I_SMI_GREATER_THAN { int_cmp_contract(p, CMP_GT, false, args, h, h2, r) }
    else if index == I_SMI_GREATER_THAN_OR_EQUAL { int_cmp_contract(p, CMP_GTE, false, args, h, h2, r) }
    else if index == I_SMI_EQUALS { int_cmp_contract(p, CMP_EQ, false, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_LESS_THAN { int_cmp_contract(p, CMP_LT, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_LESS_THAN_OR_EQUAL { int_cmp_contract(p, CMP_LTE, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_GREATER_THAN { int_cmp_contract(p, CMP_GT, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_GREATER_THAN_OR_EQUAL { int_cmp_contract(p, CMP_GTE, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_EQUALS { int_cmp_contract(p, CMP_EQ, true, args, h, h2, r) }
    else if index == I_SMI_UNARY_MINUS { int_unop_contract(p, UN_NEG, false, args, h, h2, r) }
    else if index == I_SMI_NOT { int_unop_contract(p, UN_NOT, false, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_UNARY_MINUS { int_unop_contract(p, UN_NEG, true, args, h, h2, r) }
    else if index == I_LARGE_INTEGER_NOT { int_unop_contract(p, UN_NOT, true, args, h, h2, r) }
    else if index == I_COUNT_LEADING_ZEROS { int_unop_contract(p, UN_CLZ, false, args, h, h2, r) }
    else if index == I_POPCOUNT { int_unop_contract(p, UN_POPCOUNT, false, args, h, h2, r) }
    else if index == I_OBJECT_CLASS_ID { object_class_id_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_LENGTH { array_length_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_AT { array_at_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_AT_PUT { array_at_put_contract(p, args, h, h2, r) }
    else if index == I_BYTE_ARRAY_AT { byte_array_at_contract(p, args, h, h2, r) }
    else if index == I_BYTE_ARRAY_AT_PUT { byte_array_at_put_contract(p, args, h, h2, r) }
    else if index == I_STRING_LENGTH { string_length_contract(p, args, h, h2, r) }
    else { true }
}

} // verus!
