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

//! The end-to-end statement of the core (verified/core/DESIGN.md,
//! section 9). Meant to be read on its own.
//!
//! What Verus checks about the core: every exec function in a `verus!`
//! block is memory safe under its precondition (every access goes
//! through a view whose precondition bounds it) and meets its
//! postcondition. The run loop is such a function:
//!
//! ```text
//! pub fn step::run_loop(m: &mut Machine, env: &Env, accepted: &ffi::Accepted) -> (r: (usize, i64))
//!     requires old(m).inv(&env.p),
//!     ensures run_post(&env.p, *old(m), *final(m), r),
//! ```
//!
//! `Machine::inv` is "the machine refines a well-formed state of an
//! accepted program" (exec.rs: `refines && accepts && wf`). `run_post`
//! says the loop never reports a stuck state of the spec and never takes a
//! fatal path; it returns preempted or yielded only with the machine
//! refining a well-formed state that the spec reaches from the start
//! state (`step::advances`: the spec's completed outcomes,
//! `theorem::outcome`: the step, raises completed by `prim::raised`,
//! PRIMITIVE completions, resource throws `prim::resource_throw`); every
//! other result ends the process with a defined
//! outcome (exit, uncaught exception, task end, deep sleep, reset, out of
//! memory).
//!
//! So the whole theorem is: the run loop's precondition holds for the
//! first run of an accepted, loaded program (`theorem_first_run`, from the
//! spec's `theorem_initial`), and again for every later run
//! (`theorem_next_run`), for any number of runs and steps. Both rest on
//! the trusted contracts of TRUSTED.md and verified/TRUSTED.toml; the ones
//! these two theorems name explicitly are the loader's (`loaded`: the
//! tables are the accepted program, the machine encodes the initial state)
//! and the scheduler's (`resumed`: between runs the process is resumed in
//! the state it left, up to the GC). Every opcode is verified; what stays
//! assumed are the leaf contracts of the C++ calls, each stated as an
//! instance of a spec transition (TRUSTED.md section 6).

use vstd::prelude::*;
use crate::layout::*;
use crate::exec::*;
use crate::step::*;
use toit_spec::types::{Value, HeapObj};
use toit_spec::v2::types::{State2, Program2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, loaded_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::initial_state;

verus! {

/// The process is loaded: the program tables represent an abstract
/// program the verifier accepts (with certificate `p.cert`), whose heap
/// and globals satisfy the loader's contract, and the machine (the
/// process' first task, as `prepare_process_v2` builds it) represents the
/// spec's initial state. TRUSTED: the loader establishes it
/// (verified/vmverify for untrusted launches; TRUSTED.md, "Loader").
pub open spec fn loaded(p: &Program, m: &Machine, heap0: Seq<HeapObj>, globals0: Seq<Value>) -> bool {
    &&& accepts(p.ap@, p.cert@, p.trusted@)
    // The policy table the core reads is the one the verdict was computed
    // with (the certificate's primitive table).
    &&& crate::exec::policy_rel(p)
    &&& loaded_ok(p.ap@, p.cert@, heap0, globals0)
    &&& m.refines(p)
    &&& m.g@ == initial_state(p.ap@, heap0, globals0)
}

/// The first run: the run loop's precondition holds.
pub proof fn theorem_first_run(p: &Program, m: &Machine, heap0: Seq<HeapObj>, globals0: Seq<Value>)
    requires loaded(p, m, heap0, globals0),
    ensures
        m.inv(p),
        reaches(p.ap@, initial_state(p.ap@, heap0, globals0), m.g@),
{
    toit_spec::v2::theorem::theorem_initial(p.ap@, p.cert@, p.trusted@, heap0, globals0);
    lemma_reaches_refl_pub(p.ap@, m.g@);
}

/// Between two runs the scheduler resumes the process in the state the
/// previous run saved: the machine the next run reloads refines that
/// abstract state after collections (`toit_spec::v2::gc::gc_steps`: none,
/// or any number; the GC of a process can run while it is suspended).
/// TRUSTED: the scheduler and the GC (TRUSTED.md, "Between runs").
pub open spec fn resumed(p: &Program, m1: &Machine, m2: &Machine) -> bool {
    &&& m2.refines(p)
    &&& toit_spec::v2::gc::gc_steps(p.ap@, m1.g@, m2.g@)
}

/// Every later run: when a run ends preempted or yielded, the machine the
/// next run starts with satisfies the run loop's precondition again, and
/// its state is still reached from the initial state.
pub proof fn theorem_next_run(p: &Program, m0: &Machine, m1: &Machine, m2: &Machine, r: (usize, i64),
    s0: State2)
    requires
        m0.inv(p),
        reaches(p.ap@, s0, m0.g@),
        run_post(p, *m0, *m1, r),
        r.0 == RESULT_PREEMPTED || r.0 == RESULT_YIELDED,
        resumed(p, m1, m2),
    ensures
        m2.inv(p),
        reaches(p.ap@, s0, m2.g@),
{
    lemma_reaches_trans(p.ap@, s0, m0.g@, m1.g@);
    lemma_inv_gc(p, *m1, *m2);
    lemma_advances_gc_only(p.ap@, m1.g@, m2.g@);
    let tr = seq![m1.g@, m2.g@];
    assert forall|i: int| 0 <= i < tr.len() - 1 implies #[trigger] advances(p.ap@, tr[i], tr[i + 1]) by {
        assert(i == 0);
    }
    assert(chain(p.ap@, tr));
    assert(tr.last() == m2.g@);
    lemma_reaches_trans(p.ap@, s0, m1.g@, m2.g@);
}

/// `reaches` is reflexive ...
pub proof fn lemma_reaches_refl_pub(ap: Program2, g: State2)
    ensures reaches(ap, g, g),
{
    let tr = seq![g];
    assert(chain(ap, tr));
    assert(tr.last() == g);
}

/// ... and transitive.
pub proof fn lemma_reaches_trans(ap: Program2, g0: State2, g1: State2, g2: State2)
    requires reaches(ap, g0, g1), reaches(ap, g1, g2),
    ensures reaches(ap, g0, g2),
{
    let t1 = choose|tr: Seq<State2>| #[trigger] chain(ap, tr) && tr.len() >= 1 && tr[0] == g0 && tr.last() == g1;
    let t2 = choose|tr: Seq<State2>| #[trigger] chain(ap, tr) && tr.len() >= 1 && tr[0] == g1 && tr.last() == g2;
    let t = t1 + t2.subrange(1, t2.len() as int);
    assert forall|i: int| 0 <= i < t.len() - 1 implies #[trigger] advances(ap, t[i], t[i + 1]) by {
        if i < t1.len() - 1 {
            assert(t[i] == t1[i] && t[i + 1] == t1[i + 1]);
        } else {
            let j = i - (t1.len() - 1);
            assert(t[i] == t2[j]);
            assert(t[i + 1] == t2[j + 1]);
        }
    }
    assert(chain(ap, t));
    if t2.len() == 1 {
        assert(t =~= t1);
    } else {
        assert(t.last() == t2.last());
    }
}

} // verus!
