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

//! The end-to-end statement for a whole process, composed from
//! `theorem::theorem_first_run`, `theorem::theorem_next_run` and the
//! spec's soundness lemmas (docs/sandbox-guarantee.md, "The claim").
//!
//! `theorem.rs` states the two induction steps (the first run, every later
//! run) and says in prose that they compose for any number of runs. Here
//! the composition is a theorem, and its conclusion is the conclusion of
//! the spec's `theorem::theorem_soundness` for every state a run starts
//! in. That theorem is stated for `reachable` states, whose runs have no
//! garbage collections; the core's `reaches` includes collections
//! (`step::advances`, `toit_spec::v2::gc::gc_steps`). The bridge is the
//! invariant `wf`, which collections keep (`gc::lemma_gc_steps_wf`).
//!
//! This file is deliberately not an input of the verification epoch
//! (verified/verification-epoch.cmake): it adds no assumption about a
//! verified program, only a consequence of the existing ones.

use vstd::prelude::*;
use crate::layout::*;
use crate::exec::*;
use crate::step::*;
use crate::theorem::*;
use toit_spec::types::{Value, HeapObj};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, small, step_ok, unchecked_ok, completions_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::theorem::{completion, outcome, machine_objects_ok, lemma_outcome_ok, lemma_completion_ok,
    lemma_machine_objects};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::initial_state;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::prim_listed;

verus! {

/// A process as the scheduler drives it, up to the start of run
/// `ms.len() - 1`. Run `i` starts with machine `ms[i]` and returns `rs[i]`
/// with machine `es[i]`; what is known about that return is the run loop's
/// contract (`step::run_loop`: `run_post` whenever its precondition
/// `inv` held). The run ended preempted or yielded, and the scheduler
/// resumed the process in `ms[i + 1]` (`theorem::resumed`, the trusted
/// contract between runs).
pub open spec fn scheduled(p: &Program, ms: Seq<Machine>, es: Seq<Machine>, rs: Seq<(usize, i64)>) -> bool {
    &&& ms.len() >= 1
    &&& es.len() + 1 == ms.len()
    &&& rs.len() + 1 == ms.len()
    &&& forall|i: int| 0 <= i < es.len() ==> #[trigger] run_ok(p, ms[i], es[i], rs[i], ms[i + 1])
}

/// Run `i` of `scheduled`: the run loop's contract, a preemption or yield,
/// and the scheduler's resumption.
pub open spec fn run_ok(p: &Program, m0: Machine, m1: Machine, r: (usize, i64), m2: Machine) -> bool {
    &&& m0.inv(p) ==> run_post(p, m0, m1, r)
    &&& r.0 == RESULT_PREEMPTED || r.0 == RESULT_YIELDED
    &&& resumed(p, &m1, &m2)
}

/// The process theorem. For a program the loader established (`loaded`:
/// accepted by the verifier with its certificate, heap and globals as the
/// loader's contract says, the first machine representing the spec's
/// initial state), not in the unchecked mode of trusted programs (which
/// `accepts` excludes for every untrusted program), every run `i` starts
/// with a machine that
/// * satisfies the run loop's precondition (`inv`: it refines a
///   well-formed state of the accepted program),
/// * represents a state the spec reaches from the initial state by its
///   transitions and collections (`step::reaches`),
/// and that state has the properties the spec's soundness theorem gives a
/// reachable state: its step is not stuck, no completion of a PRIMITIVE
/// step is stuck, no outcome is stuck or an uncompleted raise, and the
/// machine's own objects (task stacks and ids) keep their meaning.
pub proof fn theorem_process(p: &Program, heap0: Seq<HeapObj>, globals0: Seq<Value>,
    ms: Seq<Machine>, es: Seq<Machine>, rs: Seq<(usize, i64)>, i: int)
    requires
        scheduled(p, ms, es, rs),
        loaded(p, &ms[0], heap0, globals0),
        !p.ap@.unchecked,
        0 <= i < ms.len(),
    ensures
        ms[i].inv(p),
        reaches(p.ap@, initial_state(p.ap@, heap0, globals0), ms[i].g@),
        !(sp::step(p.ap@, ms[i].g@) is Stuck),
        forall|s1: State2, module: u8, index: u16, o: Outcome2|
            sp::step(p.ap@, ms[i].g@) == Outcome2::Primitive(s1, module, index)
                && #[trigger] completion(p.ap@, s1, module, index, o)
                ==> !(o is Stuck),
        forall|o: Outcome2| #[trigger] outcome(p.ap@, ms[i].g@, o) ==> !(o is Stuck) && !(o is Raise),
        machine_objects_ok(p.ap@, ms[i].g@),
        // Confinement to the policy: a PRIMITIVE step names a primitive the
        // verified table (the policy's, `p.policy`) allows with the frame's
        // arity, one it denies, or one it does not have; the core runs a
        // primitive (C++: `gc_call_primitive`; Rust: `prims::call`) only if
        // the table allows it (both require `prim_allowed`) and completes a
        // denied one with `prim_denied` (PERMISSION_DENIED) and an absent one
        // with PRIMITIVE_LOOKUP_FAILED, calling nothing.
        sp::step(p.ap@, ms[i].g@) is Primitive ==>
            prim_listed(p.cert@.prim_arity, (sp::step(p.ap@, ms[i].g@)->Primitive_1) as int,
                (sp::step(p.ap@, ms[i].g@)->Primitive_2) as int, sp::frame_height(ms[i].g@)),
{
    lemma_process_inv(p, heap0, globals0, ms, es, rs, i);
    let ap = p.ap@;
    let c = p.cert@;
    let g = ms[i].g@;
    lemma_small(p, &ms[i]);
    assert(unchecked_ok(ap, g));
    toit_spec::v2::sound_step::lemma_step(ap, c, p.trusted@, g);
    lemma_machine_objects(ap, c, g);
    assert(step_ok(ap, c, g));
    assert forall|s1: State2, module: u8, index: u16, o: Outcome2|
        sp::step(ap, g) == Outcome2::Primitive(s1, module, index) && #[trigger] completion(ap, s1, module, index, o)
            implies !(o is Stuck) by {
        assert(completions_ok(ap, c, s1, module, index));
        lemma_completion_ok(ap, c, s1, module, index, o);
    }
    assert forall|o: Outcome2| #[trigger] outcome(ap, g, o) implies !(o is Stuck) && !(o is Raise) by {
        lemma_outcome_ok(ap, c, p.trusted@, g, o);
    }
}

/// The induction: `theorem_first_run` for run 0, `theorem_next_run` for
/// every later one.
proof fn lemma_process_inv(p: &Program, heap0: Seq<HeapObj>, globals0: Seq<Value>,
    ms: Seq<Machine>, es: Seq<Machine>, rs: Seq<(usize, i64)>, i: int)
    requires
        scheduled(p, ms, es, rs),
        loaded(p, &ms[0], heap0, globals0),
        0 <= i < ms.len(),
    ensures
        ms[i].inv(p),
        reaches(p.ap@, initial_state(p.ap@, heap0, globals0), ms[i].g@),
    decreases i,
{
    if i == 0 {
        theorem_first_run(p, &ms[0], heap0, globals0);
    } else {
        lemma_process_inv(p, heap0, globals0, ms, es, rs, i - 1);
        assert(run_ok(p, ms[i - 1], es[i - 1], rs[i - 1], ms[i - 1 + 1]));
        assert(ms[i - 1 + 1] == ms[i]);
        theorem_next_run(p, &ms[i - 1], &es[i - 1], &ms[i], rs[i - 1],
            initial_state(p.ap@, heap0, globals0));
    }
}

} // verus!
