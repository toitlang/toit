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

//! Binary64 classification and comparisons use verified bit operations.
//! Arithmetic, NaN payload conversions and libm calls still use trusted scalar
//! operations. The primitive differential test compares them with C++.

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

/// Use libm for sqrt and for the platform-specific NaN bits of directed rounding.
#[verifier::external_body]
#[inline(always)]
pub fn libm_unop(op: u8, x: u64) -> u64
    requires op == 1 || toit_spec::spec_helpers::is_nan_bits(x),
{
    let a = f64::from_bits(x);
    // The C library's functions (the core is no_std; the C++ primitives
    // call the same ones).
    let r = unsafe {
        match op {
            1 => libm::sqrt(a),
            2 => libm::ceil(a),
            3 => libm::floor(a),
            _ => libm::trunc(a),
        }
    };
    r.to_bits()
}

}  // verus!

mod libm {
    extern "C" {
        pub fn sqrt(x: f64) -> f64;
        pub fn ceil(x: f64) -> f64;
        pub fn floor(x: f64) -> f64;
        pub fn trunc(x: f64) -> f64;
    }
}

verus! {

/// 2 ceil, 3 floor, 4 trunc. All three preserve the sign of a zero result.
pub fn round_integral(op: u8, bits: u64) -> (r: u64)
    ensures toit_spec::v2::prim_core::integral_round_result(op, bits, r),
{
    let sign = bits & 0x8000_0000_0000_0000;
    let magnitude = bits & 0x7fff_ffff_ffff_ffff;
    let e = magnitude >> 52;
    if e >= 1075 {
        if crate::numbers::nan_bits(bits) {
            let native = libm_unop(op, bits);
            if crate::numbers::nan_bits(native) { return native; }
        }
        return bits;
    }
    assert(((bits >> 52) & 0x7ff) < 1075) by (bit_vector)
        requires e == (bits & 0x7fff_ffff_ffff_ffffu64) >> 52, e < 1075u64;
    if magnitude == 0 { return bits; }
    let away = (op == 2 && sign == 0) || (op == 3 && sign != 0);
    if e < 1023 { return sign | (if away { 0x3ff0_0000_0000_0000 } else { 0 }); }
    let unit = 1u64 << (1075 - e);
    assert(unit > 0) by (bit_vector)
        requires unit == 1u64 << 1075u64.wrapping_sub(e), 1023u64 <= e < 1075u64;
    let mask = unit - 1;
    let base = bits & !mask;
    if away && bits & mask != 0 { base.wrapping_add(unit) } else { base }
}

/// The comparisons `<`, `<=`, `>`, `>=`, `==` (ops 0..4).
#[inline(always)]
pub fn compare(op: u8, x: u64, y: u64) -> (r: bool)
    ensures r == toit_spec::v2::prim_core::binary64_compare(op, x, y),
{
    if crate::numbers::nan_bits(x) || crate::numbers::nan_bits(y) { return false; }
    let a = toit_spec::exec_step::x_binary64_rank(x);
    let b = toit_spec::exec_step::x_binary64_rank(y);
    match op {
        0 => a < b,
        1 => a <= b,
        2 => a > b,
        3 => a >= b,
        _ => a == b,
    }
}

/// `float_sign`: 1 for NaN, -1 if the sign bit is set, 0 for +0, else 1.
#[inline(always)]
pub fn sign(x: u64) -> (r: i64)
    ensures r == toit_spec::v2::prim_core::float_sign(x), -1 <= r <= 1,
{
    if crate::numbers::nan_bits(x) { 1 }
    else if x >> 63 == 1 { -1 }
    else if x == 0 { 0 }
    else { 1 }
}

#[inline(always)]
pub fn is_finite(x: u64) -> (r: bool)
    ensures r == toit_spec::v2::prim_core::finite_bits(x),
{
    ((x >> 52) & 0x7ff) != 0x7ff
}

/// Encode a signed integer as binary64, rounding halfway cases to even.
#[inline(always)]
pub fn from_int(i: i64) -> (r: u64)
    ensures r == toit_spec::v2::prim_core::integer_binary64(i),
{
    if i == 0 { return 0; }
    let magnitude = if i < 0 { 0u64.wrapping_sub(i as u64) } else { i as u64 };
    let shift = magnitude.leading_zeros();
    proof {
        assert(magnitude != 0) by (bit_vector)
            requires i != 0, magnitude == (if i < 0 { 0u64.wrapping_sub(i as u64) } else { i as u64 });
        vstd::std_specs::bits::axiom_u64_leading_zeros(magnitude);
    }
    let normalized = magnitude << shift;
    let retained = normalized >> 11;
    let discarded = normalized & 0x7ff;
    let increment = discarded > 0x400 || (discarded == 0x400 && retained & 1 == 1);
    let base = ((1085 - shift) as u64) << 52;
    assert(base <= 0x43d0_0000_0000_0000) by (bit_vector)
        requires shift < 64u32, base == ((1085u32.wrapping_sub(shift)) as u64) << 52;
    assert(retained <= 0x001f_ffff_ffff_ffff) by (bit_vector) requires retained == normalized >> 11;
    let unsigned = base + retained + (if increment { 1 } else { 0 });
    unsigned | ((i as u64) & 0x8000_0000_0000_0000)
}

/// `number_to_integer` of a double: None for NaN (INVALID_ARGUMENT),
/// Some(None) outside `[INT64_MIN, INT64_MAX)` (OUT_OF_RANGE), else the
/// truncated value.
#[inline(always)]
pub fn to_int(x: u64) -> (r: Option<Option<i64>>)
    ensures r == toit_spec::v2::prim_core::truncate_binary64(x),
{
    if crate::numbers::nan_bits(x) { return None; }
    if x == 0xc3e0_0000_0000_0000 { return Some(Some(i64::MIN)); }
    let exponent = (x >> 52) & 0x7ff;
    if exponent >= 1023 + 63 { return Some(None); }
    if exponent < 1023 { return Some(Some(0)); }
    let significand = (x & 0x000f_ffff_ffff_ffff) | (1u64 << 52);
    let magnitude = if exponent < 1023 + 52 {
        significand >> (1023 + 52 - exponent)
    } else {
        significand << (exponent - (1023 + 52))
    };
    assert(magnitude <= i64::MAX as u64) by (bit_vector)
        requires
            significand == (x & 0x000f_ffff_ffff_ffff) | (1u64 << 52),
            1023u64 <= exponent && exponent < 1086u64,
            magnitude == (if exponent < 1075u64 { significand >> 1075u64.wrapping_sub(exponent) }
                else { significand << exponent.wrapping_sub(1075u64) });
    let value = magnitude as i64;
    Some(Some(if x >> 63 == 0 { value } else { -value }))
}

/// Preserve the native sign and payload choice for a NaN.
#[verifier::external_body]
#[inline(always)]
fn native_narrow_nan(x: u64) -> u32 {
    (f64::from_bits(x) as f32).to_bits()
}

/// Round to binary32, including gradual underflow and carry into infinity.
#[inline(always)]
pub fn to_raw32(bits: u64) -> (r: u32)
    ensures toit_spec::v2::prim_core::narrowing_result(bits, r),
{
    let sign = ((bits >> 32) as u32) & 0x8000_0000;
    let e = (bits >> 52) & 0x7ff;
    if e < 873 { return sign; }
    if e > 1150 {
        if crate::numbers::nan_bits(bits) {
            let raw = native_narrow_nan(bits);
            if (raw & 0x7fff_ffff) > 0x7f80_0000 { return raw; }
            assert(toit_spec::v2::prim_core::binary32_nan(0x7fc0_0000)) by (compute);
            return 0x7fc0_0000;
        }
        return sign | 0x7f80_0000;
    }
    let sig = (bits & 0x000f_ffff_ffff_ffff) | (1u64 << 52);
    let shift = if e < 897 { 926 - e } else { 29 };
    let base = if e < 897 { 0u32 } else { ((e - 897) as u32) << 23 };
    let kept = sig >> shift;
    let half = 1u64 << (shift - 1);
    assert(0 < half <= 0x0010_0000_0000_0000) by (bit_vector)
        requires half == 1u64 << shift.wrapping_sub(1), 29u64 <= shift <= 53u64;
    let rest = sig & (2 * half - 1);
    let up = rest > half || (rest == half && kept & 1 == 1);
    // Rounding may carry from the significand into the exponent.
    assert(base <= 0x7e80_0000) by (bit_vector)
        requires e <= 1150u64, base == (if e < 897 { 0u32 } else { (e.wrapping_sub(897) as u32) << 23 });
    assert(kept <= 0x00ff_ffff) by (bit_vector)
        requires kept == sig >> shift, 29u64 <= shift <= 53u64,
            sig == (bits & 0x000f_ffff_ffff_ffff) | (1u64 << 52);
    sign | (base + (kept as u32) + (if up { 1 } else { 0 }))
}

/// Keep the target's choice of sign and payload when widening a NaN.
#[verifier::external_body]
#[inline(always)]
fn native_widen_nan(raw: u32) -> u64 {
    (f32::from_bits(raw) as f64).to_bits()
}

#[inline(always)]
pub fn from_raw32(raw: u32) -> (r: u64)
    ensures toit_spec::v2::prim_core::widening_result(raw, r),
{
    let sign = ((raw & 0x8000_0000) as u64) << 32;
    let exponent = (raw >> 23) & 0xff;
    let fraction = raw & 0x007f_ffff;
    assert(exponent <= 255) by (bit_vector) requires exponent == (raw >> 23) & 0xff;
    assert(toit_spec::v2::prim_core::binary32_nan(raw) == (exponent == 255 && fraction != 0)) by {
        assert(((raw & 0x7fff_ffff) > 0x7f80_0000) == (exponent == 255 && fraction != 0)) by (bit_vector)
            requires exponent == (raw >> 23) & 0xff, fraction == raw & 0x007f_ffff;
    }
    if exponent == 0 {
        if fraction == 0 { return sign; }
        let shift = fraction.leading_zeros();
        proof { vstd::std_specs::bits::axiom_u32_leading_zeros(fraction); }
        let mantissa = (((fraction << shift) & 0x7fff_ffff) as u64) << 21;
        return sign | (((905 - shift) as u64) << 52) | mantissa;
    }
    if exponent == 255 {
        if fraction == 0 { return sign | 0x7ff0_0000_0000_0000; }
        let bits = native_widen_nan(raw);
        if crate::numbers::nan_bits(bits) { return bits; }
        assert(toit_spec::spec_helpers::is_nan_bits(0x7ff8_0000_0000_0000)) by (compute);
        return 0x7ff8_0000_0000_0000;
    }
    sign | (((exponent + 896) as u64) << 52) | ((fraction as u64) << 29)
}

/// The VM comparison flags for two numeric primitive arguments.
pub fn compare_numbers(xi: bool, x: u64, yi: bool, y: u64) -> (r: u8)
    ensures r & 3 != 0,
        r == toit_spec::spec_helpers::compare_mixed(
            if xi { toit_spec::spec_helpers::Num::Int(x as i64 as int) } else { toit_spec::spec_helpers::Num::Dbl(x) },
            if yi { toit_spec::spec_helpers::Num::Int(y as i64 as int) } else { toit_spec::spec_helpers::Num::Dbl(y) }),
{
    use toit_spec::exec_step::{x_compare_mixed, XNum};
    let lhs = if xi { XNum::Int(x as i64) } else { XNum::Dbl(x) };
    let rhs = if yi { XNum::Int(y as i64) } else { XNum::Dbl(y) };
    x_compare_mixed(lhs, rhs)
}

} // verus!
