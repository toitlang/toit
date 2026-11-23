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

//! Spec versions of the interpreter helpers in `src/interpreter_core.cc`
//! and `src/interpreter_run.cc`: number comparison, floating point,
//! type checks, `fast_at`, `fast_size`, `hash_do`, `hash_find`.

use vstd::prelude::*;
use crate::types::*;
use crate::spec_common::*;

verus! {

// ---------------------------------------------------------------------------
// Floating point. IEEE-754 arithmetic operations
// are uninterpreted in the spec; the interpreter implements them with the
// host's f64 (trusted, see DESIGN.md).

pub uninterp spec fn double_add(a: u64, b: u64) -> u64;
pub uninterp spec fn double_sub(a: u64, b: u64) -> u64;
pub uninterp spec fn double_mul(a: u64, b: u64) -> u64;

pub enum Num {
    Int(int),
    Dbl(u64),
}

pub open spec fn is_nan_bits(bits: u64) -> bool {
    ((bits >> 52u64) & 0x7ffu64) == 0x7ffu64 && (bits & 0xf_ffff_ffff_ffffu64) != 0
}

// Compare flags (interpreter.h).
pub const COMPARE_FLAG_STRICTLY_LESS: u8 = 8;
pub const COMPARE_FLAG_LESS_EQUAL: u8 = 16;
pub const COMPARE_FLAG_EQUAL: u8 = 32;
pub const COMPARE_FLAG_GREATER_EQUAL: u8 = 64;
pub const COMPARE_FLAG_STRICTLY_GREATER: u8 = 128;
pub const SIMPLE_LESS: u8 = 29;
pub const SIMPLE_EQUAL: u8 = 114;
pub const SIMPLE_GREATER: u8 = 195;

pub open spec fn compare_ints(a: int, b: int) -> u8 {
    if a < b { SIMPLE_LESS } else if a == b { SIMPLE_EQUAL } else { SIMPLE_GREATER }
}

/// Non-NaN encodings increase with magnitude. Applying the sign orders
/// negatives in reverse and maps both encodings of zero to the same rank.
pub open spec fn binary64_rank(bits: u64) -> i64 {
    let magnitude = (bits & 0x7fff_ffff_ffff_ffff) as int;
    (if bits >> 63 == 0 { magnitude } else { -magnitude }) as i64
}

/// Order an unsigned integer and the absolute value of a nonnegative binary64
/// encoding. Below 2^52, a fractional remainder breaks a tie with the integer part.
pub open spec fn magnitude_order(i: u64, d: u64) -> int {
    let e = d >> 52;
    let sig = (d & 0x000f_ffff_ffff_ffff) | (1u64 << 52);
    if d == 0 { i as int }
    else if e < 1023 { if i == 0 { -1 } else { 1 } }
    else if e >= 1087 { -1 }
    else if e >= 1075 { i as int - (sig << (e - 1075)) as int }
    else {
        let shift = (1075 - e) as u64;
        let whole = sig >> shift;
        if i == whole && sig != whole << shift { -1 } else { i as int - whole as int }
    }
}

pub open spec fn order_flags(order: int) -> u8 {
    compare_ints(order, 0)
}

/// Opposite signed zeros are relationally equal (bits 4, 5 and 6).
/// The low two bits order -0 before +0, and bit 2 selects -0 for min.
pub open spec fn zero_flags(lhs_negative: bool, rhs_negative: bool) -> u8 {
    if lhs_negative == rhs_negative { SIMPLE_EQUAL }
    else if lhs_negative { 117 } else { 115 }
}

pub open spec fn int_double_flags(i: i64, d: u64, int_first: bool) -> u8 {
    let mag = d & 0x7fff_ffff_ffff_ffff;
    let neg = d >> 63 != 0;
    if is_nan_bits(d) { if int_first { 1 } else { 7 } }
    else if i == 0 && mag == 0 { zero_flags(!int_first && neg, int_first && neg) }
    else {
        let order = if (i < 0) != neg { if i < 0 { -1int } else { 1int } }
            else {
                let abs_i = if i < 0 { 0u64.wrapping_sub(i as u64) } else { i as u64 };
                let m = magnitude_order(abs_i, mag);
                if neg { -m } else { m }
            };
        order_flags(if int_first { order } else { -order })
    }
}

/// For NaNs the relational flags are clear. The low bits order every NaN
/// after ordinary numbers and tie two NaNs. For min, a left NaN sets bit 2.
pub open spec fn compare_mixed(a: Num, b: Num) -> u8 {
    match (a, b) {
        (Num::Int(x), Num::Int(y)) => compare_ints(x, y),
        (Num::Int(i), Num::Dbl(d)) => int_double_flags(i as i64, d, true),
        (Num::Dbl(d), Num::Int(i)) => int_double_flags(i as i64, d, false),
        (Num::Dbl(x), Num::Dbl(y)) => {
            if is_nan_bits(x) { if is_nan_bits(y) { 6 } else { 7 } }
            else if is_nan_bits(y) { 1 }
            else {
                let a = binary64_rank(x);
                let b = binary64_rank(y);
                if a == b { zero_flags(x >> 63 != 0, y >> 63 != 0) }
                else { compare_ints(a as int, b as int) }
            }
        },
    }
}

pub open spec fn num_of(s: State, v: Value) -> Option<Num> {
    match v {
        Value::Smi(i) => Some(Num::Int(i as int)),
        Value::Obj(_) => {
            if is_large_int(s, v) {
                Some(Num::Int(large_int(s, v)))
            } else if is_double(s, v) {
                Some(Num::Dbl(double_bits(s, v)))
            } else {
                None
            }
        },
        _ => None,
    }
}

/// `Interpreter::compare_numbers`: 0 means "not two numbers".
pub open spec fn compare_numbers(s: State, a: Value, b: Value) -> u8 {
    match (num_of(s, a), num_of(s, b)) {
        (Some(Num::Int(x)), Some(Num::Int(y))) => compare_ints(x, y),
        (Some(x), Some(y)) => compare_mixed(x, y),
        _ => 0,
    }
}

pub open spec fn are_smis(a: Value, b: Value) -> bool {
    a is Smi && b is Smi
}

pub open spec fn smi_val(v: Value) -> int {
    match v {
        Value::Smi(i) => i as int,
        _ => 0,
    }
}

pub open spec fn are_floats(s: State, a: Value, b: Value) -> bool {
    is_double(s, a) && is_double(s, b)
}

/// Bitwise and of two smi values (two's complement).
pub open spec fn band(a: int, b: int) -> int {
    ((a as i64) & (b as i64)) as int
}

// ---------------------------------------------------------------------------
// IDENTICAL.

pub open spec fn identical(s: State, a: Value, b: Value) -> bool {
    if a == b {
        true
    } else if is_double(s, a) && is_double(s, b) {
        double_bits(s, a) == double_bits(s, b)
    } else if is_large_int(s, a) && is_large_int(s, b) {
        large_int(s, a) == large_int(s, b)
    } else if is_string(s, a) && is_string(s, b) {
        str_bytes(s, a) == str_bytes(s, b)
    } else {
        false
    }
}

// ---------------------------------------------------------------------------
// Type checks.

pub enum Check {
    Yes,
    No,
    Stuck(Stuck),
}

pub open spec fn check(b: bool) -> Check {
    if b { Check::Yes } else { Check::No }
}

/// `Interpreter::typecheck_class`.
pub open spec fn typecheck_class(p: Program, s: State, v: Value, ci: int, nullable: bool) -> Check {
    if nullable && v == null_v(p) {
        Check::Yes
    } else if !class_id_ok(s, v) {
        Check::Stuck(Stuck::NotObject)
    } else if !(0 <= 2 * ci + 1 < p.class_check_ids.len()) {
        Check::Stuck(Stuck::TableRange)
    } else {
        let cid = class_id_of(p, s, v);
        check(p.class_check_ids[2 * ci] as int <= cid && cid < p.class_check_ids[2 * ci + 1] as int)
    }
}

/// `Interpreter::typecheck_interface`.
pub open spec fn typecheck_interface(p: Program, s: State, v: Value, ii: int, nullable: bool) -> Check {
    if nullable && v == null_v(p) {
        Check::Yes
    } else if !(0 <= ii < p.interface_check_offsets.len()) {
        Check::Stuck(Stuck::TableRange)
    } else {
        match find_method(p, s, v, p.interface_check_offsets[ii] as int) {
            Lookup::Found(_) => Check::Yes,
            Lookup::Missing => Check::No,
            Lookup::Stuck(r) => Check::Stuck(r),
        }
    }
}

// ---------------------------------------------------------------------------
// fast_at / fast_size (interpreter_core.cc).

pub enum FastAt {
    /// The fast path does not apply; fall back to a virtual call.
    Fail,
    Get(Value),
    /// The element was stored; the new state and the value to push.
    Put(State, Value),
    Stuck(Stuck),
}

/// Recursion bound for nested large arrays (each level shrinks the size, so
/// 8 levels cover every array that fits in memory).
pub spec const FAST_AT_FUEL: nat = 8;

pub open spec fn array_at(s: State, arr: Value, length: int, n: int, is_put: bool, value: Value) -> FastAt {
    if n >= length || n >= elements(s, arr).len() {
        FastAt::Fail
    } else if is_put {
        if obj(s, arr).ro {
            FastAt::Stuck(Stuck::ReadOnly)
        } else {
            let o = obj(s, arr);
            FastAt::Put(
                set_obj(s, obj_id(arr), HeapObj { body: Body::Array(elements(s, arr).update(n, value)), ..o }),
                value,
            )
        }
    } else {
        FastAt::Get(elements(s, arr)[n])
    }
}

pub open spec fn bytes_at(s: State, ba: Value, n: int, is_put: bool, value: Value) -> FastAt {
    if n >= bytes(s, ba).len() {
        FastAt::Fail
    } else if is_put {
        match value {
            Value::Smi(v) => {
                if obj(s, ba).ro {
                    FastAt::Stuck(Stuck::ReadOnly)
                } else {
                    let b = (v as int) % 256;
                    let o = obj(s, ba);
                    FastAt::Put(
                        set_obj(s, obj_id(ba), HeapObj { body: Body::Bytes(bytes(s, ba).update(n, b as u8)), ..o }),
                        smi(b),
                    )
                }
            },
            _ => FastAt::Fail,
        }
    } else {
        FastAt::Get(smi(bytes(s, ba)[n] as int))
    }
}

/// Copy-on-write byte array backing (used for slices and directly).
pub open spec fn cow_at(p: Program, s: State, cow: Value, n: int, is_put: bool, value: Value) -> FastAt {
    let f = fields(s, cow);
    if f.len() < 2 {
        FastAt::Stuck(Stuck::FieldRange)
    } else if is_put && f[1] == false_v(p) {
        FastAt::Fail
    } else if !is_bytes(s, f[0]) {
        FastAt::Fail
    } else {
        bytes_at(s, f[0], n, is_put, value)
    }
}

pub open spec fn fast_at(p: Program, s: State, recv: Value, arg: Value, is_put: bool, value: Value, fuel: nat) -> FastAt
    decreases fuel,
{
    match arg {
        Value::Smi(a) => {
            let n = a as int;
            if n < 0 {
                FastAt::Fail
            } else if is_instance(s, recv) {
                let cid = class_of_obj(s, recv);
                let f = fields(s, recv);
                if cid == builtin(p, LIST_CLASS) && f.len() < 2 {
                    FastAt::Stuck(Stuck::FieldRange)
                } else if cid == builtin(p, LIST_CLASS) && is_array(s, f[0]) {
                    match f[1] {
                        Value::Smi(size) => {
                            if size as int > elements(s, f[0]).len() {
                                FastAt::Fail
                            } else {
                                array_at(s, f[0], size as int, n, is_put, value)
                            }
                        },
                        _ => FastAt::Fail,
                    }
                } else if cid == builtin(p, BYTE_ARRAY_SLICE_CLASS) {
                    if f.len() < 3 {
                        FastAt::Stuck(Stuck::FieldRange)
                    } else {
                        match (f[1], f[2]) {
                            (Value::Smi(from), Value::Smi(to)) => {
                                let m = from as int + n;
                                if from < 0 || m >= to as int {
                                    FastAt::Fail
                                } else if is_bytes(s, f[0]) {
                                    bytes_at(s, f[0], m, is_put, value)
                                } else if is_instance(s, f[0]) {
                                    if class_of_obj(s, f[0]) != builtin(p, BYTE_ARRAY_COW_CLASS) {
                                        FastAt::Fail
                                    } else {
                                        cow_at(p, s, f[0], m, is_put, value)
                                    }
                                } else {
                                    FastAt::Fail
                                }
                            },
                            _ => FastAt::Fail,
                        }
                    }
                } else if cid == builtin(p, LARGE_ARRAY_CLASS) || cid == builtin(p, LIST_CLASS) {
                    if f.len() < 2 {
                        FastAt::Stuck(Stuck::FieldRange)
                    } else {
                        // List backed by a large array, or a large array.
                        let la = if cid == builtin(p, LARGE_ARRAY_CLASS) { recv } else { f[0] };
                        let size_obj = if cid == builtin(p, LARGE_ARRAY_CLASS) { f[0] } else { f[1] };
                        if !is_instance(s, la) || class_of_obj(s, la) != builtin(p, LARGE_ARRAY_CLASS) {
                            FastAt::Fail
                        } else if fields(s, la).len() < 2 {
                            FastAt::Stuck(Stuck::FieldRange)
                        } else {
                            let vector = fields(s, la)[1];
                            match size_obj {
                                Value::Smi(size) => {
                                    let vector_ok = is_array(s, vector) || (
                                        is_instance(s, vector)
                                        && class_of_obj(s, vector) == builtin(p, LARGE_ARRAY_CLASS)
                                        && fields(s, vector).len() >= 1
                                        && fields(s, vector)[0] is Smi
                                        && smi_val(fields(s, vector)[0]) < size as int);
                                    if n >= size as int || !vector_ok {
                                        FastAt::Fail
                                    } else if fuel == 0 {
                                        FastAt::Stuck(Stuck::OutOfFuel)
                                    } else {
                                        match fast_at(p, s, vector, smi(n / ARRAYLET_SIZE), false, value, (fuel - 1) as nat) {
                                            FastAt::Get(arraylet) => {
                                                if !is_array(s, arraylet) {
                                                    FastAt::Fail
                                                } else {
                                                    fast_at(p, s, arraylet, smi(n % ARRAYLET_SIZE), is_put, value, (fuel - 1) as nat)
                                                }
                                            },
                                            FastAt::Stuck(r) => FastAt::Stuck(r),
                                            _ => FastAt::Fail,
                                        }
                                    }
                                },
                                _ => FastAt::Fail,
                            }
                        }
                    }
                } else if cid == builtin(p, BYTE_ARRAY_COW_CLASS) {
                    cow_at(p, s, recv, n, is_put, value)
                } else {
                    FastAt::Fail
                }
            } else if is_bytes(s, recv) {
                bytes_at(s, recv, n, is_put, value)
            } else if is_array(s, recv) {
                array_at(s, recv, elements(s, recv).len() as int, n, is_put, value)
            } else {
                FastAt::Fail
            }
        },
        _ => FastAt::Fail,
    }
}

/// `Interpreter::fast_size`; `None` means fall back.
pub open spec fn fast_size(p: Program, s: State, recv: Value) -> Option<int> {
    if is_instance(s, recv) {
        let cid = class_of_obj(s, recv);
        let f = fields(s, recv);
        if cid == builtin(p, LIST_CLASS) && f.len() >= 2 {
            if f[1] is Smi { Some(smi_val(f[1])) } else { None }
        } else if cid == builtin(p, BYTE_ARRAY_SLICE_CLASS) && f.len() >= 3 {
            if f[1] is Smi && f[2] is Smi && 0 <= smi_val(f[1]) <= smi_val(f[2]) {
                Some(smi_val(f[2]) - smi_val(f[1]))
            } else {
                None
            }
        } else if cid == builtin(p, LARGE_ARRAY_CLASS) && f.len() >= 1 {
            if f[0] is Smi { Some(smi_val(f[0])) } else { None }
        } else if cid == builtin(p, BYTE_ARRAY_COW_CLASS) && f.len() >= 1 {
            if is_bytes(s, f[0]) { Some(bytes(s, f[0]).len() as int) } else { None }
        } else {
            None
        }
    } else if is_bytes(s, recv) {
        Some(bytes(s, recv).len() as int)
    } else if is_array(s, recv) {
        Some(elements(s, recv).len() as int)
    } else {
        None
    }
}

/// Field-count precondition of `fast_size` that the C++ code does not
/// check (builtin classes always have enough fields when the program tables
/// are well formed).
pub open spec fn fast_size_fields_ok(p: Program, s: State, recv: Value) -> bool {
    is_instance(s, recv) ==> {
        let cid = class_of_obj(s, recv);
        let n = fields(s, recv).len();
        (cid == builtin(p, LIST_CLASS) ==> n >= 2)
        && (cid == builtin(p, BYTE_ARRAY_SLICE_CLASS) ==> n >= 3)
        && (cid == builtin(p, LARGE_ARRAY_CLASS) ==> n >= 1)
        && (cid == builtin(p, BYTE_ARRAY_COW_CLASS) ==> n >= 1)
    }
}

// ---------------------------------------------------------------------------
// hash_do (interpreter_core.cc).

pub enum HashDo {
    Stuck(Stuck),
    /// Return from the surrounding method with this value.
    Return(State, Value),
    /// Call the block with the entry at backing index `c`.
    Call(State, int, Value),
}

/// Loop bound standing in for "the C++ loop terminates": the index moves
/// monotonically through the backing, so any real collection finishes far
/// earlier.
pub spec const HASH_FUEL: nat = 0x1_0000_0000;

pub open spec fn hash_do_loop(
    p: Program, s: State, backing: Value, step: int, c: int,
    first_tombstone: int, first_obj: Value, skipped: int, fuel: nat,
) -> HashDo
    decreases fuel,
{
    if fuel == 0 {
        HashDo::Stuck(Stuck::OutOfFuel)
    } else if !smi_ok(p, c) {
        HashDo::Stuck(Stuck::SmiRange)
    } else {
        match fast_at(p, s, backing, smi(c), false, null_v(p), FAST_AT_FUEL) {
            FastAt::Stuck(r) => HashDo::Stuck(r),
            FastAt::Get(entry) => {
                if !class_id_ok(s, entry) {
                    HashDo::Stuck(Stuck::NotObject)
                } else if entry is Smi || class_of_obj(s, entry) != builtin(p, TOMBSTONE_CLASS) {
                    if first_tombstone != -1 && skipped > 10 {
                        if !is_instance(s, first_obj) || fields(s, first_obj).len() < 1 {
                            HashDo::Stuck(Stuck::FieldRange)
                        } else {
                            let distance = fields(s, first_obj)[0];
                            let new_distance = c - first_tombstone;
                            if !(distance is Smi) || distance == smi(0) || !smi_ok(p, new_distance) {
                                HashDo::Return(s, smi(first_tombstone))
                            } else if obj(s, first_obj).ro {
                                HashDo::Stuck(Stuck::ReadOnly)
                            } else {
                                HashDo::Call(set_field(s, first_obj, 0, smi(new_distance)), c, entry)
                            }
                        }
                    } else {
                        HashDo::Call(s, c, entry)
                    }
                } else if !is_instance(s, entry) || fields(s, entry).len() < 1 {
                    HashDo::Stuck(Stuck::FieldRange)
                } else {
                    let ft = if first_tombstone == -1 { c } else { first_tombstone };
                    let fo = if first_tombstone == -1 { entry } else { first_obj };
                    let sk = if first_tombstone == -1 { 0 } else { skipped + 1 };
                    let skip = fields(s, entry)[0];
                    if skip is Smi && smi_val(skip) != 0 && ((smi_val(skip) >= 0) == (step >= 0)) {
                        hash_do_loop(p, s, backing, step, c + smi_val(skip), ft, fo, sk, (fuel - 1) as nat)
                    } else {
                        hash_do_loop(p, s, backing, step, c + step, ft, fo, sk, (fuel - 1) as nat)
                    }
                }
            },
            _ => HashDo::Return(s, null_v(p)),
        }
    }
}

/// First entry: decide the start index and check the block's arity.
pub open spec fn hash_do_start(p: Program, s: State, backing: Value, step: int, block: Value, c: int) -> HashDo {
    if !block_ok(p, s, block) {
        HashDo::Stuck(Stuck::NotBlock)
    } else {
        let arity = method_arity(p, block_method(p, s, block));
        let ok = if step % 2 != 0 { arity == 2 } else { 2 <= arity <= 3 };
        if !ok {
            HashDo::Return(s, smi(c))
        } else {
            hash_do_loop(p, s, backing, step, c, -1, null_v(p), 0, HASH_FUEL)
        }
    }
}

/// `Interpreter::hash_do`.
pub open spec fn hash_do(p: Program, s: State, current: Value, backing: Value, step: int, block: Value) -> HashDo {
    match current {
        Value::Smi(c) => hash_do_loop(p, s, backing, step, c as int + step, -1, null_v(p), 0, HASH_FUEL),
        _ => {
            if !is_instance(s, backing) {
                if !is_array(s, backing) {
                    HashDo::Return(s, null_v(p))
                } else {
                    let c = if step < 0 { elements(s, backing).len() + step } else { 0 };
                    hash_do_start(p, s, backing, step, block, c)
                }
            } else if class_of_obj(s, backing) != builtin(p, LIST_CLASS) {
                HashDo::Return(s, null_v(p))
            } else if step < 0 {
                if fields(s, backing).len() < 2 {
                    HashDo::Stuck(Stuck::FieldRange)
                } else if !(fields(s, backing)[1] is Smi) {
                    HashDo::Return(s, null_v(p))
                } else {
                    hash_do_start(p, s, backing, step, block, smi_val(fields(s, backing)[1]) + step)
                }
            } else {
                hash_do_start(p, s, backing, step, block, 0)
            }
        },
    }
}

} // verus!
