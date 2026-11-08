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

//! Completion of PRIMITIVE steps, the machine-level task primitives, and
//! the initial state of a process.
//!
//! `step` stops at a PRIMITIVE bytecode with `Outcome::Primitive`. The
//! primitive itself is an oracle (the VM's primitive table): it is given the
//! stack and the heap and answers with success (its arity, a value and a
//! new heap), failure (an error value and a new heap), or "does not exist". The machine then continues
//! with `prim_success`, `prim_failure` or `prim_missing`. Two primitives
//! change the machine state beyond the heap and are specified here:
//! `core.task_new` and `core.task_transfer`.

use vstd::prelude::*;
use crate::types::*;
use crate::spec_common::*;
use crate::spec_step::*;

verus! {

/// The arguments of a primitive: the parameters of the method whose body
/// contains the PRIMITIVE bytecode (the expression stack is empty there).
pub open spec fn prim_args(s: State, arity: int) -> Seq<Value> {
    Seq::new(arity as nat, |j: int| at(s, FRAME_SIZE + arity - 1 - j))
}

pub open spec fn prim_args_ok(s: State, arity: int) -> bool {
    height(s) >= FRAME_SIZE + arity
}

/// The primitive does not exist: call `primitive_lookup_failure(m, i)`.
pub open spec fn prim_missing(p: Program, s: State, m: int, i: int) -> Outcome {
    call_entry(p, push(push(s, smi(m)), smi(i)), PRIMITIVE_LOOKUP_FAILURE, 4)
}

/// Success: return `result` from the method, dropping its `arity`
/// parameters. Allocation and mutation by the primitive are in `heap`.
pub open spec fn prim_success(s: State, heap: Seq<HeapObj>, arity: int, result: Value) -> Outcome {
    return_to_caller(State { heap: heap, ..s }, arity, result)
}

/// Failure: push the error and continue with the method body after the
/// PRIMITIVE bytecode (the `#primitive: | error | ...` block).
pub open spec fn prim_failure(s: State, heap: Seq<HeapObj>, error: Value) -> Outcome {
    next(push(State { heap: heap, ..s }, error), 4)
}

pub open spec fn error_v(p: Program) -> Value {
    p.roots[ERROR_ROOT]
}

/// The stack of a task that has never run: a fake call of
/// `task_transfer_(task, false)` from `__entry__task(code)` at bci 1 (right
/// after its LOAD_NULL), see `Interpreter::prepare_task`.
pub open spec fn new_task_stack(p: Program, code: Value, task: Value) -> Seq<Value> {
    let entry = method_entry(entry_method(p, ENTRY_TASK));
    seq![
        code,
        Value::RetAddr(entry as usize),
        Value::FrameMarker,
        task,
        false_v(p),
        Value::RetAddr((entry + 1) as usize),
        Value::FrameMarker,
    ]
}

/// A Task instance: field 0 the stack, field 1 the id, the rest null.
pub open spec fn new_task_obj(p: Program, stack_id: int, id: int) -> HeapObj {
    let cid = builtin(p, TASK_CLASS);
    HeapObj {
        class_id: cid as u16,
        ro: false,
        body: Body::Instance(Seq::new(instance_field_count(p, cid) as nat, |i: int|
            if i == 0 { Value::Obj(stack_id as usize) } else if i == 1 { smi(id) } else { null_v(p) })),
    }
}

pub open spec fn new_stack_obj(p: Program, words: Seq<Value>) -> HeapObj {
    HeapObj { class_id: p.builtin[STACK_CLASS], ro: false, body: Body::Stack(words, 0) }
}

/// `core.task_new(code)`.
pub open spec fn task_new_step(p: Program, s: State, code: Value) -> Outcome {
    let cid = builtin(p, TASK_CLASS);
    if !is_instance(s, code) {
        prim_failure(s, s.heap, p.roots[30])  // WRONG_OBJECT_TYPE
    } else if !valid_method(p, entry_method(p, ENTRY_TASK)) || !(0 <= cid < p.class_bits.len())
        || instance_field_count(p, cid) < 2 {
        stuck(Stuck::Fatal)
    } else {
        let stack_id = s.heap.len() as int;
        let task = Value::Obj((stack_id + 1) as usize);
        let heap = s.heap
            .push(new_stack_obj(p, new_task_stack(p, code, task)))
            .push(new_task_obj(p, stack_id, s.next_task_id as int));
        prim_success(State { next_task_id: (s.next_task_id + 1) as i64, ..s }, heap, 1, task)
    }
}

pub open spec fn is_task(p: Program, s: State, v: Value) -> bool {
    is_instance(s, v) && class_of_obj(s, v) == builtin(p, TASK_CLASS) && fields(s, v).len() >= 2
}

pub open spec fn task_stack_ref(s: State, task: Value) -> Value {
    fields(s, task)[0]
}

pub open spec fn has_stack(s: State, task: Value) -> bool {
    let st = task_stack_ref(s, task);
    obj_ok(s, st) && obj(s, st).body is Stack
}

/// `core.task_transfer(to, detach_stack)`. On success the primitive
/// returns `to` marked as an error, so the machine continues on the target
/// task's stack with the failure path: push `to`, continue after the
/// PRIMITIVE bytecode (in the same method, task_transfer_).
pub open spec fn task_transfer_step(p: Program, s: State, to: Value, detach: Value) -> Outcome {
    let from = Value::Obj(s.task);
    if !is_task(p, s, to) || !(detach == true_v(p) || detach == false_v(p)) {
        prim_failure(s, s.heap, p.roots[30])  // WRONG_OBJECT_TYPE
    } else if from == to {
        prim_failure(s, s.heap, to)
    } else if !has_stack(s, to) {
        prim_failure(s, s.heap, error_v(p))
    } else if !is_task(p, s, from) || !has_stack(s, from) {
        stuck(Stuck::Fatal)
    } else {
        let from_stack = task_stack_ref(s, from);
        let saved = HeapObj { body: Body::Stack(s.stack, s.try_h), ..obj(s, from_stack) };
        let s1 = set_obj(s, obj_id(from_stack), saved);
        let s2 = if detach == true_v(p) { set_field(s1, from, 0, smi(0)) } else { s1 };
        let to_stack = obj(s2, task_stack_ref(s2, to));
        match to_stack.body {
            Body::Stack(words, try_h) => {
                let s3 = State { stack: words, try_h: try_h, task: obj_id(to) as usize, ..s2 };
                next(push(s3, to), 4)
            },
            _ => stuck(Stuck::Fatal),
        }
    }
}

/// The initial state of a process running `program` with program heap
/// `heap0` and initial globals `globals0`: the main task's stack holds the
/// task argument and a frame for `__entry__main` (see
/// `Interpreter::prepare_process`).
pub open spec fn initial_state(p: Program, heap0: Seq<HeapObj>, globals0: Seq<Value>) -> State {
    let stack_id = heap0.len() as int;
    let task = Value::Obj((stack_id + 1) as usize);
    let entry = method_entry(entry_method(p, ENTRY_MAIN));
    State {
        heap: heap0.push(new_stack_obj(p, Seq::empty())).push(new_task_obj(p, stack_id, 0)),
        globals: globals0,
        stack: seq![task, Value::RetAddr(entry as usize), Value::FrameMarker],
        try_h: 0,
        bci: entry as usize,
        task: (stack_id + 1) as usize,
        next_task_id: 1,
    }
}

} // verus!
