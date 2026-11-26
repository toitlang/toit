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

//! The soundness theorem of the format-2 structural verifier.
//!
//! For every program `p` the verifier accepts (`accepts(p, c, trusted)`,
//! v2/verifier.rs, with some certificate `c`), started from a loaded heap
//! and globals (`loaded_ok`, the loader's contract), every state reachable
//! in any number of transitions makes a step that is not stuck, and every
//! completion of a PRIMITIVE step is not stuck either. No `Stuck` variant
//! remains. The objects the machine interprets itself keep the meaning it
//! gives them (`machine_objects_ok`: the tasks' stacks and ids). The
//! defined failures are not stuck outcomes: machine-raised exceptions
//! (lookup, as-check, code invocation, invalid program, missing or
//! unimplemented primitive: `raise`, completed by `prim::raised` with the
//! machine's trace or the out-of-memory error), the resource throws
//! (`prim::resource_throw`: stack overflow and out of memory, at the
//! instructions where the machine grows its stack or allocates), an
//! uncaught exception, task end, exit, deep sleep and reset
//! (`Outcome2::Halt`), and out-of-memory (no transition to a state beyond
//! `small`).
//!
//! The untrusted claim is the instance `trusted == false`, under which the
//! verifier rejects HALT 2 and 3 (deep sleep, reset); `trusted == true`
//! (system programs) permits them.
//!
//! The hypotheses are the trusted contract of an implementation; see
//! SOUNDNESS.md for each with its unfolding:
//! * `loaded_ok` (v2/sound.rs): the loader's heap and globals;
//! * `prim_heap_ok` (v2/sound.rs), inside `completion`: what a primitive
//!   may do to the heap (the oracle);
//! * `small` (v2/sound.rs), inside `transition`: the memory bound; the
//!   implementation must stop with out-of-memory instead of exceeding it.
//! `step` (v2/spec.rs, opaque only to keep proofs fast), `initial_state`
//! and the completions (v2/prim.rs) are the specification.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::prim::*;

verus! {

/// The outcomes a PRIMITIVE `(module, index)` step to state `s` may
/// complete with (the protocol of `v2::prim`): a missing (unimplemented)
/// primitive; a primitive the policy denies (`prim_denied`: not called, it
/// fails with PERMISSION_DENIED); the continuation after a call that
/// returned a heap and result the primitive's contract allows
/// (`prim_returns`: success, failure, out of memory); and the task
/// primitives, which the machine completes itself (task creation and
/// switching).
pub open spec fn completion(p: Program2, s: State2, module: u8, index: u16, o: Outcome2) -> bool {
    ||| o == prim_missing(p, s)
    ||| o == prim_denied(p, s)
    ||| exists|h2: Seq<HeapObj>, r: PrimRet| #[trigger] prim_returns(p, s, module, index, h2, r)
            && o == prim_complete(p, s, h2, r)
    ||| machine_completed(module, index) && o == task_step(p, s, index)
}

/// The machine continues in `s2` after outcome `o`: a next state, or the
/// state a yield resumes in (the scheduler resumes it at any later time).
pub open spec fn continues(o: Outcome2, s2: State2) -> bool {
    o == Outcome2::Next(s2) || o == Outcome2::Halt(s2, Halt2::Yield)
}

/// The outcomes of the machine in state `s`, oracle steps completed: the
/// step's outcome, a raise completed by `raised` (the machine allocates the
/// exception and its trace), every completion of a PRIMITIVE step, and the
/// resource throws at the instructions where the machine can run out of
/// stack or memory (`resource_throw`); each completed if it raises.
pub open spec fn outcome(p: Program2, s: State2, o: Outcome2) -> bool {
    ||| completes(p, step(p, s), o)
    ||| match step(p, s) {
            Outcome2::Primitive(s1, module, index) =>
                exists|o1: Outcome2| #[trigger] completion(p, s1, module, index, o1) && completes(p, o1, o),
            _ => false,
        }
    ||| exists|o1: Outcome2| #[trigger] resource_throw(p, s, o1) && completes(p, o1, o)
}

/// One transition: an outcome of `s` that continues in `s2`. There is no
/// transition to a state beyond the memory bound `small`: the machine
/// stops with out-of-memory instead.
pub open spec fn transition(p: Program2, s: State2, s2: State2) -> bool {
    &&& small(s2)
    &&& exists|o: Outcome2| #[trigger] outcome(p, s, o) && continues(o, s2)
}

/// A run of the process with loaded heap `heap0` and globals `globals0`:
/// it starts in the initial state and each state is followed by a
/// transition.
pub open spec fn run(p: Program2, heap0: Seq<HeapObj>, globals0: Seq<Value>, tr: Seq<State2>) -> bool {
    &&& tr.len() >= 1
    &&& tr[0] == initial_state(p, heap0, globals0)
    &&& forall|i: int| 0 <= i < tr.len() - 1 ==> #[trigger] transition(p, tr[i], tr[i + 1])
}

/// `s` is reachable: the last state of some run (of any length).
pub open spec fn reachable(p: Program2, heap0: Seq<HeapObj>, globals0: Seq<Value>, s: State2) -> bool {
    exists|tr: Seq<State2>| #[trigger] run(p, heap0, globals0, tr) && tr.last() == s
}

/// Every state of a run satisfies the invariant.
pub proof fn lemma_run_wf(p: Program2, c: Cert, trusted: bool, heap0: Seq<HeapObj>, globals0: Seq<Value>, tr: Seq<State2>, i: int)
    requires
        accepts(p, c, trusted),
        !p.unchecked,
        loaded_ok(p, c, heap0, globals0),
        run(p, heap0, globals0, tr),
        0 <= i < tr.len(),
    ensures wf(p, c, tr[i]), small(tr[i]),
    decreases i,
{
    if i == 0 {
        crate::v2::sound_prim::lemma_initial(p, c, trusted, heap0, globals0);
    } else {
        let s0 = tr[i - 1];
        let s = tr[i];
        assert(transition(p, tr[i - 1], tr[i - 1 + 1]));
        lemma_run_wf(p, c, trusted, heap0, globals0, tr, i - 1);
        let o = choose|o: Outcome2| #[trigger] outcome(p, s0, o) && continues(o, s);
        lemma_outcome_ok(p, c, trusted, s0, o);
    }
}

/// A completion of a good outcome is good, and not an oracle step.
pub proof fn lemma_completes_ok(p: Program2, c: Cert, o1: Outcome2, o: Outcome2)
    requires outcome_ok(p, c, o1), completes(p, o1, o),
    ensures outcome_ok(p, c, o), !(o is Raise), !(o is Stuck),
        o is Next || o is Halt ==> final_ok(p, c, o),
{
    match o1 {
        Outcome2::Raise(s1, v) => {
            assert(raised(p, s1, v, o));
            assert(final_ok(p, c, o));
        },
        _ => {},
    }
}

/// Every outcome of a well-formed state is good.
pub proof fn lemma_outcome_ok(p: Program2, c: Cert, trusted: bool, s: State2, o: Outcome2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), outcome(p, s, o), unchecked_ok(p, s),
    ensures outcome_ok(p, c, o), !(o is Raise), !(o is Stuck),
        o is Next || o is Halt ==> final_ok(p, c, o),
{
    crate::v2::sound_step::lemma_step(p, c, trusted, s);
    if completes(p, step(p, s), o) {
        lemma_completes_ok(p, c, step(p, s), o);
    } else if exists|o1: Outcome2| #[trigger] resource_throw(p, s, o1) && completes(p, o1, o) {
        let o1 = choose|o1: Outcome2| #[trigger] resource_throw(p, s, o1) && completes(p, o1, o);
        crate::v2::sound_resource::lemma_resource(p, c, trusted, s, o1);
        lemma_completes_ok(p, c, o1, o);
    } else {
        match step(p, s) {
            Outcome2::Primitive(s1, module, index) => {
                let o1 = choose|o1: Outcome2| #[trigger] completion(p, s1, module, index, o1) && completes(p, o1, o);
                assert(completions_ok(p, c, s1, module, index));
                lemma_completion_ok(p, c, s1, module, index, o1);
                lemma_completes_ok(p, c, o1, o);
            },
            _ => {},
        }
    }
}

/// Every reachable state satisfies the invariant.
pub proof fn lemma_reachable_wf(p: Program2, c: Cert, trusted: bool, heap0: Seq<HeapObj>, globals0: Seq<Value>, s: State2)
    requires
        accepts(p, c, trusted),
        !p.unchecked,
        loaded_ok(p, c, heap0, globals0),
        reachable(p, heap0, globals0, s),
    ensures wf(p, c, s), small(s),
{
    let tr = choose|tr: Seq<State2>| run(p, heap0, globals0, tr) && tr.last() == s;
    lemma_run_wf(p, c, trusted, heap0, globals0, tr, tr.len() - 1);
}

/// Each completion of a PRIMITIVE step keeps the invariant (from
/// `completions_ok`).
pub proof fn lemma_completion_ok(p: Program2, c: Cert, s: State2, module: u8, index: u16, o: Outcome2)
    requires completions_ok(p, c, s, module, index), completion(p, s, module, index, o),
    ensures outcome_ok(p, c, o),
{
    if exists|h2: Seq<HeapObj>, r: PrimRet| #[trigger] prim_returns(p, s, module, index, h2, r)
            && o == prim_complete(p, s, h2, r) {
        let (h2, r) = choose|h2: Seq<HeapObj>, r: PrimRet| #[trigger] prim_returns(p, s, module, index, h2, r)
            && o == prim_complete(p, s, h2, r);
        lemma_prim_spec_default(p, module, index, prim_args(p, s), s.heap, h2, r);
        assert(outcome_ok(p, c, prim_complete(p, s, h2, r)));
    }
    if o == prim_denied(p, s) {
        assert(outcome_ok(p, c, prim_denied(p, s)));
    }
}

/// The objects the machine gives a meaning the program cannot see: every
/// task's stack field refers to a stack object (or is the smi 0 once the
/// task has terminated) and its id is a smi, and the running task's stack
/// field refers to a stack object (the stack the machine runs on). A
/// program can neither read a task's stack field nor write it or the id
/// (`v2::spec::field_readable`, `field_writable`).
pub open spec fn machine_objects_ok(p: Program2, s: State2) -> bool {
    &&& running_ok(p, s)
    &&& forall|i: int| 0 <= i < s.heap.len() && (#[trigger] s.heap[i]).class_id as int == task_class(p) ==>
            task_obj_ok(s.heap, s.heap[i])
}

pub proof fn lemma_machine_objects(p: Program2, c: Cert, s: State2)
    requires wf(p, c, s),
    ensures machine_objects_ok(p, s),
{
    reveal(wf);
    reveal(heap_ok);
    assert forall|i: int| 0 <= i < s.heap.len() && (#[trigger] s.heap[i]).class_id as int == task_class(p) implies
        task_obj_ok(s.heap, s.heap[i]) by {
        assert(obj_ok(p, c, s.heap, s.heap[i]));
    }
}

/// The soundness theorem.
/// Stated for programs without the unchecked mode of trusted programs
/// (`spec::unchecked_fail`): every untrusted program (`accepts` with
/// `trusted == false` excludes the mode), and trusted programs verified as
/// such. A trusted program in the unchecked mode relies on the compiler for
/// its field accesses instead (verified/core/EXPERIMENT-trusted.md).
pub proof fn theorem_soundness(p: Program2, c: Cert, trusted: bool, heap0: Seq<HeapObj>, globals0: Seq<Value>, s: State2)
    requires
        accepts(p, c, trusted),
        !p.unchecked,
        loaded_ok(p, c, heap0, globals0),
        reachable(p, heap0, globals0, s),
    ensures
        !(step(p, s) is Stuck),
        forall|s1: State2, module: u8, index: u16, o: Outcome2|
            step(p, s) == Outcome2::Primitive(s1, module, index) && #[trigger] completion(p, s1, module, index, o)
                ==> !(o is Stuck),
        forall|o: Outcome2| #[trigger] outcome(p, s, o) ==> !(o is Stuck) && !(o is Raise),
        machine_objects_ok(p, s),
        // Confinement to the policy: a PRIMITIVE step names a primitive the
        // certificate's table (the policy's) allows with the frame's arity,
        // or one it denies, whose only completion the machine takes is
        // `prim_denied` (verified/core: `gc_call_primitive` and
        // `prims::call`, the only ways to run a primitive, require
        // `prim_allowed`).
        step(p, s) is Primitive ==> prim_listed(c.prim_arity, (step(p, s)->Primitive_1) as int,
            (step(p, s)->Primitive_2) as int, frame_height(s)),
{
    lemma_reachable_wf(p, c, trusted, heap0, globals0, s);
    lemma_machine_objects(p, c, s);
    crate::v2::sound_step::lemma_step(p, c, trusted, s);
    assert forall|s1: State2, module: u8, index: u16, o: Outcome2|
        step(p, s) == Outcome2::Primitive(s1, module, index) && #[trigger] completion(p, s1, module, index, o)
            implies !(o is Stuck) by {
        lemma_completion_ok(p, c, s1, module, index, o);
    }
    assert forall|o: Outcome2| #[trigger] outcome(p, s, o) implies !(o is Stuck) && !(o is Raise) by {
        lemma_outcome_ok(p, c, trusted, s, o);
    }
}

/// Non-vacuity: the invariant holds for the initial state of every
/// accepted, loaded program (so `wf` is satisfiable whenever `accepts` and
/// `loaded_ok` are; the checker tests show `accepts` for compiler output).
pub proof fn theorem_initial(p: Program2, c: Cert, trusted: bool, heap0: Seq<HeapObj>, globals0: Seq<Value>)
    requires accepts(p, c, trusted), loaded_ok(p, c, heap0, globals0),
    ensures reachable(p, heap0, globals0, initial_state(p, heap0, globals0)),
        wf(p, c, initial_state(p, heap0, globals0)),
{
    crate::v2::sound_prim::lemma_initial(p, c, trusted, heap0, globals0);
    let tr = seq![initial_state(p, heap0, globals0)];
    assert(run(p, heap0, globals0, tr));
    assert(tr.last() == initial_state(p, heap0, globals0));
}

} // verus!
