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

//! Verified executable step of the revised format (format 2).
//!
//! `step_verified` is proven to agree with `v2::spec::step`: whenever it
//! returns `Some(outcome)`, the spec step of the old state is that outcome
//! on the new state. It returns `None` (state untouched) for the opcodes
//! it does not cover; the interpreter then uses its unverified mirror
//! (`interp::exec2`). Zero `assume`/`admit`.
//!
//! Covered: the locals, constants, pops and branches; the operators with
//! their smi and double fast paths and their virtual-call fallback (method
//! lookup, arity check, call, or the raised LOOKUP_FAILED); the frame
//! operations (INVOKE_STATIC with the receiver check, INVOKE_STATIC_TAIL,
//! RETURN, RETURN_NULL, INVOKE_VIRTUAL); the block operations (LOAD_BLOCK,
//! LOAD_OUTER, STORE_OUTER, LOAD_OUTER_BLOCK, INVOKE_BLOCK,
//! NON_LOCAL_RETURN, NON_LOCAL_BRANCH); exceptions and finally (THROW, TRY,
//! UNWIND, including the unwinding loop and the raised exceptions); the
//! field accesses (LOAD_FIELD, LOAD_FIELD_WIDE, LOAD_FIELD_LOCAL,
//! POP_LOAD_FIELD_LOCAL, STORE_FIELD, STORE_FIELD_WIDE, STORE_FIELD_POP,
//! LOAD_FIELD_THIS, STORE_FIELD_THIS); and the invalid instruction.
//!
//! Trusted: as for format 1, IEEE-754 add/sub/mul and the mixed
//! comparison (`exec_step`'s external_body functions).

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
#[cfg(verus_only)]
use crate::spec_common::{smi, smi_ok, smi_min, smi_max, u16_at, u32_at, is_instance, fields, obj,
    obj_id, class_id_ok, class_id_of, builtin, instance_field_count, new_double, EXCEPTION_CLASS,
    is_array, elements};
use crate::spec_helpers::{COMPARE_FLAG_EQUAL, COMPARE_FLAG_STRICTLY_LESS, COMPARE_FLAG_LESS_EQUAL,
    COMPARE_FLAG_STRICTLY_GREATER, COMPARE_FLAG_GREATER_EQUAL};
#[cfg(verus_only)]
use crate::spec_helpers::{compare_numbers, are_smis, smi_val, are_floats, identical, is_nan_bits};
#[cfg(verus_only)]
use crate::spec_step::{smi_arith, float_arith, relational_flag, relational_smi};
use crate::exec_step::{x_value_eq, x_double_bits, x_compare_numbers, x_smi_arith, x_double_add,
    x_double_sub, x_double_mul};
#[cfg(verus_only)]
use crate::exec_step::{wf_program, wf_state};

verus! {

pub enum ExecOutcome2 {
    Next,
    Stuck(Stuck),
    Uncaught(Value),
    TaskReturned,
    /// The machine raises an exception with this value (`Outcome2::Raise`);
    /// `x_throw_null` is the reference completion.
    Raise(Value),
}

/// The exec outcome `r` with final state `s` is the spec outcome `o`.
pub open spec fn matches2(o: Outcome2, r: ExecOutcome2, s: State2) -> bool {
    match r {
        ExecOutcome2::Next => o == Outcome2::Next(s),
        ExecOutcome2::Stuck(k) => o == Outcome2::Stuck(k),
        ExecOutcome2::Uncaught(v) => o == Outcome2::Halt(s, Halt2::Uncaught(v)),
        ExecOutcome2::TaskReturned => o == Outcome2::Halt(s, Halt2::TaskReturned),
        ExecOutcome2::Raise(v) => o == Outcome2::Raise(s, v),
    }
}

/// Shape of the program tables that the loader guarantees.
pub open spec fn wf_program2(p: Program2) -> bool {
    &&& p.word_bits == 32 || p.word_bits == 64
    &&& p.bytecodes.len() < 0x1000_0000
    &&& p.methods.len() < 0x1000_0000
    &&& p.dispatch.len() < 0x1000_0000
    &&& forall|m: int| 0 <= m < p.methods.len() ==>
            #[trigger] p.methods[m].entry <= p.methods[m].end <= p.bytecodes.len()
    &&& p.roots.len() == 35
    &&& p.invoke_offsets.len() == 19
    &&& p.builtin.len() == 23
    &&& p.entry_points.len() == 9
    &&& p.literals.len() >= 7
}

/// The exec program of a format-2 program: format-2 tables, and the
/// format-1 view agrees with the adapter (no method-start bitmap).
pub open spec fn wf_exec_program2(p: &ExecProgram) -> bool {
    &&& wf_program2(pview2(p))
    &&& p.method_start@ =~= Seq::new(p.bytecodes@.len(), |i: int| false)
}

/// Sizes stay far from the machine limits.
pub open spec fn wf_state2(s: State2) -> bool {
    &&& s.stack.len() < 0x1_0000_0000_0000
    &&& s.heap.len() < 0x1_0000_0000_0000
    &&& s.frames.len() < 0x1_0000_0000_0000
    &&& s.bci < 0x1000_0000
}

/// Sizes of a state a few pushes away from a `wf_state2` one (internal
/// helpers do not need the bci bound).
pub open spec fn small(s: State2) -> bool {
    &&& s.stack.len() < 0x100_0000_0000_0000
    &&& s.heap.len() < 0x100_0000_0000_0000
    &&& s.frames.len() < 0x100_0000_0000_0000
}

pub open spec fn wf_exec_state2(s: &ExecState) -> bool {
    &&& wf_state2(view2(s))
    &&& s.try_h == 0
}

proof fn lemma_views(p: &ExecProgram, s: &ExecState)
    requires wf_exec_program2(p), wf_exec_state2(s),
    ensures
        p@ == p1(pview2(p)),
        s@ == as1(view2(s)),
        wf_program(p@),
        wf_state(s@),
{
    assert(p@.method_start =~= p1(pview2(p)).method_start);
}

/// The view of the heap is index-wise.
proof fn lemma_heap_index(s: &ExecState, id: int)
    requires 0 <= id < s.heap.len(),
    ensures view2(s).heap[id] == s.heap[id]@, view2(s).heap.len() == s.heap.len(),
{
}

// ---------------------------------------------------------------------------
// The object stack, seen from the top frame.

pub fn x_base(s: &ExecState) -> (r: usize)
    ensures r as int == base(view2(s)),
{
    if s.frames.len() > 0 { s.frames[s.frames.len() - 1].base } else { 0 }
}

pub fn x_frame_height(s: &ExecState) -> (r: i64)
    requires small(view2(s)), base(view2(s)) < 0x1_0000_0000_0000,
    ensures r as int == frame_height(view2(s)),
{
    s.stack.len() as i64 - x_base(s) as i64
}

pub fn x_has_slot(s: &ExecState, n: usize) -> (r: bool)
    requires
    ensures r == has_slot(view2(s), n as int),
{
    let b = x_base(s);
    b <= s.stack.len() && n < s.stack.len() - b
}

pub fn x_at(s: &ExecState, n: usize) -> (v: Value)
    requires has_slot(view2(s), n as int),
    ensures v == at(view2(s), n as int),
{
    s.stack[s.stack.len() - 1 - n]
}

pub fn x_push(s: &mut ExecState, v: Value)
    ensures view2(final(s)) == push(view2(old(s)), v),
{
    s.stack.push(v);
}

pub fn x_drop(s: &mut ExecState, n: usize)
    requires n <= old(s).stack.len(),
    ensures view2(final(s)) == drop(view2(old(s)), n as int),
{
    let len = s.stack.len();
    s.stack.truncate(len - n);
    assert(view2(s).stack =~= drop(view2(old(s)), n as int).stack);
}

pub fn x_put(s: &mut ExecState, n: usize, v: Value)
    requires n < old(s).stack.len(),
    ensures view2(final(s)) == put(view2(old(s)), n as int, v),
{
    let i = s.stack.len() - 1 - n;
    s.stack.set(i, v);
}

pub fn x_next(s: &mut ExecState, len: usize) -> (r: ExecOutcome2)
    requires old(s).bci + len < 0x2000_0000,
    ensures matches2(next(view2(old(s)), len as int), r, view2(final(s))),
{
    s.bci = s.bci + len;
    ExecOutcome2::Next
}

pub fn x_null(p: &ExecProgram) -> (r: Value)
    requires wf_program2(pview2(p)),
    ensures r == null2(pview2(p)),
{
    p.roots[0]
}

pub fn x_true(p: &ExecProgram) -> (r: Value)
    requires wf_program2(pview2(p)),
    ensures r == true2(pview2(p)),
{
    p.roots[1]
}

pub fn x_false(p: &ExecProgram) -> (r: Value)
    requires wf_program2(pview2(p)),
    ensures r == false2(pview2(p)),
{
    p.roots[2]
}

pub fn x_boolean(p: &ExecProgram, b: bool) -> (r: Value)
    requires wf_program2(pview2(p)),
    ensures r == boolean2(pview2(p), b),
{
    if b { x_true(p) } else { x_false(p) }
}

pub fn x_truthy(p: &ExecProgram, v: Value) -> (r: bool)
    requires wf_program2(pview2(p)),
    ensures r == truthy2(pview2(p), v),
{
    !x_value_eq(v, x_false(p)) && !x_value_eq(v, x_null(p))
}

// ---------------------------------------------------------------------------
// Heap.

/// The class id of a value, if it has one.
pub fn x_class_id(p: &ExecProgram, s: &ExecState, v: Value) -> (r: Option<i64>)
    requires wf_program2(pview2(p)),
    ensures
        r is Some <==> class_id_ok(as1(view2(s)), v),
        r is Some ==> r->0 as int == class_id_of(p1(pview2(p)), as1(view2(s)), v),
{
    match v {
        Value::Smi(_) => Some(p.builtin[18] as i64),
        Value::Obj(id) => {
            if id < s.heap.len() {
                proof { lemma_heap_index(s, id as int); }
                Some(s.heap[id].class_id as i64)
            } else {
                None
            }
        },
        _ => None,
    }
}

/// Field `f` of an instance, if it exists.
pub fn x_field(s: &ExecState, inst: Value, f: usize) -> (r: Option<Value>)
    ensures
        r is Some <==> field_ok(view2(s), inst, f as int),
        r is Some ==> r->0 == field(view2(s), inst, f as int),
{
    match inst {
        Value::Obj(id) => {
            if id < s.heap.len() {
                proof { lemma_heap_index(s, id as int); }
                match &s.heap[id].body {
                    ExecBody::Instance(fs) => if f < fs.len() { Some(fs[f]) } else { None },
                    _ => None,
                }
            } else {
                None
            }
        },
        _ => None,
    }
}

/// Whether `inst` is a task (an instance of the builtin task class).
pub fn x_is_task(p: &ExecProgram, s: &ExecState, inst: Value) -> (r: bool)
    requires wf_program2(pview2(p)),
    ensures r == is_task_obj(pview2(p), view2(s), inst),
{
    match inst {
        Value::Obj(id) => {
            if id < s.heap.len() {
                proof { lemma_heap_index(s, id as int); }
                match &s.heap[id].body {
                    ExecBody::Instance(_) => s.heap[id].class_id == p.builtin[19],
                    _ => false,
                }
            } else {
                false
            }
        },
        _ => false,
    }
}

/// Field `f` of `inst` if the program may read it.
pub fn x_field_readable(p: &ExecProgram, s: &ExecState, inst: Value, f: usize) -> (r: Option<Value>)
    requires wf_program2(pview2(p)),
    ensures
        r is Some <==> field_readable(pview2(p), view2(s), inst, f as int),
        r is Some ==> r->0 == field(view2(s), inst, f as int),
{
    match x_field(s, inst, f) {
        None => None,
        Some(v) => if f == 0 && x_is_task(p, s, inst) { None } else { Some(v) },
    }
}

/// Field `f` of `inst` exists and the program may write it.
pub fn x_field_writable(p: &ExecProgram, s: &ExecState, inst: Value, f: usize) -> (r: bool)
    requires wf_program2(pview2(p)),
    ensures r == field_writable(pview2(p), view2(s), inst, f as int),
{
    x_field(s, inst, f).is_some() && !x_is_ro(s, inst) && !(f <= 1 && x_is_task(p, s, inst))
}

/// Whether the object `inst` (an instance) is read-only.
pub fn x_is_ro(s: &ExecState, inst: Value) -> (r: bool)
    requires is_instance(as1(view2(s)), inst),
    ensures r == is_ro(view2(s), inst),
{
    match inst {
        Value::Obj(id) => {
            proof { lemma_heap_index(s, id as int); }
            s.heap[id].ro
        },
        _ => false,
    }
}

pub fn x_set_field(s: &mut ExecState, inst: Value, f: usize, v: Value)
    requires field_ok(view2(old(s)), inst, f as int),
    ensures view2(final(s)) == set_field2(view2(old(s)), inst, f as int, v),
{
    let ghost s0 = view2(s);
    match inst {
        Value::Obj(id) => {
            proof { lemma_heap_index(s, id as int); }
            let class_id = s.heap[id].class_id;
            let ro = s.heap[id].ro;
            let mut fs = match &s.heap[id].body {
                ExecBody::Instance(fs) => fs.clone(),
                _ => Vec::new(),
            };
            fs.set(f, v);
            let o = ExecObj { class_id, ro, body: ExecBody::Instance(fs) };
            s.heap.set(id, o);
            proof {
                assert(view2(s).heap =~= set_field2(s0, inst, f as int, v).heap);
            }
        },
        _ => {},
    }
}

pub fn x_alloc(s: &mut ExecState, o: ExecObj) -> (r: Value)
    ensures
        view2(final(s)) == alloc2(view2(old(s)), o@),
        r == new_ref2(view2(old(s))),
{
    let id = s.heap.len();
    s.heap.push(o);
    proof { assert(view2(s).heap =~= alloc2(view2(old(s)), o@).heap); }
    Value::Obj(id)
}

// ---------------------------------------------------------------------------
// Calls and returns.

pub fn x_valid_method(p: &ExecProgram, m: i64) -> (r: bool)
    ensures r == valid_method(pview2(p), m as int),
{
    0 <= m && (m as u64) < p.methods.len() as u64
}

pub fn x_call(p: &ExecProgram, s: &mut ExecState, target: i64, ret: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)),
    ensures matches2(call(pview2(p), view2(old(s)), target as int, ret as int), r, view2(final(s))),
{
    if !x_valid_method(p, target) {
        return ExecOutcome2::Stuck(Stuck::NotMethod);
    }
    let info = p.methods[target as usize];
    let a = info.arity as usize;
    let b = x_base(s);
    if b > s.stack.len() || a > s.stack.len() - b {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let base = s.stack.len() - a;
    s.frames.push(Frame { method: target as usize, ret, base, handler: false });
    s.bci = info.entry;
    ExecOutcome2::Next
}

/// Enters the finally code at `bci` of the top frame, the object stack cut
/// to `h` (format note 23).
pub fn x_enter_finally(p: &ExecProgram, s: &mut ExecState, h: usize, bci: usize, u: Option<Unwind>) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)),
    ensures matches2(enter_finally(pview2(p), view2(old(s)), h as int, bci as int, u), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    if s.frames.len() == 0 {
        return ExecOutcome2::Stuck(Stuck::BadFrame);
    }
    let b = x_base(s);
    if !(b <= h && h <= s.stack.len()) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let g = s.frames.len() - 1;
    s.stack.truncate(h);
    s.bci = bci;
    let ghost s1 = view2(s);
    proof {
        assert(s1.stack =~= s0.stack.subrange(0, h as int));
    }
    let (value, reason, d): (Value, i64, Pending) = match u {
        None => (x_null(p), -1, Pending::Normal),
        Some(Unwind::Throw(v)) => (v, -2, Pending::Throw),
        Some(Unwind::Return(f, v)) => (v, -1, Pending::Return(f)),
        Some(Unwind::Branch(f, nb, hb)) => (x_null(p), -1, Pending::Branch(f, nb, hb)),
    };
    x_push(s, value);
    x_push(s, Value::Token(false, d, g, h));
    x_push(s, Value::Token(true, d, g, h));
    x_push(s, Value::Smi(reason));
    proof { assert(crate::spec_common::smi(reason as int) == Value::Smi(reason)); }
    ExecOutcome2::Next
}

/// Pops the top frame (`pop_frame`), with its slots.
pub fn x_pop_frame(s: &mut ExecState)
    requires old(s).frames.len() > 0, old(s).frames@.last().base <= old(s).stack.len(),
    ensures view2(final(s)) == pop_frame(view2(old(s))),
{
    let ghost s0 = view2(s);
    let f = s.frames[s.frames.len() - 1];
    s.stack.truncate(f.base);
    s.frames.pop();
    proof {
        assert(view2(s).stack =~= pop_frame(s0).stack);
        assert(view2(s).frames =~= pop_frame(s0).frames);
    }
}

/// Returns `result` from the top frame.
pub fn x_return(p: &ExecProgram, s: &mut ExecState, result: Value) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)),
    ensures matches2(return_from(pview2(p), view2(old(s)), result), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    if s.frames.len() == 0 {
        return ExecOutcome2::Stuck(Stuck::BadFrame);
    }
    if s.frames.len() == 1 {
        return ExecOutcome2::TaskReturned;
    }
    let f = s.frames[s.frames.len() - 1];
    if f.base > s.stack.len() {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    if f.handler {
        x_pop_frame(s);
        return x_enter_finally(p, s, f.base, f.ret, None);
    }
    s.stack.truncate(f.base);
    s.stack.push(result);
    s.frames.pop();
    s.bci = f.ret;
    let ghost s1 = view2(s);
    proof {
        assert(s1.stack =~= s0.stack.subrange(0, f.base as int).push(result));
        assert(s1.frames =~= s0.frames.drop_last());
    }
    ExecOutcome2::Next
}

/// Unwinds the frame stack.
pub fn x_unwind(p: &ExecProgram, s: &mut ExecState, u: Unwind) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)),
    ensures matches2(unwind(pview2(p), view2(old(s)), u), r, view2(final(s))),
{
    loop
        invariant
            wf_program2(pview2(p)),
            unwind(pview2(p), view2(s), u) == unwind(pview2(p), view2(old(s)), u),
        decreases s.frames.len(),
    {
        let ghost s0 = view2(s);
        if s.frames.len() == 0 {
            return match u {
                Unwind::Throw(v) => ExecOutcome2::Uncaught(v),
                _ => ExecOutcome2::Stuck(Stuck::BadFrame),
            };
        }
        let fi = s.frames.len() - 1;
        let f = s.frames[fi];
        if f.base > s.stack.len() {
            return ExecOutcome2::Stuck(Stuck::StackRange);
        }
        match u {
            Unwind::Return(target, v) => {
                if target == fi {
                    return x_return(p, s, v);
                }
            },
            Unwind::Branch(target, bci, h) => {
                if target == fi {
                    if !(f.base <= h && h <= s.stack.len()) {
                        return ExecOutcome2::Stuck(Stuck::StackRange);
                    }
                    s.stack.truncate(h);
                    s.bci = bci;
                    proof { assert(view2(s).stack =~= s0.stack.subrange(0, h as int)); }
                    return ExecOutcome2::Next;
                }
            },
            Unwind::Throw(_) => {},
        }
        x_pop_frame(s);
        if f.handler {
            return x_enter_finally(p, s, f.base, f.ret, Some(u));
        }
    }
}

/// Raises failure `k`: an oracle step (`Outcome2::Raise`), completed by
/// the caller (`x_throw_null` for the reference completion).
#[allow(unused_variables)]
pub fn x_raise(p: &ExecProgram, s: &mut ExecState, k: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), k < 5,
    ensures matches2(raise(pview2(p), view2(old(s)), k as int), r, view2(final(s))),
{
    ExecOutcome2::Raise(p.literals[2 + k])
}

/// The reference completion of `Raise(s, value)`: an `Exception_` with the
/// value and a null trace, allocated at the end of the heap; then unwinds.
pub fn x_throw_null(p: &ExecProgram, s: &mut ExecState, value: Value) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)),
    ensures matches2(throw_exception(pview2(p), view2(old(s)), value, null2(pview2(p))), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    let ghost pv = pview2(p);
    let cid = p.builtin[22] as usize;
    if cid >= p.class_bits.len() {
        return ExecOutcome2::Stuck(Stuck::Fatal);
    }
    let words = ((p.class_bits[cid] >> 5u16) & 0x7ffu16) as i64;
    if words - 1 < 2 {
        return ExecOutcome2::Stuck(Stuck::Fatal);
    }
    let n = (words - 1) as usize;
    let null = x_null(p);
    let mut fs: Vec<Value> = Vec::new();
    let mut i: usize = 0;
    while i < n
        invariant
            i <= n, n as int == instance_field_count(p1(pv), cid as int), wf_program2(pv), pv == pview2(p),
            null == null2(pv),
            fs@.len() == i,
            forall|j: int| 0 <= j < i ==> fs@[j] == (if j == 0 { value } else if j == 1 { null } else { null }),
        decreases n - i,
    {
        if i == 0 { fs.push(value); } else { fs.push(null); }
        i = i + 1;
    }
    let ghost o = exception_obj2(pv, value, null2(pv));
    proof {
        assert(fs@ =~= Seq::new(instance_field_count(p1(pv), cid as int) as nat, |j: int|
            if j == 0 { value } else if j == 1 { null2(pv) } else { null2(pv) }));
    }
    let e = x_alloc(s, ExecObj { class_id: cid as u16, ro: false, body: ExecBody::Instance(fs) });
    proof { assert(view2(s) == alloc2(s0, o)); }
    x_unwind(p, s, Unwind::Throw(e))
}

// ---------------------------------------------------------------------------
// Dispatch.

pub enum XLookup2 {
    Found(usize),
    Missing,
    Stuck(Stuck),
}

pub open spec fn lookup_matches2(x: XLookup2, l: Lookup2) -> bool {
    match x {
        XLookup2::Found(t) => l == Lookup2::Found(t as int),
        XLookup2::Missing => l == Lookup2::Missing,
        XLookup2::Stuck(k) => l == Lookup2::Stuck(k),
    }
}

pub fn x_find_method(p: &ExecProgram, s: &ExecState, recv: Value, sel: i64) -> (r: XLookup2)
    requires wf_program2(pview2(p)), -0x1_0000_0000 < sel < 0x1_0000_0000,
    ensures lookup_matches2(r, find_method(pview2(p), view2(s), recv, sel as int)),
{
    let cid = match x_class_id(p, s, recv) {
        Some(c) => c,
        None => { return XLookup2::Stuck(Stuck::NotObject); },
    };
    if sel < 0 {
        return XLookup2::Missing;
    }
    let index = cid + sel;
    if !(0 <= index && index < p.dispatch.len() as i64) {
        return XLookup2::Stuck(Stuck::TableRange);
    }
    let entry = p.dispatch[index as usize] as i64;
    if entry == -1 {
        return XLookup2::Missing;
    }
    if !x_valid_method(p, entry) {
        return XLookup2::Stuck(Stuck::NotMethod);
    }
    if p.methods[entry as usize].selector as i64 != sel {
        return XLookup2::Missing;
    }
    XLookup2::Found(entry as usize)
}

pub fn x_invoke_virtual(p: &ExecProgram, s: &mut ExecState, sel: i64, n: usize, len: usize) -> (r: ExecOutcome2)
    requires
        wf_program2(pview2(p)), old(s).bci < 0x1000_0000, -0x1_0000_0000 < sel < 0x1_0000_0000,
        n <= 0x1_0000, len <= 6,
    ensures matches2(invoke_virtual(pview2(p), view2(old(s)), sel as int, n as int, len as int), r, view2(final(s))),
{
    if !(1 <= n && x_has_slot(s, n - 1)) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let recv = x_at(s, n - 1);
    match x_find_method(p, s, recv, sel) {
        XLookup2::Stuck(k) => ExecOutcome2::Stuck(k),
        XLookup2::Missing => x_raise(p, s, 0),
        XLookup2::Found(t) => {
            if p.methods[t].arity as usize != n {
                return ExecOutcome2::Stuck(Stuck::BadArity);
            }
            let ret = s.bci + len;
            x_call(p, s, t as i64, ret)
        },
    }
}

/// The class-id range check of a statically called method.
pub fn x_receiver_check(p: &ExecProgram, s: &ExecState, t: usize) -> (r: Option<bool>)
    requires
        wf_program2(pview2(p)), valid_method(pview2(p), t as int),
        arity(pview2(p), t as int) <= frame_height(view2(s)),
    ensures
        r is Some <==> receiver_check_ok(pview2(p), view2(s), t as int),
        r is Some ==> r->0 == receiver_fails(pview2(p), view2(s), t as int),
{
    let info = p.methods[t];
    if info.recv_start == 0xffff {
        return Some(false);
    }
    if info.arity == 0 {
        return None;
    }
    let recv = x_at(s, info.arity as usize - 1);
    match x_class_id(p, s, recv) {
        None => None,
        Some(cid) => Some(!(info.recv_start as i64 <= cid && cid < info.recv_end as i64)),
    }
}

pub fn x_call_static(p: &ExecProgram, s: &mut ExecState, t: i64, len: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), old(s).bci < 0x1000_0000, len <= 6,
    ensures matches2(call_static(pview2(p), view2(old(s)), t as int, len as int), r, view2(final(s))),
{
    if !x_valid_method(p, t) {
        return ExecOutcome2::Stuck(Stuck::NotMethod);
    }
    let a = p.methods[t as usize].arity as usize;
    let b = x_base(s);
    if b > s.stack.len() || a > s.stack.len() - b {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_receiver_check(p, s, t as usize) {
        None => ExecOutcome2::Stuck(Stuck::NotObject),
        Some(true) => x_raise(p, s, 1),
        Some(false) => {
            let ret = s.bci + len;
            x_call(p, s, t, ret)
        },
    }
}

pub fn x_dispatch_target(p: &ExecProgram, d: usize) -> (r: i64)
    requires wf_program2(pview2(p)),
    ensures r as int == dispatch_target(pview2(p), d as int),
{
    if d < p.dispatch.len() { p.dispatch[d] as i64 } else { -1 }
}

/// Replaces the top frame's method by `target` with the top `nargs` slots
/// (and `extra` after them) as its arguments.
pub fn x_replace_frame(p: &ExecProgram, s: &mut ExecState, target: usize, args: Vec<Value>) -> (r: ExecOutcome2)
    requires
        wf_program2(pview2(p)), valid_method(pview2(p), target as int),
        old(s).frames.len() > 0, base(view2(old(s))) <= old(s).stack.len(),
    ensures matches2(replace_frame(pview2(p), view2(old(s)), target as int, args@), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    let fi = s.frames.len() - 1;
    let f = s.frames[fi];
    let ghost sc = view2(s);
    s.stack.truncate(f.base);
    let mut i: usize = 0;
    while i < args.len()
        invariant
            i <= args.len(), f.base <= s0.stack.len(),
            view2(s) == (State2 { stack: view2(s).stack, ..sc }),
            s.stack@ =~= s0.stack.subrange(0, f.base as int) + args@.subrange(0, i as int),
        decreases args.len() - i,
    {
        s.stack.push(args[i]);
        i = i + 1;
        proof { assert(s.stack@ =~= s0.stack.subrange(0, f.base as int) + args@.subrange(0, i as int)); }
    }
    s.frames.set(fi, Frame { method: target, ret: f.ret, base: f.base, handler: f.handler });
    s.bci = p.methods[target].entry;
    proof {
        assert(args@.subrange(0, args@.len() as int) =~= args@);
        assert(view2(s).stack =~= s0.stack.subrange(0, base(s0)) + args@);
        assert(view2(s).frames =~= s0.frames.update(top_index(s0), Frame { method: target, ..top(s0) }));
    }
    ExecOutcome2::Next
}

// ---------------------------------------------------------------------------
// Opcodes: locals, constants, pops.

pub fn x_load_local(s: &mut ExecState, n: usize, len: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))), len <= 6,
    ensures matches2(op_load_local(view2(old(s)), n as int, len as int), r, view2(final(s))),
{
    if !x_has_slot(s, n) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, n);
    x_push(s, v);
    x_next(s, len)
}

pub fn x_pop_load_local(s: &mut ExecState, n: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))), n < 0x1_0000,
    ensures matches2(op_pop_load_local(view2(old(s)), n as int), r, view2(final(s))),
{
    if !x_has_slot(s, n + 1) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, n + 1);
    x_put(s, 0, v);
    x_next(s, 2)
}

pub fn x_store_local(s: &mut ExecState, n: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))),
    ensures matches2(op_store_local(view2(old(s)), n as int), r, view2(final(s))),
{
    if !x_has_slot(s, n) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, 0);
    x_put(s, n, v);
    x_next(s, 2)
}

pub fn x_store_local_pop(s: &mut ExecState, n: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))),
    ensures matches2(op_store_local_pop(view2(old(s)), n as int), r, view2(final(s))),
{
    if n < 1 || !x_has_slot(s, n) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, 0);
    x_drop(s, 1);
    x_put(s, n - 1, v);
    x_next(s, 2)
}

pub fn x_load_literal(p: &ExecProgram, s: &mut ExecState, i: usize, len: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))), len <= 6,
    ensures matches2(op_load_literal(pview2(p), view2(old(s)), i as int, len as int), r, view2(final(s))),
{
    if i >= p.literals.len() {
        return ExecOutcome2::Stuck(Stuck::TableRange);
    }
    x_push(s, p.literals[i]);
    x_next(s, len)
}

pub fn x_smi_ok(p: &ExecProgram, v: i64) -> (r: bool)
    requires wf_program2(pview2(p)),
    ensures r == smi_ok(p1(pview2(p)), v as int),
{
    if p.word_bits == 32 { -0x4000_0000 <= v && v <= 0x3fff_ffff } else { -0x4000_0000_0000_0000 <= v && v <= 0x3fff_ffff_ffff_ffff }
}

pub fn x_load_smi(p: &ExecProgram, s: &mut ExecState, v: u32, len: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), len <= 6,
    ensures matches2(op_load_smi(pview2(p), view2(old(s)), v as int, len as int), r, view2(final(s))),
{
    if !x_smi_ok(p, v as i64) {
        return ExecOutcome2::Stuck(Stuck::SmiRange);
    }
    x_push(s, Value::Smi(v as i64));
    x_next(s, len)
}

pub fn x_load_method(p: &ExecProgram, s: &mut ExecState, m: u32) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))),
    ensures matches2(op_load_method(pview2(p), view2(old(s)), m as int), r, view2(final(s))),
{
    if !x_valid_method(p, m as i64) || !x_smi_ok(p, m as i64) {
        return ExecOutcome2::Stuck(Stuck::NotMethod);
    }
    x_push(s, Value::Smi(m as i64));
    x_next(s, 5)
}

pub fn x_load_smis_0(s: &mut ExecState, n: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))), n < 256,
    ensures matches2(op_load_smis_0(view2(old(s)), n as int), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    let mut i: usize = 0;
    while i < n
        invariant
            i <= n, view2(s) == (State2 { stack: s0.stack + Seq::new(i as nat, |j: int| Value::Smi(0)), ..s0 }),
        decreases n - i,
    {
        s.stack.push(Value::Smi(0));
        i = i + 1;
        proof {
            assert(view2(s).stack =~= s0.stack + Seq::new(i as nat, |j: int| Value::Smi(0)));
        }
    }
    x_next(s, 2)
}

pub fn x_pop(s: &mut ExecState, n: usize, len: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))), len <= 6,
    ensures matches2(op_pop(view2(old(s)), n as int, len as int), r, view2(final(s))),
{
    let b = x_base(s);
    if !(b <= s.stack.len() && n <= s.stack.len() - b) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    x_drop(s, n);
    x_next(s, len)
}

// ---------------------------------------------------------------------------
// Branches.

pub fn x_branch_to(p: &ExecProgram, s: &mut ExecState, target: i64) -> (r: ExecOutcome2)
    requires
        wf_program2(pview2(p)), old(s).frames.len() > 0,
        valid_method(pview2(p), top(view2(old(s))).method as int),
    ensures matches2(branch_to(pview2(p), view2(old(s)), target as int), r, view2(final(s))),
{
    let m = s.frames[s.frames.len() - 1].method;
    let info = p.methods[m];
    if !(info.entry as i64 <= target && target < info.end as i64) {
        return ExecOutcome2::Stuck(Stuck::BadBranch);
    }
    s.bci = target as usize;
    ExecOutcome2::Next
}

pub fn x_branch(p: &ExecProgram, s: &mut ExecState, kind: u8, target: i64, len: usize) -> (r: ExecOutcome2)
    requires
        wf_program2(pview2(p)), wf_state2(view2(old(s))), old(s).frames.len() > 0,
        valid_method(pview2(p), top(view2(old(s))).method as int), kind <= 3, len <= 6,
    ensures matches2(op_branch(pview2(p), view2(old(s)), kind as int, target as int, len as int), r, view2(final(s))),
{
    if kind == 0 {
        return x_branch_to(p, s, target);
    }
    if !x_has_slot(s, 0) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, 0);
    let taken = if kind == 1 { x_truthy(p, v) } else if kind == 2 { !x_truthy(p, v) } else { !x_value_eq(v, x_null(p)) };
    x_drop(s, 1);
    if taken {
        x_branch_to(p, s, target)
    } else {
        x_next(s, len)
    }
}

// ---------------------------------------------------------------------------
// Operators.

pub fn x_binary_result(s: &mut ExecState, v: Value) -> (r: ExecOutcome2)
    requires small(view2(old(s))), old(s).bci < 0x1000_0000, has_slot(view2(old(s)), 1),
    ensures matches2(binary_result(view2(old(s)), v), r, view2(final(s))),
{
    x_drop(s, 2);
    x_push(s, v);
    x_next(s, 1)
}

pub fn x_operator_fallback(p: &ExecProgram, s: &mut ExecState, op: u8) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), old(s).bci < 0x1000_0000, INVOKE_EQ <= op <= INVOKE_AT_PUT,
    ensures matches2(operator_fallback(pview2(p), view2(old(s)), op), r, view2(final(s))),
{
    let n: usize = if op == INVOKE_AT_PUT { 3 } else { 2 };
    let sel = p.invoke_offsets[(op - INVOKE_EQ) as usize] as i64;
    x_invoke_virtual(p, s, sel, n, 1)
}

pub fn x_invoke_eq(p: &ExecProgram, s: &mut ExecState) -> (r: ExecOutcome2)
    requires
        wf_exec_program2(p), wf_exec_state2(old(s)), has_slot(view2(old(s)), 1),
    ensures matches2(op_invoke_eq(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_views(p, s); }
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
    x_operator_fallback(p, s, INVOKE_EQ)
}

pub fn x_invoke_relational(p: &ExecProgram, s: &mut ExecState, op: u8) -> (r: ExecOutcome2)
    requires
        wf_exec_program2(p), wf_exec_state2(old(s)), has_slot(view2(old(s)), 1),
        INVOKE_LT <= op <= INVOKE_GTE,
    ensures matches2(op_invoke_relational(pview2(p), view2(old(s)), op), r, view2(final(s))),
{
    proof { lemma_views(p, s); }
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
    x_operator_fallback(p, s, op)
}

pub fn x_invoke_arith(p: &ExecProgram, s: &mut ExecState, op: u8) -> (r: ExecOutcome2)
    requires
        wf_exec_program2(p), wf_exec_state2(old(s)), has_slot(view2(old(s)), 1),
        INVOKE_BIT_OR <= op <= INVOKE_MOD,
    ensures matches2(op_invoke_arith(pview2(p), view2(old(s)), op), r, view2(final(s))),
{
    proof { lemma_views(p, s); }
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
            let ghost s0 = view2(s);
            let d = x_alloc(s, ExecObj { class_id: p.builtin[16], ro: false, body: ExecBody::Double(bits) });
            proof { assert(view2(s) == alloc2(s0, new_double(as1(s0), p1(pview2(p)), bits))); }
            return x_binary_result(s, d);
        }
    }
    x_operator_fallback(p, s, op)
}

// ---------------------------------------------------------------------------
// Fields.

pub fn x_load_field(p: &ExecProgram, s: &mut ExecState, f: usize, len: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), len <= 6, !twin_at(pview2(p), view2(old(s))),
    ensures matches2(op_load_field(pview2(p), view2(old(s)), f as int, len as int), r, view2(final(s))),
{
    if !x_has_slot(s, 0) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_field_readable(p, s, x_at(s, 0), f) {
        None => x_raise(p, s, 3),
        Some(v) => {
            x_put(s, 0, v);
            x_next(s, len)
        },
    }
}

pub fn x_load_field_local(p: &ExecProgram, s: &mut ExecState, enc: usize, pop: bool) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), enc < 256, !twin_at(pview2(p), view2(old(s))),
    ensures matches2(op_load_field_local(pview2(p), view2(old(s)), enc as int, pop), r, view2(final(s))),
{
    let local = enc % 16;
    let f = enc / 16;
    let slot = if pop { local + 1 } else { local };
    if !x_has_slot(s, slot) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_field_readable(p, s, x_at(s, slot), f) {
        None => x_raise(p, s, 3),
        Some(v) => {
            if pop { x_put(s, 0, v); } else { x_push(s, v); }
            x_next(s, 2)
        },
    }
}

pub fn x_store_field(p: &ExecProgram, s: &mut ExecState, f: usize, len: usize, keep: bool) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), len <= 6, !twin_at(pview2(p), view2(old(s))),
    ensures matches2(op_store_field(pview2(p), view2(old(s)), f as int, len as int, keep), r, view2(final(s))),
{
    if !x_has_slot(s, 1) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, 0);
    let inst = x_at(s, 1);
    if !x_field_writable(p, s, inst, f) {
        return x_raise(p, s, 3);
    }
    x_drop(s, 2);
    x_set_field(s, inst, f, v);
    if keep { x_push(s, v); }
    x_next(s, len)
}

/// The `this` of the top frame if `this.f` exists, for the unchecked field
/// instructions.
pub fn x_this(p: &ExecProgram, s: &ExecState, f: usize) -> (r: Option<Value>)
    requires wf_program2(pview2(p)),
    ensures
        r is Some <==> this_ok(pview2(p), view2(s), f as int),
        r is Some ==> r->0 == view2(s).stack[top(view2(s)).base as int],
{
    if s.frames.len() == 0 {
        return None;
    }
    let fr = s.frames[s.frames.len() - 1];
    if fr.method >= p.methods.len() {
        return None;
    }
    let info = p.methods[fr.method];
    if info.recv_start == 0xffff || info.arity < 1 || fr.base >= s.stack.len() {
        return None;
    }
    let this = s.stack[fr.base];
    match x_field(s, this, f) {
        None => None,
        Some(_) => Some(this),
    }
}

pub fn x_load_field_this(p: &ExecProgram, s: &mut ExecState, f: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))),
    ensures matches2(op_load_field_this(pview2(p), view2(old(s)), f as int), r, view2(final(s))),
{
    match x_this(p, s, f) {
        None => ExecOutcome2::Stuck(Stuck::NotInstance),
        Some(this) => {
            if f == 0 && x_is_task(p, s, this) {
                return ExecOutcome2::Stuck(Stuck::NotInstance);
            }
            let v = match x_field(s, this, f) { Some(v) => v, None => this };
            x_push(s, v);
            x_next(s, 2)
        },
    }
}

pub fn x_store_field_this(p: &ExecProgram, s: &mut ExecState, f: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), !twin_at(pview2(p), view2(old(s))),
    ensures matches2(op_store_field_this(pview2(p), view2(old(s)), f as int), r, view2(final(s))),
{
    if !x_has_slot(s, 0) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_this(p, s, f) {
        None => ExecOutcome2::Stuck(Stuck::NotInstance),
        Some(this) => {
            if f <= 1 && x_is_task(p, s, this) {
                return ExecOutcome2::Stuck(Stuck::NotInstance);
            }
            if x_is_ro(s, this) {
                return x_raise(p, s, 3);
            }
            let v = x_at(s, 0);
            x_set_field(s, this, f, v);
            x_next(s, 2)
        },
    }
}

// ---------------------------------------------------------------------------
// Blocks.

pub fn x_ref_ok(s: &ExecState, f: usize, slot: usize) -> (r: bool)
    ensures r == ref_ok(view2(s), f as int, slot as int),
{
    if f >= s.frames.len() || slot >= s.stack.len() {
        return false;
    }
    let limit = if f < s.frames.len() - 1 { s.frames[f + 1].base } else { s.stack.len() };
    s.frames[f].base <= slot && slot < limit
}

pub fn x_block_ref(s: &ExecState, v: Value) -> (r: Option<(usize, usize)>)
    ensures
        r is Some <==> block_ref(view2(s), v) is Some,
        r is Some ==> block_ref(view2(s), v) == Some(((r->0).0 as int, (r->0).1 as int)),
        r is Some ==> ref_ok(view2(s), (r->0).0 as int, (r->0).1 as int),
        r is Some ==> (r->0).0 < s.frames.len() && (r->0).1 < s.stack.len(),
{
    match v {
        Value::BlockRef(f, slot) => if x_ref_ok(s, f, slot) { Some((f, slot)) } else { None },
        _ => None,
    }
}

pub fn x_outer_slot(s: &ExecState, f: usize, slot: usize, k: usize) -> (r: Option<usize>)
    requires f < s.frames.len(),
    ensures
        r is Some <==> outer_slot(view2(s), f as int, slot as int, k as int) is Some,
        r is Some ==> outer_slot(view2(s), f as int, slot as int, k as int) == Some(r->0 as int),
{
    if k <= slot && s.frames[f].base <= slot - k { Some(slot - k) } else { None }
}

pub fn x_load_outer(s: &mut ExecState, k: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))),
    ensures matches2(op_load_outer(view2(old(s)), k as int), r, view2(final(s))),
{
    if !x_has_slot(s, 0) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_block_ref(s, x_at(s, 0)) {
        None => ExecOutcome2::Stuck(Stuck::NotBlock),
        Some((f, slot)) => match x_outer_slot(s, f, slot, k) {
            None => ExecOutcome2::Stuck(Stuck::StackRange),
            Some(i) => {
                let v = s.stack[i];
                x_put(s, 0, v);
                x_next(s, 2)
            },
        },
    }
}

pub fn x_store_outer(s: &mut ExecState, k: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))),
    ensures matches2(op_store_outer(view2(old(s)), k as int), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    if !x_has_slot(s, 1) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let v = x_at(s, 0);
    match x_block_ref(s, x_at(s, 1)) {
        None => ExecOutcome2::Stuck(Stuck::NotBlock),
        Some((f, slot)) => match x_outer_slot(s, f, slot, k) {
            None => ExecOutcome2::Stuck(Stuck::StackRange),
            Some(i) => {
                if i >= s.stack.len() - 2 {
                    return ExecOutcome2::Stuck(Stuck::StackRange);
                }
                x_drop(s, 2);
                let ghost s1 = view2(s);
                s.stack.set(i, v);
                proof { assert(view2(s) == (State2 { stack: s1.stack.update(i as int, v), ..s1 })); }
                x_push(s, v);
                x_next(s, 2)
            },
        },
    }
}

pub fn x_load_block(s: &mut ExecState, k: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))), old(s).frames.len() > 0,
    ensures matches2(op_load_block(view2(old(s)), k as int), r, view2(final(s))),
{
    if !x_has_slot(s, k) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let fi = s.frames.len() - 1;
    let slot = s.stack.len() - 1 - k;
    x_push(s, Value::BlockRef(fi, slot));
    x_next(s, 2)
}

pub fn x_load_outer_block(s: &mut ExecState, k: usize) -> (r: ExecOutcome2)
    requires wf_state2(view2(old(s))),
    ensures matches2(op_load_outer_block(view2(old(s)), k as int), r, view2(final(s))),
{
    if !x_has_slot(s, 0) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_block_ref(s, x_at(s, 0)) {
        None => ExecOutcome2::Stuck(Stuck::NotBlock),
        Some((f, slot)) => match x_outer_slot(s, f, slot, k) {
            None => ExecOutcome2::Stuck(Stuck::StackRange),
            Some(i) => {
                x_put(s, 0, Value::BlockRef(f, i));
                x_next(s, 2)
            },
        },
    }
}

pub fn x_block_target(p: &ExecProgram, s: &ExecState, slot: usize) -> (r: Option<usize>)
    requires slot < s.stack.len(),
    ensures
        r is Some <==> block_target(pview2(p), view2(s), slot as int) is Some,
        r is Some ==> block_target(pview2(p), view2(s), slot as int) == Some(r->0 as int),
{
    match s.stack[slot] {
        Value::Smi(m) => {
            if 0 <= m && (m as u64) < (p.methods.len() as u64) {
                let mi = m as usize;
                assert(mi as int == m as int);
                let k = p.methods[mi].kind;
                if k == 3 { Some(mi) } else { None }
            } else {
                None
            }
        },
        _ => None,
    }
}

pub fn x_invoke_block(p: &ExecProgram, s: &mut ExecState, n: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), n < 256,
    ensures matches2(op_invoke_block(pview2(p), view2(old(s)), n as int), r, view2(final(s))),
{
    if n < 1 || !x_has_slot(s, n - 1) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_block_ref(s, x_at(s, n - 1)) {
        None => ExecOutcome2::Stuck(Stuck::NotBlock),
        Some((_, slot)) => match x_block_target(p, s, slot) {
            None => x_raise(p, s, 3),
            Some(t) => {
                let a = p.methods[t].arity as usize;
                if n < a {
                    return x_raise(p, s, 2);
                }
                let ret = s.bci + 2;
                x_drop(s, n - a);
                x_call(p, s, t as i64, ret)
            },
        },
    }
}

pub fn x_non_local_return(p: &ExecProgram, s: &mut ExecState) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))),
    ensures matches2(op_non_local_return(pview2(p), view2(old(s))), r, view2(final(s))),
{
    if !x_has_slot(s, 1) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_block_ref(s, x_at(s, 0)) {
        None => ExecOutcome2::Stuck(Stuck::NotBlock),
        Some((f, _)) => {
            if f >= s.frames.len() - 1 {
                return ExecOutcome2::Stuck(Stuck::BadFrame);
            }
            let v = x_at(s, 1);
            x_unwind(p, s, Unwind::Return(f, v))
        },
    }
}

pub fn x_non_local_branch(p: &ExecProgram, s: &mut ExecState, hd: usize, off: u32) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), hd < 256,
    ensures matches2(op_non_local_branch(pview2(p), view2(old(s)), hd as int, off as int), r, view2(final(s))),
{
    if !x_has_slot(s, 0) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_block_ref(s, x_at(s, 0)) {
        None => ExecOutcome2::Stuck(Stuck::NotBlock),
        Some((f, slot)) => {
            let m = s.frames[f].method;
            if f >= s.frames.len() - 1 {
                return ExecOutcome2::Stuck(Stuck::BadFrame);
            }
            if slot + 1 < hd || slot + 1 - hd < s.frames[f].base {
                return ExecOutcome2::Stuck(Stuck::StackRange);
            }
            if m >= p.methods.len() {
                return ExecOutcome2::Stuck(Stuck::BadBranch);
            }
            let info = p.methods[m];
            if !((info.entry as u64) + (off as u64) < info.end as u64) {
                return ExecOutcome2::Stuck(Stuck::BadBranch);
            }
            x_unwind(p, s, Unwind::Branch(f, info.entry + off as usize, slot + 1 - hd))
        },
    }
}

pub fn x_try(p: &ExecProgram, s: &mut ExecState) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))),
    ensures matches2(op_try(pview2(p), view2(old(s))), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    if !x_has_slot(s, 0) || s.frames.len() == 0 {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let fi = s.frames.len() - 1;
    let height = s.stack.len();
    let bci = s.bci;
    let slot = height - 1;
    let target = x_block_target(p, s, slot);
    match target {
        None => x_raise(p, s, 3),
        Some(t) => {
            if p.methods[t].arity != 1 {
                return x_raise(p, s, 2);
            }
            x_push(s, Value::BlockRef(fi, slot));
            let ghost s1 = view2(s);
            let r = x_call(p, s, t as i64, bci + 1);
            match r {
                ExecOutcome2::Next => {
                    let n = s.frames.len() - 1;
                    let fr = s.frames[n];
                    s.frames.set(n, Frame { handler: true, ..fr });
                    proof { assert(view2(s).frames =~= flag_top(call(pview2(p), s1, t as int, bci + 1)->Next_0).frames); }
                    r
                },
                _ => r,
            }
        },
    }
}

pub fn x_unwind_op(p: &ExecProgram, s: &mut ExecState) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))),
    ensures matches2(op_unwind(pview2(p), view2(old(s))), r, view2(final(s))),
{
    let ghost s0 = view2(s);
    if !x_has_slot(s, 3) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let wb = x_at(s, 1);
    let wa = x_at(s, 2);
    let value = x_at(s, 3);
    let d = match wa {
        Value::Token(false, d, g, h) => {
            if x_value_eq(wb, Value::Token(true, d, g, h)) && s.frames.len() > 0 && g == s.frames.len() - 1
                && s.stack.len() >= 4 && h == s.stack.len() - 4 {
                d
            } else {
                return ExecOutcome2::Stuck(Stuck::NotUnwind);
            }
        },
        _ => { return ExecOutcome2::Stuck(Stuck::NotUnwind); },
    };
    proof { assert(token_at(s0) == Some(d)); }
    x_drop(s, 4);
    match d {
        Pending::Normal => x_next(s, 1),
        Pending::Throw => x_unwind(p, s, Unwind::Throw(value)),
        Pending::Return(f) => x_unwind(p, s, Unwind::Return(f, value)),
        Pending::Branch(f, bci, hb) => x_unwind(p, s, Unwind::Branch(f, bci, hb)),
    }
}


// ---------------------------------------------------------------------------
// Calls and returns as opcodes.

pub fn x_invoke_static_tail(p: &ExecProgram, s: &mut ExecState, d: usize) -> (r: ExecOutcome2)
    requires wf_program2(pview2(p)), wf_state2(view2(old(s))), old(s).frames.len() > 0,
    ensures matches2(op_invoke_static_tail(pview2(p), view2(old(s)), d as int), r, view2(final(s))),
{
    let t = x_dispatch_target(p, d);
    if !x_valid_method(p, t) {
        return ExecOutcome2::Stuck(Stuck::NotMethod);
    }
    let a = p.methods[t as usize].arity as usize;
    let b = x_base(s);
    if b > s.stack.len() || a > s.stack.len() - b {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    match x_receiver_check(p, s, t as usize) {
        None => ExecOutcome2::Stuck(Stuck::NotObject),
        Some(true) => x_raise(p, s, 1),
        Some(false) => {
            let len = s.stack.len();
            let ghost st = s.stack@;
            let mut args: Vec<Value> = Vec::new();
            let start = len - a;
            let mut i = start;
            while i < len
                invariant
                    start <= i <= len, len == st.len(), s.stack@ == st,
                    args@ =~= st.subrange(start as int, i as int),
                decreases len - i,
            {
                args.push(s.stack[i]);
                proof { assert(st.subrange(start as int, i + 1) =~= st.subrange(start as int, i as int).push(st[i as int])); }
                i = i + 1;
            }
            x_replace_frame(p, s, t as usize, args)
        },
    }
}

// ---------------------------------------------------------------------------
// The step function at each covered opcode. `step` is opaque; each lemma
// reveals it for one family of opcodes.

pub open spec fn op_at(p: Program2, s: State2) -> u8 {
    p.bytecodes[s.bci as int]
}

pub open spec fn b1_at(p: Program2, s: State2) -> int {
    byte2(p, s.bci + 1)
}

pub open spec fn w1_at(p: Program2, s: State2) -> int {
    u16_at(p1(p), s.bci + 1)
}

proof fn lemma_step_bad(p: Program2, s: State2)
    requires !instruction_ok(p, s),
    ensures step(p, s) == stuck(Stuck::BadInstruction),
{
    reveal(step);
}

proof fn lemma_step_locals(p: Program2, s: State2)
    requires instruction_ok(p, s),
    ensures
        op_at(p, s) == LOAD_LOCAL ==> step(p, s) == op_load_local(s, b1_at(p, s), 2),
        op_at(p, s) == LOAD_LOCAL_WIDE ==> step(p, s) == op_load_local(s, w1_at(p, s), 3),
        LOAD_LOCAL_0 <= op_at(p, s) <= LOAD_LOCAL_5 ==>
            step(p, s) == op_load_local(s, op_at(p, s) - LOAD_LOCAL_0, 1),
        op_at(p, s) == POP_LOAD_LOCAL ==> step(p, s) == op_pop_load_local(s, b1_at(p, s)),
        op_at(p, s) == STORE_LOCAL ==> step(p, s) == op_store_local(s, b1_at(p, s)),
        op_at(p, s) == STORE_LOCAL_POP ==> step(p, s) == op_store_local_pop(s, b1_at(p, s)),
{
    reveal(step);
}

proof fn lemma_step_blocks(p: Program2, s: State2)
    requires instruction_ok(p, s),
    ensures
        op_at(p, s) == LOAD_OUTER ==> step(p, s) == op_load_outer(s, b1_at(p, s)),
        op_at(p, s) == STORE_OUTER ==> step(p, s) == op_store_outer(s, b1_at(p, s)),
        op_at(p, s) == LOAD_BLOCK ==> step(p, s) == op_load_block(s, b1_at(p, s)),
        op_at(p, s) == LOAD_OUTER_BLOCK ==> step(p, s) == op_load_outer_block(s, b1_at(p, s)),
        op_at(p, s) == INVOKE_BLOCK ==> step(p, s) == op_invoke_block(p, s, b1_at(p, s)),
        op_at(p, s) == NON_LOCAL_RETURN ==> step(p, s) == op_non_local_return(p, s),
        op_at(p, s) == NON_LOCAL_BRANCH ==>
            step(p, s) == op_non_local_branch(p, s, b1_at(p, s), u32_at(p1(p), s.bci + 2)),
        op_at(p, s) == TRY ==> step(p, s) == op_try(p, s),
        op_at(p, s) == UNWIND ==> step(p, s) == op_unwind(p, s),
{
    reveal(step);
}

proof fn lemma_step_fields(p: Program2, s: State2)
    requires instruction_ok(p, s),
    ensures
        op_at(p, s) == LOAD_FIELD ==> step(p, s) == op_load_field(p, s, b1_at(p, s), 2),
        op_at(p, s) == LOAD_FIELD_WIDE ==> step(p, s) == op_load_field(p, s, w1_at(p, s), 3),
        op_at(p, s) == LOAD_FIELD_LOCAL ==> step(p, s) == op_load_field_local(p, s, b1_at(p, s), false),
        op_at(p, s) == POP_LOAD_FIELD_LOCAL ==> step(p, s) == op_load_field_local(p, s, b1_at(p, s), true),
        op_at(p, s) == STORE_FIELD ==> step(p, s) == op_store_field(p, s, b1_at(p, s), 2, true),
        op_at(p, s) == STORE_FIELD_WIDE ==> step(p, s) == op_store_field(p, s, w1_at(p, s), 3, true),
        op_at(p, s) == STORE_FIELD_POP ==> step(p, s) == op_store_field(p, s, b1_at(p, s), 2, false),
        op_at(p, s) == LOAD_FIELD_THIS ==> step(p, s) == op_load_field_this(p, s, b1_at(p, s)),
        op_at(p, s) == STORE_FIELD_THIS ==> step(p, s) == op_store_field_this(p, s, b1_at(p, s)),
{
    reveal(step);
}

proof fn lemma_step_constants(p: Program2, s: State2)
    requires instruction_ok(p, s),
    ensures
        op_at(p, s) == LOAD_LITERAL ==> step(p, s) == op_load_literal(p, s, b1_at(p, s), 2),
        op_at(p, s) == LOAD_LITERAL_WIDE ==> step(p, s) == op_load_literal(p, s, w1_at(p, s), 3),
        op_at(p, s) == LOAD_NULL ==> step(p, s) == next(push(s, null2(p)), 1),
        op_at(p, s) == LOAD_SMI_0 ==> step(p, s) == next(push(s, smi(0)), 1),
        op_at(p, s) == LOAD_SMIS_0 ==> step(p, s) == op_load_smis_0(s, b1_at(p, s)),
        op_at(p, s) == LOAD_SMI_1 ==> step(p, s) == next(push(s, smi(1)), 1),
        op_at(p, s) == LOAD_SMI_U8 ==> step(p, s) == next(push(s, smi(b1_at(p, s))), 2),
        op_at(p, s) == LOAD_SMI_U16 ==> step(p, s) == next(push(s, smi(w1_at(p, s))), 3),
        op_at(p, s) == LOAD_SMI_U32 ==> step(p, s) == op_load_smi(p, s, u32_at(p1(p), s.bci + 1), 5),
        op_at(p, s) == LOAD_METHOD ==> step(p, s) == op_load_method(p, s, u32_at(p1(p), s.bci + 1)),
        op_at(p, s) == POP ==> step(p, s) == op_pop(s, b1_at(p, s), 2),
        op_at(p, s) == POP_1 ==> step(p, s) == op_pop(s, 1, 1),
{
    reveal(step);
}

proof fn lemma_step_calls(p: Program2, s: State2)
    requires instruction_ok(p, s),
    ensures
        op_at(p, s) == INVOKE_STATIC ==> step(p, s) == op_invoke_static(p, s, w1_at(p, s)),
        op_at(p, s) == INVOKE_STATIC_TAIL ==> step(p, s) == op_invoke_static_tail(p, s, w1_at(p, s)),
        op_at(p, s) == INVOKE_VIRTUAL ==>
            step(p, s) == invoke_virtual(p, s, u16_at(p1(p), s.bci + 2), b1_at(p, s) + 1, 4),
        op_at(p, s) == INVOKE_VIRTUAL_WIDE ==>
            step(p, s) == invoke_virtual(p, s, u16_at(p1(p), s.bci + 3), w1_at(p, s) + 1, 5),
        op_at(p, s) == RETURN ==> step(p, s) ==
            (if !has_slot(s, 0) { stuck(Stuck::StackRange) } else { return_from(p, s, at(s, 0)) }),
        op_at(p, s) == RETURN_NULL ==> step(p, s) == return_from(p, s, null2(p)),
        op_at(p, s) == THROW ==> step(p, s) ==
            (if !has_slot(s, 0) { stuck(Stuck::StackRange) } else { unwind(p, s, Unwind::Throw(at(s, 0))) }),
{
    reveal(step);
}

proof fn lemma_step_operators(p: Program2, s: State2)
    requires instruction_ok(p, s), INVOKE_EQ <= op_at(p, s) <= INVOKE_MOD,
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

proof fn lemma_step_branches(p: Program2, s: State2)
    requires instruction_ok(p, s), BRANCH <= op_at(p, s) <= BRANCH_BACK_IF_NOT_NULL || BRANCH_S <= op_at(p, s) <= BRANCH_BACK_S,
    ensures
        op_at(p, s) <= BRANCH_IF_NOT_NULL && w1_at(p, s) == 0 ==> step(p, s) == stuck(Stuck::BadBranch),
        op_at(p, s) <= BRANCH_IF_NOT_NULL && w1_at(p, s) != 0 ==>
            step(p, s) == op_branch(p, s, op_at(p, s) - BRANCH, s.bci + w1_at(p, s), 3),
        BRANCH_BACK <= op_at(p, s) <= BRANCH_BACK_IF_NOT_NULL ==>
            step(p, s) == op_branch(p, s, op_at(p, s) - BRANCH_BACK, s.bci - w1_at(p, s), 3),
        BRANCH_S <= op_at(p, s) <= BRANCH_IF_NOT_NULL_S && b1_at(p, s) == 0 ==> step(p, s) == stuck(Stuck::BadBranch),
        BRANCH_S <= op_at(p, s) <= BRANCH_IF_NOT_NULL_S && b1_at(p, s) != 0 ==>
            step(p, s) == op_branch(p, s, op_at(p, s) - BRANCH_S, s.bci + b1_at(p, s), 2),
        op_at(p, s) == BRANCH_BACK_S ==> step(p, s) == op_branch(p, s, 0, s.bci - b1_at(p, s), 2),
{
    reveal(step);
}

/// Common precondition of the per-family dispatchers.
pub open spec fn decoded(p: &ExecProgram, s: &ExecState, op: u8, len: usize, b1: usize, w1: usize) -> bool {
    let pv = pview2(p);
    let sv = view2(s);
    &&& wf_exec_program2(p)
    &&& wf_exec_state2(s)
    &&& instruction_ok(pv, sv)
    &&& op == op_at(pv, sv)
    &&& len as int == opcode_length2(op)
    &&& s.bci + len <= p.bytecodes.len()
    &&& (len >= 2 ==> b1 as int == b1_at(pv, sv))
    &&& (len >= 3 ==> w1 as int == w1_at(pv, sv))
    &&& b1 < 256 && w1 < 0x1_0000
}

fn x_u32_at(p: &ExecProgram, i: usize) -> (r: u32)
    requires i + 4 <= p.bytecodes.len(),
    ensures r as int == u32_at(p1(pview2(p)), i as int),
{
    (p.bytecodes[i] as u32) + 256 * (p.bytecodes[i + 1] as u32)
        + 65536 * ((p.bytecodes[i + 2] as u32) + 256 * (p.bytecodes[i + 3] as u32))
}

fn x_u16_at(p: &ExecProgram, i: usize) -> (r: u16)
    requires i + 2 <= p.bytecodes.len(),
    ensures r as int == u16_at(p1(pview2(p)), i as int),
{
    (p.bytecodes[i] as u16) + 256 * (p.bytecodes[i + 1] as u16)
}

fn x_step_locals(_p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, b1: usize, w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(_p, old(s), op, len, b1, w1),
        op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op <= LOAD_LOCAL_5)
            || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP,
    ensures matches2(step(pview2(_p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_locals(pview2(_p), view2(s)); }
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

fn x_step_blocks(p: &ExecProgram, s: &mut ExecState, op: u8, _len: usize, b1: usize, _w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, _len, b1, _w1),
        op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_BLOCK || op == LOAD_OUTER_BLOCK
            || op == INVOKE_BLOCK || op == NON_LOCAL_RETURN || op == NON_LOCAL_BRANCH || op == TRY
            || op == UNWIND,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_blocks(pview2(p), view2(s)); }
    if op == LOAD_OUTER {
        x_load_outer(s, b1)
    } else if op == STORE_OUTER {
        x_store_outer(s, b1)
    } else if op == LOAD_BLOCK {
        x_load_block(s, b1)
    } else if op == LOAD_OUTER_BLOCK {
        x_load_outer_block(s, b1)
    } else if op == INVOKE_BLOCK {
        x_invoke_block(p, s, b1)
    } else if op == NON_LOCAL_RETURN {
        x_non_local_return(p, s)
    } else if op == NON_LOCAL_BRANCH {
        let off = x_u32_at(p, s.bci + 2);
        x_non_local_branch(p, s, b1, off)
    } else if op == TRY {
        x_try(p, s)
    } else {
        x_unwind_op(p, s)
    }
}

fn x_step_fields(p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, b1: usize, w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, len, b1, w1),
        (LOAD_FIELD <= op <= STORE_FIELD_POP) || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_fields(pview2(p), view2(s)); }
    if op == LOAD_FIELD {
        x_load_field(p, s, b1, len)
    } else if op == LOAD_FIELD_WIDE {
        x_load_field(p, s, w1, len)
    } else if op == LOAD_FIELD_LOCAL {
        x_load_field_local(p, s, b1, false)
    } else if op == POP_LOAD_FIELD_LOCAL {
        x_load_field_local(p, s, b1, true)
    } else if op == STORE_FIELD {
        x_store_field(p, s, b1, len, true)
    } else if op == STORE_FIELD_WIDE {
        x_store_field(p, s, w1, len, true)
    } else if op == STORE_FIELD_POP {
        x_store_field(p, s, b1, len, false)
    } else if op == LOAD_FIELD_THIS {
        x_load_field_this(p, s, b1)
    } else {
        x_store_field_this(p, s, b1)
    }
}

fn x_step_constants(p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, b1: usize, w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, len, b1, w1),
        (LOAD_LITERAL <= op <= LOAD_METHOD) || op == POP || op == POP_1,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_constants(pview2(p), view2(s)); }
    if op == LOAD_LITERAL {
        x_load_literal(p, s, b1, len)
    } else if op == LOAD_LITERAL_WIDE {
        x_load_literal(p, s, w1, len)
    } else if op == LOAD_NULL {
        x_push(s, x_null(p));
        x_next(s, len)
    } else if op == LOAD_SMI_0 {
        x_push(s, Value::Smi(0));
        x_next(s, len)
    } else if op == LOAD_SMIS_0 {
        x_load_smis_0(s, b1)
    } else if op == LOAD_SMI_1 {
        x_push(s, Value::Smi(1));
        x_next(s, len)
    } else if op == LOAD_SMI_U8 {
        x_push(s, Value::Smi(b1 as i64));
        x_next(s, len)
    } else if op == LOAD_SMI_U16 {
        x_push(s, Value::Smi(w1 as i64));
        x_next(s, len)
    } else if op == LOAD_SMI_U32 {
        let v = x_u32_at(p, s.bci + 1);
        x_load_smi(p, s, v, len)
    } else if op == LOAD_METHOD {
        let v = x_u32_at(p, s.bci + 1);
        x_load_method(p, s, v)
    } else if op == POP {
        x_pop(s, b1, len)
    } else {
        x_pop(s, 1, len)
    }
}

fn x_step_calls(p: &ExecProgram, s: &mut ExecState, op: u8, _len: usize, b1: usize, w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, _len, b1, w1),
        op == INVOKE_STATIC || op == INVOKE_STATIC_TAIL || op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE
            || op == RETURN || op == RETURN_NULL || op == THROW,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_calls(pview2(p), view2(s)); }
    if op == INVOKE_STATIC {
        let t = x_dispatch_target(p, w1);
        x_call_static(p, s, t, 3)
    } else if op == INVOKE_STATIC_TAIL {
        x_invoke_static_tail(p, s, w1)
    } else if op == INVOKE_VIRTUAL {
        let sel = x_u16_at(p, s.bci + 2);
        x_invoke_virtual(p, s, sel as i64, b1 + 1, 4)
    } else if op == INVOKE_VIRTUAL_WIDE {
        let sel = x_u16_at(p, s.bci + 3);
        x_invoke_virtual(p, s, sel as i64, w1 + 1, 5)
    } else if op == RETURN {
        if !x_has_slot(s, 0) {
            return ExecOutcome2::Stuck(Stuck::StackRange);
        }
        let v = x_at(s, 0);
        x_return(p, s, v)
    } else if op == RETURN_NULL {
        let n = x_null(p);
        x_return(p, s, n)
    } else {
        if !x_has_slot(s, 0) {
            return ExecOutcome2::Stuck(Stuck::StackRange);
        }
        let v = x_at(s, 0);
        x_unwind(p, s, Unwind::Throw(v))
    }
}

fn x_step_operators(p: &ExecProgram, s: &mut ExecState, op: u8, _len: usize, _b1: usize, _w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, _len, _b1, _w1),
        INVOKE_EQ <= op <= INVOKE_MOD,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_operators(pview2(p), view2(s)); }
    if !x_has_slot(s, 1) {
        ExecOutcome2::Stuck(Stuck::StackRange)
    } else if op == INVOKE_EQ {
        x_invoke_eq(p, s)
    } else if op <= INVOKE_GTE {
        x_invoke_relational(p, s, op)
    } else {
        x_invoke_arith(p, s, op)
    }
}

fn x_step_branches(p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, b1: usize, w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, len, b1, w1),
        BRANCH <= op <= BRANCH_BACK_IF_NOT_NULL || BRANCH_S <= op <= BRANCH_BACK_S,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_branches(pview2(p), view2(s)); }
    let bci = s.bci;
    if op >= BRANCH_S {
        // The short branches (format note 22): a one-byte distance.
        if op == BRANCH_BACK_S {
            x_branch(p, s, 0, bci as i64 - b1 as i64, len)
        } else if b1 == 0 {
            ExecOutcome2::Stuck(Stuck::BadBranch)
        } else {
            x_branch(p, s, op - BRANCH_S, bci as i64 + b1 as i64, len)
        }
    } else if op <= BRANCH_IF_NOT_NULL {
        if w1 == 0 {
            return ExecOutcome2::Stuck(Stuck::BadBranch);
        }
        x_branch(p, s, op - BRANCH, bci as i64 + w1 as i64, len)
    } else {
        x_branch(p, s, op - BRANCH_BACK, bci as i64 - w1 as i64, len)
    }
}

proof fn lemma_step_loop_repeat(p: Program2, s: State2)
    requires instruction_ok(p, s), op_at(p, s) == LOOP_REPEAT,
    ensures step(p, s) == op_loop_repeat(p, s, s.bci - w1_at(p, s), byte2(p, s.bci + 3), 4),
{
    reveal(step);
}

/// LOOP_REPEAT (proposal, format note 19).
fn x_step_loops(p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, _b1: usize, w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, len, _b1, w1),
        op == LOOP_REPEAT,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_loop_repeat(pview2(p), view2(s)); }
    let bci = s.bci;
    let n = p.bytecodes[bci + 3] as usize;
    if !(1 <= n && x_has_slot(s, n) && x_has_slot(s, n + 1) && x_has_slot(s, n + 2)) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let vc = x_at(s, n);
    let vb = x_at(s, n + 1);
    let vl = x_at(s, n + 2);
    match (vc, vl) {
        (Value::Smi(i), Value::Smi(l)) => {
            if i < l {
                x_put(s, n, Value::Smi(i + 1));
                x_drop(s, 1);
                x_push(s, vb);
                x_push(s, vc);
                proof {
                    assert(view2(s) == push(push(drop(put(view2(old(s)), n as int, smi(i + 1)), 1), at(view2(old(s)), n as int + 1)), vc));
                }
                return x_branch_to(p, s, bci as i64 - w1 as i64);
            }
        },
        _ => {},
    }
    x_drop(s, 1);
    x_next(s, len)
}

proof fn lemma_step_loop_array(p: Program2, s: State2)
    requires instruction_ok(p, s), op_at(p, s) == LOOP_ARRAY,
    ensures step(p, s) == op_loop_array(p, s, s.bci - w1_at(p, s), byte2(p, s.bci + 3), 4),
{
    reveal(step);
}

/// The element `i` of `a` if `a` is an array with more than `i` elements.
fn x_array_elem(s: &ExecState, a: Value, i: i64) -> (r: Option<Value>)
    ensures
        match r {
            Some(v) => is_array(as1(view2(s)), a) && 0 <= i < elements(as1(view2(s)), a).len()
                && v == elements(as1(view2(s)), a)[i as int],
            None => !(is_array(as1(view2(s)), a) && 0 <= i < elements(as1(view2(s)), a).len()),
        },
{
    match a {
        Value::Obj(id) => {
            if id >= s.heap.len() { return None; }
            proof { lemma_heap_index(s, id as int); }
            match &s.heap[id].body {
                ExecBody::Array(e) => {
                    if 0 <= i && (i as u64) < (e.len() as u64) { Some(e[i as usize]) } else { None }
                },
                _ => None,
            }
        },
        _ => None,
    }
}

/// LOOP_ARRAY (proposal, format note 19).
fn x_step_loop_array(p: &ExecProgram, s: &mut ExecState, op: u8, len: usize, _b1: usize, w1: usize) -> (r: ExecOutcome2)
    requires
        decoded(p, old(s), op, len, _b1, w1),
        op == LOOP_ARRAY,
    ensures matches2(step(pview2(p), view2(old(s))), r, view2(final(s))),
{
    proof { lemma_step_loop_array(pview2(p), view2(s)); }
    let bci = s.bci;
    let n = p.bytecodes[bci + 3] as usize;
    if !(1 <= n && x_has_slot(s, n) && x_has_slot(s, n + 1) && x_has_slot(s, n + 2) && x_has_slot(s, n + 3)) {
        return ExecOutcome2::Stuck(Stuck::StackRange);
    }
    let vc = x_at(s, n);
    let vb = x_at(s, n + 1);
    let ve = x_at(s, n + 2);
    let va = x_at(s, n + 3);
    match (vc, ve) {
        (Value::Smi(i), Value::Smi(e)) => {
            if 0 <= i && i < e {
                match x_array_elem(s, va, i) {
                    Some(v) => {
                        x_put(s, n, Value::Smi(i + 1));
                        x_drop(s, 1);
                        x_push(s, vb);
                        x_push(s, v);
                        proof {
                            assert(view2(s) == push(push(drop(put(view2(old(s)), n as int, smi(i + 1)), 1), at(view2(old(s)), n as int + 1)), v));
                        }
                        return x_branch_to(p, s, bci as i64 - w1 as i64);
                    },
                    None => {},
                }
            }
        },
        _ => {},
    }
    x_drop(s, 1);
    x_next(s, len)
}

/// One step of the covered opcodes. `None`: not covered, state unchanged.
pub fn step_verified(p: &ExecProgram, s: &mut ExecState) -> (r: Option<ExecOutcome2>)
    requires wf_exec_program2(p), wf_exec_state2(old(s)),
    ensures
        match r {
            Some(o) => matches2(step(pview2(p), view2(old(s))), o, view2(final(s))),
            None => view2(final(s)) == view2(old(s)),
        },
{
    let ghost pv = pview2(p);
    let ghost s0 = view2(s);
    if s.frames.len() == 0 {
        proof { lemma_step_bad(pv, s0); }
        return Some(ExecOutcome2::Stuck(Stuck::BadInstruction));
    }
    let m = s.frames[s.frames.len() - 1].method;
    if m >= p.methods.len() {
        proof { lemma_step_bad(pv, s0); }
        return Some(ExecOutcome2::Stuck(Stuck::BadInstruction));
    }
    let info = p.methods[m];
    let bci = s.bci;
    if !(info.entry <= bci && bci < info.end) || info.end > p.bytecodes.len() {
        proof { lemma_step_bad(pv, s0); }
        return Some(ExecOutcome2::Stuck(Stuck::BadInstruction));
    }
    let op = p.bytecodes[bci];
    if op >= OPCODE_COUNT2 {
        proof { lemma_step_bad(pv, s0); }
        return Some(ExecOutcome2::Stuck(Stuck::BadInstruction));
    }
    let len = exec_opcode_length2(op);
    if bci + len > info.end {
        proof { lemma_step_bad(pv, s0); }
        return Some(ExecOutcome2::Stuck(Stuck::BadInstruction));
    }
    let b1: usize = if len >= 2 { p.bytecodes[bci + 1] as usize } else { 0 };
    let w1: usize = if len >= 3 { b1 + 256 * (p.bytecodes[bci + 2] as usize) } else { 0 };
    assert(decoded(p, s, op, len, b1, w1));
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5)
        || op == POP_LOAD_LOCAL || op == STORE_LOCAL || op == STORE_LOCAL_POP {
        Some(x_step_locals(p, s, op, len, b1, w1))
    } else if op == LOAD_OUTER || op == STORE_OUTER || op == LOAD_BLOCK || op == LOAD_OUTER_BLOCK
        || op == INVOKE_BLOCK || op == NON_LOCAL_RETURN || op == NON_LOCAL_BRANCH || op == TRY
        || op == UNWIND {
        Some(x_step_blocks(p, s, op, len, b1, w1))
    } else if (LOAD_FIELD <= op && op <= STORE_FIELD_POP) || op == LOAD_FIELD_THIS || op == STORE_FIELD_THIS {
        Some(x_step_fields(p, s, op, len, b1, w1))
    } else if (LOAD_LITERAL <= op && op <= LOAD_METHOD) || op == POP || op == POP_1 {
        Some(x_step_constants(p, s, op, len, b1, w1))
    } else if op == INVOKE_STATIC || op == INVOKE_STATIC_TAIL || op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE
        || op == RETURN || op == RETURN_NULL || op == THROW {
        Some(x_step_calls(p, s, op, len, b1, w1))
    } else if INVOKE_EQ <= op && op <= INVOKE_MOD {
        Some(x_step_operators(p, s, op, len, b1, w1))
    } else if (BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL) || (BRANCH_S <= op && op <= BRANCH_BACK_S) {
        Some(x_step_branches(p, s, op, len, b1, w1))
    } else if op == LOOP_REPEAT {
        Some(x_step_loops(p, s, op, len, b1, w1))
    } else if op == LOOP_ARRAY {
        Some(x_step_loop_array(p, s, op, len, b1, w1))
    } else {
        None
    }
}

} // verus!
