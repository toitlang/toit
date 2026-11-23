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

//! Verified executable step for the stack and arithmetic opcodes.
//!
//! `step_verified` is proven to agree with `spec_step::step`: whenever it
//! returns `Some(outcome)`, the spec step of the old state is exactly that
//! outcome on the new state. It returns `None` (state untouched) for the
//! opcodes it does not cover; the interpreter then uses its unverified
//! mirror (`interp::exec`). Zero `assume`/`admit`.
//!
//! Covered (47 opcodes): LOAD_LOCAL, LOAD_LOCAL_WIDE, LOAD_LOCAL_0..5,
//! POP_LOAD_LOCAL, STORE_LOCAL, STORE_LOCAL_POP, LOAD_LITERAL,
//! LOAD_LITERAL_WIDE, LOAD_NULL, LOAD_SMI_0, LOAD_SMIS_0, LOAD_SMI_1,
//! LOAD_SMI_U8, LOAD_SMI_U16, LOAD_SMI_U32, LOAD_METHOD, POP, POP_1, the
//! eight BRANCH opcodes, INVOKE_EQ, INVOKE_LT, INVOKE_GT, INVOKE_LTE,
//! INVOKE_GTE, INVOKE_BIT_OR, INVOKE_BIT_XOR, INVOKE_BIT_AND,
//! INVOKE_BIT_SHL, INVOKE_BIT_SHR, INVOKE_BIT_USHR, INVOKE_ADD, INVOKE_SUB,
//! INVOKE_MUL, INVOKE_DIV, INVOKE_MOD — including their double fast paths
//! and their virtual-call fallback (method lookup and call), and the
//! stuck state for an invalid instruction.
//!
//! Trusted (external_body, see DESIGN.md): IEEE-754 add/sub/mul, which are uninterpreted in the spec.

use vstd::prelude::*;
use crate::types::*;
use crate::bytecodes::*;
use crate::spec_common::*;
use crate::spec_helpers::*;
use crate::spec_step::*;

verus! {

pub enum ExecOutcome {
    Next,
    Stuck(Stuck),
}

/// The exec outcome `r` with final state `s` is the spec outcome `o`.
pub open spec fn matches(o: Outcome, r: ExecOutcome, s: State) -> bool {
    match r {
        ExecOutcome::Next => o == Outcome::Next(s),
        ExecOutcome::Stuck(k) => o == Outcome::Stuck(k),
    }
}

/// Shape of the program tables that the loader guarantees.
pub open spec fn wf_program(p: Program) -> bool {
    &&& p.word_bits == 32 || p.word_bits == 64
    &&& p.method_start.len() == p.bytecodes.len()
    &&& p.bytecodes.len() < 0x1000_0000
    &&& p.dispatch.len() < 0x1000_0000
    &&& p.roots.len() == 35
    &&& p.invoke_offsets.len() == 19
    &&& p.builtin.len() == 23
    &&& p.entry_points.len() == 9
}

/// Sizes stay far from the machine limits.
pub open spec fn wf_state(s: State) -> bool {
    &&& s.stack.len() < 0x1_0000_0000_0000
    &&& s.heap.len() < 0x1_0000_0000_0000
}

// ---------------------------------------------------------------------------
// Trusted floating point (the spec leaves these uninterpreted).

#[verifier::external_body]
pub fn x_double_add(a: u64, b: u64) -> (r: u64)
    ensures r == double_add(a, b),
{
    (f64::from_bits(a) + f64::from_bits(b)).to_bits()
}

#[verifier::external_body]
pub fn x_double_sub(a: u64, b: u64) -> (r: u64)
    ensures r == double_sub(a, b),
{
    (f64::from_bits(a) - f64::from_bits(b)).to_bits()
}

#[verifier::external_body]
pub fn x_double_mul(a: u64, b: u64) -> (r: u64)
    ensures r == double_mul(a, b),
{
    (f64::from_bits(a) * f64::from_bits(b)).to_bits()
}

pub enum XNum {
    Int(i64),
    Dbl(u64),
}

impl View for XNum {
    type V = Num;
    open spec fn view(&self) -> Num {
        match self {
            XNum::Int(i) => Num::Int(*i as int),
            XNum::Dbl(d) => Num::Dbl(*d),
        }
    }
}

#[inline(always)]
fn magnitude_flags(i: u64, d: u64, reverse: bool) -> (r: u8)
    ensures r == order_flags(if reverse { -magnitude_order(i, d) } else { magnitude_order(i, d) }),
{
    let e = d >> 52;
    let sig = (d & 0x000f_ffff_ffff_ffff) | (1u64 << 52);
    let (whole, fraction) = if d == 0 { (0, false) }
        else if e < 1023 { (0, true) }
        else if e >= 1087 { return if reverse { SIMPLE_GREATER } else { SIMPLE_LESS }; }
        else if e >= 1075 { (sig << (e - 1075), false) }
        else {
            let shift = 1075 - e;
            let whole = sig >> shift;
            (whole, sig != whole << shift)
        };
    if i < whole || (i == whole && fraction) { if reverse { SIMPLE_GREATER } else { SIMPLE_LESS } }
    else if i == whole { SIMPLE_EQUAL }
    else if reverse { SIMPLE_LESS } else { SIMPLE_GREATER }
}

#[inline(always)]
fn nan_encoding(d: u64) -> (r: bool)
    ensures r == is_nan_bits(d),
{
    ((d >> 52) & 0x7ff) == 0x7ff && (d & 0x000f_ffff_ffff_ffff) != 0
}

#[inline(always)]
fn signed_zero_flags(lhs_negative: bool, rhs_negative: bool) -> (r: u8)
    ensures r == zero_flags(lhs_negative, rhs_negative),
{
    if lhs_negative == rhs_negative { SIMPLE_EQUAL }
    else if lhs_negative { 117 } else { 115 }
}

fn x_int_double(i: i64, d: u64, int_first: bool) -> (r: u8)
    ensures r == int_double_flags(i, d, int_first),
{
    let mag = d & 0x7fff_ffff_ffff_ffff;
    let neg = d >> 63 != 0;
    if nan_encoding(d) { return if int_first { 1 } else { 7 }; }
    if i == 0 && mag == 0 { return signed_zero_flags(!int_first && neg, int_first && neg); }
    if (i < 0) != neg { return if (i < 0) == int_first { SIMPLE_LESS } else { SIMPLE_GREATER }; }
    let abs_i = if i < 0 { 0u64.wrapping_sub(i as u64) } else { i as u64 };
    // Reverse magnitude order for negative operands and again for a double on the left.
    magnitude_flags(abs_i, mag, neg == int_first)
}

#[inline(always)]
pub fn x_binary64_rank(d: u64) -> (r: i64)
    ensures r == binary64_rank(d),
{
    let m = d & 0x7fff_ffff_ffff_ffff;
    assert(m <= i64::MAX as u64) by (bit_vector) requires m == d & 0x7fff_ffff_ffff_ffff;
    if d >> 63 == 0 { m as i64 } else { -(m as i64) }
}

pub fn x_compare_mixed(a: XNum, b: XNum) -> (r: u8)
    ensures r == compare_mixed(a@, b@), r & 3 != 0,
{
    let r = match (a, b) {
        (XNum::Int(x), XNum::Int(y)) => x_compare_ints(x, y),
        (XNum::Int(i), XNum::Dbl(d)) => x_int_double(i, d, true),
        (XNum::Dbl(d), XNum::Int(i)) => x_int_double(i, d, false),
        (XNum::Dbl(x), XNum::Dbl(y)) => {
            if nan_encoding(x) { if nan_encoding(y) { 6 } else { 7 } }
            else if nan_encoding(y) { 1 }
            else {
                let lhs = x_binary64_rank(x);
                let rhs = x_binary64_rank(y);
                if lhs == rhs { signed_zero_flags(x >> 63 != 0, y >> 63 != 0) }
                else { x_compare_ints(lhs, rhs) }
            }
        },
    };
    assert(r & 3 != 0) by (bit_vector)
        requires r == 29 || r == 114 || r == 195 || r == 117 || r == 115 || r == 1 || r == 6 || r == 7;
    r
}

// ---------------------------------------------------------------------------
// Basic accessors.

pub fn x_value_eq(a: Value, b: Value) -> (r: bool)
    ensures r == (a == b),
{
    match (a, b) {
        (Value::Smi(x), Value::Smi(y)) => x == y,
        (Value::Obj(x), Value::Obj(y)) => x == y,
        (Value::RetAddr(x), Value::RetAddr(y)) => x == y,
        (Value::FrameMarker, Value::FrameMarker) => true,
        (Value::Block(x), Value::Block(y)) => x == y,
        (Value::Link(x), Value::Link(y)) => x == y,
        (Value::BlockRef(x1, x2), Value::BlockRef(y1, y2)) => x1 == y1 && x2 == y2,
        _ => false,
    }
}

pub fn x_is_value(v: Value) -> (r: bool)
    ensures r == is_value(v),
{
    match v {
        Value::RetAddr(_) => false,
        Value::FrameMarker => false,
        _ => true,
    }
}

pub fn x_at(s: &ExecState, n: usize) -> (v: Value)
    requires n < s.stack.len(),
    ensures v == at(s@, n as int),
{
    s.stack[s.stack.len() - 1 - n]
}

pub fn x_push(s: &mut ExecState, v: Value)
    ensures final(s)@ == push(old(s)@, v),
{
    s.stack.push(v);
}

pub fn x_drop(s: &mut ExecState, n: usize)
    requires n <= old(s).stack.len(),
    ensures final(s)@ == drop(old(s)@, n as int),
{
    let len = s.stack.len();
    s.stack.truncate(len - n);
    assert(s@.stack =~= drop(old(s)@, n as int).stack);
}

pub fn x_put(s: &mut ExecState, n: usize, v: Value)
    requires n < old(s).stack.len(),
    ensures final(s)@ == put(old(s)@, n as int, v),
{
    let i = s.stack.len() - 1 - n;
    s.stack.set(i, v);
}

proof fn lemma_drop_push(s: State, v: Value)
    ensures drop(push(s, v), 1) == s,
{
    assert(drop(push(s, v), 1).stack =~= s.stack);
}

pub fn x_null(p: &ExecProgram) -> (r: Value)
    requires wf_program(p@),
    ensures r == null_v(p@),
{
    p.roots[0]
}

pub fn x_true(p: &ExecProgram) -> (r: Value)
    requires wf_program(p@),
    ensures r == true_v(p@),
{
    p.roots[1]
}

pub fn x_false(p: &ExecProgram) -> (r: Value)
    requires wf_program(p@),
    ensures r == false_v(p@),
{
    p.roots[2]
}

pub fn x_boolean(p: &ExecProgram, b: bool) -> (r: Value)
    requires wf_program(p@),
    ensures r == boolean(p@, b),
{
    if b { x_true(p) } else { x_false(p) }
}

pub fn x_truthy(p: &ExecProgram, v: Value) -> (r: bool)
    requires wf_program(p@),
    ensures r == truthy(p@, v),
{
    !x_value_eq(v, x_false(p)) && !x_value_eq(v, x_null(p))
}

pub fn x_smi_max(p: &ExecProgram) -> (r: i64)
    requires wf_program(p@),
    ensures r == smi_max(p@),
{
    if p.word_bits == 32 { 0x3fff_ffff } else { 0x3fff_ffff_ffff_ffff }
}

pub fn x_smi_min(p: &ExecProgram) -> (r: i64)
    requires wf_program(p@),
    ensures r == smi_min(p@),
{
    if p.word_bits == 32 { -0x4000_0000 } else { -0x4000_0000_0000_0000 }
}

/// The view of the heap is index-wise.
proof fn lemma_heap_index(s: &ExecState, id: int)
    requires 0 <= id < s.heap.len(),
    ensures s@.heap[id] == s.heap[id]@, s@.heap.len() == s.heap.len(),
{
}

pub fn x_double_bits(s: &ExecState, v: Value) -> (r: Option<u64>)
    ensures
        r is Some <==> is_double(s@, v),
        r is Some ==> r->0 == double_bits(s@, v),
{
    match v {
        Value::Obj(id) => {
            if id < s.heap.len() {
                proof { lemma_heap_index(s, id as int); }
                match &s.heap[id].body {
                    ExecBody::Double(b) => Some(*b),
                    _ => None,
                }
            } else {
                None
            }
        },
        _ => None,
    }
}

pub fn x_large_int(s: &ExecState, v: Value) -> (r: Option<i64>)
    ensures
        r is Some <==> is_large_int(s@, v),
        r is Some ==> r->0 as int == large_int(s@, v),
{
    match v {
        Value::Obj(id) => {
            if id < s.heap.len() {
                proof { lemma_heap_index(s, id as int); }
                match &s.heap[id].body {
                    ExecBody::LargeInt(i) => Some(*i),
                    _ => None,
                }
            } else {
                None
            }
        },
        _ => None,
    }
}

pub fn x_num_of(s: &ExecState, v: Value) -> (r: Option<XNum>)
    ensures
        r is Some <==> num_of(s@, v) is Some,
        r is Some ==> num_of(s@, v) == Some(r->0@),
{
    match v {
        Value::Smi(i) => Some(XNum::Int(i)),
        Value::Obj(_) => {
            match x_large_int(s, v) {
                Some(i) => Some(XNum::Int(i)),
                None => match x_double_bits(s, v) {
                    Some(d) => Some(XNum::Dbl(d)),
                    None => None,
                },
            }
        },
        _ => None,
    }
}

pub fn x_compare_ints(a: i64, b: i64) -> (r: u8)
    ensures r == compare_ints(a as int, b as int),
{
    if a < b { SIMPLE_LESS } else if a == b { SIMPLE_EQUAL } else { SIMPLE_GREATER }
}

pub fn x_compare_numbers(s: &ExecState, a: Value, b: Value) -> (r: u8)
    ensures r == compare_numbers(s@, a, b),
{
    let na = x_num_of(s, a);
    let nb = x_num_of(s, b);
    match (na, nb) {
        (Some(XNum::Int(x)), Some(XNum::Int(y))) => x_compare_ints(x, y),
        (Some(x), Some(y)) => x_compare_mixed(x, y),
        _ => 0,
    }
}

// ---------------------------------------------------------------------------
// Methods and calls.

pub fn x_valid_method(p: &ExecProgram, id: i64) -> (r: bool)
    requires wf_program(p@),
    ensures r == valid_method(p@, id as int),
{
    id >= 0 && (id as u64) + 4 <= p.bytecodes.len() as u64 && p.method_start[id as usize]
}

pub fn x_method_selector_offset(p: &ExecProgram, id: usize) -> (r: i64)
    requires wf_program(p@), valid_method(p@, id as int),
    ensures r == method_selector_offset(p@, id as int),
{
    let value: i64 = p.bytecodes[id + 2] as i64 + 256 * (p.bytecodes[id + 3] as i64);
    if (p.bytecodes[id] & 0x80) != 0 {
        -value
    } else if value == 0xffff {
        -1
    } else {
        value
    }
}

pub fn x_call_with(p: &ExecProgram, s: &mut ExecState, target: i64, ret: usize) -> (r: ExecOutcome)
    requires wf_program(p@),
    ensures matches(call_with(p@, old(s)@, target as int, ret as int), r, final(s)@),
{
    if !x_valid_method(p, target) {
        return ExecOutcome::Stuck(Stuck::NotMethod);
    }
    x_push(s, Value::RetAddr(ret));
    x_push(s, Value::FrameMarker);
    s.bci = target as usize + 4;
    ExecOutcome::Next
}

pub fn x_entry_method(p: &ExecProgram, k: usize) -> (r: i64)
    requires wf_program(p@), k < 9,
    ensures r == entry_method(p@, k as int),
{
    let d = p.entry_points[k] as i64;
    if 0 <= d && d < p.dispatch.len() as i64 { p.dispatch[d as usize] as i64 } else { -1 }
}

pub enum XLookup {
    Found(usize),
    Missing,
    Stuck(Stuck),
}

pub open spec fn lookup_matches(x: XLookup, l: Lookup) -> bool {
    match x {
        XLookup::Found(t) => l == Lookup::Found(t as int),
        XLookup::Missing => l == Lookup::Missing,
        XLookup::Stuck(k) => l == Lookup::Stuck(k),
    }
}

pub fn x_find_method(p: &ExecProgram, s: &ExecState, recv: Value, offset: i64) -> (r: XLookup)
    requires wf_program(p@), -0x1_0000_0000 < offset < 0x1_0000_0000,
    ensures lookup_matches(r, find_method(p@, s@, recv, offset as int)),
{
    let cid: i64 = match recv {
        Value::Smi(_) => p.builtin[18] as i64,
        Value::Obj(id) => {
            if id >= s.heap.len() {
                return XLookup::Stuck(Stuck::NotObject);
            }
            proof { lemma_heap_index(s, id as int); }
            s.heap[id].class_id as i64
        },
        _ => { return XLookup::Stuck(Stuck::NotObject); },
    };
    let index = cid + offset;
    if !(0 <= index && index < p.dispatch.len() as i64) {
        return XLookup::Stuck(Stuck::TableRange);
    }
    let entry = p.dispatch[index as usize] as i64;
    if entry == -1 {
        return XLookup::Missing;
    }
    if !x_valid_method(p, entry) {
        return XLookup::Stuck(Stuck::NotMethod);
    }
    if x_method_selector_offset(p, entry as usize) != offset {
        return XLookup::Missing;
    }
    XLookup::Found(entry as usize)
}

/// `invoke_virtual` with return offset `len`.
pub fn x_invoke_virtual(p: &ExecProgram, s: &mut ExecState, recv: Value, offset: i64, len: usize) -> (r: ExecOutcome)
    requires
        wf_program(p@), -0x1_0000_0000 < offset < 0x1_0000_0000,
        old(s).bci + len < 0x2000_0000,
    ensures matches(invoke_virtual(p@, old(s)@, recv, offset as int, len as int), r, final(s)@),
{
    match x_find_method(p, s, recv, offset) {
        XLookup::Stuck(k) => ExecOutcome::Stuck(k),
        XLookup::Missing => {
            x_push(s, recv);
            x_push(s, Value::Smi(offset));
            let t = x_entry_method(p, 3);
            let ret = s.bci + len;
            x_call_with(p, s, t, ret)
        },
        XLookup::Found(t) => {
            let ret = s.bci + len;
            x_call_with(p, s, t as i64, ret)
        },
    }
}

/// The operator fallback: invoke the operator's selector on the receiver
/// (STACK_AT(1)), keeping both operands as arguments.
pub fn x_fallback(p: &ExecProgram, s: &mut ExecState, op: u8) -> (r: ExecOutcome)
    requires
        wf_program(p@), INVOKE_EQ <= op <= INVOKE_SIZE,
        has_slot(old(s)@, 1), old(s).bci + 1 < 0x2000_0000,
    ensures matches(fallback(p@, old(s)@, op), r, final(s)@),
{
    let recv = x_at(s, 1);
    let sel = p.invoke_offsets[(op - INVOKE_EQ) as usize] as i64;
    proof {
        let s0 = old(s)@;
        lemma_drop_push(s0, recv);
        assert(at(push(s0, at(s0, 1)), 0) == recv);
    }
    x_invoke_virtual(p, s, recv, sel, 1)
}

// ---------------------------------------------------------------------------
// Stack opcodes.

pub fn x_next(s: &mut ExecState, len: usize) -> (r: ExecOutcome)
    requires old(s).bci + len < 0x2000_0000,
    ensures matches(next(old(s)@, len as int), r, final(s)@),
{
    s.bci = s.bci + len;
    ExecOutcome::Next
}

pub fn x_load_local(s: &mut ExecState, n: usize, len: usize) -> (r: ExecOutcome)
    requires old(s).bci + len < 0x2000_0000,
    ensures matches(op_load_local(old(s)@, n as int, len as int), r, final(s)@),
{
    if n >= s.stack.len() {
        return ExecOutcome::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, n);
    if !x_is_value(v) {
        return ExecOutcome::Stuck(Stuck::FrameWord);
    }
    x_push(s, v);
    x_next(s, len)
}

pub fn x_pop_load_local(s: &mut ExecState, n: usize) -> (r: ExecOutcome)
    requires old(s).bci + 2 < 0x2000_0000, n < 0x1_0000,
    ensures matches(op_pop_load_local(old(s)@, n as int), r, final(s)@),
{
    if n + 1 >= s.stack.len() {
        return ExecOutcome::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, n + 1);
    if !x_is_value(v) || !x_is_value(x_at(s, 0)) {
        return ExecOutcome::Stuck(Stuck::FrameWord);
    }
    x_put(s, 0, v);
    x_next(s, 2)
}

pub fn x_store_local(s: &mut ExecState, n: usize) -> (r: ExecOutcome)
    requires old(s).bci + 2 < 0x2000_0000,
    ensures matches(op_store_local(old(s)@, n as int), r, final(s)@),
{
    if n >= s.stack.len() {
        return ExecOutcome::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, 0);
    if !x_is_value(x_at(s, n)) || !x_is_value(v) {
        return ExecOutcome::Stuck(Stuck::FrameWord);
    }
    x_put(s, n, v);
    x_next(s, 2)
}

pub fn x_store_local_pop(s: &mut ExecState, n: usize) -> (r: ExecOutcome)
    requires old(s).bci + 2 < 0x2000_0000,
    ensures matches(op_store_local_pop(old(s)@, n as int), r, final(s)@),
{
    if n < 1 || n >= s.stack.len() {
        return ExecOutcome::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, 0);
    if !x_is_value(x_at(s, n)) || !x_is_value(v) {
        return ExecOutcome::Stuck(Stuck::FrameWord);
    }
    x_drop(s, 1);
    x_put(s, n - 1, v);
    x_next(s, 2)
}

pub fn x_load_literal(p: &ExecProgram, s: &mut ExecState, i: usize, len: usize) -> (r: ExecOutcome)
    requires old(s).bci + len < 0x2000_0000,
    ensures matches(op_load_literal(p@, old(s)@, i as int, len as int), r, final(s)@),
{
    if i >= p.literals.len() {
        return ExecOutcome::Stuck(Stuck::TableRange);
    }
    x_push(s, p.literals[i]);
    x_next(s, len)
}

/// `smi_wrap` of a non-negative value below 2^32.
pub fn x_smi_wrap_u32(p: &ExecProgram, v: u32) -> (r: i64)
    requires wf_program(p@),
    ensures r as int == smi_wrap(p@, v as int),
{
    let m: u64 = if p.word_bits == 32 { 0x4000_0000 } else { 0x4000_0000_0000_0000 };
    assert(m as int == smi_max(p@) + 1);
    let w: u64 = (v as u64 + m) % (2 * m);
    (w as i64) - (m as i64)
}

pub fn x_load_smi(p: &ExecProgram, s: &mut ExecState, v: u32, len: usize) -> (r: ExecOutcome)
    requires wf_program(p@), old(s).bci + len < 0x2000_0000,
    ensures matches(op_load_smi(p@, old(s)@, v as int, len as int), r, final(s)@),
{
    let w = x_smi_wrap_u32(p, v);
    x_push(s, Value::Smi(w));
    x_next(s, len)
}

pub fn x_load_smis_0(s: &mut ExecState, n: usize) -> (r: ExecOutcome)
    requires old(s).bci + 2 < 0x2000_0000, n < 256, wf_state(old(s)@),
    ensures matches(op_load_smis_0(old(s)@, n as int), r, final(s)@),
{
    let ghost s0 = s@;
    let mut i: usize = 0;
    while i < n
        invariant
            i <= n, n < 256, wf_state(s0),
            s@ == (State { stack: s0.stack + Seq::new(i as nat, |j: int| Value::Smi(0)), ..s0 }),
        decreases n - i,
    {
        x_push(s, Value::Smi(0));
        i = i + 1;
        assert(s@.stack =~= s0.stack + Seq::new(i as nat, |j: int| Value::Smi(0)));
    }
    x_next(s, 2)
}

pub fn x_pop(s: &mut ExecState, n: usize, len: usize) -> (r: ExecOutcome)
    requires old(s).bci + len < 0x2000_0000,
    ensures matches(op_pop(old(s)@, n as int, len as int), r, final(s)@),
{
    if n > s.stack.len() {
        return ExecOutcome::Stuck(Stuck::StackRange);
    }
    x_drop(s, n);
    x_next(s, len)
}

pub fn x_branch(p: &ExecProgram, s: &mut ExecState, kind: u8, target: i64, len: usize) -> (r: ExecOutcome)
    requires
        wf_program(p@), old(s).bci + len < 0x2000_0000, kind <= 3,
        -0x1000_0000 < target < 0x2000_0000,
    ensures matches(op_branch(p@, old(s)@, kind as int, target as int, len as int), r, final(s)@),
{
    let taken = if kind == 0 {
        true
    } else {
        if s.stack.len() == 0 {
            return ExecOutcome::Stuck(Stuck::StackRange);
        }
        let v = x_at(s, 0);
        x_drop(s, 1);
        if kind == 1 {
            x_truthy(p, v)
        } else if kind == 2 {
            !x_truthy(p, v)
        } else {
            !x_value_eq(v, x_null(p))
        }
    };
    if taken {
        if !(0 <= target && target < p.bytecodes.len() as i64) {
            return ExecOutcome::Stuck(Stuck::BadBranch);
        }
        s.bci = target as usize;
        ExecOutcome::Next
    } else {
        x_next(s, len)
    }
}

// ---------------------------------------------------------------------------
// Arithmetic.

pub fn x_binary_result(s: &mut ExecState, v: Value) -> (r: ExecOutcome)
    requires has_slot(old(s)@, 1), old(s).bci + 1 < 0x2000_0000,
    ensures matches(binary_result(old(s)@, v), r, final(s)@),
{
    x_put(s, 1, v);
    x_drop(s, 1);
    x_next(s, 1)
}

/// C/C++ truncating division and remainder on i64 operands, computed on
/// magnitudes (`b != 0`).
pub fn x_tdiv_trem(a: i64, b: i64) -> (r: (i128, i128))
    requires b != 0,
    ensures r.0 as int == tdiv(a as int, b as int), r.1 as int == trem(a as int, b as int),
        -0x8000_0000_0000_0000 <= r.0 <= 0x8000_0000_0000_0000,
        -0x8000_0000_0000_0000 < r.1 < 0x8000_0000_0000_0000,
{
    let ua: u128 = if a >= 0 { a as u128 } else { (-(a as i128)) as u128 };
    let ub: u128 = if b >= 0 { b as u128 } else { (-(b as i128)) as u128 };
    let q: u128 = ua / ub;
    let m: u128 = ua % ub;
    proof {
        vstd::arithmetic::div_mod::lemma_fundamental_div_mod(ua as int, ub as int);
        vstd::arithmetic::div_mod::lemma_div_is_ordered_by_denominator(ua as int, 1, ub as int);
        vstd::arithmetic::div_mod::lemma_div_basics(ua as int);
        vstd::arithmetic::div_mod::lemma_mod_pos_bound(ua as int, ub as int);
    }
    let qs: i128 = if (a >= 0) == (b >= 0) { q as i128 } else { -(q as i128) };
    let rs: i128 = if a >= 0 { m as i128 } else { -(m as i128) };
    proof {
        let ai = a as int;
        let bi = b as int;
        assert(tdiv(ai, bi) == qs as int);
        assert(ua as int == ub as int * q as int + m as int);
        // trem(a, b) = a - b * tdiv(a, b) = sign(a) * (|a| - |b| * (|a| / |b|)).
        if a >= 0 && b >= 0 {
            assert(bi * (qs as int) == (ub as int) * (q as int));
        } else if a >= 0 && b < 0 {
            assert(bi * (qs as int) == (ub as int) * (q as int)) by (nonlinear_arith)
                requires bi == -(ub as int), qs as int == -(q as int);
        } else if a < 0 && b >= 0 {
            assert(bi * (qs as int) == -((ub as int) * (q as int))) by (nonlinear_arith)
                requires bi == ub as int, qs as int == -(q as int);
        } else {
            assert(bi * (qs as int) == -((ub as int) * (q as int))) by (nonlinear_arith)
                requires bi == -(ub as int), qs as int == q as int;
        }
    }
    (qs, rs)
}

/// Shifts `a` left by `b` bits if the result is a smi (`a * 2^b`).
pub fn x_shl(p: &ExecProgram, a: i64, b: i64) -> (r: Option<i64>)
    requires wf_program(p@), 0 <= b < word_bit_size(p@),
    ensures
        r is Some <==> smi_ok(p@, a * vstd::arithmetic::power2::pow2(b as nat)),
        r is Some ==> r->0 as int == a * vstd::arithmetic::power2::pow2(b as nat),
{
    let max = x_smi_max(p) as i128;
    let min = x_smi_min(p) as i128;
    let mut v: i128 = a as i128;
    let mut i: i64 = 0;
    proof { vstd::arithmetic::power2::lemma2_to64(); }
    while i < b
        invariant
            0 <= i <= b, b < 64,
            v as int == a * vstd::arithmetic::power2::pow2(i as nat),
            -0x8000_0000_0000_0000 <= v <= 0x8000_0000_0000_0000,
            max as int == smi_max(p@), min as int == smi_min(p@),
            min <= 0 <= max, max <= 0x3fff_ffff_ffff_ffff, min >= -0x4000_0000_0000_0000,
        decreases b - i,
    {
        if v > max || v < min {
            // Out of the smi range already; more shifting keeps it out
            // (or a was zero, which stays zero and is handled below).
            proof {
                let rest = (b - i) as nat;
                vstd::arithmetic::power2::lemma_pow2_adds(i as nat, rest);
                vstd::arithmetic::power2::lemma_pow2_pos(rest);
                let pr = vstd::arithmetic::power2::pow2(rest) as int;
                let pi = vstd::arithmetic::power2::pow2(i as nat) as int;
                assert(vstd::arithmetic::power2::pow2(b as nat) as int == pi * pr);
                assert(a * (pi * pr) == (v as int) * pr) by (nonlinear_arith)
                    requires v as int == a * pi;
                if v > max {
                    assert((v as int) * pr >= (v as int)) by (nonlinear_arith)
                        requires pr >= 1, v > 0;
                } else {
                    assert((v as int) * pr <= (v as int)) by (nonlinear_arith)
                        requires pr >= 1, v < 0;
                }
            }
            return None;
        }
        proof {
            vstd::arithmetic::power2::lemma_pow2_unfold((i + 1) as nat);
            assert(a * vstd::arithmetic::power2::pow2((i + 1) as nat)
                == 2 * (a * vstd::arithmetic::power2::pow2(i as nat))) by (nonlinear_arith)
                requires vstd::arithmetic::power2::pow2((i + 1) as nat)
                    == 2 * vstd::arithmetic::power2::pow2(i as nat);
        }
        v = 2 * v;
        i = i + 1;
    }
    if v > max || v < min { None } else { Some(v as i64) }
}

pub fn x_smi_arith(p: &ExecProgram, op: u8, a: i64, b: i64) -> (r: Option<i64>)
    requires wf_program(p@), INVOKE_BIT_OR <= op <= INVOKE_MOD,
    ensures
        r is Some <==> smi_arith(p@, op, a as int, b as int) is Some,
        r is Some ==> smi_arith(p@, op, a as int, b as int) == Some(r->0 as int),
{
    let max = x_smi_max(p) as i128;
    let min = x_smi_min(p) as i128;
    let wbs: i64 = if p.word_bits == 32 { 32 } else { 64 };
    if op == INVOKE_BIT_OR {
        Some(a | b)
    } else if op == INVOKE_BIT_XOR {
        Some(a ^ b)
    } else if op == INVOKE_BIT_AND {
        Some(a & b)
    } else if op == INVOKE_ADD {
        let v = a as i128 + b as i128;
        if min <= v && v <= max { Some(v as i64) } else { None }
    } else if op == INVOKE_SUB {
        let v = a as i128 - b as i128;
        if min <= v && v <= max { Some(v as i64) } else { None }
    } else if op == INVOKE_MUL {
        assert(-0x4000_0000_0000_0000_0000_0000_0000_0000 <= (a as int) * (b as int)
            <= 0x4000_0000_0000_0000_0000_0000_0000_0000) by (nonlinear_arith)
            requires -0x8000_0000_0000_0000 <= a <= 0x7fff_ffff_ffff_ffff,
                -0x8000_0000_0000_0000 <= b <= 0x7fff_ffff_ffff_ffff;
        let v = (a as i128) * (b as i128);
        if min <= v && v <= max { Some(v as i64) } else { None }
    } else if op == INVOKE_DIV {
        if b == 0 {
            None
        } else {
            let (q, _) = x_tdiv_trem(a, b);
            if min <= q && q <= max { Some(q as i64) } else { None }
        }
    } else if op == INVOKE_MOD {
        if b == 0 {
            None
        } else {
            let (_, m) = x_tdiv_trem(a, b);
            Some(m as i64)
        }
    } else if op == INVOKE_BIT_SHL {
        if 0 <= b && b < wbs { x_shl(p, a, b) } else { None }
    } else if op == INVOKE_BIT_SHR {
        if 0 <= b && b < wbs {
            Some(a >> (b as u64))
        } else {
            None
        }
    } else {
        if 0 <= b && b < wbs && a >= 0 {
            Some(a >> (b as u64))
        } else {
            None
        }
    }
}

pub fn x_invoke_arith(p: &ExecProgram, s: &mut ExecState, op: u8) -> (r: ExecOutcome)
    requires
        wf_program(p@), wf_state(old(s)@), INVOKE_BIT_OR <= op <= INVOKE_MOD,
        has_slot(old(s)@, 1), old(s).bci + 1 < 0x2000_0000,
    ensures matches(op_invoke_arith(p@, old(s)@, op), r, final(s)@),
{
    let a0 = x_at(s, 1);
    let a1 = x_at(s, 0);
    if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
        if let Some(v) = x_smi_arith(p, op, x, y) {
            return x_binary_result(s, Value::Smi(v));
        }
    }
    if op == INVOKE_ADD || op == INVOKE_SUB || op == INVOKE_MUL {
        let da = x_double_bits(s, a0);
        let db = x_double_bits(s, a1);
        if let (Some(x), Some(y)) = (da, db) {
            let bits = if op == INVOKE_ADD {
                x_double_add(x, y)
            } else if op == INVOKE_SUB {
                x_double_sub(x, y)
            } else {
                x_double_mul(x, y)
            };
            let ghost s0 = s@;
            let id = s.heap.len();
            s.heap.push(ExecObj { class_id: p.builtin[16], ro: false, body: ExecBody::Double(bits) });
            proof {
                assert(s@.heap =~= alloc(s0, new_double(s0, p@, bits)).heap);
                assert(s@ == alloc(s0, new_double(s0, p@, bits)));
            }
            return x_binary_result(s, Value::Obj(id));
        }
    }
    x_fallback(p, s, op)
}

pub fn x_invoke_relational(p: &ExecProgram, s: &mut ExecState, op: u8) -> (r: ExecOutcome)
    requires
        wf_program(p@), wf_state(old(s)@), INVOKE_LT <= op <= INVOKE_GTE,
        has_slot(old(s)@, 1), old(s).bci + 1 < 0x2000_0000,
    ensures matches(op_invoke_relational(p@, old(s)@, op), r, final(s)@),
{
    let a0 = x_at(s, 1);
    let a1 = x_at(s, 0);
    if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
        let b = if op == INVOKE_LT { x < y } else if op == INVOKE_LTE { x <= y } else if op == INVOKE_GT { x > y } else { x >= y };
        return x_binary_result(s, x_boolean(p, b));
    }
    let c = x_compare_numbers(s, a0, a1);
    if c != 0 {
        let flag: u8 = if op == INVOKE_LT { COMPARE_FLAG_STRICTLY_LESS }
            else if op == INVOKE_LTE { COMPARE_FLAG_LESS_EQUAL }
            else if op == INVOKE_GT { COMPARE_FLAG_STRICTLY_GREATER }
            else { COMPARE_FLAG_GREATER_EQUAL };
        return x_binary_result(s, x_boolean(p, (c & flag) != 0));
    }
    x_fallback(p, s, op)
}

pub fn x_invoke_eq(p: &ExecProgram, s: &mut ExecState) -> (r: ExecOutcome)
    requires
        wf_program(p@), wf_state(old(s)@), has_slot(old(s)@, 1), old(s).bci + 1 < 0x2000_0000,
    ensures matches(op_invoke_eq(p@, old(s)@), r, final(s)@),
{
    let a0 = x_at(s, 1);
    let a1 = x_at(s, 0);
    if x_value_eq(a0, a1) {
        let nan = match x_double_bits(s, a0) {
            Some(bits) => ((bits >> 52u64) & 0x7ffu64) == 0x7ffu64 && (bits & 0xf_ffff_ffff_ffffu64) != 0,
            None => false,
        };
        return x_binary_result(s, x_boolean(p, !nan));
    }
    if x_value_eq(a0, x_null(p)) || x_value_eq(a1, x_null(p)) {
        return x_binary_result(s, x_false(p));
    }
    if let (Value::Smi(x), Value::Smi(y)) = (a0, a1) {
        return x_binary_result(s, x_boolean(p, x == y));
    }
    let c = x_compare_numbers(s, a0, a1);
    if c != 0 {
        return x_binary_result(s, x_boolean(p, (c & COMPARE_FLAG_EQUAL) != 0));
    }
    x_fallback(p, s, INVOKE_EQ)
}

// ---------------------------------------------------------------------------
// Dispatch.

pub fn x_binary_ok(s: &ExecState) -> (r: bool)
    ensures r == binary_ok(s@),
{
    s.stack.len() >= 2 && x_is_value(x_at(s, 0)) && x_is_value(x_at(s, 1))
}

// ---------------------------------------------------------------------------
// The step function at each covered opcode. `step` is opaque; each lemma
// reveals it for one opcode (or one family of opcodes).

pub open spec fn op_at(p: Program, s: State) -> u8 {
    p.bytecodes[s.bci as int]
}

pub open spec fn b1_at(p: Program, s: State) -> int {
    byte(p, s.bci + 1)
}

pub open spec fn w1_at(p: Program, s: State) -> int {
    u16_at(p, s.bci + 1)
}

proof fn lemma_step_bad(p: Program, s: State)
    requires !instruction_ok(p, s.bci as int),
    ensures step(p, s) == stuck(Stuck::BadInstruction),
{
    reveal(step);
}

proof fn lemma_step_locals(p: Program, s: State)
    requires instruction_ok(p, s.bci as int),
    ensures
        op_at(p, s) == LOAD_LOCAL ==> step(p, s) == op_load_local(s, b1_at(p, s), 2),
        op_at(p, s) == LOAD_LOCAL_WIDE ==> step(p, s) == op_load_local(s, w1_at(p, s), 3),
        op_at(p, s) == POP_LOAD_LOCAL ==> step(p, s) == op_pop_load_local(s, b1_at(p, s)),
        op_at(p, s) == STORE_LOCAL ==> step(p, s) == op_store_local(s, b1_at(p, s)),
        op_at(p, s) == STORE_LOCAL_POP ==> step(p, s) == op_store_local_pop(s, b1_at(p, s)),
        LOAD_LOCAL_0 <= op_at(p, s) <= LOAD_LOCAL_5 ==>
            step(p, s) == op_load_local(s, op_at(p, s) - LOAD_LOCAL_0, 1),
{
    reveal(step);
}

proof fn lemma_step_constants(p: Program, s: State)
    requires instruction_ok(p, s.bci as int),
    ensures
        op_at(p, s) == LOAD_LITERAL ==> step(p, s) == op_load_literal(p, s, b1_at(p, s), 2),
        op_at(p, s) == LOAD_LITERAL_WIDE ==> step(p, s) == op_load_literal(p, s, w1_at(p, s), 3),
        op_at(p, s) == LOAD_NULL ==> step(p, s) == next(push(s, null_v(p)), 1),
        op_at(p, s) == LOAD_SMI_0 ==> step(p, s) == op_load_smi(p, s, 0, 1),
        op_at(p, s) == LOAD_SMIS_0 ==> step(p, s) == op_load_smis_0(s, b1_at(p, s)),
        op_at(p, s) == LOAD_SMI_1 ==> step(p, s) == op_load_smi(p, s, 1, 1),
        op_at(p, s) == LOAD_SMI_U8 ==> step(p, s) == op_load_smi(p, s, b1_at(p, s), 2),
        op_at(p, s) == LOAD_SMI_U16 ==> step(p, s) == op_load_smi(p, s, w1_at(p, s), 3),
        (op_at(p, s) == LOAD_SMI_U32 || op_at(p, s) == LOAD_METHOD) ==>
            step(p, s) == op_load_smi(p, s, u32_at(p, s.bci + 1), 5),
        op_at(p, s) == POP ==> step(p, s) == op_pop(s, b1_at(p, s), 2),
        op_at(p, s) == POP_1 ==> step(p, s) == op_pop(s, 1, 1),
{
    reveal(step);
}

proof fn lemma_step_operators(p: Program, s: State)
    requires instruction_ok(p, s.bci as int), INVOKE_EQ <= op_at(p, s) <= INVOKE_MOD,
    ensures
        !binary_ok(s) ==> step(p, s) == stuck(Stuck::StackRange),
        binary_ok(s) && op_at(p, s) == INVOKE_EQ ==> step(p, s) == op_invoke_eq(p, s),
        binary_ok(s) && INVOKE_LT <= op_at(p, s) <= INVOKE_GTE ==>
            step(p, s) == op_invoke_relational(p, s, op_at(p, s)),
        binary_ok(s) && INVOKE_BIT_OR <= op_at(p, s) <= INVOKE_MOD ==>
            step(p, s) == op_invoke_arith(p, s, op_at(p, s)),
{
    reveal(step);
}

proof fn lemma_step_branches(p: Program, s: State)
    requires instruction_ok(p, s.bci as int), BRANCH <= op_at(p, s) <= BRANCH_BACK_IF_NOT_NULL,
    ensures
        op_at(p, s) <= BRANCH_IF_NOT_NULL ==>
            step(p, s) == op_branch(p, s, op_at(p, s) - BRANCH, s.bci + w1_at(p, s), 3),
        op_at(p, s) >= BRANCH_BACK ==>
            step(p, s) == op_branch(p, s, op_at(p, s) - BRANCH_BACK, s.bci - w1_at(p, s), 5),
{
    reveal(step);
}

/// Common precondition of the per-family dispatchers.
pub open spec fn decoded(p: Program, s: State, op: u8, len: usize, b1: usize, w1: usize) -> bool {
    &&& wf_program(p)
    &&& wf_state(s)
    &&& instruction_ok(p, s.bci as int)
    &&& op == op_at(p, s)
    &&& len as int == opcode_length(op)
    &&& s.bci + len <= p.bytecodes.len()
    &&& (len >= 2 ==> b1 as int == b1_at(p, s))
    &&& (len >= 3 ==> w1 as int == w1_at(p, s))
    &&& b1 < 256 && w1 < 0x1_0000
}

fn x_step_locals(_p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, b1: usize, w1: usize) -> (r: ExecOutcome)
    requires
        decoded(_p@, old(s)@, op, len, b1, w1),
        (op <= STORE_LOCAL_POP && op != LOAD_OUTER && op != STORE_OUTER) || (LOAD_LOCAL_0 <= op <= LOAD_LOCAL_5),
    ensures matches(step(_p@, old(s)@), r, final(s)@),
{
    proof { lemma_step_locals(_p@, old(s)@); }
    if op == LOAD_LOCAL {
        x_load_local(s, b1, len)
    } else if op == LOAD_LOCAL_WIDE {
        x_load_local(s, w1, len)
    } else if op == POP_LOAD_LOCAL {
        x_pop_load_local(s, b1)
    } else if op == STORE_LOCAL {
        x_store_local(s, b1)
    } else if op == STORE_LOCAL_POP {
        x_store_local_pop(s, b1)
    } else {
        x_load_local(s, (op - LOAD_LOCAL_0) as usize, len)
    }
}

fn x_step_constants(p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, b1: usize, w1: usize) -> (r: ExecOutcome)
    requires
        decoded(p@, old(s)@, op, len, b1, w1),
        (LOAD_LITERAL <= op <= LOAD_METHOD) || op == POP || op == POP_1,
    ensures matches(step(p@, old(s)@), r, final(s)@),
{
    proof { lemma_step_constants(p@, old(s)@); }
    let bci = s.bci;
    if op == LOAD_LITERAL {
        x_load_literal(p, s, b1, len)
    } else if op == LOAD_LITERAL_WIDE {
        x_load_literal(p, s, w1, len)
    } else if op == LOAD_NULL {
        x_push(s, x_null(p));
        x_next(s, len)
    } else if op == LOAD_SMI_0 {
        x_load_smi(p, s, 0, len)
    } else if op == LOAD_SMIS_0 {
        x_load_smis_0(s, b1)
    } else if op == LOAD_SMI_1 {
        x_load_smi(p, s, 1, len)
    } else if op == LOAD_SMI_U8 {
        x_load_smi(p, s, b1 as u32, len)
    } else if op == LOAD_SMI_U16 {
        x_load_smi(p, s, w1 as u32, len)
    } else if op == LOAD_SMI_U32 || op == LOAD_METHOD {
        let v: u32 = (w1 as u32) + 65536 * (p.bytecodes[bci + 3] as u32 + 256 * (p.bytecodes[bci + 4] as u32));
        proof { assert(v as int == u32_at(p@, bci + 1)); }
        x_load_smi(p, s, v, len)
    } else if op == POP {
        x_pop(s, b1, len)
    } else {
        x_pop(s, 1, len)
    }
}

fn x_step_operators(p: &ExecProgram, s: &mut ExecState, op: u8, _len: usize, _b1: usize, _w1: usize) -> (r: ExecOutcome)
    requires
        decoded(p@, old(s)@, op, _len, _b1, _w1),
        INVOKE_EQ <= op <= INVOKE_MOD,
    ensures matches(step(p@, old(s)@), r, final(s)@),
{
    proof { lemma_step_operators(p@, old(s)@); }
    if !x_binary_ok(s) {
        ExecOutcome::Stuck(Stuck::StackRange)
    } else if op == INVOKE_EQ {
        x_invoke_eq(p, s)
    } else if op <= INVOKE_GTE {
        x_invoke_relational(p, s, op)
    } else {
        x_invoke_arith(p, s, op)
    }
}

fn x_step_branches(p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, _b1: usize, w1: usize) -> (r: ExecOutcome)
    requires
        decoded(p@, old(s)@, op, len, _b1, w1),
        BRANCH <= op <= BRANCH_BACK_IF_NOT_NULL,
    ensures matches(step(p@, old(s)@), r, final(s)@),
{
    proof { lemma_step_branches(p@, old(s)@); }
    let bci = s.bci;
    if op <= BRANCH_IF_NOT_NULL {
        x_branch(p, s, op - BRANCH, bci as i64 + w1 as i64, len)
    } else {
        x_branch(p, s, op - BRANCH_BACK, bci as i64 - w1 as i64, len)
    }
}

/// One step of the covered opcodes. `None`: not covered, state unchanged.
pub fn step_verified(p: &ExecProgram, s: &mut ExecState) -> (r: Option<ExecOutcome>)
    requires wf_program(p@), wf_state(old(s)@),
    ensures
        match r {
            Some(o) => matches(step(p@, old(s)@), o, final(s)@),
            None => final(s)@ == old(s)@,
        },
{
    let ghost s0 = s@;
    let bci = s.bci;
    let n = p.bytecodes.len();
    if bci >= n {
        proof { lemma_step_bad(p@, s0); }
        return Some(ExecOutcome::Stuck(Stuck::BadInstruction));
    }
    let op = p.bytecodes[bci];
    if op >= OPCODE_COUNT {
        proof { lemma_step_bad(p@, s0); }
        return Some(ExecOutcome::Stuck(Stuck::BadInstruction));
    }
    let len = exec_opcode_length(op);
    if bci + len > n {
        proof { lemma_step_bad(p@, s0); }
        return Some(ExecOutcome::Stuck(Stuck::BadInstruction));
    }
    let b1: usize = if len >= 2 { p.bytecodes[bci + 1] as usize } else { 0 };
    let w1: usize = if len >= 3 { b1 + 256 * (p.bytecodes[bci + 2] as usize) } else { 0 };
    assert(decoded(p@, s0, op, len, b1, w1));
    if (op <= STORE_LOCAL_POP && op != LOAD_OUTER && op != STORE_OUTER) || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5) {
        Some(x_step_locals(p, s, op, len, b1, w1))
    } else if (LOAD_LITERAL <= op && op <= LOAD_METHOD) || op == POP || op == POP_1 {
        Some(x_step_constants(p, s, op, len, b1, w1))
    } else if INVOKE_EQ <= op && op <= INVOKE_MOD {
        Some(x_step_operators(p, s, op, len, b1, w1))
    } else if BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL {
        Some(x_step_branches(p, s, op, len, b1, w1))
    } else {
        None
    }
}

} // verus!
