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

//! Format 2: the oracle steps (completion of raised exceptions and of
//! PRIMITIVE steps), the task primitives, and the initial state.
//!
//! A raise (`Outcome2::Raise`) is completed by `raised`: the machine
//! allocates the exception with a trace of its choosing, or throws the
//! out-of-memory error when that allocation fails.
//!
//! As in format 1 a primitive is an oracle. Its arguments are the
//! parameters of the top frame (PRIMITIVE requires an otherwise empty
//! frame); success returns from the frame (no arity from the primitive
//! table), failure continues after the PRIMITIVE with the error pushed, and
//! a missing primitive raises PRIMITIVE_LOOKUP_FAILED.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
#[cfg(verus_only)]
use crate::v2::sound::{good, prim_heap_ok};
#[cfg(verus_only)]
use crate::spec_common::{builtin, instance_field_count, is_instance, fields, set_field,
    STACK_CLASS, TASK_CLASS, ENTRY_MAIN, ENTRY_TASK, class_of_obj, obj_ok, obj, obj_id, smi};

verus! {

// ---------------------------------------------------------------------------
// Raised exceptions.

/// The root holding the out-of-memory error (`Program::out_of_memory_error`).
pub spec const ROOT_OUT_OF_MEMORY: int = 4;

pub open spec fn out_of_memory(p: Program2) -> Value {
    p.roots[ROOT_OUT_OF_MEMORY]
}

/// `h2` is `h` with objects added (the old ones unchanged) under the
/// contract of a primitive's heap (`v2::sound::prim_heap_ok`: the new
/// objects are well formed, neither stacks nor tasks). What the machine's
/// allocations and its collector (which keeps every live object, as seen
/// through the abstraction) leave behind.
pub open spec fn heap_extended(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>) -> bool {
    &&& prim_heap_ok(p, h, h2)
    &&& h2.subrange(0, h.len() as int) == h
}

pub open spec fn with_heap2(s: State2, h2: Seq<HeapObj>) -> State2 {
    State2 { heap: h2, ..s }
}

/// The completions of `Outcome2::Raise(s, value)`. The machine allocates
/// the exception (`throw_exception`) after extending the heap (the trace
/// and the message, encoded from the stack), with any trace of the grown
/// heap; or the allocation fails and it throws the out-of-memory error
/// itself (no exception object). Both are GC points. The reference
/// interpreter's completion (`raise_null`: no trace, no other allocation)
/// is one of them (`v2::sound_raise::lemma_raise_null`).
pub open spec fn raised(p: Program2, s: State2, value: Value, o: Outcome2) -> bool {
    ||| exists|h2: Seq<HeapObj>, trace: Value| heap_extended(p, s.heap, h2) && good(h2, trace)
            && o == #[trigger] throw_exception(p, with_heap2(s, h2), value, trace)
    ||| exists|h2: Seq<HeapObj>| heap_extended(p, s.heap, h2)
            && o == #[trigger] unwind(p, with_heap2(s, h2), Unwind::Throw(out_of_memory(p)))
}

/// `o2` completes outcome `o`: a raise by `raised`, any other outcome is
/// its own completion.
pub open spec fn completes(p: Program2, o: Outcome2, o2: Outcome2) -> bool {
    match o {
        Outcome2::Raise(s, value) => raised(p, s, value, o2),
        _ => o2 == o,
    }
}

// ---------------------------------------------------------------------------
// Resource throws.

/// Roots holding the errors of exhausted resources (`Program` roots: the
/// error strings start at index 7).
pub spec const ROOT_ALLOCATION_FAILED: int = 7;
pub spec const ROOT_MALLOC_FAILED: int = 17;
pub spec const ROOT_CROSS_PROCESS_GC: int = 18;
pub spec const ROOT_STACK_OVERFLOW: int = 28;

/// The instructions before which the machine makes room on its stack for a
/// frame (the core's `ensure_room`, a GC point): every instruction that
/// may push a frame or replace the top frame (calls, virtual calls and
/// their fast paths, operators and their fallbacks, tail calls, TRY, lazy
/// globals). Growing the stack fails with stack overflow (the stack is at
/// its maximal size) or out of memory.
pub open spec fn grows_stack(op: u8) -> bool {
    ||| op == INVOKE_STATIC || op == INVOKE_STATIC_TAIL || op == INVOKE_BLOCK
    ||| op == INVOKE_LAMBDA_TAIL || op == INVOKE_INITIALIZER_TAIL
    ||| op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE || op == INVOKE_VIRTUAL_GET || op == INVOKE_VIRTUAL_SET
    ||| (INVOKE_EQ <= op && op <= INVOKE_SIZE)
    ||| op == TRY || op == LOAD_GLOBAL_VAR_LAZY || op == LOAD_GLOBAL_VAR_LAZY_WIDE
}

/// ALLOCATE(_WIDE): allocating the instance may fail with out of memory.
pub open spec fn allocates_instance(op: u8) -> bool {
    op == ALLOCATE || op == ALLOCATE_WIDE
}

/// INVOKE_ADD/SUB/MUL on two doubles allocate the result; if that fails
/// the machine calls the operator's method instead (which allocates
/// through a primitive, and so reports the failure: its completion
/// `PrimRet::OutOfMemory`).
pub open spec fn allocates_double(p: Program2, s: State2, op: u8) -> bool {
    &&& (op == INVOKE_ADD || op == INVOKE_SUB || op == INVOKE_MUL)
    &&& binary_ok(s)
    &&& crate::spec_helpers::are_floats(as1(s), at(s, 1), at(s, 0))
}

/// The resource throws in state `s`: what the machine may do instead of
/// the step when a resource the abstract machine does not bound runs out.
/// They exist only at these instructions:
///
/// * `grows_stack`: the out-of-memory error is thrown (no allocation), or
///   the stack-overflow error is raised (an `Exception_` with a trace,
///   `Outcome2::Raise`, itself completed by `raised`);
/// * `allocates_instance`: the out-of-memory error is thrown;
/// * `allocates_double`: the operator's method is called (the fallback
///   of the step).
///
/// A primitive's own resource failure is a completion of PRIMITIVE
/// (`PrimRet::OutOfMemory`); a raise's is a completion of the raise
/// (`raised`). Each alternative starts from `s` itself: the instruction
/// has not run (stack growth and allocation happen before any change).
pub open spec fn resource_throw(p: Program2, s: State2, o: Outcome2) -> bool {
    let b = s.bci as int;
    let op = p.bytecodes[b];
    &&& 0 <= b < p.bytecodes.len()
    &&& {
        ||| (grows_stack(op) || allocates_instance(op)) && o == unwind(p, s, Unwind::Throw(out_of_memory(p)))
        ||| grows_stack(op) && o == Outcome2::Raise(s, p.roots[ROOT_STACK_OVERFLOW])
        ||| allocates_double(p, s, op) && o == operator_fallback(p, s, op)
    }
}

// ---------------------------------------------------------------------------
// Primitives.

/// The arguments of a primitive: the top frame's parameters.
pub open spec fn prim_args(p: Program2, s: State2) -> Seq<Value> {
    s.stack.subrange(base(s), s.stack.len() as int)
}

pub open spec fn prim_success(p: Program2, s: State2, heap: Seq<HeapObj>, result: Value) -> Outcome2 {
    return_from(p, State2 { heap: heap, ..s }, result)
}

pub open spec fn prim_failure(s: State2, heap: Seq<HeapObj>, error: Value) -> Outcome2 {
    next(push(State2 { heap: heap, ..s }, error), 4)
}

pub open spec fn prim_missing(p: Program2, s: State2) -> Outcome2 {
    raise(p, s, PRIMITIVE_LOOKUP_FAILED)
}

pub open spec fn wrong_object_type(p: Program2) -> Value {
    p.roots[30]
}

pub open spec fn new_task_obj2(p: Program2, stack_id: int, id: int) -> HeapObj {
    let cid = builtin(p1(p), TASK_CLASS);
    HeapObj {
        class_id: cid as u16,
        ro: false,
        body: Body::Instance(Seq::new(instance_field_count(p1(p), cid) as nat, |i: int|
            if i == 0 { Value::Obj(stack_id as usize) } else if i == 1 { smi(id) } else { null2(p) })),
    }
}

/// A suspended task's state.
pub open spec fn stack_obj2(p: Program2, words: Seq<Value>, frames: Seq<Frame>, tries: Seq<Handler>, fins: Seq<Fin>, bci: int) -> HeapObj {
    HeapObj { class_id: p.builtin[STACK_CLASS], ro: false, body: Body::Stack2(words, frames, tries, fins, bci as usize) }
}

/// `core.task_new(code)`: a task that never ran has no frames and its code
/// as its only stack slot.
pub open spec fn task_new_step(p: Program2, s: State2, code: Value) -> Outcome2 {
    let cid = builtin(p1(p), TASK_CLASS);
    if !is_instance(as1(s), code) {
        prim_failure(s, s.heap, wrong_object_type(p))
    } else if !valid_method(p, entry_method(p, ENTRY_TASK)) || !(0 <= cid < p.class_bits.len())
        || instance_field_count(p1(p), cid) < 2 {
        stuck(Stuck::Fatal)
    } else {
        let stack_id = s.heap.len() as int;
        let task = Value::Obj((stack_id + 1) as usize);
        let heap = s.heap
            .push(stack_obj2(p, seq![code], Seq::empty(), Seq::empty(), Seq::empty(), 0))
            .push(new_task_obj2(p, stack_id, s.next_task_id as int));
        prim_success(p, State2 { next_task_id: (s.next_task_id + 1) as i64, ..s }, heap, task)
    }
}

pub open spec fn is_task(p: Program2, s: State2, v: Value) -> bool {
    is_instance(as1(s), v) && class_of_obj(as1(s), v) == builtin(p1(p), TASK_CLASS) && fields(as1(s), v).len() >= 2
}

pub open spec fn task_stack_ref(s: State2, task: Value) -> Value {
    fields(as1(s), task)[0]
}

pub open spec fn has_stack2(s: State2, task: Value) -> bool {
    let st = task_stack_ref(s, task);
    obj_ok(as1(s), st) && obj(as1(s), st).body is Stack2
}

/// A transfer to the task can resume it: it was suspended (has frames) or
/// never ran and has its code. A terminated task has no stack (its stack
/// field is the smi 0 after a detaching transfer), so this is checked at
/// run time. The program cannot write a task's stack field
/// (`v2::spec::field_writable`).
pub open spec fn resumable(s: State2, task: Value) -> bool {
    match obj(as1(s), task_stack_ref(s, task)).body {
        Body::Stack2(words, frames, _, _, _) => frames.len() > 0 || words.len() >= 1,
        _ => false,
    }
}

/// The state a task continues in after a transfer to it: a suspended task
/// continues after its PRIMITIVE; a new task gets the frames of
/// `__entry__task(code)` having called the transferring method (whose
/// failure path continues) from its bci 1, like `Interpreter::prepare_task`.
pub open spec fn resume(p: Program2, s: State2, to: Value, words: Seq<Value>, frames: Seq<Frame>, tries: Seq<Handler>, fins: Seq<Fin>, bci: int) -> Outcome2 {
    if frames.len() == 0 {
        let e = entry_method(p, ENTRY_TASK);
        if words.len() < 1 || !valid_method(p, e) {
            stuck(Stuck::Fatal)
        } else {
            let entry = info(p, e).entry;
            Outcome2::Next(State2 {
                stack: seq![words[0], to, false2(p), to],
                frames: seq![
                    Frame { method: e as usize, ret: entry, base: 0 },
                    Frame { method: top(s).method, ret: (entry + 1) as usize, base: 1 },
                ],
                tries: Seq::empty(),
                fins: Seq::empty(),
                bci: (s.bci + 4) as usize,
                task: obj_id(to) as usize,
                ..s
            })
        }
    } else {
        Outcome2::Next(State2 {
            stack: words.push(to),
            frames: frames,
            tries: tries,
            fins: fins,
            bci: (bci + 4) as usize,
            task: obj_id(to) as usize,
            ..s
        })
    }
}

/// `core.task_transfer(to, detach_stack)`.
pub open spec fn task_transfer_step(p: Program2, s: State2, to: Value, detach: Value) -> Outcome2 {
    let from = Value::Obj(s.task);
    if !is_task(p, s, to) || !(detach == true2(p) || detach == false2(p)) {
        prim_failure(s, s.heap, wrong_object_type(p))
    } else if from == to {
        prim_failure(s, s.heap, to)
    } else if !is_task(p, s, from) || !has_stack2(s, from) || s.frames.len() == 0 {
        // The machine runs on the running task's stack; the invariant
        // (`v2::sound::running_ok`) excludes this.
        stuck(Stuck::Fatal)
    } else if !has_stack2(s, to) || !resumable(s, to) {
        // The target has terminated: the transfer fails.
        prim_failure(s, s.heap, p.roots[12])  // ERROR
    } else {
        let from_stack = task_stack_ref(s, from);
        let saved = HeapObj { body: Body::Stack2(s.stack, s.frames, s.tries, s.fins, s.bci), ..obj(as1(s), from_stack) };
        let s1 = State2 { heap: s.heap.update(obj_id(from_stack), saved), ..s };
        let s2 = if detach == true2(p) { State2 { heap: set_field(as1(s1), from, 0, smi(0)).heap, ..s1 } } else { s1 };
        match obj(as1(s2), task_stack_ref(s2, to)).body {
            Body::Stack2(words, frames, tries, fins, bci) => resume(p, s2, to, words, frames, tries, fins, bci as int),
            _ => stuck(Stuck::Fatal),
        }
    }
}

/// The initial state of a process: the main task's stack holds the task,
/// the frame stack one frame for `__entry__main`.
pub open spec fn initial_state(p: Program2, heap0: Seq<HeapObj>, globals0: Seq<Value>) -> State2 {
    let stack_id = heap0.len() as int;
    let task = Value::Obj((stack_id + 1) as usize);
    let e = entry_method(p, ENTRY_MAIN);
    State2 {
        heap: heap0.push(stack_obj2(p, Seq::empty(), Seq::empty(), Seq::empty(), Seq::empty(), 0)).push(new_task_obj2(p, stack_id, 0)),
        globals: globals0,
        stack: seq![task],
        frames: seq![Frame { method: e as usize, ret: info(p, e).entry, base: 0 }],
        tries: Seq::empty(),
        fins: Seq::empty(),
        bci: info(p, e).entry,
        task: (stack_id + 1) as usize,
        next_task_id: 1,
    }
}

} // verus!
