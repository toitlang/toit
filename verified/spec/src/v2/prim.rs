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
//! a missing primitive raises PRIMITIVE_LOOKUP_FAILED. The protocol, as the
//! machine implements it, is stated next to `prim_returns`; what a
//! primitive may return is `prim_spec` (the default contract, refined per
//! primitive where stated).

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
#[cfg(verus_only)]
use crate::v2::sound::{good, prim_heap_ok};
#[cfg(verus_only)]
use crate::v2::verifier::{PRIM_TASK_NEW, PRIM_TASK_TRANSFER};
#[cfg(verus_only)]
use crate::v2::prim_core::core_contract;
#[cfg(verus_only)]
use crate::spec_common::{smi_ok, builtin, instance_field_count, is_instance, fields, set_field,
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
/// is one of them (`v2::sound_raise::lemma_raise_null`). The allocation
/// may collect first (`v2::gc::gc_steps`; the value is a smi or a
/// program-heap object, which every collection keeps: `v2::gc::kept`).
pub open spec fn raised(p: Program2, s: State2, value: Value, o: Outcome2) -> bool {
    ||| exists|h2: Seq<HeapObj>, trace: Value| heap_extended(p, s.heap, h2) && good(h2, trace)
            && o == #[trigger] throw_exception(p, with_heap2(s, h2), value, trace)
    ||| exists|h2: Seq<HeapObj>| heap_extended(p, s.heap, h2)
            && o == #[trigger] unwind(p, with_heap2(s, h2), Unwind::Throw(out_of_memory(p)))
    ||| raised_gc(p, s, value, o)
}

/// The allocation of a raise collected first (opaque: only the proofs about
/// raises look inside).
#[verifier::opaque]
pub open spec fn raised_gc(p: Program2, s: State2, value: Value, o: Outcome2) -> bool {
    exists|s2: State2| #[trigger] crate::v2::gc::gc_steps(p, s, s2) && crate::v2::gc::kept(s.heap, value)
        && raised_now(p, s2, value, o)
}

/// `raised` without a collection.
pub open spec fn raised_now(p: Program2, s: State2, value: Value, o: Outcome2) -> bool {
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
/// its maximal size) or out of memory. An unchecked twin (format note 20)
/// as its base.
pub open spec fn grows_stack(raw: u8) -> bool {
    let op = base_op(raw);
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
    let op = base_op(p.bytecodes[b]);
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

/// A primitive the policy denies (its entry in the verifier's table is -1):
/// the machine does not call it; the PRIMITIVE fails with PERMISSION_DENIED
/// (pushed, execution continues after the instruction), the heap
/// unchanged, as the C++ policy's denying entry did.
pub open spec fn prim_denied(p: Program2, s: State2) -> Outcome2 {
    prim_failure(s, s.heap, p.roots[ROOT_PERMISSION_DENIED])
}

pub open spec fn wrong_object_type(p: Program2) -> Value {
    p.roots[30]
}

// ---------------------------------------------------------------------------
// The PRIMITIVE protocol.
//
// PRIMITIVE m i in state `s`: the step (`spec::step`) checks that the top
// frame holds exactly its method's parameters, the arguments
// (`prim_args`), and its outcome is `Outcome2::Primitive(s, m, i)`. The
// machine then
//
// 1. looks the primitive up (`toit_v2_lookup_primitive`): if it is not
//    implemented, denied by the process' policy, or its arity differs from
//    the method's, the outcome is `prim_missing(p, s)` (a raise of
//    PRIMITIVE_LOOKUP_FAILED, completed by `raised`);
// 2. calls it (`toit_v2_call_primitive`, a GC point), which returns a heap
//    `h2` and a result `r` with `prim_returns(p, s, m, i, h2, r)`, and
//    continues with `prim_complete(p, s, h2, r)`:
//    * `Success(v)`: the frame returns `v` (`return_from`);
//    * `Failure(v)`: `v` is pushed and execution continues after the
//      PRIMITIVE (bci + 4) in the same frame;
//    * `OutOfMemory(v)`: memory ran out after the collector's retries; the
//      error `v` (a `resource_error`) is raised (completed by `raised`);
// 3. except that the task primitives core.task_new (0:115) and
//    core.task_transfer (0:116) are completed by the machine
//    (`task_step`: task creation and switching); for them a call returns
//    only `OutOfMemory`.
//
// `theorem::completion` is exactly these outcomes.

/// What a call of a primitive returns besides the heap (the status and
/// result word of `toit_v2_call_primitive`).
pub enum PrimRet {
    Success(Value),
    Failure(Value),
    OutOfMemory(Value),
}

/// The errors a primitive reports when memory ran out after the
/// collector's retries: allocation failed, malloc failed, cross-process
/// GC needed.
pub open spec fn resource_error(p: Program2, v: Value) -> bool {
    ||| v == p.roots[ROOT_ALLOCATION_FAILED]
    ||| v == p.roots[ROOT_MALLOC_FAILED]
    ||| v == p.roots[ROOT_CROSS_PROCESS_GC]
}

/// The contract every primitive satisfies (SOUNDNESS.md hypothesis 2):
/// the heap changes only as `prim_heap_ok` allows, a result is a value of
/// the new heap, an out-of-memory result a resource error. The theorem
/// needs only this.
pub open spec fn prim_default(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool {
    &&& prim_heap_ok(p, h, h2)
    &&& match r {
        PrimRet::Success(v) => good(h2, v),
        PrimRet::Failure(v) => good(h2, v),
        PrimRet::OutOfMemory(v) => resource_error(p, v),
    }
}

/// Primitive indices (core module 0) of the precise contracts below
/// (`v2::prim_arity::PRIM_TABLE`, from src/primitive.h).
pub spec const PRIM_ARRAY_AT: int = 14;
pub spec const PRIM_ARRAY_AT_PUT: int = 15;
pub spec const PRIM_SMI_ADD: int = 51;

/// Error roots used by the precise contracts.
pub spec const ROOT_OUT_OF_BOUNDS: int = 20;
pub spec const ROOT_PERMISSION_DENIED: int = 25;
pub spec const ROOT_WRONG_OBJECT_TYPE: int = 30;

/// The precise contract of primitive `(module, index)` where one is
/// stated, else `true`: the three examples below, and for the other core
/// primitives the per-primitive contracts of `v2::prim_core`
/// (`core_contract`, `true` where none is stated). A primitive ported to
/// Rust is proven against `prim_spec`, i.e. against this refinement and the
/// default contract; a C++ primitive is assumed to satisfy it (the core's
/// leaf contract of the call).
pub open spec fn prim_refined(p: Program2, module: u8, index: u16, args: Seq<Value>,
    h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    if module == 0 && index as int == PRIM_SMI_ADD {
        smi_add_spec(p, args, h, h2, r)
    } else if module == 0 && index as int == PRIM_ARRAY_AT {
        array_at_spec(p, args, h, h2, r)
    } else if module == 0 && index as int == PRIM_ARRAY_AT_PUT {
        array_at_put_spec(p, args, h, h2, r)
    } else if module == 0 {
        core_contract(p, index as int, args, h, h2, r)
    } else {
        true
    }
}

/// The arguments hold no block references. A primitive method may have
/// block parameters (`int.parse`'s `--if-error`, for which `int_parse`
/// takes an ignored argument); the primitive sees a block reference as the
/// word that encodes it, so the precise contracts, which are stated over
/// values, apply only to arguments without block references.
pub open spec fn plain_args(args: Seq<Value>) -> bool {
    forall|i: int| 0 <= i < args.len() ==> !(#[trigger] args[i] is BlockRef)
}

/// The set of what primitive `(module, index)` may return for `args` in
/// heap `h`, as a predicate: `(h2, r)` is in it if it satisfies the default
/// contract, refined where stated (`prim_refined`) for plain arguments. So
/// every element satisfies `prim_default` (`lemma_prim_spec_default`),
/// which is all the theorem uses.
pub open spec fn prim_spec(p: Program2, module: u8, index: u16, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet) -> bool
{
    &&& prim_default(p, h, h2, r)
    &&& plain_args(args) ==> prim_refined(p, module, index, args, h, h2, r)
}

pub proof fn lemma_prim_spec_default(p: Program2, module: u8, index: u16, args: Seq<Value>, h: Seq<HeapObj>,
    h2: Seq<HeapObj>, r: PrimRet)
    requires prim_spec(p, module, index, args, h, h2, r),
    ensures prim_default(p, h, h2, r),
{
}

/// The task primitives, which the machine completes itself.
pub open spec fn machine_completed(module: u8, index: u16) -> bool {
    module == 0 && (index as int == PRIM_TASK_NEW || index as int == PRIM_TASK_TRANSFER)
}

/// The machine's completion of a task primitive in state `s`.
pub open spec fn task_step(p: Program2, s: State2, index: u16) -> Outcome2 {
    let a = base(s);
    if index as int == PRIM_TASK_NEW {
        task_new_step(p, s, s.stack[a])
    } else {
        task_transfer_step(p, s, s.stack[a], s.stack[a + 1])
    }
}

/// The call of primitive `(module, index)` in state `s` (the step's
/// `Primitive` state) may return heap `h2` and result `r`.
pub open spec fn prim_returns(p: Program2, s: State2, module: u8, index: u16, h2: Seq<HeapObj>, r: PrimRet) -> bool {
    &&& prim_spec(p, module, index, prim_args(p, s), s.heap, h2, r)
    &&& (machine_completed(module, index) ==> r is OutOfMemory)
}

/// How the machine continues after the call returned `h2` and `r`.
pub open spec fn prim_complete(p: Program2, s: State2, h2: Seq<HeapObj>, r: PrimRet) -> Outcome2 {
    match r {
        PrimRet::Success(v) => prim_success(p, s, h2, v),
        PrimRet::Failure(v) => prim_failure(s, h2, v),
        PrimRet::OutOfMemory(v) => Outcome2::Raise(with_heap2(s, h2), v),
    }
}

// ---------------------------------------------------------------------------
// Precise contracts (examples; the C++ primitives `smi_add`, `array_at`,
// `array_at_put` of src/primitive_core.cc). Cases not listed are left to
// the default contract.

/// The array `v` refers to, as `(id, elements)`.
pub open spec fn array_of(h: Seq<HeapObj>, v: Value) -> Option<(int, Seq<Value>)> {
    match v {
        Value::Obj(id) => if (id as int) < h.len() {
            match h[id as int].body {
                Body::Array(e) => Some((id as int, e)),
                _ => None,
            }
        } else { None },
        _ => None,
    }
}

/// `smi_add(receiver, arg)`: a non-smi receiver fails with
/// WRONG_OBJECT_TYPE; two smis whose sum is a smi return the sum; the heap
/// is unchanged. (Overflow and large integers: default.)
pub open spec fn smi_add_spec(p: Program2, args: Seq<Value>, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool {
    args.len() == 2 ==> match (args[0], args[1]) {
        (Value::Smi(a), Value::Smi(b)) =>
            smi_ok(p1(p), a + b) ==> h2 == h && r == PrimRet::Success(smi(a + b)),
        (Value::Smi(_), _) => true,
        _ => h2 == h && r == PrimRet::Failure(p.roots[ROOT_WRONG_OBJECT_TYPE]),
    }
}

/// `array_at(array, index)`: a non-array fails with WRONG_OBJECT_TYPE; a
/// smi index inside the array returns the element, one outside it (and
/// inside the 32-bit range) fails with OUT_OF_BOUNDS; the heap is
/// unchanged.
pub open spec fn array_at_spec(p: Program2, args: Seq<Value>, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool {
    args.len() == 2 ==> match array_of(h, args[0]) {
        None => h2 == h && r == PrimRet::Failure(p.roots[ROOT_WRONG_OBJECT_TYPE]),
        Some((_, e)) => match args[1] {
            Value::Smi(i) =>
                if 0 <= i < e.len() {
                    h2 == h && r == PrimRet::Success(e[i as int])
                } else if -0x8000_0000 <= i < 0x8000_0000 {
                    h2 == h && r == PrimRet::Failure(p.roots[ROOT_OUT_OF_BOUNDS])
                } else {
                    true
                },
            _ => true,
        },
    }
}

/// `array_at_put(array, index, value)` in the order the C++ decodes its
/// arguments (`ARGS(Array, int, Object)`, then the checks): a non-array
/// fails with WRONG_OBJECT_TYPE; for a smi index in the 32-bit range, an
/// array of the program heap (read-only) fails with PERMISSION_DENIED, an
/// index inside the array stores the value and returns it, one outside it
/// fails with OUT_OF_BOUNDS. Only the stored element changes. (Another
/// index fails while decoding it, before the program-heap check: default.)
pub open spec fn array_at_put_spec(p: Program2, args: Seq<Value>, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet) -> bool {
    args.len() == 3 ==> match array_of(h, args[0]) {
        None => h2 == h && r == PrimRet::Failure(p.roots[ROOT_WRONG_OBJECT_TYPE]),
        Some((id, e)) => match args[1] {
            Value::Smi(i) =>
                if !(-0x8000_0000 <= i < 0x8000_0000) {
                    true
                } else if h[id].ro {
                    h2 == h && r == PrimRet::Failure(p.roots[ROOT_PERMISSION_DENIED])
                } else if 0 <= i < e.len() {
                    h2 == h.update(id, HeapObj { body: Body::Array(e.update(i as int, args[2])), ..h[id] })
                        && r == PrimRet::Success(args[2])
                } else {
                    h2 == h && r == PrimRet::Failure(p.roots[ROOT_OUT_OF_BOUNDS])
                },
            _ => true,
        },
    }
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
