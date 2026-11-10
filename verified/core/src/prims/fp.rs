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

//! TRUSTED: IEEE-754 operations Verus has no model of (bit casts, the
//! libm functions, the mixed int/double comparison). Pure functions of
//! scalars: no memory access, no contract (the primitives' contracts do
//! not depend on float values; the spec leaves float operations
//! uninterpreted). Each is the Rust standard-library operation matching
//! the C function the C++ primitive calls (`fmod`, `sqrt`, ...); the
//! differential test compares them with the C++ results bit for bit.

use vstd::prelude::*;

verus! {

#[verifier::external_body]
#[inline(always)]
pub fn binop(op: u8, x: u64, y: u64) -> u64 {
    let (a, b) = (f64::from_bits(x), f64::from_bits(y));
    // Two NaN operands: x86 returns the first operand of the instruction,
    // quieted. IEEE leaves the payload open, and the compilers commute the
    // operands of + and * freely: the reference (gcc) build computes
    // `arg + receiver` and `arg * receiver` (found by prim_diff.sh), so
    // match it explicitly.
    if op <= 3 && a.is_nan() && b.is_nan() {
        let pick = if op == 0 || op == 2 { y } else { x };
        return pick | 0x0008_0000_0000_0000;
    }
    let r = match op {
        0 => a + b,
        1 => a - b,
        2 => a * b,
        3 => a / b,
        _ => a % b,  // fmod
    };
    r.to_bits()
}

/// 0 negate, 1 sqrt, 2 ceil, 3 floor, 4 trunc.
#[verifier::external_body]
#[inline(always)]
pub fn unop(op: u8, x: u64) -> u64 {
    let a = f64::from_bits(x);
    let r = match op {
        0 => -a,
        1 => a.sqrt(),
        2 => a.ceil(),
        3 => a.floor(),
        _ => a.trunc(),
    };
    r.to_bits()
}

/// The comparisons `<`, `<=`, `>`, `>=`, `==` (ops 0..4).
#[verifier::external_body]
#[inline(always)]
pub fn compare(op: u8, x: u64, y: u64) -> bool {
    let (a, b) = (f64::from_bits(x), f64::from_bits(y));
    match op {
        0 => a < b,
        1 => a <= b,
        2 => a > b,
        3 => a >= b,
        _ => a == b,
    }
}

/// `float_sign`: 1 for NaN, -1 if the sign bit is set, 0 for +0, else 1.
#[verifier::external_body]
#[inline(always)]
pub fn sign(x: u64) -> (r: i64)
    ensures -1 <= r <= 1,
{
    let a = f64::from_bits(x);
    if a.is_nan() { 1 } else if a.is_sign_negative() { -1 } else if a == 0.0 { 0 } else { 1 }
}

#[verifier::external_body]
#[inline(always)]
pub fn is_nan(x: u64) -> bool {
    f64::from_bits(x).is_nan()
}

#[verifier::external_body]
#[inline(always)]
pub fn is_finite(x: u64) -> bool {
    f64::from_bits(x).is_finite()
}

/// `(double) i`.
#[verifier::external_body]
#[inline(always)]
pub fn from_int(i: i64) -> u64 {
    (i as f64).to_bits()
}

/// `number_to_integer` of a double: None for NaN (INVALID_ARGUMENT),
/// Some(None) outside `[INT64_MIN, INT64_MAX)` (OUT_OF_RANGE), else the
/// truncated value.
#[verifier::external_body]
#[inline(always)]
pub fn to_int(x: u64) -> Option<Option<i64>> {
    let a = f64::from_bits(x);
    if a.is_nan() { return None; }
    if a < (i64::MIN as f64) || a >= (i64::MAX as f64) { return Some(None); }
    Some(Some(a as i64))
}

/// `bit_cast<uint32>(static_cast<float>(x))`.
#[verifier::external_body]
#[inline(always)]
pub fn to_raw32(x: u64) -> (r: u32) {
    (f64::from_bits(x) as f32).to_bits()
}

/// `bit_cast<float>(raw)` widened to double.
#[verifier::external_body]
#[inline(always)]
pub fn from_raw32(raw: u32) -> u64 {
    (f32::from_bits(raw) as f64).to_bits()
}

// The COMPARE_ constants of src/interpreter.h.
const SIMPLE_LESS: u8 = 29;
const SIMPLE_EQUAL: u8 = 114;
const SIMPLE_GREATER: u8 = 195;
const RESULT_MINUS_1: u8 = 1;
const RESULT_ZERO: u8 = 2;
const RESULT_PLUS_1: u8 = 3;
const FLAG_LESS_FOR_MIN: u8 = 4;
const FLAG_LESS_EQUAL: u8 = 16;
const FLAG_EQUAL: u8 = 32;
const FLAG_GREATER_EQUAL: u8 = 64;
const SHORTCUT_LIMIT: i64 = 0x20000000000000;

/// `Interpreter::compare_numbers` of two numbers (src/interpreter_core.cc;
/// the same as the checked core's `machine::compare_num`): the
/// COMPARE_RESULT and COMPARE_FLAG bits, never COMPARE_FAILED (0).
/// `xi`/`yi`: the operand is an integer (`x`/`y` its value as bits of an
/// i64), else a double (`x`/`y` its bits).
#[verifier::external_body]
pub fn compare_numbers(xi: bool, x: u64, yi: bool, y: u64) -> (r: u8)
    ensures r & 3 != 0,
{
    let (lhs_is_int, lhs_int, lhs) = if xi { (true, x as i64, x as i64 as f64) } else { (false, 0, f64::from_bits(x)) };
    let (rhs_is_int, rhs_int, rhs) = if yi { (true, y as i64, y as i64 as f64) } else { (false, 0, f64::from_bits(y)) };
    if lhs_is_int && rhs_is_int {
        return if lhs_int < rhs_int { SIMPLE_LESS } else if lhs_int == rhs_int { SIMPLE_EQUAL } else { SIMPLE_GREATER };
    }
    if lhs < rhs { return SIMPLE_LESS; }
    if lhs > rhs { return SIMPLE_GREATER; }
    if lhs != rhs {
        if lhs.is_nan() {
            if rhs.is_nan() { return RESULT_ZERO | FLAG_LESS_FOR_MIN; }
            return RESULT_PLUS_1 | FLAG_LESS_FOR_MIN;
        }
        return RESULT_MINUS_1;
    }
    if lhs == 0.0 {
        if lhs.is_sign_negative() == rhs.is_sign_negative() {
            return SIMPLE_EQUAL;
        } else if lhs.is_sign_negative() {
            return RESULT_MINUS_1 | FLAG_LESS_EQUAL | FLAG_EQUAL | FLAG_GREATER_EQUAL | FLAG_LESS_FOR_MIN;
        } else {
            return RESULT_PLUS_1 | FLAG_LESS_EQUAL | FLAG_EQUAL | FLAG_GREATER_EQUAL;
        }
    }
    if !lhs_is_int && !rhs_is_int { return SIMPLE_EQUAL; }
    let the_int = if lhs_is_int { lhs_int } else { rhs_int };
    if -SHORTCUT_LIMIT <= the_int && the_int <= SHORTCUT_LIMIT { return SIMPLE_EQUAL; }
    let the_double = if lhs_is_int { rhs } else { lhs };
    if the_double <= -9223372036854778e3 {
        return if lhs_is_int { SIMPLE_GREATER } else { SIMPLE_LESS };
    }
    if the_double >= 9223372036854776e3 {
        return if lhs_is_int { SIMPLE_LESS } else { SIMPLE_GREATER };
    }
    let other_int = the_double as i64;
    let c = if the_int < other_int { SIMPLE_LESS } else if the_int == other_int { SIMPLE_EQUAL } else { SIMPLE_GREATER };
    if lhs_is_int { c } else if c == SIMPLE_LESS { SIMPLE_GREATER } else if c == SIMPLE_GREATER { SIMPLE_LESS } else { c }
}

} // verus!
