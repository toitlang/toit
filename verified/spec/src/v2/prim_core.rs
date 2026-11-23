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
//! is the `else` branch of `prim::prim_refined` (core module), so it is
//! part of `prim::prim_spec`: every ported primitive is proven against it,
//! and every C++ primitive the core calls is assumed to satisfy it (the
//! core's leaf contract `gc_call_primitive`). The indices of the three
//! examples of `prim.rs` (array_at, array_at_put, smi_add) are refined
//! there, not here.
//!
//! The contracts follow the C++ primitives (src/primitive_core.cc),
//! including the order in which `ARGS` decodes the arguments. Results are
//! `PrimRet` values; `OutOfMemory` appears only where the primitive
//! allocates.

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
pub spec const I_ARRAY_NEW: int = 16;
pub spec const I_ARRAY_EXPAND: int = 17;
pub spec const I_ARRAY_REPLACE: int = 18;
pub spec const I_SMI_UNARY_MINUS: int = 20;
pub spec const I_SMI_NOT: int = 21;
pub spec const I_SMI_AND: int = 22;
pub spec const I_SMI_OR: int = 23;
pub spec const I_SMI_XOR: int = 24;
pub spec const I_COMPARE_TO: int = 31;
pub spec const I_MIN_SPECIAL_COMPARE_TO: int = 32;
pub spec const I_COUNT_LEADING_ZEROS: int = 39;
pub spec const I_POPCOUNT: int = 40;
pub spec const I_NUMBER_TO_FLOAT: int = 42;
pub spec const I_SMI_ADD: int = 51;
pub spec const I_SMI_SUBTRACT: int = 52;
pub spec const I_SMI_MULTIPLY: int = 53;
pub spec const I_SMI_DIVIDE: int = 54;
pub spec const I_FLOAT_UNARY_MINUS: int = 55;
pub spec const I_FLOAT_SIGN: int = 63;
pub spec const I_FLOAT_IS_NAN: int = 64;
pub spec const I_FLOAT_IS_FINITE: int = 65;
pub spec const I_SMI_LESS_THAN: int = 67;
pub spec const I_SMI_LESS_THAN_OR_EQUAL: int = 68;
pub spec const I_SMI_GREATER_THAN: int = 69;
pub spec const I_SMI_GREATER_THAN_OR_EQUAL: int = 70;
pub spec const I_FLOAT_LESS_THAN: int = 72;
pub spec const I_FLOAT_LESS_THAN_OR_EQUAL: int = 73;
pub spec const I_FLOAT_GREATER_THAN: int = 74;
pub spec const I_FLOAT_GREATER_THAN_OR_EQUAL: int = 75;
pub spec const I_FLOAT_EQUALS: int = 83;
pub spec const I_SMI_MOD: int = 71;
pub spec const I_SMI_EQUALS: int = 82;
pub spec const I_SMI_SHIFT_RIGHT: int = 84;
pub spec const I_SMI_UNSIGNED_SHIFT_RIGHT: int = 85;
pub spec const I_SMI_SHIFT_LEFT: int = 86;
pub spec const I_FLOAT_TO_RAW: int = 88;
pub spec const I_RAW_TO_FLOAT: int = 89;
pub spec const I_FLOAT_TO_RAW32: int = 90;
pub spec const I_RAW32_TO_FLOAT: int = 91;
pub spec const I_OBJECT_CLASS_ID: int = 92;
pub spec const I_NUMBER_TO_INTEGER: int = 93;
pub spec const I_FLOAT_CEIL: int = 95;
pub spec const I_FLOAT_FLOOR: int = 96;
pub spec const I_FLOAT_TRUNC: int = 97;
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
/// The smi range of the VM the primitive contracts are stated for: the
/// target the spec is compiled (and verified) for, whose `word_bits` the
/// programs it runs have (`smi_ok` with `word_bits` 64 resp. 32; the core
/// requires `word_bits == WORD_BITS`).
#[cfg(not(target_pointer_width = "32"))]
pub open spec fn smi_in(z: i64) -> bool {
    -0x4000_0000_0000_0000 <= z <= 0x3fff_ffff_ffff_ffff
}

#[cfg(target_pointer_width = "32")]
pub open spec fn smi_in(z: i64) -> bool {
    -0x4000_0000 <= z <= 0x3fff_ffff
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
/// `int_err`. The quotient truncates toward zero and wraps to 64 bits.
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
    else if y == 0 { None }
    else if op == OP_DIV {
        if x == i64::MIN && y == -1 { Some(i64::MIN) }
        else { Some(crate::spec_common::tdiv(x as int, y as int) as i64) }
    }
    else { Some(crate::spec_common::trem(x as int, y as int) as i64) }
}

pub open spec fn int_err(op: u8) -> int {
    if op == OP_DIV || op == OP_MOD { R_DIVISION_BY_ZERO } else { R_NEGATIVE_ARGUMENT }
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
                Some(z) => raw_integer_result(p, h, h2, r, z),
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

/// Negation, complement and bit counts use the full 64-bit representation.
pub open spec fn unop_spec(op: u8, x: i64) -> i64 {
    if op == UN_NEG { 0i64.wrapping_sub(x) }
    else if op == UN_NOT { !x }
    else if op == UN_POPCOUNT { popcount(x as u64, 64) as i64 }
    else { vstd::std_specs::bits::u64_leading_zeros(x as u64) as i64 }
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
            Some(x) => raw_integer_result(p, h, h2, r, unop_spec(op, x)),
        }
    }
}

/// The Toit primitive treats every NaN as positive and returns -1 for negative zero.
pub open spec fn float_sign(bits: u64) -> i64 {
    if crate::spec_helpers::is_nan_bits(bits) { 1 }
    else if bits >> 63 == 1 { (-1int) as i64 }
    else if bits == 0 { 0 }
    else { 1 }
}

pub open spec fn finite_bits(bits: u64) -> bool {
    ((bits >> 52) & 0x7ff) != 0x7ff
}

pub open spec fn binary64_compare(op: u8, x: u64, y: u64) -> bool {
    !crate::spec_helpers::is_nan_bits(x) && !crate::spec_helpers::is_nan_bits(y)
        && int_cmp(op, crate::spec_helpers::binary64_rank(x), crate::spec_helpers::binary64_rank(y))
}

pub open spec fn double_val(h: Seq<HeapObj>, v: Value) -> Option<u64> {
    if v is Obj && (v->Obj_0 as int) < h.len() && h[v->Obj_0 as int].body is Double {
        Some(h[v->Obj_0 as int].body->Double_0)
    } else { None }
}

pub open spec fn numeric_arg(h: Seq<HeapObj>, v: Value) -> Option<crate::spec_helpers::Num> {
    match int_val(h, v) {
        Some(i) => Some(crate::spec_helpers::Num::Int(i as int)),
        None => match double_val(h, v) {
            Some(d) => Some(crate::spec_helpers::Num::Dbl(d)), None => None,
        },
    }
}

pub open spec fn compare_to_contract(p: Program2, for_min: bool, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> match (numeric_arg(h, args[0]), numeric_arg(h, args[1])) {
        (Some(x), Some(y)) => {
            let flags = crate::spec_helpers::compare_mixed(x, y);
            h == h2 && r == PrimRet::Success(if for_min { bool_val(p, flags & 4 != 0) }
                else { Value::Smi(((flags & 3) as int - 2) as i64) })
        },
        _ => fails(p, h, h2, r, R_INVALID_ARGUMENT),
    }
}

/// A successful box appends exactly one writable object and returns its ID.
pub open spec fn boxed_result(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>,
    r: PrimRet, class: int, body: Body) -> bool
{
    match r {
        PrimRet::Success(v) => h2 == h.push(HeapObj { class_id: p.builtin[class], ro: false, body })
            && v == Value::Obj(h.len() as usize),
        PrimRet::OutOfMemory(e) => h2 == h && e == p.roots[ROOT_ALLOCATION_FAILED],
        _ => false,
    }
}

pub open spec fn raw_integer_result(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>,
    r: PrimRet, value: i64) -> bool
{
    if smi_in(value) { h2 == h && r == PrimRet::Success(Value::Smi(value)) }
    else { boxed_result(p, h, h2, r, crate::spec_common::LARGE_INTEGER_CLASS, Body::LargeInt(value)) }
}

/// Align the leading one at bit 63. The low 11 bits then decide whether
/// the retained 53-bit significand rounds up, including at an exact tie.
pub open spec fn integer_binary64(i: i64) -> u64 {
    if i == 0 { 0 } else {
        let magnitude = if i < 0 { 0u64.wrapping_sub(i as u64) } else { i as u64 };
        let shift = vstd::std_specs::bits::u64_leading_zeros(magnitude) as u32;
        let normalized = magnitude << shift;
        let retained = normalized >> 11;
        let discarded = normalized & 0x7ff;
        let increment = discarded > 0x400 || (discarded == 0x400 && retained & 1 == 1);
        // Adding the implicit bit supplies one exponent unit; a carry from
        // rounding the largest significand supplies another.
        let base = ((1085 - shift) as u64) << 52;
        let unsigned = (base + retained + (if increment { 1int } else { 0int })) as u64;
        unsigned | ((i as u64) & 0x8000_0000_0000_0000)
    }
}

pub open spec fn number_to_float_contract(p: Program2, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> {
        let bits = match int_val(h, args[0]) {
            Some(i) => Some(integer_binary64(i)),
            None => double_val(h, args[0]),
        };
        match bits {
            Some(b) => boxed_result(p, h, h2, r, crate::spec_common::DOUBLE_CLASS, Body::Double(b)),
            None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
        }
    }
}

/// Truncate binary64 to a signed 64-bit integer. The outer None denotes
/// NaN and the inner None denotes a value outside the signed range.
pub open spec fn truncate_binary64(bits: u64) -> Option<Option<i64>> {
    let exponent = (bits >> 52) & 0x7ff;
    if crate::spec_helpers::is_nan_bits(bits) { None }
    else if bits == 0xc3e0_0000_0000_0000 { Some(Some(i64::MIN)) }
    else if exponent >= 1086 { Some(None) }
    else if exponent < 1023 { Some(Some(0)) }
    else {
        let significand = (bits & 0x000f_ffff_ffff_ffff) | (1u64 << 52);
        let magnitude = if exponent < 1075 { significand >> ((1075 - exponent) as u64) }
            else { significand << ((exponent - 1075) as u64) };
        Some(Some((if bits >> 63 == 0 { magnitude as int } else { -(magnitude as int) }) as i64))
    }
}

pub open spec fn number_to_integer_contract(p: Program2, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> {
        let v = args[0];
        if int_val(h, v) is Some { h2 == h && r == PrimRet::Success(v) }
        else {
            match double_val(h, v) {
                None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
                Some(bits) => match truncate_binary64(bits) {
                    None => fails(p, h, h2, r, R_INVALID_ARGUMENT),
                    Some(None) => fails(p, h, h2, r, R_OUT_OF_RANGE),
                    Some(Some(i)) => raw_integer_result(p, h, h2, r, i),
                },
            }
        }
    }
}

pub open spec fn binary32_nan(raw: u32) -> bool {
    (raw & 0x7fff_ffff) > 0x7f80_0000
}

/// Exact widening for a number or infinity. NaN payloads are platform-dependent.
pub open spec fn widened_binary32(raw: u32) -> u64 {
    let sign = ((raw & 0x8000_0000) as u64) << 32;
    let exponent = (raw >> 23) & 0xff;
    let fraction = raw & 0x007f_ffff;
    if exponent == 0 {
        if fraction == 0 { sign } else {
            let shift = vstd::std_specs::bits::u32_leading_zeros(fraction);
            sign | (((905 - shift) as u64) << 52)
                | ((((fraction << shift) & 0x7fff_ffff) as u64) << 21)
        }
    } else if exponent == 255 { sign | 0x7ff0_0000_0000_0000 }
    else { sign | (((exponent + 896) as u64) << 52) | ((fraction as u64) << 29) }
}

/// Round binary64 numbers to binary32. In the subnormal range, one unit
/// in the retained significand is 2^-149. The implicit bit contributes
/// one exponent unit when the result is normal.
pub open spec fn narrowed_binary64(bits: u64) -> u32 {
    let sign = ((bits >> 32) as u32) & 0x8000_0000;
    let e = (bits >> 52) & 0x7ff;
    if e < 873 { sign }
    else if e > 1150 { sign | 0x7f80_0000 }
    else {
        let sig = (bits & 0x000f_ffff_ffff_ffff) | (1u64 << 52);
        let shift: u64 = if e < 897 { (926 - e) as u64 } else { 29 };
        let base = if e < 897 { 0u32 } else { ((e - 897) as u32) << 23 };
        let kept = sig >> shift;
        let half = 1u64 << ((shift - 1) as u64);
        let rest = sig & ((2 * half - 1) as u64);
        let up = rest > half || (rest == half && kept & 1 == 1);
        sign | ((base + kept + (if up { 1int } else { 0int })) as u32)
    }
}

pub open spec fn narrowing_result(bits: u64, raw: u32) -> bool {
    if crate::spec_helpers::is_nan_bits(bits) { binary32_nan(raw) }
    else { raw == narrowed_binary64(bits) }
}

pub open spec fn float_to_raw32_contract(p: Program2, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> match double_val(h, args[0]) {
        None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
        Some(bits) => exists|raw: u32| #[trigger] narrowing_result(bits, raw)
            && raw_integer_result(p, h, h2, r, raw as i64),
    }
}

pub open spec fn widening_result(raw: u32, bits: u64) -> bool {
    if binary32_nan(raw) { crate::spec_helpers::is_nan_bits(bits) }
    else { bits == widened_binary32(raw) }
}

pub open spec fn raw32_to_float_contract(p: Program2, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> match int_val(h, args[0]) {
        None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
        Some(i) => if i < 0 || i > 0xffff_ffff {
            fails(p, h, h2, r, R_OUT_OF_RANGE)
        } else {
            exists|bits: u64| #[trigger] widening_result(i as u32, bits)
                && boxed_result(p, h, h2, r, crate::spec_common::DOUBLE_CLASS, Body::Double(bits))
        },
    }
}

/// Round finite binary64 values to an integral binary64. The exponent
/// determines the encoded weight of one, including at a power-of-two carry.
pub open spec fn rounded_integral_bits(op: u8, bits: u64) -> u64 {
    let sign = bits & 0x8000_0000_0000_0000;
    let magnitude = bits & 0x7fff_ffff_ffff_ffff;
    let e = magnitude >> 52;
    let away = (op == 2 && sign == 0) || (op == 3 && sign != 0);
    if magnitude == 0 || e >= 1075 { bits }
    else if e < 1023 { sign | (if away { 0x3ff0_0000_0000_0000u64 } else { 0u64 }) }
    else {
        let unit = 1u64 << ((1075 - e) as u64);
        let mask = (unit - 1) as u64;
        let base = bits & !mask;
        if away && bits & mask != 0 { base.wrapping_add(unit) } else { base }
    }
}

pub open spec fn integral_round_result(op: u8, bits: u64, out: u64) -> bool {
    if crate::spec_helpers::is_nan_bits(bits) { crate::spec_helpers::is_nan_bits(out) }
    else { out == rounded_integral_bits(op, bits) }
}

pub open spec fn float_round_integral_contract(p: Program2, op: u8, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> match double_val(h, args[0]) {
        None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
        Some(bits) => exists|out: u64| #[trigger] integral_round_result(op, bits, out)
            && boxed_result(p, h, h2, r, crate::spec_common::DOUBLE_CLASS, Body::Double(out)),
    }
}

pub open spec fn float_bits_contract(p: Program2, index: int, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> {
        if index == I_RAW_TO_FLOAT {
            match int_val(h, args[0]) {
                Some(raw) => boxed_result(p, h, h2, r, crate::spec_common::DOUBLE_CLASS, Body::Double(raw as u64)),
                None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
            }
        } else {
            match double_val(h, args[0]) {
                None => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
                Some(bits) => if index == I_FLOAT_TO_RAW {
                    raw_integer_result(p, h, h2, r, bits as i64)
                } else {
                    boxed_result(p, h, h2, r, crate::spec_common::DOUBLE_CLASS,
                        Body::Double(bits ^ 0x8000_0000_0000_0000))
                },
            }
        }
    }
}

pub open spec fn float_cmp_contract(p: Program2, op: u8, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> match (double_val(h, args[0]), double_val(h, args[1])) {
        (Some(x), Some(y)) => h2 == h && r == PrimRet::Success(bool_val(p, binary64_compare(op, x, y))),
        _ => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
    }
}

pub open spec fn float_classify_contract(p: Program2, index: int, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 1 ==> {
        let v = args[0];
        if v is Obj && (v->Obj_0 as int) < h.len() && h[v->Obj_0 as int].body is Double {
            let bits = h[v->Obj_0 as int].body->Double_0;
            let result = if index == I_FLOAT_SIGN { Value::Smi(float_sign(bits)) }
                else {
                    let b = if index == I_FLOAT_IS_NAN { crate::spec_helpers::is_nan_bits(bits) }
                        else { finite_bits(bits) };
                    p.roots[if b { 1 } else { 2 }]
                };
            h2 == h && r == PrimRet::Success(result)
        } else {
            fails(p, h, h2, r, R_WRONG_OBJECT_TYPE)
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

/// Error returned by ARGS(int) when the operand cannot be decoded.
pub open spec fn int32_error(h: Seq<HeapObj>, v: Value) -> int {
    if int_val(h, v) is Some { R_OUT_OF_RANGE } else { R_WRONG_OBJECT_TYPE }
}

pub open spec fn array_new_contract(p: Program2, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> match int32_val(args[0]) {
        None => fails(p, h, h2, r, int32_error(h, args[0])),
        Some(n) => if n == 0 { h2 == h && r == PrimRet::Success(p.roots[crate::spec_common::EMPTY_ARRAY_ROOT]) }
            else if n < 0 { fails(p, h, h2, r, R_OUT_OF_BOUNDS) }
            else if n > crate::spec_common::ARRAYLET_SIZE { fails(p, h, h2, r, R_OUT_OF_RANGE) }
            else { boxed_result(p, h, h2, r, crate::spec_common::ARRAY_CLASS,
                Body::Array(Seq::new(n as nat, |i: int| args[1]))) },
    }
}

pub open spec fn array_expand_contract(p: Program2, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 4 ==> match (array_val(h, args[0]), args[1], args[2]) {
        (Some(src), Value::Smi(old_len), Value::Smi(n)) =>
            if n == 0 { h2 == h && r == PrimRet::Success(p.roots[crate::spec_common::EMPTY_ARRAY_ROOT]) }
            else if n < 0 { fails(p, h, h2, r, R_OUT_OF_BOUNDS) }
            else if n > crate::spec_common::ARRAYLET_SIZE || old_len < 0 || old_len > src.len() {
                fails(p, h, h2, r, R_OUT_OF_RANGE)
            } else { boxed_result(p, h, h2, r, crate::spec_common::ARRAY_CLASS,
                Body::Array(Seq::new(n as nat, |i: int| if i < old_len { src[i] } else { args[3] }))) },
        _ => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
    }
}

/// The source slice comes from the original heap even when both arguments refer to one array.
pub open spec fn array_replace_contract(p: Program2, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 5 ==> match (array_val(h, args[0]), args[1], array_val(h, args[2]), args[3], args[4]) {
        (Some(dst), Value::Smi(index), Some(src), Value::Smi(from), Value::Smi(to)) => {
            let end = index + to - from;
            let id = args[0]->Obj_0 as int;
            if index < 0 || from < 0 || from > to || to > src.len() || end > dst.len() {
                fails(p, h, h2, r, R_OUT_OF_BOUNDS)
            } else if h[id].ro { fails(p, h, h2, r, R_PERMISSION_DENIED) }
            else {
                let elements = dst.subrange(0, index as int) + src.subrange(from as int, to as int)
                    + dst.subrange(end, dst.len() as int);
                h2 == h.update(id, HeapObj { body: Body::Array(elements), ..h[id] })
                    && r == PrimRet::Success(p.roots[crate::spec_common::NULL_ROOT])
            }
        },
        _ => fails(p, h, h2, r, R_WRONG_OBJECT_TYPE),
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
            None => fails(p, h, h2, r, int32_error(h, args[1])),
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
                None => fails(p, h, h2, r, int32_error(h, args[1])),
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
// Byte arrays and strings. The model's byte arrays (`Body::Bytes`) are the
// internal ones and the external ones with raw bytes; a mapped file or a
// resource proxy has the byte-array class but is an opaque object of the
// model (verified/core/TRUSTED.md V5), so the contracts say nothing about
// its bytes.

/// `byte_array_at`: on success the byte at the index of a byte array of the
/// model (C++ also reads mapped files: any byte), heap unchanged.
pub open spec fn byte_array_at_contract(p: Program2, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    args.len() == 2 ==> match r {
        PrimRet::Success(v) => h2 == h && match (args[0], args[1]) {
            (Value::Obj(id), Value::Smi(i)) => (id as int) < h.len()
                && (h[id as int].body is Bytes ==>
                    0 <= i < bytes_of(h[id as int]).len()
                    && v == Value::Smi(bytes_of(h[id as int])[i as int] as i64)),
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
    else if I_FLOAT_CEIL <= index <= I_FLOAT_TRUNC {
        float_round_integral_contract(p, (index - I_FLOAT_CEIL + 2) as u8, args, h, h2, r)
    }
    else if index == I_FLOAT_TO_RAW32 { float_to_raw32_contract(p, args, h, h2, r) }
    else if index == I_RAW32_TO_FLOAT { raw32_to_float_contract(p, args, h, h2, r) }
    else if index == I_NUMBER_TO_FLOAT { number_to_float_contract(p, args, h, h2, r) }
    else if index == I_NUMBER_TO_INTEGER { number_to_integer_contract(p, args, h, h2, r) }
    else if index == I_FLOAT_UNARY_MINUS || index == I_FLOAT_TO_RAW || index == I_RAW_TO_FLOAT {
        float_bits_contract(p, index, args, h, h2, r)
    }
    else if index == I_FLOAT_LESS_THAN { float_cmp_contract(p, CMP_LT, args, h, h2, r) }
    else if index == I_FLOAT_LESS_THAN_OR_EQUAL { float_cmp_contract(p, CMP_LTE, args, h, h2, r) }
    else if index == I_FLOAT_GREATER_THAN { float_cmp_contract(p, CMP_GT, args, h, h2, r) }
    else if index == I_FLOAT_GREATER_THAN_OR_EQUAL { float_cmp_contract(p, CMP_GTE, args, h, h2, r) }
    else if index == I_COMPARE_TO || index == I_MIN_SPECIAL_COMPARE_TO {
        compare_to_contract(p, index == I_MIN_SPECIAL_COMPARE_TO, args, h, h2, r)
    }
    else if index == I_FLOAT_EQUALS { float_cmp_contract(p, CMP_EQ, args, h, h2, r) }
    else if index == I_FLOAT_SIGN || index == I_FLOAT_IS_NAN || index == I_FLOAT_IS_FINITE {
        float_classify_contract(p, index, args, h, h2, r)
    }
    else if index == I_OBJECT_CLASS_ID { object_class_id_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_NEW { array_new_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_EXPAND { array_expand_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_REPLACE { array_replace_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_LENGTH { array_length_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_AT { array_at_contract(p, args, h, h2, r) }
    else if index == I_ARRAY_AT_PUT { array_at_put_contract(p, args, h, h2, r) }
    else if index == I_BYTE_ARRAY_AT { byte_array_at_contract(p, args, h, h2, r) }
    else if index == I_BYTE_ARRAY_AT_PUT { byte_array_at_put_contract(p, args, h, h2, r) }
    else if index == I_STRING_LENGTH { string_length_contract(p, args, h, h2, r) }
    else { true }
}

} // verus!
