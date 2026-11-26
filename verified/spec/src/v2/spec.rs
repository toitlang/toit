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

//! The step function of the revised format (format 2).
//!
//! Every opcode has a spec function `op_*`; `step` decodes the instruction
//! at `s.bci` (which must lie inside the top frame's method) and
//! dispatches. Compared to format 1 (`crate::spec_step`):
//!
//! * the frame stack is separate: calls push a `Frame`, returns pop it, and
//!   local slots are only accessible inside the top frame;
//! * block references are `(frame, slot)`; a non-local return or branch
//!   unwinds to that frame;
//! * TRY installs a `Handler`; unwinding enters the finally code of the
//!   innermost handler with an unwinding token (the index of a finally
//!   record, `Fin`), which UNWIND resumes;
//! * failures (lookup, as-check, code invocation, invalid program,
//!   primitive lookup) raise an exception (`raise`), they do not call Toit
//!   methods;
//! * method ids read from data (lambdas, initializers, block slots) are
//!   checked at run time (index and kind) and raise INVALID_PROGRAM;
//! * field access is checked (raises INVALID_PROGRAM) except for
//!   LOAD_FIELD_THIS/STORE_FIELD_THIS, whose receiver is guaranteed by the
//!   method's declared receiver range; the fields of a task the machine
//!   owns (its stack, its id) are not writable, the stack not readable;
//! * the intrinsics are gone.
//!
//! `Stuck` remains for what the structural verifier must exclude
//! (`v2::verifier`).

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::bytecodes::*;
use crate::spec_common::INSTANCE_TAG;
#[cfg(verus_only)]
use crate::spec_common::{
    smi, smi_ok, u16_at, u32_at, builtin, class_tag, instance_field_count, is_instance, fields,
    obj, obj_id, is_array, elements, class_id_ok, class_id_of, class_of_obj, new_double,
    LAZY_INITIALIZER_CLASS, EXCEPTION_CLASS, TASK_CLASS, ENTRY_MAIN, ENTRY_TASK, RUN_GLOBAL_INITIALIZER,
    TOMBSTONE_CLASS,
};
use crate::spec_helpers::{Check, FastAt, COMPARE_FLAG_EQUAL};
#[cfg(verus_only)]
use crate::spec_helpers::{
    compare_numbers, are_smis, smi_val, are_floats, identical, typecheck_class, fast_at,
    FAST_AT_FUEL, fast_size, is_nan_bits, band,
};
#[cfg(verus_only)]
use crate::spec_step::{smi_arith, float_arith, relational_flag, relational_smi};

verus! {

// ---------------------------------------------------------------------------
// Program tables.

pub spec const OBJECT_CLASS: int = 15;

pub spec const KIND_METHOD: u8 = 0;
pub spec const KIND_FIELD_ACCESSOR: u8 = 1;
pub spec const KIND_LAMBDA: u8 = 2;
pub spec const KIND_BLOCK: u8 = 3;

/// The exceptions the machine raises; the value is `literals[2 + k]`.
pub spec const LOOKUP_FAILED: int = 0;
pub spec const AS_CHECK_FAILED: int = 1;
pub spec const CODE_INVOCATION_FAILED: int = 2;
pub spec const INVALID_PROGRAM: int = 3;
pub spec const PRIMITIVE_LOOKUP_FAILED: int = 4;

pub open spec fn null2(p: Program2) -> Value { p.roots[0] }
pub open spec fn true2(p: Program2) -> Value { p.roots[1] }
pub open spec fn false2(p: Program2) -> Value { p.roots[2] }

pub open spec fn boolean2(p: Program2, b: bool) -> Value {
    if b { true2(p) } else { false2(p) }
}

pub open spec fn truthy2(p: Program2, v: Value) -> bool {
    v != false2(p) && v != null2(p)
}

pub open spec fn byte2(p: Program2, i: int) -> int {
    p.bytecodes[i] as int
}

pub open spec fn valid_method(p: Program2, m: int) -> bool {
    0 <= m < p.methods.len()
}

pub open spec fn info(p: Program2, m: int) -> MethodInfo
    recommends valid_method(p, m),
{
    p.methods[m]
}

pub open spec fn arity(p: Program2, m: int) -> int {
    p.methods[m].arity as int
}

pub open spec fn has_receiver_range(i: MethodInfo) -> bool {
    i.recv_start != 0xffff
}

/// Method id of entry point `k`, or -1.
pub open spec fn entry_method(p: Program2, k: int) -> int {
    let d = p.entry_points[k] as int;
    if 0 <= d < p.dispatch.len() { p.dispatch[d] as int } else { -1 }
}

/// INVOKE_STATIC's target: a method id from the dispatch table.
pub open spec fn dispatch_target(p: Program2, d: int) -> int {
    if 0 <= d < p.dispatch.len() { p.dispatch[d] as int } else { -1 }
}

// ---------------------------------------------------------------------------
// The object stack, seen from the top frame.

pub open spec fn top(s: State2) -> Frame
    recommends s.frames.len() > 0,
{
    s.frames.last()
}

pub open spec fn top_index(s: State2) -> int {
    s.frames.len() - 1
}

pub open spec fn base(s: State2) -> int {
    if s.frames.len() > 0 { top(s).base as int } else { 0 }
}

/// Number of slots of the top frame: parameters, locals, temporaries.
pub open spec fn frame_height(s: State2) -> int {
    s.stack.len() - base(s)
}

pub open spec fn has_slot(s: State2, n: int) -> bool {
    0 <= n < frame_height(s)
}

/// `STACK_AT(n)`.
pub open spec fn at(s: State2, n: int) -> Value
    recommends has_slot(s, n),
{
    s.stack[s.stack.len() - 1 - n]
}

pub open spec fn push(s: State2, v: Value) -> State2 {
    State2 { stack: s.stack.push(v), ..s }
}

pub open spec fn drop(s: State2, n: int) -> State2 {
    State2 { stack: s.stack.subrange(0, s.stack.len() - n), ..s }
}

pub open spec fn put(s: State2, n: int, v: Value) -> State2 {
    State2 { stack: s.stack.update(s.stack.len() - 1 - n, v), ..s }
}

pub open spec fn goto(s: State2, bci: int) -> State2 {
    State2 { bci: bci as usize, ..s }
}

pub open spec fn next(s: State2, len: int) -> Outcome2 {
    Outcome2::Next(goto(s, s.bci + len))
}

pub open spec fn stuck(r: Stuck) -> Outcome2 {
    Outcome2::Stuck(r)
}

/// The slot of a block reference belongs to the live frame `f`: it is at or
/// above the frame's base and below the next frame's (or the top).
pub open spec fn ref_ok(s: State2, f: int, slot: int) -> bool {
    &&& 0 <= f < s.frames.len()
    &&& 0 <= slot < s.stack.len()
    &&& s.frames[f].base as int <= slot
    &&& slot < (if f + 1 < s.frames.len() { s.frames[f + 1].base as int } else { s.stack.len() as int })
}

/// The block reference `v`, or `None`.
pub open spec fn block_ref(s: State2, v: Value) -> Option<(int, int)> {
    match v {
        Value::BlockRef(f, slot) => if ref_ok(s, f as int, slot as int) { Some((f as int, slot as int)) } else { None },
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Heap.

pub open spec fn alloc2(s: State2, o: HeapObj) -> State2 {
    State2 { heap: s.heap.push(o), ..s }
}

pub open spec fn new_ref2(s: State2) -> Value {
    Value::Obj(s.heap.len() as usize)
}

/// Field `f` of an instance exists.
pub open spec fn field_ok(s: State2, inst: Value, f: int) -> bool {
    is_instance(as1(s), inst) && 0 <= f < fields(as1(s), inst).len()
}

/// The fields of a task the machine owns: field 0 holds the task's stack
/// (`Task::STACK_INDEX`; the scheduler, the task switch and the collector
/// use it as the task's stack) and is neither readable nor writable by the
/// program; field 1 holds the task's id (`Task::ID_INDEX`, a smi) and is
/// read-only. Only the task primitives (`v2::prim`) change them.
pub spec const TASK_STACK_FIELD: int = 0;
pub spec const TASK_ID_FIELD: int = 1;

/// `inst` is a task: an instance of the builtin task class.
pub open spec fn is_task_obj(p: Program2, s: State2, inst: Value) -> bool {
    is_instance(as1(s), inst) && class_of_obj(as1(s), inst) == builtin(p1(p), TASK_CLASS)
}

/// Field `f` of `inst` exists and the program may read it.
pub open spec fn field_readable(p: Program2, s: State2, inst: Value, f: int) -> bool {
    field_ok(s, inst, f) && !(is_task_obj(p, s, inst) && f == TASK_STACK_FIELD)
}

/// Field `f` of `inst` exists and the program may write it: not in the
/// read-only program heap, not a field the machine owns.
pub open spec fn field_writable(p: Program2, s: State2, inst: Value, f: int) -> bool {
    field_ok(s, inst, f) && !is_ro(s, inst) && !(is_task_obj(p, s, inst) && f <= TASK_ID_FIELD)
}

pub open spec fn field(s: State2, inst: Value, f: int) -> Value {
    fields(as1(s), inst)[f]
}

pub open spec fn is_ro(s: State2, v: Value) -> bool {
    obj(as1(s), v).ro
}

pub open spec fn set_field2(s: State2, inst: Value, f: int, v: Value) -> State2 {
    let o = obj(as1(s), inst);
    State2 {
        heap: s.heap.update(obj_id(inst), HeapObj { body: Body::Instance(fields(as1(s), inst).update(f, v)), ..o }),
        ..s
    }
}

// ---------------------------------------------------------------------------
// Calls and returns.

/// Pushes a frame for `target`, whose arguments are the top `arity(target)`
/// slots of the current frame, returning to `ret`.
pub open spec fn call(p: Program2, s: State2, target: int, ret: int) -> Outcome2 {
    if !valid_method(p, target) {
        stuck(Stuck::NotMethod)
    } else if arity(p, target) > frame_height(s) {
        stuck(Stuck::StackRange)
    } else {
        Outcome2::Next(State2 {
            frames: s.frames.push(Frame { method: target as usize, ret: ret as usize, base: (s.stack.len() - arity(p, target)) as usize }),
            bci: info(p, target).entry,
            ..s
        })
    }
}

/// The receiver (parameter 0) of a statically called method is outside the
/// method's declared receiver range.
pub open spec fn receiver_fails(p: Program2, s: State2, target: int) -> bool {
    has_receiver_range(info(p, target)) && {
        let r = at(s, arity(p, target) - 1);
        let cid = class_id_of(p1(p), as1(s), r);
        !(info(p, target).recv_start as int <= cid && cid < info(p, target).recv_end as int)
    }
}

/// The receiver check needs a receiver with a class.
pub open spec fn receiver_check_ok(p: Program2, s: State2, target: int) -> bool {
    has_receiver_range(info(p, target)) ==>
        arity(p, target) >= 1 && class_id_ok(as1(s), at(s, arity(p, target) - 1))
}

/// INVOKE_STATIC and the calls of entry points: the receiver check, then
/// the call.
pub open spec fn call_static(p: Program2, s: State2, target: int, len: int) -> Outcome2 {
    if !valid_method(p, target) {
        stuck(Stuck::NotMethod)
    } else if arity(p, target) > frame_height(s) {
        stuck(Stuck::StackRange)
    } else if !receiver_check_ok(p, s, target) {
        stuck(Stuck::NotObject)
    } else if receiver_fails(p, s, target) {
        raise(p, s, AS_CHECK_FAILED)
    } else {
        call(p, s, target, s.bci + len)
    }
}

/// The top frame has an active handler (it is suspended in a TRY).
pub open spec fn has_handler(s: State2) -> bool {
    s.tries.len() > 0 && s.tries.last().frame as int == top_index(s)
}

/// Drops the trailing finally records of frames above `g` and those of
/// frame `g` at height `lim` or above. Records are ordered by frame and
/// height (`v2::sound::fins_ok`), so `cut_fins(fins, t, 0)` drops exactly
/// the records of frames `t` and above.
pub open spec fn cut_fins(fins: Seq<Fin>, g: int, lim: int) -> Seq<Fin>
    decreases fins.len(),
{
    if fins.len() > 0 && (fins.last().frame as int > g || (fins.last().frame as int == g && fins.last().height as int >= lim)) {
        cut_fins(fins.drop_last(), g, lim)
    } else {
        fins
    }
}

/// The records after popping the top frame.
pub open spec fn fins_popped(s: State2) -> Seq<Fin> {
    cut_fins(s.fins, top_index(s), 0)
}

/// What the finally code of unwinding `u` resumes.
pub open spec fn resume_of(u: Unwind) -> Resume {
    match u {
        Unwind::Throw(_) => Resume::Throw,
        Unwind::Return(f, _) => Resume::Return(f),
        Unwind::Branch(f, bci, h) => Resume::Branch(f, bci, h),
    }
}

/// The first slot of the finally code of unwinding `u`: the exception or
/// the return value (null for a branch).
pub open spec fn value_of(p: Program2, u: Unwind) -> Value {
    match u {
        Unwind::Throw(v) => v,
        Unwind::Return(_, v) => v,
        Unwind::Branch(_, _, _) => null2(p),
    }
}

/// The unwinding UNWIND resumes: the record's, with the value of the
/// finally code's first slot.
pub open spec fn unwind_of(r: Resume, v: Value) -> Unwind {
    match r {
        Resume::Throw => Unwind::Throw(v),
        Resume::Return(f) => Unwind::Return(f, v),
        Resume::Branch(f, bci, h) => Unwind::Branch(f, bci, h),
    }
}

/// Returns `result` from the top frame. If the caller is a TRY whose try
/// block just returned, its finally code runs.
pub open spec fn return_from(p: Program2, s: State2, result: Value) -> Outcome2 {
    if s.frames.len() == 0 {
        stuck(Stuck::BadFrame)
    } else if has_handler(s) {
        stuck(Stuck::BadFrame)
    } else if s.frames.len() == 1 {
        Outcome2::Halt(s, Halt2::TaskReturned)
    } else if top(s).base as int > s.stack.len() {
        stuck(Stuck::StackRange)
    } else {
        let s1 = State2 {
            stack: s.stack.subrange(0, top(s).base as int).push(result),
            frames: s.frames.drop_last(),
            fins: fins_popped(s),
            bci: top(s).ret,
            ..s
        };
        if has_handler(s1) {
            enter_finally(p, s1, s1.tries.last(), None)
        } else {
            Outcome2::Next(s1)
        }
    }
}

/// Enters the finally code of handler `h` (the last handler, of the top
/// frame), normally (`None`) or while unwinding: the object stack is cut
/// back to the TRY's height, and the value (the exception or return
/// value, else null), the unwinding token and the reason (-2 for an
/// exception, -1 otherwise) are pushed. The token is null for a normal
/// completion; for an unwinding it is the smi index of a new finally
/// record that takes the handler's place (no allocation).
pub open spec fn enter_finally(p: Program2, s: State2, h: Handler, u: Option<Unwind>) -> Outcome2 {
    if !(base(s) <= h.height as int <= s.stack.len()) {
        stuck(Stuck::StackRange)
    } else {
        let s1 = State2 {
            stack: s.stack.subrange(0, h.height as int),
            tries: s.tries.drop_last(),
            bci: h.bci,
            ..s
        };
        match u {
            None => Outcome2::Next(push(push(push(s1, null2(p)), null2(p)), smi(-1))),
            Some(w) => {
                let token = smi(s1.fins.len() as int);
                let s2 = State2 {
                    fins: s1.fins.push(Fin { frame: h.frame, height: h.height, resume: resume_of(w) }),
                    ..s1
                };
                let reason = match w { Unwind::Throw(_) => -2int, _ => -1int };
                Outcome2::Next(push(push(push(s2, value_of(p, w)), token), smi(reason)))
            },
        }
    }
}

/// Pops the top frame, its object-stack slots and its finally records.
pub open spec fn pop_frame(s: State2) -> State2
    recommends s.frames.len() > 0,
{
    State2 { stack: s.stack.subrange(0, top(s).base as int), frames: s.frames.drop_last(), fins: fins_popped(s), ..s }
}

/// Unwinds: the innermost handler of the top frame gets control (with the
/// unwinding as token); a non-local return or branch that reaches its
/// frame completes; otherwise the top frame is popped. An exception that
/// passes the bottom frame ends the task.
pub open spec fn unwind(p: Program2, s: State2, u: Unwind) -> Outcome2
    decreases s.frames.len(),
{
    if s.frames.len() == 0 {
        match u {
            Unwind::Throw(v) => Outcome2::Halt(s, Halt2::Uncaught(v)),
            _ => stuck(Stuck::BadFrame),
        }
    } else if has_handler(s) {
        enter_finally(p, s, s.tries.last(), Some(u))
    } else if top(s).base as int > s.stack.len() {
        stuck(Stuck::StackRange)
    } else {
        let fi = top_index(s);
        match u {
            Unwind::Return(f, v) => {
                if f as int == fi { return_from(p, s, v) } else { unwind(p, pop_frame(s), u) }
            },
            Unwind::Branch(f, bci, h) => {
                if f as int == fi {
                    if !(base(s) <= h as int <= s.stack.len()) {
                        stuck(Stuck::StackRange)
                    } else {
                        Outcome2::Next(State2 { stack: s.stack.subrange(0, h as int), bci: bci, ..s })
                    }
                } else {
                    unwind(p, pop_frame(s), u)
                }
            },
            Unwind::Throw(_) => unwind(p, pop_frame(s), u),
        }
    }
}

/// The exception object the machine raises: an `Exception_` with `value`
/// (field 0), `trace` (field 1) and null in its other fields.
pub open spec fn exception_obj2(p: Program2, value: Value, trace: Value) -> HeapObj {
    let cid = builtin(p1(p), EXCEPTION_CLASS);
    HeapObj {
        class_id: cid as u16,
        ro: false,
        body: Body::Instance(Seq::new(instance_field_count(p1(p), cid) as nat, |i: int|
            if i == 0 { value } else if i == 1 { trace } else { null2(p) })),
    }
}

/// The exception object of failure `k` without a trace (what the reference
/// interpreter raises).
pub open spec fn exception_obj(p: Program2, k: int) -> HeapObj {
    exception_obj2(p, p.literals[2 + k], null2(p))
}

/// The value of the exception of failure `k`: the failure string.
pub open spec fn failure_value(p: Program2, k: int) -> Value {
    p.literals[2 + k]
}

/// Raises failure `k`: the machine allocates the exception (an oracle
/// step: the trace is the machine's, `v2::prim::raised`) and unwinds.
pub open spec fn raise(p: Program2, s: State2, k: int) -> Outcome2 {
    Outcome2::Raise(s, failure_value(p, k))
}

/// Throws a new exception with value `value` and trace `trace`, allocated
/// at the end of the heap: one completion of `Raise(s, value)`.
pub open spec fn throw_exception(p: Program2, s: State2, value: Value, trace: Value) -> Outcome2 {
    let cid = builtin(p1(p), EXCEPTION_CLASS);
    if !(0 <= cid < p.class_bits.len()) || instance_field_count(p1(p), cid) < 2 {
        stuck(Stuck::Fatal)
    } else {
        unwind(p, alloc2(s, exception_obj2(p, value, trace)), Unwind::Throw(new_ref2(s)))
    }
}

/// The reference interpreter's completion of a raise: no trace, no other
/// allocation (the step function before raising became an oracle step).
pub open spec fn raise_null(p: Program2, s: State2, k: int) -> Outcome2 {
    throw_exception(p, s, failure_value(p, k), null2(p))
}

/// Replaces the top frame's method by `target`, whose arguments are `args`
/// (tail calls); the return address stays.
pub open spec fn replace_frame(p: Program2, s: State2, target: int, args: Seq<Value>) -> Outcome2 {
    if has_handler(s) {
        stuck(Stuck::BadFrame)
    } else {
        Outcome2::Next(State2 {
            stack: s.stack.subrange(0, base(s)) + args,
            frames: s.frames.update(top_index(s), Frame { method: target as usize, ..top(s) }),
            fins: fins_popped(s),
            bci: info(p, target).entry,
            ..s
        })
    }
}

// ---------------------------------------------------------------------------
// Dispatch.

pub enum Lookup2 {
    Found(int),
    Missing,
    Stuck(Stuck),
}

/// `find_method` on the method table: the entry at class id + selector,
/// if its selector matches.
pub open spec fn find_method(p: Program2, s: State2, receiver: Value, sel: int) -> Lookup2 {
    if !class_id_ok(as1(s), receiver) {
        Lookup2::Stuck(Stuck::NotObject)
    } else if sel < 0 {
        Lookup2::Missing
    } else {
        let index = class_id_of(p1(p), as1(s), receiver) + sel;
        if !(0 <= index < p.dispatch.len()) {
            Lookup2::Stuck(Stuck::TableRange)
        } else {
            let entry = p.dispatch[index] as int;
            if entry == -1 {
                Lookup2::Missing
            } else if !valid_method(p, entry) {
                Lookup2::Stuck(Stuck::NotMethod)
            } else if info(p, entry).selector as int != sel {
                Lookup2::Missing
            } else {
                Lookup2::Found(entry)
            }
        }
    }
}

/// A virtual call of selector `sel` with `n` arguments (receiver included)
/// on the stack. The target's arity must match the call site's.
pub open spec fn invoke_virtual(p: Program2, s: State2, sel: int, n: int, len: int) -> Outcome2 {
    if !(1 <= n && has_slot(s, n - 1)) {
        stuck(Stuck::StackRange)
    } else {
        match find_method(p, s, at(s, n - 1), sel) {
            Lookup2::Stuck(r) => stuck(r),
            Lookup2::Missing => raise(p, s, LOOKUP_FAILED),
            Lookup2::Found(t) => {
                if arity(p, t) != n {
                    stuck(Stuck::BadArity)
                } else {
                    call(p, s, t, s.bci + len)
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Locals.

pub open spec fn op_load_local(s: State2, n: int, len: int) -> Outcome2 {
    if !has_slot(s, n) { stuck(Stuck::StackRange) } else { next(push(s, at(s, n)), len) }
}

pub open spec fn op_pop_load_local(s: State2, n: int) -> Outcome2 {
    if !has_slot(s, n + 1) { stuck(Stuck::StackRange) } else { next(put(s, 0, at(s, n + 1)), 2) }
}

pub open spec fn op_store_local(s: State2, n: int) -> Outcome2 {
    if !has_slot(s, n) { stuck(Stuck::StackRange) } else { next(put(s, n, at(s, 0)), 2) }
}

pub open spec fn op_store_local_pop(s: State2, n: int) -> Outcome2 {
    if n < 1 || !has_slot(s, n) {
        stuck(Stuck::StackRange)
    } else {
        next(put(drop(s, 1), n - 1, at(s, 0)), 2)
    }
}

// ---------------------------------------------------------------------------
// Blocks. A block reference names the frame and slot of the block's method
// id; LOAD_OUTER/STORE_OUTER/LOAD_OUTER_BLOCK address slots of that frame
// relative to the block's slot.

/// The slot `k` below a block reference's slot, inside the block's frame.
pub open spec fn outer_slot(s: State2, f: int, slot: int, k: int) -> Option<int> {
    if 0 <= k && s.frames[f].base as int <= slot - k { Some(slot - k) } else { None }
}

pub open spec fn op_load_outer(s: State2, k: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match block_ref(s, at(s, 0)) {
            None => stuck(Stuck::NotBlock),
            Some((f, slot)) => match outer_slot(s, f, slot, k) {
                None => stuck(Stuck::StackRange),
                Some(i) => next(put(s, 0, s.stack[i]), 2),
            },
        }
    }
}

pub open spec fn op_store_outer(s: State2, k: int) -> Outcome2 {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, 0);
        match block_ref(s, at(s, 1)) {
            None => stuck(Stuck::NotBlock),
            Some((f, slot)) => match outer_slot(s, f, slot, k) {
                None => stuck(Stuck::StackRange),
                Some(i) => {
                    let s1 = drop(s, 2);
                    if i >= s1.stack.len() {
                        stuck(Stuck::StackRange)
                    } else {
                        next(push(State2 { stack: s1.stack.update(i, v), ..s1 }, v), 2)
                    }
                },
            },
        }
    }
}

pub open spec fn op_load_block(s: State2, k: int) -> Outcome2 {
    if !has_slot(s, k) {
        stuck(Stuck::StackRange)
    } else {
        next(push(s, Value::BlockRef(top_index(s) as usize, (s.stack.len() - 1 - k) as usize)), 2)
    }
}

pub open spec fn op_load_outer_block(s: State2, k: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match block_ref(s, at(s, 0)) {
            None => stuck(Stuck::NotBlock),
            Some((f, slot)) => match outer_slot(s, f, slot, k) {
                None => stuck(Stuck::StackRange),
                Some(i) => next(put(s, 0, Value::BlockRef(f as usize, i as usize)), 2),
            },
        }
    }
}

/// The block method in a block's slot: checked at run time.
pub open spec fn block_target(p: Program2, s: State2, slot: int) -> Option<int> {
    match s.stack[slot] {
        Value::Smi(m) => if valid_method(p, m as int) && info(p, m as int).kind == KIND_BLOCK { Some(m as int) } else { None },
        _ => None,
    }
}

/// INVOKE_BLOCK n: the block reference is at STACK_AT(n - 1), followed by
/// the arguments. Extra arguments are dropped; too few raise.
pub open spec fn op_invoke_block(p: Program2, s: State2, n: int) -> Outcome2 {
    if n < 1 || !has_slot(s, n - 1) {
        stuck(Stuck::StackRange)
    } else {
        match block_ref(s, at(s, n - 1)) {
            None => stuck(Stuck::NotBlock),
            Some((f, slot)) => match block_target(p, s, slot) {
                None => raise(p, s, INVALID_PROGRAM),
                Some(t) => {
                    if n < arity(p, t) {
                        raise(p, s, CODE_INVOCATION_FAILED)
                    } else {
                        call(p, drop(s, n - arity(p, t)), t, s.bci + 2)
                    }
                },
            },
        }
    }
}

/// NON_LOCAL_RETURN: return the value below the block reference from the
/// block's frame, running the finally code of the frames in between.
pub open spec fn op_non_local_return(p: Program2, s: State2) -> Outcome2 {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        match block_ref(s, at(s, 0)) {
            None => stuck(Stuck::NotBlock),
            Some((f, slot)) => {
                if f >= top_index(s) {
                    stuck(Stuck::BadFrame)
                } else {
                    unwind(p, s, Unwind::Return(f as usize, at(s, 1)))
                }
            },
        }
    }
}

/// NON_LOCAL_BRANCH h off: continue in the block's frame at `off` from its
/// method's entry, with the object stack cut to `h` slots below the end of
/// the block's slot.
pub open spec fn op_non_local_branch(p: Program2, s: State2, hd: int, off: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match block_ref(s, at(s, 0)) {
            None => stuck(Stuck::NotBlock),
            Some((f, slot)) => {
                let m = s.frames[f].method as int;
                if f >= top_index(s) {
                    stuck(Stuck::BadFrame)
                } else if slot + 1 - hd < s.frames[f].base as int {
                    stuck(Stuck::StackRange)
                } else if !valid_method(p, m) || !(info(p, m).entry + off < info(p, m).end) {
                    stuck(Stuck::BadBranch)
                } else {
                    unwind(p, s, Unwind::Branch(f as usize, (info(p, m).entry + off) as usize, (slot + 1 - hd) as usize))
                }
            },
        }
    }
}

/// TRY: install a handler of the current frame (finally code right after
/// the TRY), then call the try block, whose method is the top slot, with a
/// reference to that slot. The frame's trailing finally records whose
/// token slot is at the TRY's height or above (left by a `break` out of
/// finally code) are dropped first: no live token names them, and the
/// frame's records stay below the handler's height.
pub open spec fn op_try(p: Program2, s: State2) -> Outcome2 {
    if !has_slot(s, 0) || s.frames.len() == 0 {
        stuck(Stuck::StackRange)
    } else {
        let h = Handler { frame: top_index(s) as usize, height: s.stack.len() as usize, bci: (s.bci + 1) as usize };
        let s1 = State2 { tries: s.tries.push(h), fins: cut_fins(s.fins, top_index(s), s.stack.len() - 1), ..s };
        let slot = s.stack.len() - 1;
        match block_target(p, s, slot) {
            None => raise(p, s1, INVALID_PROGRAM),
            Some(t) => {
                if arity(p, t) != 1 {
                    raise(p, s1, CODE_INVOCATION_FAILED)
                } else {
                    call(p, push(s1, Value::BlockRef(top_index(s) as usize, slot as usize)), t, s.bci + 1)
                }
            },
        }
    }
}

/// The token `k` names a finally record of the top frame whose token slot
/// is the UNWIND's.
pub open spec fn fin_matches(s: State2, k: int) -> bool {
    &&& 0 <= k < s.fins.len()
    &&& s.fins[k].frame as int == top_index(s)
    &&& s.fins[k].height as int + 1 == s.stack.len() - 2
}

/// UNWIND: the end of a finally code. Pops reason, token and value; a null
/// token continues, a token resumes its record's unwinding with the value
/// (the records from the token's on are dropped).
pub open spec fn op_unwind(p: Program2, s: State2) -> Outcome2 {
    if !has_slot(s, 2) {
        stuck(Stuck::StackRange)
    } else {
        let token = at(s, 1);
        let s1 = drop(s, 3);
        if token == null2(p) {
            next(s1, 1)
        } else {
            match token {
                Value::Smi(k) => {
                    if fin_matches(s, k as int) {
                        unwind(p, State2 { fins: s.fins.subrange(0, k as int), ..s1 }, unwind_of(s.fins[k as int].resume, at(s, 2)))
                    } else {
                        stuck(Stuck::NotUnwind)
                    }
                },
                _ => stuck(Stuck::NotUnwind),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Fields.

/// A field access whose run-time check failed (a receiver other than `this`
/// that is not an instance with the field, a machine-owned task field, a
/// store into the program heap): INVALID_PROGRAM. For the unchecked twins
/// of the field accesses (`bytecodes::is_twin`, format note 20; trusted
/// programs in the unchecked mode `Program2::unchecked` only) the machine
/// does not check: the access is assumed to succeed, and its failure is a
/// stuck state (`Stuck::FieldRange`, used for nothing else in format 2).
/// The verifier accepts twins only in the unchecked mode, and the mode only
/// for trusted programs (`accepts`); the soundness theorem is stated
/// without it.
pub open spec fn unchecked_fail(p: Program2, s: State2) -> Outcome2 {
    if twin_at(p, s) { stuck(Stuck::FieldRange) } else { raise(p, s, INVALID_PROGRAM) }
}

/// The instruction at the bci is an unchecked twin.
pub open spec fn twin_at(p: Program2, s: State2) -> bool {
    is_twin(p.bytecodes[s.bci as int])
}

pub open spec fn op_load_field(p: Program2, s: State2, f: int, len: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else if !field_readable(p, s, at(s, 0), f) {
        unchecked_fail(p, s)
    } else {
        next(put(s, 0, field(s, at(s, 0), f)), len)
    }
}

/// LOAD_FIELD_LOCAL enc / POP_LOAD_FIELD_LOCAL enc: local = enc & 15,
/// field = enc >> 4.
pub open spec fn op_load_field_local(p: Program2, s: State2, enc: int, pop: bool) -> Outcome2 {
    let local = enc % 16;
    let f = enc / 16;
    let slot = if pop { local + 1 } else { local };
    if !has_slot(s, slot) {
        stuck(Stuck::StackRange)
    } else if !field_readable(p, s, at(s, slot), f) {
        unchecked_fail(p, s)
    } else {
        let v = field(s, at(s, slot), f);
        if pop { next(put(s, 0, v), 2) } else { next(push(s, v), 2) }
    }
}

pub open spec fn op_store_field(p: Program2, s: State2, f: int, len: int, keep: bool) -> Outcome2 {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        let v = at(s, 0);
        let inst = at(s, 1);
        if !field_writable(p, s, inst, f) {
            unchecked_fail(p, s)
        } else {
            let s1 = set_field2(drop(s, 2), inst, f, v);
            if keep { next(push(s1, v), len) } else { next(s1, len) }
        }
    }
}

/// `this` of the top frame: parameter 0 of a method with a declared
/// receiver range. Its field accesses are not checked at run time; the
/// verifier proves them (`v2::verifier`), including that they do not touch
/// the fields of a task the machine owns.
pub open spec fn this_ok(p: Program2, s: State2, f: int) -> bool {
    &&& s.frames.len() > 0
    &&& valid_method(p, top(s).method as int)
    &&& has_receiver_range(info(p, top(s).method as int))
    &&& arity(p, top(s).method as int) >= 1
    &&& 0 <= top(s).base < s.stack.len()
    &&& field_ok(s, s.stack[top(s).base as int], f)
}

pub open spec fn op_load_field_this(p: Program2, s: State2, f: int) -> Outcome2 {
    if !this_ok(p, s, f) || (is_task_obj(p, s, s.stack[top(s).base as int]) && f == TASK_STACK_FIELD) {
        stuck(Stuck::NotInstance)
    } else {
        next(push(s, field(s, s.stack[top(s).base as int], f)), 2)
    }
}

/// STORE_FIELD_THIS f: the value stays on the stack. Program-heap objects
/// are read-only (checked at run time).
pub open spec fn op_store_field_this(p: Program2, s: State2, f: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else if !this_ok(p, s, f) || (is_task_obj(p, s, s.stack[top(s).base as int]) && f <= TASK_ID_FIELD) {
        stuck(Stuck::NotInstance)
    } else {
        let this = s.stack[top(s).base as int];
        if is_ro(s, this) {
            unchecked_fail(p, s)
        } else {
            next(set_field2(s, this, f, at(s, 0)), 2)
        }
    }
}

// ---------------------------------------------------------------------------
// Constants and globals.

pub open spec fn op_load_literal(p: Program2, s: State2, i: int, len: int) -> Outcome2 {
    if !(0 <= i < p.literals.len()) { stuck(Stuck::TableRange) } else { next(push(s, p.literals[i]), len) }
}

/// LOAD_SMI_*: the operand must be a smi (no wrapping).
pub open spec fn op_load_smi(p: Program2, s: State2, v: int, len: int) -> Outcome2 {
    if !smi_ok(p1(p), v) { stuck(Stuck::SmiRange) } else { next(push(s, smi(v)), len) }
}

pub open spec fn op_load_smis_0(s: State2, n: int) -> Outcome2 {
    next(State2 { stack: s.stack + Seq::new(n as nat, |i: int| Value::Smi(0)), ..s }, 2)
}

/// LOAD_METHOD m: the method id (an index into the method table).
pub open spec fn op_load_method(p: Program2, s: State2, m: int) -> Outcome2 {
    if !valid_method(p, m) || !smi_ok(p1(p), m) { stuck(Stuck::NotMethod) } else { next(push(s, smi(m)), 5) }
}

pub open spec fn op_load_global(s: State2, g: int, len: int) -> Outcome2 {
    if !(0 <= g < s.globals.len()) { stuck(Stuck::TableRange) } else { next(push(s, s.globals[g]), len) }
}

pub open spec fn is_lazy(p: Program2, s: State2, v: Value) -> bool {
    is_instance(as1(s), v) && class_of_obj(as1(s), v) == builtin(p1(p), LAZY_INITIALIZER_CLASS)
}

/// LOAD_GLOBAL_VAR_LAZY g: an initializer in the global is replaced by the
/// result of `run_global_initializer(g, initializer)`.
pub open spec fn op_load_global_lazy(p: Program2, s: State2, g: int, len: int) -> Outcome2 {
    if !(0 <= g < s.globals.len()) {
        stuck(Stuck::TableRange)
    } else if is_lazy(p, s, s.globals[g]) {
        call_static(p, push(push(s, smi(g)), s.globals[g]), entry_method(p, RUN_GLOBAL_INITIALIZER), len)
    } else {
        next(push(s, s.globals[g]), len)
    }
}

/// A dynamic global index: a smi in range, else INVALID_PROGRAM.
pub open spec fn global_index(s: State2, v: Value) -> Option<int> {
    match v {
        Value::Smi(i) => if 0 <= i < s.globals.len() { Some(i as int) } else { None },
        _ => None,
    }
}

pub open spec fn op_load_global_dynamic(p: Program2, s: State2) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match global_index(s, at(s, 0)) {
            None => raise(p, s, INVALID_PROGRAM),
            Some(g) => next(put(s, 0, s.globals[g]), 1),
        }
    }
}

pub open spec fn op_store_global(s: State2, g: int, len: int) -> Outcome2 {
    if !(0 <= g < s.globals.len()) {
        stuck(Stuck::TableRange)
    } else if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        next(State2 { globals: s.globals.update(g, at(s, 0)), ..s }, len)
    }
}

pub open spec fn op_store_global_dynamic(p: Program2, s: State2) -> Outcome2 {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        match global_index(s, at(s, 1)) {
            None => raise(p, s, INVALID_PROGRAM),
            Some(g) => {
                let s1 = drop(s, 2);
                next(State2 { globals: s1.globals.update(g, at(s, 0)), ..s1 }, 1)
            },
        }
    }
}

pub open spec fn op_pop(s: State2, n: int, len: int) -> Outcome2 {
    if !(0 <= n <= frame_height(s)) { stuck(Stuck::StackRange) } else { next(drop(s, n), len) }
}

pub open spec fn op_allocate(p: Program2, s: State2, c: int, len: int) -> Outcome2 {
    if !(0 <= c < p.class_bits.len()) {
        stuck(Stuck::TableRange)
    } else if class_tag(p1(p), c) != INSTANCE_TAG || instance_field_count(p1(p), c) < 0 {
        stuck(Stuck::NotInstantiable)
    } else {
        let o = HeapObj {
            class_id: c as u16,
            ro: false,
            body: Body::Instance(Seq::new(instance_field_count(p1(p), c) as nat, |i: int| null2(p))),
        };
        next(push(alloc2(s, o), new_ref2(s)), len)
    }
}

// ---------------------------------------------------------------------------
// Type checks.

pub open spec fn typecheck(p: Program2, s: State2, v: Value, index: int, nullable: bool, interface: bool) -> Check {
    if !interface {
        typecheck_class(p1(p), as1(s), v, index, nullable)
    } else if nullable && v == null2(p) {
        Check::Yes
    } else if !(0 <= index < p.interface_check_offsets.len()) {
        Check::Stuck(Stuck::TableRange)
    } else {
        match find_method(p, s, v, p.interface_check_offsets[index] as int) {
            Lookup2::Found(_) => Check::Yes,
            Lookup2::Missing => Check::No,
            Lookup2::Stuck(r) => Check::Stuck(r),
        }
    }
}

pub open spec fn op_is(p: Program2, s: State2, enc: int, interface: bool, len: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match typecheck(p, s, at(s, 0), enc / 2, enc % 2 == 1, interface) {
            Check::Stuck(r) => stuck(r),
            Check::Yes => next(put(s, 0, true2(p)), len),
            Check::No => next(put(s, 0, false2(p)), len),
        }
    }
}

pub open spec fn op_as(p: Program2, s: State2, enc: int, interface: bool, len: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match typecheck(p, s, at(s, 0), enc / 2, enc % 2 == 1, interface) {
            Check::Stuck(r) => stuck(r),
            Check::Yes => next(s, len),
            Check::No => raise(p, s, AS_CHECK_FAILED),
        }
    }
}

/// AS_LOCAL enc: local = enc >> 5, class check index = enc & 31.
pub open spec fn op_as_local(p: Program2, s: State2, enc: int) -> Outcome2 {
    if !has_slot(s, enc / 32) {
        stuck(Stuck::StackRange)
    } else {
        match typecheck(p, s, at(s, enc / 32), enc % 32, false, false) {
            Check::Stuck(r) => stuck(r),
            Check::Yes => next(s, 2),
            Check::No => raise(p, s, AS_CHECK_FAILED),
        }
    }
}

// ---------------------------------------------------------------------------
// Static, tail, lambda and initializer calls.

pub open spec fn op_invoke_static(p: Program2, s: State2, d: int) -> Outcome2 {
    call_static(p, s, dispatch_target(p, d), 3)
}

/// INVOKE_STATIC_TAIL d: the top `arity` slots become the arguments of the
/// target, which replaces the current frame's method.
pub open spec fn op_invoke_static_tail(p: Program2, s: State2, d: int) -> Outcome2 {
    let t = dispatch_target(p, d);
    if !valid_method(p, t) {
        stuck(Stuck::NotMethod)
    } else if arity(p, t) > frame_height(s) {
        stuck(Stuck::StackRange)
    } else if !receiver_check_ok(p, s, t) {
        stuck(Stuck::NotObject)
    } else if receiver_fails(p, s, t) {
        raise(p, s, AS_CHECK_FAILED)
    } else {
        replace_frame(p, s, t, s.stack.subrange(s.stack.len() - arity(p, t), s.stack.len() as int))
    }
}

/// The captured values of a lambda: an array of the declared count, or a
/// single non-array value if it captures one.
pub open spec fn captured(p: Program2, s: State2, argument: Value, c: int) -> Option<Seq<Value>> {
    if is_array(as1(s), argument) {
        if elements(as1(s), argument).len() == c { Some(elements(as1(s), argument)) } else { None }
    } else if c == 1 {
        Some(seq![argument])
    } else {
        None
    }
}

/// INVOKE_LAMBDA_TAIL: in the body of `Lambda.call` (parameters: the
/// lambda, then the arguments; nothing else on the frame). The lambda's
/// method id and captures come from the heap and are checked.
pub open spec fn op_invoke_lambda_tail(p: Program2, s: State2) -> Outcome2 {
    if s.frames.len() == 0 || !valid_method(p, top(s).method as int) {
        stuck(Stuck::BadFrame)
    } else {
        let a = arity(p, top(s).method as int);
        let b = base(s);
        if a < 1 || frame_height(s) != a {
            stuck(Stuck::StackRange)
        } else {
            let recv = s.stack[b];
            if !is_instance(as1(s), recv) || fields(as1(s), recv).len() < 2 {
                raise(p, s, INVALID_PROGRAM)
            } else {
                let mid = fields(as1(s), recv)[0];
                match mid {
                    Value::Smi(m) => {
                        if !valid_method(p, m as int) || info(p, m as int).kind != KIND_LAMBDA {
                            raise(p, s, INVALID_PROGRAM)
                        } else {
                            let t = m as int;
                            let c = info(p, t).aux as int;
                            match captured(p, s, fields(as1(s), recv)[1], c) {
                                None => raise(p, s, INVALID_PROGRAM),
                                Some(cap) => {
                                    let user = arity(p, t) - c;
                                    if user < 0 {
                                        raise(p, s, INVALID_PROGRAM)
                                    } else if a - 1 < user {
                                        raise(p, s, CODE_INVOCATION_FAILED)
                                    } else {
                                        replace_frame(p, s, t, s.stack.subrange(b + 1, b + 1 + user) + cap)
                                    }
                                },
                            }
                        }
                    },
                    _ => raise(p, s, INVALID_PROGRAM),
                }
            }
        }
    }
}

/// INVOKE_INITIALIZER_TAIL: the top slot is the initializer's method id
/// (from a LazyInitializer_, checked).
pub open spec fn op_invoke_initializer_tail(p: Program2, s: State2) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match at(s, 0) {
            Value::Smi(m) => {
                if !valid_method(p, m as int) || info(p, m as int).kind != KIND_METHOD || arity(p, m as int) != 0 {
                    raise(p, s, INVALID_PROGRAM)
                } else {
                    replace_frame(p, s, m as int, Seq::empty())
                }
            },
            _ => raise(p, s, INVALID_PROGRAM),
        }
    }
}

// ---------------------------------------------------------------------------
// Virtual calls with field-accessor fast paths.

pub open spec fn op_invoke_virtual_get(p: Program2, s: State2, sel: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        let recv = at(s, 0);
        match find_method(p, s, recv, sel) {
            Lookup2::Stuck(r) => stuck(r),
            Lookup2::Missing => raise(p, s, LOOKUP_FAILED),
            Lookup2::Found(t) => {
                let f = info(p, t).aux as int;
                if arity(p, t) != 1 {
                    stuck(Stuck::BadArity)
                } else if info(p, t).kind == KIND_FIELD_ACCESSOR && field_readable(p, s, recv, f) {
                    next(put(s, 0, field(s, recv, f)), 3)
                } else if info(p, t).kind == KIND_FIELD_ACCESSOR && twin_at(p, s) {
                    // The unchecked twin (`unchecked_fail`): an accessor's field
                    // is assumed to exist.
                    stuck(Stuck::FieldRange)
                } else {
                    call(p, s, t, s.bci + 3)
                }
            },
        }
    }
}

pub open spec fn op_invoke_virtual_set(p: Program2, s: State2, sel: int) -> Outcome2 {
    if !has_slot(s, 1) {
        stuck(Stuck::StackRange)
    } else {
        let recv = at(s, 1);
        let v = at(s, 0);
        match find_method(p, s, recv, sel) {
            Lookup2::Stuck(r) => stuck(r),
            Lookup2::Missing => raise(p, s, LOOKUP_FAILED),
            Lookup2::Found(t) => {
                let f = info(p, t).aux as int;
                if arity(p, t) != 2 {
                    stuck(Stuck::BadArity)
                } else if info(p, t).kind == KIND_FIELD_ACCESSOR && field_writable(p, s, recv, f) {
                    next(push(set_field2(drop(s, 2), recv, f, v), v), 3)
                } else if info(p, t).kind == KIND_FIELD_ACCESSOR && twin_at(p, s) {
                    stuck(Stuck::FieldRange)
                } else {
                    call(p, s, t, s.bci + 3)
                }
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Operators: fast path, else a virtual call of the operator's selector.

pub open spec fn binary_result(s: State2, r: Value) -> Outcome2 {
    next(push(drop(s, 2), r), 1)
}

pub open spec fn operator_fallback(p: Program2, s: State2, op: u8) -> Outcome2 {
    let n = if op == INVOKE_AT_PUT { 3int } else { 2int };
    invoke_virtual(p, s, p.invoke_offsets[op - INVOKE_EQ] as int, n, 1)
}

pub open spec fn op_invoke_eq(p: Program2, s: State2) -> Outcome2 {
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    let s1 = as1(s);
    if a0 == a1 {
        binary_result(s, boolean2(p, !(crate::spec_common::is_double(s1, a0) && is_nan_bits(crate::spec_common::double_bits(s1, a0)))))
    } else if a0 == null2(p) || a1 == null2(p) {
        binary_result(s, false2(p))
    } else if are_smis(a0, a1) {
        binary_result(s, boolean2(p, smi_val(a0) == smi_val(a1)))
    } else if compare_numbers(s1, a0, a1) != 0 {
        binary_result(s, boolean2(p, (compare_numbers(s1, a0, a1) & COMPARE_FLAG_EQUAL) != 0))
    } else {
        operator_fallback(p, s, INVOKE_EQ)
    }
}

pub open spec fn op_invoke_relational(p: Program2, s: State2, op: u8) -> Outcome2 {
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    if are_smis(a0, a1) {
        binary_result(s, boolean2(p, relational_smi(op, smi_val(a0), smi_val(a1))))
    } else if compare_numbers(as1(s), a0, a1) != 0 {
        binary_result(s, boolean2(p, (compare_numbers(as1(s), a0, a1) & relational_flag(op)) != 0))
    } else {
        operator_fallback(p, s, op)
    }
}

pub open spec fn op_invoke_arith(p: Program2, s: State2, op: u8) -> Outcome2 {
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    if are_smis(a0, a1) && smi_arith(p1(p), op, smi_val(a0), smi_val(a1)) is Some {
        binary_result(s, smi(smi_arith(p1(p), op, smi_val(a0), smi_val(a1))->0))
    } else if (op == INVOKE_ADD || op == INVOKE_SUB || op == INVOKE_MUL) && are_floats(as1(s), a0, a1) {
        let bits = float_arith(op, crate::spec_common::double_bits(as1(s), a0), crate::spec_common::double_bits(as1(s), a1));
        binary_result(alloc2(s, new_double(as1(s), p1(p), bits)), new_ref2(s))
    } else {
        operator_fallback(p, s, op)
    }
}

/// INVOKE_AT: `fast_at`; anything it does not handle (including corrupted
/// collections, where format 1 is stuck) is a virtual call.
pub open spec fn op_invoke_at(p: Program2, s: State2) -> Outcome2 {
    match fast_at(p1(p), as1(s), at(s, 1), at(s, 0), false, null2(p), FAST_AT_FUEL) {
        FastAt::Get(v) => binary_result(s, v),
        _ => operator_fallback(p, s, INVOKE_AT),
    }
}

pub open spec fn op_invoke_at_put(p: Program2, s: State2) -> Outcome2 {
    if !has_slot(s, 2) {
        stuck(Stuck::StackRange)
    } else {
        match fast_at(p1(p), as1(s), at(s, 2), at(s, 1), true, at(s, 0), FAST_AT_FUEL) {
            FastAt::Put(s1, v) => next(push(drop(State2 { heap: s1.heap, ..s }, 3), v), 1),
            _ => operator_fallback(p, s, INVOKE_AT_PUT),
        }
    }
}

pub open spec fn op_invoke_size(p: Program2, s: State2, sel: int) -> Outcome2 {
    if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else {
        match fast_size(p1(p), as1(s), at(s, 0)) {
            Some(n) => next(put(s, 0, smi(n)), 3),
            None => op_invoke_virtual_get(p, s, sel),
        }
    }
}

// ---------------------------------------------------------------------------
// Branches: targets must lie inside the current method; a forward branch
// must move forward.

pub open spec fn branch_to(p: Program2, s: State2, target: int) -> Outcome2 {
    let m = top(s).method as int;
    if !(info(p, m).entry <= target < info(p, m).end) {
        stuck(Stuck::BadBranch)
    } else {
        Outcome2::Next(goto(s, target))
    }
}

/// kind: 0 = always, 1 = if true, 2 = if false, 3 = if not null.
pub open spec fn branch_taken(p: Program2, kind: int, v: Value) -> bool {
    if kind == 1 { truthy2(p, v) } else if kind == 2 { !truthy2(p, v) } else { v != null2(p) }
}

pub open spec fn op_branch(p: Program2, s: State2, kind: int, target: int, len: int) -> Outcome2 {
    if kind == 0 {
        branch_to(p, s, target)
    } else if !has_slot(s, 0) {
        stuck(Stuck::StackRange)
    } else if branch_taken(p, kind, at(s, 0)) {
        branch_to(p, drop(s, 1), target)
    } else {
        next(drop(s, 1), len)
    }
}

// ---------------------------------------------------------------------------
// Loop steps (proposal, format note 19): one bounded step of a counted
// loop whose structure stays in the bytecode. The step pops the previous
// block result; when its fast condition holds it stores the incremented
// counter, pushes a copy of the block slot and the block argument, and
// branches back to the INVOKE_BLOCK; otherwise it falls through to the
// method's ordinary loop, which re-checks everything. No calls, no heap
// writes. Slots are counted from the top before the pop.

/// The operand slots exist, above the popped result.
pub open spec fn loop_slots_ok(s: State2, c: int, b: int, x: int, y: int) -> bool {
    &&& 1 <= c && 1 <= b && 1 <= x && 1 <= y
    &&& has_slot(s, c) && has_slot(s, b) && has_slot(s, x) && has_slot(s, y)
}

/// The taken branch: counter `c` becomes `i + 1`, the result is popped, the
/// block (slot `b`) and `v` are pushed.
pub open spec fn loop_taken(p: Program2, s: State2, c: int, b: int, i: int, v: Value, target: int) -> Outcome2 {
    branch_to(p, push(push(drop(put(s, c, smi(i + 1)), 1), at(s, b)), v), target)
}

/// LOOP_REPEAT n: counter `c = n`, block `b = n + 1`, limit `l = n + 2`.
pub open spec fn op_loop_repeat(p: Program2, s: State2, target: int, n: int, len: int) -> Outcome2 {
    let (c, b, l) = (n, n + 1, n + 2);
    if !loop_slots_ok(s, c, b, l, l) {
        stuck(Stuck::StackRange)
    } else if at(s, c) is Smi && at(s, l) is Smi && smi_val(at(s, c)) < smi_val(at(s, l)) {
        loop_taken(p, s, c, b, smi_val(at(s, c)), at(s, c), target)
    } else {
        next(drop(s, 1), len)
    }
}

/// The fast condition of LOOP_ARRAY: the counter `i` and the end are smis,
/// `0 <= i < end`, and the array slot holds an array with an element `i`.
pub open spec fn loop_array_go(s: State2, c: int, e: int, a: int) -> bool {
    &&& at(s, c) is Smi && at(s, e) is Smi && is_array(as1(s), at(s, a))
    &&& 0 <= smi_val(at(s, c)) && smi_val(at(s, c)) < smi_val(at(s, e))
    &&& smi_val(at(s, c)) < elements(as1(s), at(s, a)).len()
}

/// LOOP_ARRAY n: counter `c = n`, block `b = n + 1`, end `e = n + 2`,
/// array `a = n + 3`.
pub open spec fn op_loop_array(p: Program2, s: State2, target: int, n: int, len: int) -> Outcome2 {
    let (c, b, e, a) = (n, n + 1, n + 2, n + 3);
    if !loop_slots_ok(s, c, b, e, a) {
        stuck(Stuck::StackRange)
    } else if loop_array_go(s, c, e, a) {
        loop_taken(p, s, c, b, smi_val(at(s, c)), elements(as1(s), at(s, a))[smi_val(at(s, c))], target)
    } else {
        next(drop(s, 1), len)
    }
}

// ---------------------------------------------------------------------------
// HASH_FIND (proposal, format note 19): one probe of the index of a hashed
// collection, the loop of `find-body_` in lib/core/collections.toit up to
// the first point where Toit code must run (comparing a candidate key,
// entering a new key, rebuilding). Total for any heap: every irregular
// state is the code HF_IRREGULAR, after which the Toit loop runs. Reads
// only, through the same fast paths as INVOKE_SIZE and INVOKE_AT.

/// The result of a probe.
pub enum Probe {
    /// A key whose stored hash bits match the hash: the key, its position in
    /// the backing, and the probe state (slot, step, deleted slot + 1) to
    /// continue from if it is not equal.
    Cand(Value, int, int, int, int),
    /// No candidate: `2 * slot + 1` (a free slot, no deleted one before it),
    /// `2 * slot` (the first deleted slot, to reuse), HF_FULL or HF_IRREGULAR.
    Miss(int),
}

pub spec const HF_FULL: int = -1;
pub spec const HF_IRREGULAR: int = -2;
/// Larger indexes are left to the Toit loop (keeps every code a smi).
pub spec const HF_MAX_INDEX: int = 0x100_0000;

/// Element `i` of an index or a backing, as INVOKE_AT's fast path reads it.
pub open spec fn hf_at(p: Program2, s: State2, a: Value, i: int) -> Option<Value> {
    match fast_at(p1(p), as1(s), a, smi(i), false, null2(p), FAST_AT_FUEL) {
        FastAt::Get(v) => Some(v),
        _ => None,
    }
}

pub open spec fn is_tombstone(p: Program2, s: State2, k: Value) -> bool {
    k is Obj && class_of_obj(as1(s), k) == builtin(p1(p), TOMBSTONE_CLASS)
}

/// The probe loop from `slot` with triangular step `step` and `d` the
/// first deleted slot plus one (0: none), `start` the first slot.
pub open spec fn hf_probe(p: Program2, s: State2, index: Value, backing: Value, hash: int, mask: int,
    start: int, slot: int, step: int, d: int, fuel: nat) -> Probe
    decreases fuel,
{
    if fuel == 0 {
        Probe::Miss(HF_IRREGULAR)
    } else {
        match hf_at(p, s, index, slot) {
            Some(Value::Smi(hap)) => {
                if hap == 0 {
                    Probe::Miss(if d > 0 { 2 * (d - 1) } else { 2 * slot + 1 })
                } else {
                    let pos = hap / 4096 - 1;
                    match hf_at(p, s, backing, pos) {
                        Some(k) => {
                            let tomb = is_tombstone(p, s, k);
                            let d1 = if d == 0 && tomb { slot + 1 } else { d };
                            if band(hap as int, 0xfff) == band(hash, 0xfff) && !tomb {
                                Probe::Cand(k, pos, slot, step, d1)
                            } else {
                                let slot2 = band(slot + step, mask);
                                if slot2 == start {
                                    Probe::Miss(HF_FULL)
                                } else {
                                    hf_probe(p, s, index, backing, hash, mask, start, slot2, step + 1, d1, (fuel - 1) as nat)
                                }
                            }
                        },
                        None => Probe::Miss(HF_IRREGULAR),
                    }
                }
            },
            _ => Probe::Miss(HF_IRREGULAR),
        }
    }
}

/// The probe of collection `coll` for `hashv` from the state `slotv`,
/// `stepv` (0: from the start) and `dv`.
pub open spec fn hf_find(p: Program2, s: State2, coll: Value, hashv: Value, slotv: Value, stepv: Value, dv: Value) -> Probe {
    if !(is_instance(as1(s), coll) && fields(as1(s), coll).len() >= 4
        && hashv is Smi && slotv is Smi && stepv is Smi && dv is Smi) {
        Probe::Miss(HF_IRREGULAR)
    } else {
        let index = fields(as1(s), coll)[2];
        let backing = fields(as1(s), coll)[3];
        match fast_size(p1(p), as1(s), index) {
            Some(size) => {
                let (hash, slot, step, d) = (smi_val(hashv), smi_val(slotv), smi_val(stepv), smi_val(dv));
                if !(1 <= size <= HF_MAX_INDEX && band(size, size - 1) == 0
                    && 0 <= slot < size && 0 <= step <= 2 * size && 0 <= d <= size) {
                    Probe::Miss(HF_IRREGULAR)
                } else {
                    let mask = size - 1;
                    let start = band(hash, mask);
                    if step == 0 {
                        hf_probe(p, s, index, backing, hash, mask, start, start, 1, d, (2 * size) as nat)
                    } else {
                        // Continue after a candidate that was not equal.
                        let slot2 = band(slot + step, mask);
                        if slot2 == start {
                            Probe::Miss(HF_FULL)
                        } else {
                            hf_probe(p, s, index, backing, hash, mask, start, slot2, step + 1, d, (2 * size) as nat)
                        }
                    }
                }
            },
            None => Probe::Miss(HF_IRREGULAR),
        }
    }
}

/// HASH_FIND n m: on a candidate, the state slots `n`, `n + 1`, `n + 2` get
/// its probe state and the key and position are pushed; otherwise the code
/// is pushed and the branch to `target` taken.
pub open spec fn op_hash_find(p: Program2, s: State2, target: int, n: int, m: int, len: int) -> Outcome2 {
    if !(0 <= n && 0 <= m && has_slot(s, n + 2) && has_slot(s, m + 2)) {
        stuck(Stuck::StackRange)
    } else {
        match hf_find(p, s, at(s, m + 2), at(s, m), at(s, n), at(s, n + 1), at(s, n + 2)) {
            Probe::Cand(k, pos, slot, step, d) =>
                next(push(push(put(put(put(s, n, smi(slot)), n + 1, smi(step)), n + 2, smi(d)), k), smi(pos)), len),
            Probe::Miss(code) => branch_to(p, push(s, smi(code)), target),
        }
    }
}

pub open spec fn op_halt(p: Program2, s: State2, code: int) -> Outcome2 {
    if code == 0 {
        Outcome2::Halt(goto(push(s, smi(91)), s.bci + 2), Halt2::Yield)
    } else if code == 1 {
        if !has_slot(s, 0) {
            stuck(Stuck::StackRange)
        } else {
            match at(s, 0) {
                Value::Smi(v) => Outcome2::Halt(goto(drop(s, 1), s.bci + 2), Halt2::Exit(v)),
                _ => raise(p, s, INVALID_PROGRAM),
            }
        }
    } else if code == 2 {
        if !has_slot(s, 0) {
            stuck(Stuck::StackRange)
        } else {
            Outcome2::Halt(goto(drop(s, 1), s.bci + 2), Halt2::DeepSleep)
        }
    } else {
        Outcome2::Halt(goto(s, s.bci + 2), Halt2::Reset)
    }
}

// ---------------------------------------------------------------------------
// The step function.

/// The instruction at `s.bci` lies inside the top frame's method.
pub open spec fn instruction_ok(p: Program2, s: State2) -> bool {
    &&& s.frames.len() > 0
    &&& valid_method(p, top(s).method as int)
    &&& {
        let i = info(p, top(s).method as int);
        let bci = s.bci as int;
        &&& i.entry <= bci < i.end
        &&& i.end <= p.bytecodes.len()
        &&& p.bytecodes[bci] < OPCODE_COUNT2
        &&& bci + opcode_length2(p.bytecodes[bci]) <= i.end
    }
}

/// Operators need both operands in the frame.
pub open spec fn binary_ok(s: State2) -> bool {
    has_slot(s, 1)
}

#[verifier::opaque]
pub open spec fn step(p: Program2, s: State2) -> Outcome2 {
    if !instruction_ok(p, s) {
        stuck(Stuck::BadInstruction)
    } else {
        let bci = s.bci as int;
        // An unchecked twin (format note 20) runs as its base instruction;
        // only `unchecked_fail` tells them apart.
        let op = base_op(p.bytecodes[bci]);
        let len = opcode_length2(op);
        let b1 = if len >= 2 { byte2(p, bci + 1) } else { 0 };
        let w1 = if len >= 3 { u16_at(p1(p), bci + 1) } else { 0 };
        if op == LOAD_LOCAL { op_load_local(s, b1, len) }
        else if op == LOAD_LOCAL_WIDE { op_load_local(s, w1, len) }
        else if LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5 { op_load_local(s, op - LOAD_LOCAL_0, len) }
        else if op == POP_LOAD_LOCAL { op_pop_load_local(s, b1) }
        else if op == STORE_LOCAL { op_store_local(s, b1) }
        else if op == STORE_LOCAL_POP { op_store_local_pop(s, b1) }
        else if op == LOAD_OUTER { op_load_outer(s, b1) }
        else if op == STORE_OUTER { op_store_outer(s, b1) }
        else if op == LOAD_FIELD { op_load_field(p, s, b1, len) }
        else if op == LOAD_FIELD_WIDE { op_load_field(p, s, w1, len) }
        else if op == LOAD_FIELD_LOCAL { op_load_field_local(p, s, b1, false) }
        else if op == POP_LOAD_FIELD_LOCAL { op_load_field_local(p, s, b1, true) }
        else if op == STORE_FIELD { op_store_field(p, s, b1, len, true) }
        else if op == STORE_FIELD_WIDE { op_store_field(p, s, w1, len, true) }
        else if op == STORE_FIELD_POP { op_store_field(p, s, b1, len, false) }
        else if op == LOAD_LITERAL { op_load_literal(p, s, b1, len) }
        else if op == LOAD_LITERAL_WIDE { op_load_literal(p, s, w1, len) }
        else if op == LOAD_NULL { next(push(s, null2(p)), len) }
        else if op == LOAD_SMI_0 { next(push(s, smi(0)), len) }
        else if op == LOAD_SMIS_0 { op_load_smis_0(s, b1) }
        else if op == LOAD_SMI_1 { next(push(s, smi(1)), len) }
        else if op == LOAD_SMI_U8 { next(push(s, smi(b1)), len) }
        else if op == LOAD_SMI_U16 { next(push(s, smi(w1)), len) }
        else if op == LOAD_SMI_U32 { op_load_smi(p, s, u32_at(p1(p), bci + 1), len) }
        else if op == LOAD_METHOD { op_load_method(p, s, u32_at(p1(p), bci + 1)) }
        else if op == LOAD_GLOBAL_VAR { op_load_global(s, b1, len) }
        else if op == LOAD_GLOBAL_VAR_WIDE { op_load_global(s, w1, len) }
        else if op == LOAD_GLOBAL_VAR_LAZY { op_load_global_lazy(p, s, b1, len) }
        else if op == LOAD_GLOBAL_VAR_LAZY_WIDE { op_load_global_lazy(p, s, w1, len) }
        else if op == LOAD_GLOBAL_VAR_DYNAMIC { op_load_global_dynamic(p, s) }
        else if op == STORE_GLOBAL_VAR { op_store_global(s, b1, len) }
        else if op == STORE_GLOBAL_VAR_WIDE { op_store_global(s, w1, len) }
        else if op == STORE_GLOBAL_VAR_DYNAMIC { op_store_global_dynamic(p, s) }
        else if op == LOAD_BLOCK { op_load_block(s, b1) }
        else if op == LOAD_OUTER_BLOCK { op_load_outer_block(s, b1) }
        else if op == POP { op_pop(s, b1, len) }
        else if op == POP_1 { op_pop(s, 1, len) }
        else if op == ALLOCATE { op_allocate(p, s, b1, len) }
        else if op == ALLOCATE_WIDE { op_allocate(p, s, w1, len) }
        else if op == IS_CLASS { op_is(p, s, b1, false, len) }
        else if op == IS_CLASS_WIDE { op_is(p, s, w1, false, len) }
        else if op == IS_INTERFACE { op_is(p, s, b1, true, len) }
        else if op == IS_INTERFACE_WIDE { op_is(p, s, w1, true, len) }
        else if op == AS_CLASS { op_as(p, s, b1, false, len) }
        else if op == AS_CLASS_WIDE { op_as(p, s, w1, false, len) }
        else if op == AS_INTERFACE { op_as(p, s, b1, true, len) }
        else if op == AS_INTERFACE_WIDE { op_as(p, s, w1, true, len) }
        else if op == AS_LOCAL { op_as_local(p, s, b1) }
        else if op == INVOKE_STATIC { op_invoke_static(p, s, w1) }
        else if op == INVOKE_STATIC_TAIL { op_invoke_static_tail(p, s, w1) }
        else if op == INVOKE_BLOCK { op_invoke_block(p, s, b1) }
        else if op == INVOKE_LAMBDA_TAIL { op_invoke_lambda_tail(p, s) }
        else if op == INVOKE_INITIALIZER_TAIL { op_invoke_initializer_tail(p, s) }
        else if op == INVOKE_VIRTUAL { invoke_virtual(p, s, u16_at(p1(p), bci + 2), b1 + 1, len) }
        else if op == INVOKE_VIRTUAL_WIDE { invoke_virtual(p, s, u16_at(p1(p), bci + 3), w1 + 1, len) }
        else if op == INVOKE_VIRTUAL_GET { op_invoke_virtual_get(p, s, w1) }
        else if op == INVOKE_VIRTUAL_SET { op_invoke_virtual_set(p, s, w1) }
        else if INVOKE_EQ <= op && op <= INVOKE_AT_PUT && !binary_ok(s) { stuck(Stuck::StackRange) }
        else if op == INVOKE_EQ { op_invoke_eq(p, s) }
        else if INVOKE_LT <= op && op <= INVOKE_GTE { op_invoke_relational(p, s, op) }
        else if INVOKE_BIT_OR <= op && op <= INVOKE_MOD { op_invoke_arith(p, s, op) }
        else if op == INVOKE_AT { op_invoke_at(p, s) }
        else if op == INVOKE_AT_PUT { op_invoke_at_put(p, s) }
        else if op == INVOKE_SIZE { op_invoke_size(p, s, w1) }
        else if BRANCH <= op && op <= BRANCH_IF_NOT_NULL {
            if w1 == 0 { stuck(Stuck::BadBranch) } else { op_branch(p, s, op - BRANCH, bci + w1, len) }
        }
        else if BRANCH_BACK <= op && op <= BRANCH_BACK_IF_NOT_NULL { op_branch(p, s, op - BRANCH_BACK, bci - w1, len) }
        // The short branches (format note 22): a one-byte distance.
        else if BRANCH_S <= op && op <= BRANCH_IF_NOT_NULL_S {
            if b1 == 0 { stuck(Stuck::BadBranch) } else { op_branch(p, s, op - BRANCH_S, bci + b1, len) }
        }
        else if op == BRANCH_BACK_S { op_branch(p, s, 0, bci - b1, len) }
        else if op == PRIMITIVE {
            if frame_height(s) != arity(p, top(s).method as int) {
                stuck(Stuck::StackRange)
            } else {
                Outcome2::Primitive(s, p.bytecodes[bci + 1], u16_at(p1(p), bci + 2) as u16)
            }
        }
        else if op == THROW {
            if !has_slot(s, 0) { stuck(Stuck::StackRange) } else { unwind(p, s, Unwind::Throw(at(s, 0))) }
        }
        else if op == RETURN {
            if !has_slot(s, 0) { stuck(Stuck::StackRange) } else { return_from(p, s, at(s, 0)) }
        }
        else if op == RETURN_NULL { return_from(p, s, null2(p)) }
        else if op == NON_LOCAL_RETURN { op_non_local_return(p, s) }
        else if op == STORE_FIELD_THIS { op_store_field_this(p, s, b1) }
        else if op == NON_LOCAL_BRANCH { op_non_local_branch(p, s, b1, u32_at(p1(p), bci + 2)) }
        else if op == IDENTICAL {
            if !binary_ok(s) { stuck(Stuck::StackRange) }
            else { binary_result(s, boolean2(p, identical(as1(s), at(s, 1), at(s, 0)))) }
        }
        else if op == TRY { op_try(p, s) }
        else if op == LOAD_FIELD_THIS { op_load_field_this(p, s, b1) }
        else if op == UNWIND { op_unwind(p, s) }
        else if op == LOOP_REPEAT {
            op_loop_repeat(p, s, bci - w1, byte2(p, bci + 3), len)
        }
        else if op == LOOP_ARRAY {
            op_loop_array(p, s, bci - w1, byte2(p, bci + 3), len)
        }
        else if op == HASH_FIND {
            op_hash_find(p, s, bci + w1, byte2(p, bci + 3), byte2(p, bci + 4), len)
        }
        else { op_halt(p, s, b1) }  // HALT
    }
}

} // verus!
