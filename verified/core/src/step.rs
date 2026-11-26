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

//! The run loop and the instruction dispatch, verified.
//!
//! The loop invariant is `Machine::inv`: the machine refines a well-formed
//! state `g` of an accepted program (`wf`, the invariant of the verifier's
//! soundness proof, verified/spec/SOUNDNESS.md). Each iteration calls
//! `lemma_step` of the spec crate: the spec step from `g` is not stuck and
//! its next state is well formed. The handlers use "not stuck" in place of
//! run-time checks (the instruction lies in the method, slots exist, table
//! indices are in range, branch targets are in the method) and prove that
//! their result is the spec's next state.
//!
//! Every opcode of format 2 has a verified handler. The C++ calls on its
//! paths (allocation, stack growth, exception allocation, C++ primitives)
//! are leaf contracts stated as instances of the spec's transitions,
//! listed in verified/TRUSTED.toml and TRUSTED.md section 6.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::Regs;
use crate::room::*;
use crate::alloc::reload;
#[cfg(verus_keep_ghost)]
use crate::alloc::{reloaded, lemma_saved};
use toit_spec::types::{Value, HeapObj, Unwind};
use toit_spec::v2::types::{State2, Program2, Outcome2, Halt2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, small, step_ok, outcome_ok, cur_op};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, lemma_at_good, cur_k, cur_m, cur_off};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, value_operands, instr_ok, is_branch, map_at, w1_of, b1_of, bk_of, is_loop, loop_operands, loop_ok, post, hf_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::p1;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::theorem::{completion, continues, outcome};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::completes;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::gc::gc_steps;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::bytecodes::opcode_length2;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{u16_at, u32_at};

verus! {

// ---------------------------------------------------------------------------
// What a step guarantees.

/// The machine continues from a state the spec reaches from `g0`: the same
/// state (the instruction has not run: preemption before a backward
/// branch, stack growth before a call), or a state an outcome of `g0`
/// continues in (`theorem::outcome`: the step, a raise completed by
/// `prim::raised`, a completed PRIMITIVE step, or a completed resource
/// throw `prim::resource_throw`; `theorem::transition` without the size
/// bound, which `refines` implies). Garbage collections may come before
/// and after (`toit_spec::v2::gc::gc_steps`: the calls into C++ that may
/// collect, and the scheduler between runs).
pub open spec fn advances(ap: Program2, g0: State2, g1: State2) -> bool {
    ||| g1 == g0
    ||| exists|o: Outcome2| #[trigger] outcome(ap, g0, o) && continues(o, g1)
    ||| exists|ga: State2, gb: State2| #[trigger] gc_around(ap, g0, ga, gb, g1)
}

/// `advances` without collections.
pub open spec fn advances_now(ap: Program2, g0: State2, g1: State2) -> bool {
    ||| g1 == g0
    ||| exists|o: Outcome2| #[trigger] outcome(ap, g0, o) && continues(o, g1)
}

/// Collections from `g0` to `ga`, a step to `gb`, collections to `g1`.
pub open spec fn gc_around(ap: Program2, g0: State2, ga: State2, gb: State2, g1: State2) -> bool {
    &&& gc_steps(ap, g0, ga)
    &&& advances_now(ap, ga, gb)
    &&& gc_steps(ap, gb, g1)
}

/// Collections around an `advances` are one `advances`.
pub proof fn lemma_advances_gc(ap: Program2, g0: State2, ga: State2, gb: State2, g1: State2)
    requires gc_steps(ap, g0, ga), advances(ap, ga, gb), gc_steps(ap, gb, g1),
    ensures advances(ap, g0, g1),
{
    if advances_now(ap, ga, gb) {
        assert(gc_around(ap, g0, ga, gb, g1));
    } else {
        let (gc, gd) = choose|gc: State2, gd: State2| #[trigger] gc_around(ap, ga, gc, gd, gb);
        toit_spec::v2::gc::lemma_gc_steps_trans(ap, g0, ga, gc);
        toit_spec::v2::gc::lemma_gc_steps_trans(ap, gd, gb, g1);
        assert(gc_around(ap, g0, gc, gd, g1));
    }
}

/// Collections alone advance.
pub proof fn lemma_advances_gc_only(ap: Program2, g0: State2, g1: State2)
    requires gc_steps(ap, g0, g1),
    ensures advances(ap, g0, g1),
{
    toit_spec::v2::gc::lemma_gc_steps_refl(ap, g1);
    assert(gc_around(ap, g0, g1, g1, g1));
}

/// A step from a machine `ma` whose state the collections reached from
/// `m0`'s is a step from `m0`; so is a step followed by collections
/// (to a machine that has the invariant).
pub proof fn lemma_step_post_gc(p: &Program, m0: Machine, ma: Machine, mb: Machine, m1: Machine, r: Ctl)
    requires
        gc_steps(p.ap@, m0.g@, ma.g@),
        step_post(p, ma, mb, r),
        gc_steps(p.ap@, mb.g@, m1.g@),
        (r is Next || (r is Exit && (r->Exit_0 == RESULT_PREEMPTED || r->Exit_0 == RESULT_YIELDED))) ==> m1.inv(p),
    ensures step_post(p, m0, m1, r),
{
    if r is Next || (r is Exit && (r->Exit_0 == RESULT_PREEMPTED || r->Exit_0 == RESULT_YIELDED)) {
        lemma_advances_gc(p.ap@, m0.g@, ma.g@, mb.g@, m1.g@);
    }
}

/// The same for runs of steps.
pub proof fn lemma_steps_post_gc(p: &Program, m0: Machine, ma: Machine, mb: Machine, m1: Machine, r: Ctl)
    requires
        gc_steps(p.ap@, m0.g@, ma.g@),
        steps_post(p, ma, mb, r),
        gc_steps(p.ap@, mb.g@, m1.g@),
        (r is Next || (r is Exit && (r->Exit_0 == RESULT_PREEMPTED || r->Exit_0 == RESULT_YIELDED))) ==> m1.inv(p),
    ensures steps_post(p, m0, m1, r),
{
    if r is Next || (r is Exit && (r->Exit_0 == RESULT_PREEMPTED || r->Exit_0 == RESULT_YIELDED)) {
        let ap = p.ap@;
        lemma_advances_gc_only(ap, m0.g@, ma.g@);
        lemma_reaches_refl(ap, m0.g@);
        lemma_reaches_step(ap, m0.g@, m0.g@, ma.g@);
        lemma_reaches_trans(ap, m0.g@, ma.g@, mb.g@);
        lemma_advances_gc_only(ap, mb.g@, m1.g@);
        lemma_reaches_step(ap, m0.g@, mb.g@, m1.g@);
    }
}

/// An allocation that collected first (`alloc::gc_alloc_post`): the step
/// from `m0`'s state, then the collections, which commute with the
/// allocation (`toit_spec::v2::gc::lemma_gc_steps_alloc`: the new object
/// is a root afterwards).
pub proof fn lemma_alloc_gc(p: &Program, m0: Machine, m1: Machine, c: Ctl, g2: State2, o: HeapObj, k: int, len: int)
    requires
        m0.inv(p),
        step_ok(p.ap@, p.cert@, m0.g@),
        sp::step(p.ap@, m0.g@) == Outcome2::Next(toit_spec::v2::gc::alloc_push(m0.g@, o, k, len)),
        gc_steps(p.ap@, m0.g@, g2),
        toit_spec::v2::gc::plain_obj(p.ap@, o),
        0 <= k <= m0.g@.stack.len(),
        c == Ctl::Next || is_limit(c),
        c == Ctl::Next ==> m1.refines(p) && m1.g@ == toit_spec::v2::gc::alloc_push(g2, o, k, len),
    ensures step_post(p, m0, m1, c),
{
    if c == Ctl::Next {
        let ap = p.ap@;
        let g = m0.g@;
        let t = toit_spec::v2::gc::alloc_push(g, o, k, len);
        lemma_small(p, &m0);
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        assert(wf(ap, p.cert@, t));
        assert(completes(ap, sp::step(ap, g), sp::step(ap, g)));
        assert(outcome(ap, g, sp::step(ap, g)));
        assert(continues(sp::step(ap, g), t));
        assert(advances_now(ap, g, t));
        toit_spec::v2::gc::lemma_gc_steps_alloc(ap, g, g2, o, k, len);
        toit_spec::v2::gc::lemma_gc_steps_refl(ap, g);
        assert(gc_around(ap, g, g, t, m1.g@));
        toit_spec::v2::gc::lemma_gc_steps_wf(ap, p.cert@, t, m1.g@);
    }
}

/// After collections the machine that refines the collected state has the
/// invariant again.
pub proof fn lemma_inv_gc(p: &Program, m0: Machine, m1: Machine)
    requires m0.inv(p), m1.refines(p), gc_steps(p.ap@, m0.g@, m1.g@),
    ensures m1.inv(p), toit_spec::v2::gc::gc_shape(m0.g@, m1.g@),
{
    lemma_small(p, &m0);
    toit_spec::v2::gc::lemma_gc_steps_wf(p.ap@, p.cert@, m0.g@, m1.g@);
}

/// Every completion of `o` (`prim::completes`: a raise completed by
/// `raised`, anything else itself) is an outcome of `g`: `o` is the step's
/// outcome, or a resource throw of `g`. The handlers of a path that is one
/// of the spec's alternatives take this instead of `step == o`.
pub open spec fn source(ap: Program2, g: State2, o: Outcome2) -> bool {
    forall|o2: Outcome2| completes(ap, o, o2) ==> #[trigger] outcome(ap, g, o2)
}

pub proof fn lemma_source_step(ap: Program2, g: State2)
    ensures source(ap, g, sp::step(ap, g)),
{
}

pub proof fn lemma_source_resource(ap: Program2, g: State2, o1: Outcome2)
    requires toit_spec::v2::prim::resource_throw(ap, g, o1),
    ensures source(ap, g, o1),
{
    assert forall|o2: Outcome2| completes(ap, o1, o2) implies #[trigger] outcome(ap, g, o2) by {
        assert(toit_spec::v2::prim::resource_throw(ap, g, o1) && completes(ap, o1, o2));
    }
}

/// TRUSTED (verified/core/EXPERIMENT-trusted.md, TRUSTED.md section 6,
/// "Unchecked field accesses"): in the unchecked mode of a trusted program
/// (`Program2::unchecked`, which `accepts` allows only for trusted
/// programs) no step reaches a failed unchecked field access: we trust the
/// compiler for first-party code to emit field accesses only on instances
/// that have the field (and stores only outside the program heap). A wrong
/// program can crash the VM; an untrusted program never runs in this mode.
#[verifier::external_body]
pub proof fn trusted_field_accesses(ap: Program2, g: State2)
    requires ap.unchecked,
    ensures toit_spec::v2::sound::unchecked_ok(ap, g),
{
}

/// `unchecked_ok` of any state: trivial without the unchecked mode.
pub proof fn lemma_unchecked_ok(p: &Program, g: State2)
    ensures toit_spec::v2::sound::unchecked_ok(p.ap@, g),
{
    if p.ap@.unchecked { trusted_field_accesses(p.ap@, g); }
}

/// The machine a step starts from (whose state its outcomes are of): one
/// with the invariant, or a ghost machine whose state is the one that the
/// collections of a C++ call reached before the call's effect (no machine
/// refines that state; it has the state part of the invariant).
pub open spec fn src_ok(p: &Program, m: Machine) -> bool {
    ||| m.inv(p)
    ||| accepts(p.ap@, p.cert@, p.trusted@) && crate::exec::policy_rel(p) && wf(p.ap@, p.cert@, m.g@) && small(m.g@)
}

pub proof fn lemma_src_ok(p: &Program, m: Machine)
    requires src_ok(p, m),
    ensures accepts(p.ap@, p.cert@, p.trusted@), crate::exec::policy_rel(p), wf(p.ap@, p.cert@, m.g@), small(m.g@),
{
    if m.inv(p) { lemma_small(p, &m); }
}

/// A source that is not a raise is an outcome itself.
pub proof fn lemma_source_outcome(p: &Program, m: Machine, o: Outcome2)
    requires src_ok(p, m), source(p.ap@, m.g@, o), !(o is Raise),
    ensures outcome(p.ap@, m.g@, o), toit_spec::v2::sound::outcome_ok(p.ap@, p.cert@, o), !(o is Stuck),
{
    assert(completes(p.ap@, o, o));
    lemma_unchecked_ok(p, m.g@);
    lemma_src_ok(p, m);
    toit_spec::v2::theorem::lemma_outcome_ok(p.ap@, p.cert@, p.trusted@, m.g@, o);
}

/// A source is not stuck.
pub proof fn lemma_source_not_stuck(p: &Program, m: Machine, o: Outcome2)
    requires m.inv(p), source(p.ap@, m.g@, o),
    ensures !(o is Stuck),
{
    if !(o is Raise) { lemma_source_outcome(p, m, o); }
}

/// The outcome of one step: a next state that is again a well-formed state
/// the spec reaches; an exit (preemption and yield leave such a state for
/// the next run); or the defined out-of-memory stop (`stuck::LIMIT`).
/// No other stuck state and no fatal path.
pub open spec fn step_post(p: &Program, m0: Machine, m1: Machine, r: Ctl) -> bool {
    match r {
        Ctl::Next => m1.inv(p) && advances(p.ap@, m0.g@, m1.g@),
        Ctl::Exit(st, _) => (st == RESULT_PREEMPTED || st == RESULT_YIELDED) ==>
            m1.inv(p) && advances(p.ap@, m0.g@, m1.g@),
        Ctl::Stuck(reason) => reason == stuck::LIMIT,
        Ctl::Slow => false,
    }
}

/// What growing the stack leaves (`gc_grow_stack`): collections from `g`
/// to `g2` (`toit_spec::v2::gc::gc_steps`), the views represent `g2`, and
/// on success (`V2_OK`) at least `needed` words are free between the
/// records and the object stack.
pub open spec fn grow_post(p: &Program, m: Machine, g: State2, g2: State2, needed: usize, r: usize) -> bool {
    &&& gc_steps(p.ap@, g, g2)
    &&& reloaded(m, g2).refines(p)
    &&& r == V2_OK ==> reloaded(m, g2).top - reloaded(m, g2).rtop >= needed
}

/// TRUSTED (TRUSTED.md, "GC and stack growth"): `toit_v2_grow_stack` (may
/// GC). Before, the views represent `g`; after, `grow_post`: they
/// represent a state `g2` that collections reach from `g` (the task has a
/// new Stack with the frame and finally records copied to the bottom and
/// the object stack to the top, the header updated; the GC renumbers
/// objects and updates every root), and on success (`V2_OK`) at least
/// `needed` words are free between the records and the object stack. On
/// stack overflow or out of memory nothing changed but the collections.
#[verifier::external_body]
#[inline(always)]
pub fn gc_grow_stack(m: &mut Machine, env: &Env, needed: usize, Ghost(g): Ghost<State2>) -> (r: usize)
    requires
        reloaded(*old(m), g).refines(&env.p),
        // The C++ side rejects more than `Stack::max_length()` (an overflow);
        // this bound keeps every value far below 2^31 (TRUSTED.md 9).
        needed < GROW_STACK_MAX_NEEDED,
    ensures
        exists|g2: State2| #[trigger] grow_post(&env.p, *final(m), g, g2, needed, r),
{
    m.grow_stack_raw(env, needed)
}

/// Grows the stack (a GC point) so that `needed` words are free; the
/// instruction runs again afterwards (the state is unchanged). If the stack
/// cannot grow, the resource throw of the instruction
/// (`prim::resource_throw`, which every stack-growing instruction has): a
/// raise of the stack-overflow error, or a throw of the out-of-memory error.
pub fn grow(m: &mut Machine, env: &Env, needed: usize) -> (r: Ctl)
    requires
        old(m).inv(&env.p),
        needed < GROW_STACK_MAX_NEEDED,
        toit_spec::v2::prim::grows_stack(env.p.ap@.bytecodes[old(m).bci as int]),
        old(m).bci < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof { toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g); }
    m.save();
    proof { lemma_saved(p, *m); }
    let status = gc_grow_stack(m, env, needed, Ghost(g));
    // The collections reached `g2`; the instruction has not run.
    let ghost g2 = choose|g2: State2| #[trigger] grow_post(p, *m, g, g2, needed, status);
    reload(m, p, Ghost(g2));
    let ghost m1 = *m;
    proof {
        lemma_inv_gc(p, m0, m1);
        toit_spec::v2::gc::lemma_gc_steps_refl(ap, g2);
    }
    if status == V2_OK {
        proof { lemma_advances_gc_only(ap, g, g2); }
        return Ctl::Next;
    }
    if status == V2_STACK_OVERFLOW {
        let ghost v = ap.roots[ROOT_STACK_OVERFLOW as int];
        proof {
            assert(toit_spec::v2::prim::resource_throw(ap, g2, Outcome2::Raise(g2, v)));
            lemma_source_resource(ap, g2, Outcome2::Raise(g2, v));
            m.lemma_root(p, ROOT_STACK_OVERFLOW as int);
            crate::calls::lemma_shape(p, g2);
        }
        let value = p.roots.at(ROOT_STACK_OVERFLOW);
        let r = m.raise_with(env, Ghost(m1), value, Ghost(v), V2_MESSAGE_NONE, [0, 0, 0, 0], 0, Ghost(Seq::empty()));
        proof {
            toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.g@);
            lemma_step_post_gc(p, m0, m1, *m, *m, r);
        }
        return r;
    }
    proof {
        let o1 = sp::unwind(ap, g2, Unwind::Throw(toit_spec::v2::prim::out_of_memory(ap)));
        assert(toit_spec::v2::prim::resource_throw(ap, g2, o1));
        lemma_source_resource(ap, g2, o1);
    }
    let r = crate::unwind::throw_oom(m, env);
    proof {
        toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.g@);
        lemma_step_post_gc(p, m0, m1, *m, *m, r);
    }
    r
}

/// Room for a call: a frame record, the callee's slots and the reserve, plus
/// one finally record of slack (so that, even at the maximal stack length
/// after a stack overflow, the frame can enter its finally code with the
/// room `room::room_ok` asks for). `None`: there is room. `Some(r)`: the instruction did not run (it runs again after the
/// stack grew), or a stack overflow was thrown.
#[inline(always)]
pub fn ensure_room(m: &mut Machine, env: &Env) -> (r: Option<Ctl>)
    requires
        old(m).inv(&env.p),
        toit_spec::v2::prim::grows_stack(env.p.ap@.bytecodes[old(m).bci as int]),
        old(m).bci < 0x1000_0000,
    ensures
        r is None ==> *final(m) == *old(m) && final(m).top - final(m).rtop >= FRAME_WORDS + STACK_RESERVE,
        r is Some ==> step_post(&env.p, *old(m), *final(m), r->0),
{
    proof { assert(env.p.max_height < 0x1_0000); }
    let needed = FRAME_WORDS + env.p.max_height + STACK_RESERVE + FIN_WORDS;
    if m.top - m.rtop >= needed {
        return None;
    }
    Some(grow(m, env, needed))
}

// ---------------------------------------------------------------------------
// Decoding.

#[inline(always)]
pub fn code_u16(p: &Program, i: usize) -> (r: usize)
    requires i + 1 < p.code@.len() < 0x1000_0000,
    ensures
        r == p.code@[i as int] as int + 256 * p.code@[i + 1] as int,
        r < 0x1_0000,
{
    let a = p.code.at(i);
    let b = p.code.at(i + 1);
    (a as usize) + (b as usize) * 256
}

#[inline(always)]
pub fn code_u32(p: &Program, i: usize) -> (r: usize)
    requires i + 3 < p.code@.len() < 0x1000_0000,
    ensures
        r == p.code@[i as int] as int + 256 * p.code@[i + 1] as int
            + 65536 * (p.code@[i + 2] as int + 256 * p.code@[i + 3] as int),
        r < 0x1_0000_0000,
{
    let lo = code_u16(p, i);
    let hi = code_u16(p, i + 2);
    lo + hi * 65536
}

/// The bci of the instruction pointer (computed only in the arms that need
/// it as a value: before the dispatch it would cost every instruction).
#[inline(always)]
pub fn cur_bci(p: &Program, ip: crate::view::Ip) -> (r: usize)
    requires ip.sid() == p.code.sid(), 0 <= ip@ < p.code@.len() < 0x1000_0000,
    ensures r == ip@,
{
    ip.diff(p.code.cursor(0))
}

/// The little-endian u16 at offset `k` from the instruction pointer.
#[inline(always)]
pub fn ip_u16(p: &Program, ip: crate::view::Ip, k: usize) -> (r: usize)
    requires ip.sid() == p.code.sid(), 0 <= ip@, ip@ + k + 1 < p.code@.len() < 0x1000_0000,
    ensures
        r == p.code@[ip@ + k] as int + 256 * p.code@[ip@ + k + 1] as int,
        r < 0x1_0000,
{
    let a = ip.byte(k, &p.code);
    let b = ip.byte(k + 1, &p.code);
    (a as usize) + (b as usize) * 256
}

/// The little-endian u32 at offset `k` from the instruction pointer.
#[inline(always)]
pub fn ip_u32(p: &Program, ip: crate::view::Ip, k: usize) -> (r: usize)
    requires ip.sid() == p.code.sid(), 0 <= ip@, ip@ + k + 3 < p.code@.len() < 0x1000_0000,
    ensures
        r == p.code@[ip@ + k] as int + 256 * p.code@[ip@ + k + 1] as int
            + 65536 * (p.code@[ip@ + k + 2] as int + 256 * p.code@[ip@ + k + 3] as int),
        r < 0x1_0000_0000,
{
    let lo = ip_u16(p, ip, k);
    let hi = ip_u16(p, ip, k + 2);
    lo + hi * 65536
}

// ---------------------------------------------------------------------------
// The step.

pub proof fn lemma_small(p: &Program, m: &Machine)
    requires m.refines(p),
    ensures small(m.g@),
{
    let g = m.g@;
    assert(g.stack.len() == m.words().len());
    assert(g.frames.len() * 4 <= m.len);
}



/// The machine's result `r` (with machine `m1` after it) implements the
/// spec outcome `o`: the next state; a preemption right after a call (the
/// next state, to continue later); a yield; a terminal halt (exit, task
/// end, uncaught exception, deep sleep, reset); or out of room.
pub open spec fn matches(p: &Program, o: Outcome2, m1: Machine, r: Ctl) -> bool {
    match r {
        Ctl::Next => m1.refines(p) && o == Outcome2::Next(m1.g@),
        Ctl::Exit(st, _) =>
            if st == RESULT_PREEMPTED {
                m1.refines(p) && o == Outcome2::Next(m1.g@)
            } else if st == RESULT_YIELDED {
                m1.refines(p) && o == Outcome2::Halt(m1.g@, Halt2::Yield)
            } else {
                o is Halt && !(o->Halt_1 is Yield)
            },
        Ctl::Stuck(reason) => reason == stuck::LIMIT,
        Ctl::Slow => false,
    }
}

pub proof fn lemma_matches(p: &Program, m0: Machine, m1: Machine, r: Ctl)
    requires
        m0.inv(p),
        step_ok(p.ap@, p.cert@, m0.g@),
        matches(p, sp::step(p.ap@, m0.g@), m1, r),
    ensures step_post(p, m0, m1, r),
{
    let o = sp::step(p.ap@, m0.g@);
    if !(r is Stuck) {
        assert(!(o is Raise));
        assert(completes(p.ap@, o, o));
        assert(outcome(p.ap@, m0.g@, o));
        lemma_outcome_matches(p, m0, m1, r, o);
    }
}

/// The machine's result `r` implements an outcome `o` of the state (any
/// completed outcome of `theorem::outcome`, e.g. a completed raise or
/// resource throw).
pub proof fn lemma_outcome_matches(p: &Program, m0: Machine, m1: Machine, r: Ctl, o: Outcome2)
    requires
        src_ok(p, m0),
        outcome(p.ap@, m0.g@, o),
        matches(p, o, m1, r),
    ensures step_post(p, m0, m1, r),
{
    lemma_unchecked_ok(p, m0.g@);
    lemma_src_ok(p, m0);
    toit_spec::v2::theorem::lemma_outcome_ok(p.ap@, p.cert@, p.trusted@, m0.g@, o);
    match r {
        Ctl::Next => { assert(continues(o, m1.g@)); },
        Ctl::Exit(st, _) => {
            if st == RESULT_PREEMPTED || st == RESULT_YIELDED { assert(continues(o, m1.g@)); }
        },
        _ => {},
    }
}

/// A handler's result for the instruction: `Next` with the spec's next
/// state, or out of room.
pub open spec fn local_post(p: &Program, m0: Machine, m1: Machine, r: Ctl) -> bool {
    &&& r == Ctl::Next || is_limit(r)
    &&& r == Ctl::Next ==> m1.refines(p) && sp::step(p.ap@, m0.g@) == Outcome2::Next(m1.g@)
}

proof fn lemma_local_post(p: &Program, m0: Machine, m1: Machine, r: Ctl)
    requires
        m0.inv(p),
        step_ok(p.ap@, p.cert@, m0.g@),
        local_post(p, m0, m1, r),
    ensures step_post(p, m0, m1, r),
{
    if r == Ctl::Next {
        let o = sp::step(p.ap@, m0.g@);
        assert(outcome_ok(p.ap@, p.cert@, o));
        assert(continues(o, m1.g@));
        assert(completes(p.ap@, o, o));
        assert(outcome(p.ap@, m0.g@, o));
    }
}

/// The condition of a conditional branch is a value (not a block
/// reference), by the verifier's `value_operands`.
proof fn lemma_branch_cond(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        ({ let op = cur_op(p.ap@, g); (82 <= op <= 84) || (86 <= op <= 88) || (115 <= op <= 117) }),
    ensures !(sp::at(g, 0) is BlockRef),
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let k = cur_k(ap, c, g);
    assert(value_operands(k, 1));
    lemma_at_good(ap, c, p.trusted@, g, 0);
}

/// A backward branch stays at or after the method's entry (the verifier
/// maps the target offset).
proof fn lemma_back_branch(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        ({ let op = cur_op(p.ap@, g); 85 <= op <= 88 }),
    ensures
        u16_at(p1(p.ap@), g.bci + 1) <= g.bci,
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let mi = cur_m(g);
    let off = cur_off(ap, g);
    let k = cur_k(ap, c, g);
    assert(instr_ok(ap, c, mi, off, k, p.trusted@));
    assert(is_branch(cur_op(ap, g)));
    assert(map_at(c, mi, off - w1_of(ap, mi, off)) is Some);
}

/// BRANCH_BACK_S (format note 22) stays at or after the method's entry.
proof fn lemma_back_branch_s(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        cur_op(p.ap@, g) == 118,
    ensures
        p.ap@.bytecodes[g.bci + 1] <= g.bci,
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let mi = cur_m(g);
    let off = cur_off(ap, g);
    let k = cur_k(ap, c, g);
    assert(instr_ok(ap, c, mi, off, k, p.trusted@));
    assert(is_branch(cur_op(ap, g)));
    assert(map_at(c, mi, off - b1_of(ap, mi, off)) is Some);
}

/// The operands of a loop step are values and its backward branch stays at
/// or after the method's entry (the verifier's `loop_ok` and `loop_kinds`).
proof fn lemma_loop_cond(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        cur_op(p.ap@, g) == 101 || cur_op(p.ap@, g) == 102,
    ensures ({
        let n = p.ap@.bytecodes[g.bci + 3] as int;
        &&& sp::at(g, n) is Smi || sp::at(g, n) is Obj
        &&& sp::at(g, n + 2) is Smi || sp::at(g, n + 2) is Obj
        &&& cur_op(p.ap@, g) == 102 ==> (sp::at(g, n + 3) is Smi || sp::at(g, n + 3) is Obj)
        &&& u16_at(p1(p.ap@), g.bci + 1) <= g.bci
    }),
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let mi = cur_m(g);
    let off = cur_off(ap, g);
    let k = cur_k(ap, c, g);
    let n = bk_of(ap, mi, off, 3);
    let y = if cur_op(ap, g) == 102 { n + 3 } else { n + 2 };
    assert(instr_ok(ap, c, mi, off, k, p.trusted@));
    assert(is_loop(cur_op(ap, g)));
    assert(loop_operands(ap, mi, off) == (n, n + 1, n + 2, y));
    assert(post(ap, c, mi, off, k, p.trusted@) is Some);
    assert(loop_ok(ap, mi, k, n, n + 1, n + 2, y));
    lemma_at_good(ap, c, p.trusted@, g, n);
    lemma_at_good(ap, c, p.trusted@, g, n + 2);
    lemma_at_good(ap, c, p.trusted@, g, y);
    assert(map_at(c, mi, off - w1_of(ap, mi, off)) is Some);
}

/// HASH_FIND's operands are values; its forward branch stays inside the
/// method (the verifier's `hf_ok` and the target's map).
proof fn lemma_hash_find_cond(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        cur_op(p.ap@, g) == 103,
    ensures ({
        let n = p.ap@.bytecodes[g.bci + 3] as int;
        let mm = p.ap@.bytecodes[g.bci + 4] as int;
        &&& forall|j: int| (j == n || j == n + 1 || j == n + 2 || j == mm || j == mm + 2) ==>
            (#[trigger] sp::at(g, j) is Smi || sp::at(g, j) is Obj)
        &&& g.bci + u16_at(p1(p.ap@), g.bci + 1) < p.ap@.bytecodes.len()
        &&& p.ap@.builtin.len() == 23
    }),
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let mi = cur_m(g);
    let off = cur_off(ap, g);
    let k = cur_k(ap, c, g);
    let n = bk_of(ap, mi, off, 3);
    let mm = bk_of(ap, mi, off, 4);
    assert(instr_ok(ap, c, mi, off, k, p.trusted@));
    assert(post(ap, c, mi, off, k, p.trusted@) is Some);
    assert(hf_ok(ap, mi, k, n, mm));
    lemma_at_good(ap, c, p.trusted@, g, n);
    lemma_at_good(ap, c, p.trusted@, g, n + 1);
    lemma_at_good(ap, c, p.trusted@, g, n + 2);
    lemma_at_good(ap, c, p.trusted@, g, mm);
    lemma_at_good(ap, c, p.trusted@, g, mm + 2);
    assert(map_at(c, mi, off + w1_of(ap, mi, off)) is Some);
    toit_spec::v2::sound_local::lemma_map_bound(ap, c, p.trusted@, mi, off + w1_of(ap, mi, off));
}

/// The opcodes whose handlers (or whose slow paths) run on the machine
/// (`Slow::Op`): LOAD_GLOBAL_VAR_LAZY(_WIDE) (the initializer call),
/// INVOKE_STATIC_TAIL, INVOKE_BLOCK, INVOKE_LAMBDA_TAIL and
/// INVOKE_INITIALIZER_TAIL (raises, finally records, stack growth,
/// preemption), THROW, NON_LOCAL_RETURN, NON_LOCAL_BRANCH, TRY, UNWIND and
/// HALT.
pub open spec fn machine_op(op: u8) -> bool {
    ||| op == 32 || op == 33
    ||| 54 <= op <= 57
    ||| op == 90 || op == 93 || op == 95 || op == 97 || op == 99 || op == 100
}

/// One step of a `machine_op` instruction on the machine's handler
/// (`spec::step`).
#[inline(always)]
#[verifier::spinoff_prover]
pub fn step_machine(m: &mut Machine, env: &Env) -> (r: Ctl)
    requires old(m).inv(&env.p), machine_op(env.p.ap@.bytecodes[old(m).bci as int]),
    ensures
        step_post(&env.p, *old(m), *final(m), r),
        ({ let op = env.p.ap@.bytecodes[old(m).bci as int];
           (op == 90 || op == 93 || op == 95 || op == 99) && r == Ctl::Next
           ==> crate::unwind::frames_prefix(old(m).g@, final(m).g@) && final(m).len == old(m).len }),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    proof {
        lemma_small(p, m);
        lemma_unchecked_ok(p, g);
        toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g);
        lemma_instr(ap, p.cert@, p.trusted@, g);
        reveal_with_fuel(opcode_length2, 1);
    }
    let bci = m.bci;
    let opcode = p.code.at(bci);
    match opcode {
        32 => {
            let i = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_global_lazy(ap, g, i as int, 2)) by { reveal(sp::step); } }
            crate::globals::op_load_global_lazy(m, env, bci, opcode, i, 2)
        },
        33 => {
            let i = code_u16(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::op_load_global_lazy(ap, g, i as int, 3)) by { reveal(sp::step); } }
            crate::globals::op_load_global_lazy(m, env, bci, opcode, i, 3)
        },
        54 => {
            let d = code_u16(p, bci + 1);
            proof {
                assert(sp::step(ap, g) == sp::op_invoke_static_tail(ap, g, d as int)) by { reveal(sp::step); }
            }
            crate::tail::op_invoke_static_tail(m, env, bci, opcode, d)
        },
        55 => {
            let k = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_invoke_block(ap, g, k as int)) by { reveal(sp::step); } }
            crate::blocks::op_invoke_block(m, env, bci, opcode, k)
        },
        56 => {
            proof { assert(sp::step(ap, g) == sp::op_invoke_lambda_tail(ap, g)) by { reveal(sp::step); } }
            crate::tail::op_invoke_lambda_tail(m, env, bci, opcode)
        },
        57 => {
            proof { assert(sp::step(ap, g) == sp::op_invoke_initializer_tail(ap, g)) by { reveal(sp::step); } }
            crate::tail::op_invoke_initializer_tail(m, env, bci, opcode)
        },
        97 => {
            proof { assert(sp::step(ap, g) == sp::op_try(ap, g)) by { reveal(sp::step); } }
            crate::unwind::op_try(m, env, bci, opcode)
        },
        100 => {
            let code = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_halt(ap, g, code as int)) by { reveal(sp::step); } }
            crate::halt::op_halt(m, env, bci, opcode, code)
        },
        90 | 93 | 95 | 99 => {
            // One call site: the unwinding loop is inlined once.
            let (hd, off) = if opcode == 95 { (p.code.at(bci + 1) as usize, code_u32(p, bci + 2)) } else { (0, 0) };
            proof {
                if opcode == 90 {
                    assert(sp::step(ap, g) == (if !sp::has_slot(g, 0) { sp::stuck(toit_spec::types::Stuck::StackRange) }
                        else { sp::unwind(ap, g, Unwind::Throw(sp::at(g, 0))) })) by { reveal(sp::step); }
                    assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
                } else if opcode == 93 {
                    assert(sp::step(ap, g) == sp::op_non_local_return(ap, g)) by { reveal(sp::step); }
                } else if opcode == 95 {
                    assert(sp::step(ap, g) == sp::op_non_local_branch(ap, g, hd as int, off as int)) by { reveal(sp::step); }
                } else {
                    assert(sp::step(ap, g) == sp::op_unwind(ap, g)) by { reveal(sp::step); }
                }
            }
            crate::unwind::op_unwinding(m, env, bci, opcode, hd, off)
        },
        _ => {
            proof { assert(false); }
            crate::view::proven_unreachable()
        },
    }
}

// ---------------------------------------------------------------------------
// The step on registers.

/// What a step on registers guarantees: on `Next` the registers `r1` are
/// cursors of `m1` and `m1.with(r1)` is the machine of `step_post` (one
/// step) or of `steps_post` (the machine's handlers ran several steps until
/// no finally records were left, `settle`); on `Slow` nothing changed and
/// the slow path applies (`slow_pre`: the run loop runs it); on any other
/// result the machine `m1` itself (the registers written back).
pub open spec fn rpost(p: &Program, m0: Machine, r0: Regs, m1: Machine, r1: Regs, c: Ctl) -> bool {
    if c == Ctl::Next {
        &&& m1.rok(r1)
        &&& crate::regs::ipok(p, r1)
        &&& crate::regs::gate_ok(p, m1)
        &&& step_post(p, m0.with(r0), m1.with(r1), c) || steps_post(p, m0.with(r0), m1.with(r1), c)
        &&& room_ok(p, m1.with(r1))
    } else if c is Slow {
        &&& m1 == (Machine { slow_k: m1.slow_k, slow_w: m1.slow_w, ..m0 })
        &&& r1 == r0
        &&& exists|v: Value| #[trigger] slow_pre(p, m1, r1, m1.slow_k, m1.slow_w, v)
    } else {
        step_post(p, m0.with(r0), m1, c) || steps_post(p, m0.with(r0), m1, c)
    }
}

/// `step_post` for a run of steps: `reaches` for `advances`.
pub open spec fn steps_post(p: &Program, m0: Machine, m1: Machine, r: Ctl) -> bool {
    match r {
        Ctl::Next => m1.inv(p) && reaches(p.ap@, m0.g@, m1.g@),
        Ctl::Exit(st, _) => (st == RESULT_PREEMPTED || st == RESULT_YIELDED) ==>
            m1.inv(p) && reaches(p.ap@, m0.g@, m1.g@),
        Ctl::Stuck(reason) => reason == stuck::LIMIT,
        Ctl::Slow => false,
    }
}

pub proof fn lemma_steps_post(p: &Program, m0: Machine, m1: Machine, r: Ctl)
    requires step_post(p, m0, m1, r),
    ensures steps_post(p, m0, m1, r),
{
    if r is Next || (r is Exit && (r->Exit_0 == RESULT_PREEMPTED || r->Exit_0 == RESULT_YIELDED)) {
        lemma_reaches_refl(p.ap@, m0.g@);
        lemma_reaches_step(p.ap@, m0.g@, m0.g@, m1.g@);
    }
}

/// Back to the registers after a path that ran on the machine from `w0`
/// with result `c`: on `Next` the room is re-established (the machine's
/// handlers do not track it; an unwinding into finally code adds a record)
/// and the registers derived with the gate for the finally records
/// (`Machine::enter`).
pub fn resume(m: &mut Machine, env: &Env, c: Ctl, Ghost(w0): Ghost<Machine>) -> (res: (Option<Regs>, Ctl))
    requires step_post(&env.p, w0, *old(m), c) || steps_post(&env.p, w0, *old(m), c),
    ensures
        res.1 == Ctl::Next ==> res.0 is Some && final(m).rok(res.0->0)
            && crate::regs::ipok(&env.p, res.0->0)
            && crate::regs::gate_ok(&env.p, *final(m))
            && steps_post(&env.p, w0, final(m).with(res.0->0), res.1)
            && room_ok(&env.p, final(m).with(res.0->0)),
        res.1 != Ctl::Next ==> steps_post(&env.p, w0, *final(m), res.1),
{
    resume_with(m, env, c, false, Ghost(w0))
}

/// `resume`, where `ok` says that the room is known to hold (no rescan).
pub fn resume_with(m: &mut Machine, env: &Env, c: Ctl, ok: bool, Ghost(w0): Ghost<Machine>) -> (res: (Option<Regs>, Ctl))
    requires
        step_post(&env.p, w0, *old(m), c) || steps_post(&env.p, w0, *old(m), c),
        ok ==> room_ok(&env.p, *old(m)),
    ensures
        res.1 == Ctl::Next ==> res.0 is Some && final(m).rok(res.0->0)
            && crate::regs::ipok(&env.p, res.0->0)
            && crate::regs::gate_ok(&env.p, *final(m))
            && steps_post(&env.p, w0, final(m).with(res.0->0), res.1)
            && room_ok(&env.p, final(m).with(res.0->0)),
        res.1 != Ctl::Next ==> steps_post(&env.p, w0, *final(m), res.1),
{
    proof { if step_post(&env.p, w0, *m, c) { lemma_steps_post(&env.p, w0, *m, c); } }
    if let Ctl::Next = c {
    } else {
        return (None, c);
    }
    let ghost m1 = *m;
    proof { toit_spec::v2::gc::lemma_gc_steps_refl(env.p.ap@, m1.g@); }
    let c2 = if ok { Ctl::Next } else { ensure_room_all(m, env) };
    if let Ctl::Next = c2 {
        let ghost m2 = *m;
        let r = m.enter(&env.p);
        proof {
            assert(m.with(r).g == m2.g);
            toit_spec::v2::gc::lemma_gc_steps_refl(env.p.ap@, w0.g@);
            lemma_steps_post_gc(&env.p, w0, w0, m1, m.with(r), Ctl::Next);
        }
        (Some(r), c2)
    } else {
        (None, c2)
    }
}

/// After a path on the machine that kept the frames below the top and the
/// stack length (a call, a return, an unwinding: `room::top_kept`): those
/// frames have the room they had, so the room holds if the top frame has
/// it with the finally records (`room::top_room`); `resume_with` then
/// skips the rescan of every frame (`ensure_room_all`).
pub fn top_room_kept(m: &Machine, env: &Env, Ghost(w0): Ghost<Machine>) -> (b: bool)
    requires
        step_post(&env.p, w0, *m, Ctl::Next),
        room_ok(&env.p, w0),
        top_kept(w0.g@, m.g@),
        m.len >= w0.len,
    ensures b ==> room_ok(&env.p, *m),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost n = g.frames.len() as int;
    proof {
        lemma_steps_post(p, w0, *m, Ctl::Next);
        m.lemma_frame(p);
        crate::calls::lemma_shape(p, g);
        lemma_rec_index(n, n - 1, FRAME_BASE);
        lemma_rec_index(n, n - 1, FRAME_METHOD);
        assert(rec(m.mem@, n - 1, FRAME_BASE) == g.frames[n - 1].base);
        assert(rec(m.mem@, n - 1, FRAME_METHOD) == g.frames[n - 1].method);
        assert(m.ftop == FRAME_WORDS * n);
    }
    let ri = m.ftop - FRAME_WORDS;
    let base = m.mem.read(ri + FRAME_BASE);
    let method = m.mem.read(ri + FRAME_METHOD);
    if base >= MAX_STACK_LENGTH {
        return false;
    }
    proof {
        assert(sp::valid_method(ap, g.frames[n - 1].method as int));
        assert(ap.methods[method as int] == method_info(p.minfo(method as int), p.max_height));
        assert(p.max_height < 0x1_0000);
    }
    let a = p.method(method).arity as usize;
    let total = base + a + p.max_height + m.rtop + STACK_RESERVE;
    if total > m.len {
        return false;
    }
    proof {
        assert(frame_need(p, g, n - 1) <= m.len);
        assert forall|i: int| 0 <= i < g.frames.len() implies #[trigger] frame_room(p, *m, i) by {
            if i < n - 1 {
                assert(g.frames[i] == w0.g@.frames[i]);
                assert(frame_room(p, w0, i));
            }
        }
        assert(top_room(p, *m));
    }
    true
}

/// The run loop's invariant on registers: the registers are cursors of the
/// machine, which satisfies `inv` with them and has room; the gate for the
/// finally records is set.
pub open spec fn rinv(p: &Program, m: Machine, r: Regs) -> bool {
    &&& m.rok(r)
    &&& ro_ok(p)
    &&& crate::regs::ipok(p, r)
    &&& crate::regs::gate_ok(p, m)
    &&& m.with(r).inv(p)
    &&& room_ok(p, m.with(r))
}

/// The facts every register handler starts from.
pub open spec fn rhandler_pre(p: &Program, m: Machine, r: Regs, bci: usize, opcode: u8) -> bool {
    let ap = p.ap@;
    &&& rinv(p, m, r)
    &&& r.sp@ >= r.fr@ + m.fw + STACK_RESERVE
    &&& step_ok(ap, p.cert@, m.g@)
    &&& bci == r.ip@
    &&& opcode == ap.bytecodes[bci as int]
}

/// A slow path of a register handler, run on the machine: what the
/// machine's code does there, with the word `w` (value `v`) of the
/// instruction where one is needed.
#[derive(Clone, Copy)]
pub enum Slow {
    /// The machine's handler of the instruction (`machine_op`).
    Op,
    /// Failure `k` without a message.
    Raise(usize),
    /// INVALID_PROGRAM with the bci.
    Invalid,
    /// AS_CHECK_FAILED for `w`; the instruction's length.
    As(usize),
    /// LOOKUP_FAILED for the receiver `w` and the selector.
    Lookup(i64),
    /// The call of method `t` returning to bci `ret`: stack growth,
    /// preemption at the callee's entry, finally records.
    Call(usize, usize),
    /// The return with the result `w`: the task's bottom frame, a caller in
    /// a TRY (its finally code), finally records.
    Return,
}

/// What a slow path starts from: the register loop's invariant and the
/// spec's step from the state (the step is the slow path's outcome).
pub open spec fn slow_pre(p: &Program, m: Machine, r: Regs, k: Slow, w: usize, v: Value) -> bool {
    let ap = p.ap@;
    let g = m.g@;
    let a = m.addr();
    &&& rinv(p, m, r)
    &&& match k {
        Slow::Op => machine_op(ap.bytecodes[r.ip@]),
        Slow::Raise(kk) => kk < 5 && sp::step(ap, g) == sp::raise(ap, g, kk as int),
        Slow::Invalid => sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM),
        Slow::As(len) => sp::step(ap, g) == sp::raise(ap, g, sp::AS_CHECK_FAILED)
            && w == enc(a, v) && encodable(a, v) && r.ip@ + len < 0x1000_0000,
        Slow::Lookup(sel) => sp::step(ap, g) == sp::raise(ap, g, sp::LOOKUP_FAILED)
            && w == enc(a, v) && encodable(a, v) && (v is Smi || v is Obj) && -0x8000_0000 <= sel < 0x8000_0000,
        Slow::Call(t, ret) => toit_spec::v2::prim::grows_stack(ap.bytecodes[r.ip@])
            && sp::step(ap, g) == sp::call(ap, g, t as int, ret as int),
        Slow::Return => sp::step(ap, g) == sp::return_from(ap, g, v) && w == enc(a, v) && encodable(a, v),
    }
}

/// Runs a slow path on the machine, out of line (the run loop's one call
/// out of its hot part, for every register handler's Ctl::Slow; with the
/// split loop also `step_cold` for a rare opcode's handler): writes the
/// registers back, runs the machine's code (the raises, calls, returns,
/// unwinding and C++ calls, which handle finally records, stack growth and
/// preemption), and derives the registers again (`resume`). First, calls
/// and returns while finally records exist, on the registers (rfins.rs):
/// most slow paths of finally code, kept out of `slow_body`, whose entry
/// saves many registers.
#[inline(never)]
pub fn slow(m: &mut Machine, r: Regs, env: &Env, k: Slow, w: usize, Ghost(v): Ghost<Value>) -> (res: (Regs, Ctl))
    requires slow_pre(&env.p, *old(m), r, k, w, v),
    ensures rpost(&env.p, *old(m), r, *final(m), res.0, res.1), !(res.1 is Slow),
{
    if m.fw != 0 {
        if let Slow::Call(t, ret) = k {
            let mut r2 = r;
            if crate::rfins::call_fins_r(m, &mut r2, env, t, ret) {
                return (r2, Ctl::Next);
            }
        } else if let Slow::Return = k {
            let mut r2 = r;
            if crate::rfins::ret_fins_fast(m, &mut r2, env, w, Ghost(v)) {
                return (r2, Ctl::Next);
            }
        }
    }
    slow_body(m, r, env, k, w, Ghost(v))
}

/// The machine part of `slow`.
#[inline(never)]
pub fn slow_body(m: &mut Machine, r: Regs, env: &Env, k: Slow, w: usize, Ghost(v): Ghost<Value>) -> (res: (Regs, Ctl))
    requires slow_pre(&env.p, *old(m), r, k, w, v),
    ensures rpost(&env.p, *old(m), r, *final(m), res.0, res.1), !(res.1 is Slow),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(r);
    m.sync(r, p);
    proof {
        assert(*m == w0);
        lemma_small(p, m);
        lemma_unchecked_ok(p, g);
        toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g);
        lemma_source_step(ap, g);
        crate::regs::lemma_bci(p, *m);
    }
    // The unwinding opcodes only pop frames (`unwind::lemma_unwind_prefix`).
    let op = p.code.at(m.bci);
    let unwinding = op == 90 || op == 93 || op == 95 || op == 99;
    // `kept`: on `Next` the frames below the top are the ones before
    // (`room::top_kept`) and the stack length is the same, so the top frame's
    // room is checked only (`top_room_kept`).
    let (c, kept) = match k {
        Slow::Op => (step_machine(m, env), unwinding),
        Slow::Raise(kk) => (m.v_raise_none(env, kk), false),
        Slow::Invalid => (m.v_raise_invalid(env), false),
        Slow::As(len) => (m.v_raise_as(env, w, Ghost(v), len), false),
        Slow::Lookup(sel) => (m.v_raise_lookup(env, w, Ghost(v), sel), false),
        Slow::Call(t, ret) => {
            match ensure_room(m, env) {
                Some(c) => (c, false),
                None => {
                    proof { assert(outcome_ok(ap, p.cert@, sp::step(ap, g))); }
                    let c = m.push_call(env, t, ret);
                    proof {
                        lemma_matches(p, w0, *m, c);
                        if c == Ctl::Next {
                            assert forall|i: int| 0 <= i < m.g@.frames.len() - 1
                                implies #[trigger] m.g@.frames[i] == w0.g@.frames[i] by {}
                        }
                    }
                    (c, true)
                },
            }
        },
        Slow::Return => {
            proof {
                assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
                crate::calls::lemma_shape(p, g);
            }
            let c = m.do_return(env, w, Ghost(v));
            proof {
                lemma_matches(p, w0, *m, c);
                crate::unwind::lemma_return_prefix(ap, g, v);
            }
            (c, true)
        },
    };
    let mut ok = false;
    if kept {
        if let Ctl::Next = c {
            proof {
                if unwinding && k is Op {
                    assert(crate::unwind::frames_prefix(w0.g@, m.g@));
                }
                assert(top_kept(w0.g@, m.g@));
            }
            ok = top_room_kept(m, env, Ghost(w0));
        }
    }
    match resume_with(m, env, c, ok, Ghost(w0)) {
        (Some(r2), Ctl::Next) => (r2, Ctl::Next),
        (_, c2) => (r, c2),
    }
}

/// The slow-path request fields of the machine are not part of anything
/// the slow path's precondition looks at.
pub proof fn lemma_slow_fields(p: &Program, m0: Machine, m1: Machine, r: Regs, k: Slow, w: usize, v: Value)
    requires
        slow_pre(p, m0, r, k, w, v),
        m1 == (Machine { slow_k: m1.slow_k, slow_w: m1.slow_w, ..m0 }),
    ensures slow_pre(p, m1, r, k, w, v),
{
    assert(m1.with(r) == (Machine { slow_k: m1.slow_k, slow_w: m1.slow_w, ..m0.with(r) }));
    assert(m1.with(r).inv(p));
    assert forall|i: int| 0 <= i < m1.with(r).g@.frames.len() implies #[trigger] frame_room(p, m1.with(r), i) by {
        assert(frame_room(p, m0.with(r), i));
    }
    assert(room_ok(p, m1.with(r)));
    assert(rinv(p, m1, r));
}

/// The slow path of an inlined handler: handed to the run loop
/// (`Ctl::Slow`, the request in the machine), which runs `slow` at its one
/// call site.
#[inline(always)]
pub fn slow_r(m: &mut Machine, r: &mut Regs, env: &Env, k: Slow, w: usize, Ghost(v): Ghost<Value>) -> (c: Ctl)
    requires slow_pre(&env.p, *old(m), *old(r), k, w, v),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let ghost m0 = *m;
    m.slow_k = k;
    m.slow_w = w;
    proof {
        lemma_slow_fields(&env.p, m0, *m, *r, k, w, v);
        assert(slow_pre(&env.p, *m, *r, m.slow_k, m.slow_w, v));
    }
    Ctl::Slow
}

/// A slow path without a word.
#[inline(always)]
pub fn slow0(m: &mut Machine, r: &mut Regs, env: &Env, k: Slow) -> (c: Ctl)
    requires slow_pre(&env.p, *old(m), *old(r), k, 0, Value::Smi(0)),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    slow_r(m, r, env, k, 0, Ghost(Value::Smi(0)))
}

/// A register handler's result: on anything but `Next` the registers are
/// written back (the run loop then saves the machine).
#[inline(always)]
fn done(m: &mut Machine, r: &Regs, c: Ctl, p: &Program) -> (c2: Ctl)
    requires c != Ctl::Next ==> old(m).rok(*r) && old(m).with(*r).inv(p) && crate::regs::ipok(p, *r),
    ensures
        c2 == c,
        c == Ctl::Next ==> *final(m) == *old(m),
        c != Ctl::Next ==> *final(m) == old(m).with(*r),
{
    if let Ctl::Next = c {
    } else {
        m.sync(*r, p);
    }
    c
}

/// One step on registers: executes the instruction at the bci
/// (`spec::step`). Every opcode has a register handler; slow paths and the
/// rare opcodes run on the machine out of line (`slow`).
#[inline(always)]
#[verifier::spinoff_prover]
#[verifier::rlimit(200)]
pub fn step_r(m: &mut Machine, r: &mut Regs, env: &Env, ab: &mut crate::room::Abound) -> (c: Ctl)
    requires rinv(&env.p, *old(m), *old(r)), crate::room::abound_ok(&env.p, *old(ab)),
    ensures
        rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
        crate::room::abound_ok(&env.p, *final(ab)),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        lemma_small(p, &w0);
        lemma_unchecked_ok(p, g);
        toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g);
        lemma_instr(ap, p.cert@, p.trusted@, g);
        reveal_with_fuel(opcode_length2, 1);
        lemma_room_top(p, w0);
        toit_spec::v2::sound_instr::lemma_instr_twin(ap, p.cert@, p.trusted@, g);
    }
    let ghost bci: usize = r.ip@ as usize;
    proof { crate::regs::lemma_bci(p, w0); }
    let opcode = r.ip.byte(0, &p.code);
    let c = match opcode {
        0 => {
            let n = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, n as int, 2)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, n, 2)
        },
        2 => {
            let n = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_pop_load_local(g, n as int)) by { reveal(sp::step); } }
            crate::regs::op_pop_load_local(m, r, p, n)
        },
        3 => {
            let n = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_local(g, n as int)) by { reveal(sp::step); } }
            crate::regs::op_store_local(m, r, p, n)
        },
        4 => {
            let n = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_local_pop(g, n as int)) by { reveal(sp::step); } }
            crate::regs::op_store_local_pop(m, r, p, n)
        },
        14 => {
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, 0, 1)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, 0, 1)
        },
        15 => {
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, 1, 1)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, 1, 1)
        },
        16 => {
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, 2, 1)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, 2, 1)
        },
        17 => {
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, 3, 1)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, 3, 1)
        },
        18 => {
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, 4, 1)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, 4, 1)
        },
        19 => {
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, 5, 1)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, 5, 1)
        },
        20 => {
            let i = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_literal(ap, g, i as int, 2)) by { reveal(sp::step); } }
            crate::regs::op_load_literal(m, r, p, i, 2)
        },
        22 => {
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, sp::null2(ap)), 1)) by { reveal(sp::step); } }
            crate::regs::op_load_null(m, r, p, 1)
        },
        23 => {
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(0)), 1)) by { reveal(sp::step); } }
            crate::regs::op_load_smi(m, r, p, 0, 1)
        },
        25 => {
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(1)), 1)) by { reveal(sp::step); } }
            crate::regs::op_load_smi(m, r, p, 1, 1)
        },
        26 => {
            let v = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 2)) by { reveal(sp::step); } }
            crate::regs::op_load_smi(m, r, p, v, 2)
        },
        27 => {
            let v = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 3)) by { reveal(sp::step); } }
            crate::regs::op_load_smi(m, r, p, v, 3)
        },
        29 => {
            let v = ip_u32(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_load_method(ap, g, v as int)) by { reveal(sp::step); }
                assert(toit_spec::spec_common::smi_ok(p1(ap), v as int));
                assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 5));
            }
            crate::regs::op_load_smi(m, r, p, v, 5)
        },
        30 => {
            let i = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_global(g, i as int, 2)) by { reveal(sp::step); } }
            crate::regs::op_load_global(m, r, p, i, 2)
        },
        35 => {
            let i = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_global(g, i as int, 2)) by { reveal(sp::step); } }
            crate::regs::op_store_global(m, r, p, i, 2)
        },
        40 => {
            // -Xpreempt_a_lot (debug VM builds).
            #[cfg(feature = "preempt-a-lot")]
            { if p.preempt_a_lot { env.pre.request(); } }
            let n = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_pop(g, n as int, 2)) by { reveal(sp::step); } }
            crate::regs::op_pop(m, r, p, n, 2)
        },
        41 => {
            // -Xpreempt_a_lot (debug VM builds).
            #[cfg(feature = "preempt-a-lot")]
            { if p.preempt_a_lot { env.pre.request(); } }
            proof { assert(sp::step(ap, g) == sp::op_pop(g, 1, 1)) by { reveal(sp::step); } }
            crate::regs::op_pop(m, r, p, 1, 1)
        },
        81 => {
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 0, bci + d, 3) })) by { reveal(sp::step); }
            }
            crate::regs::op_branch(m, r, p, 0, d as isize, Ghost((bci + d) as usize), 3)
        },
        82 => {
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 1, bci + d, 3) })) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
            }
            crate::regs::op_branch(m, r, p, 1, d as isize, Ghost((bci + d) as usize), 3)
        },
        83 => {
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 2, bci + d, 3) })) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
            }
            crate::regs::op_branch(m, r, p, 2, d as isize, Ghost((bci + d) as usize), 3)
        },
        84 => {
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 3, bci + d, 3) })) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
            }
            crate::regs::op_branch(m, r, p, 3, d as isize, Ghost((bci + d) as usize), 3)
        },
        // BRANCH_BACK*: the preemption points of loops (one arm per opcode).
        85 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 0, bci - d, 3)) by { reveal(sp::step); }
                lemma_back_branch(p, g);
            }
            crate::regs::op_branch(m, r, p, 0, -(d as isize), Ghost((bci - d) as usize), 3)
        },
        // The short branches (format note 22): a one-byte distance.
        114 => {
            let d = r.ip.byte(1, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 0, bci + d, 2) })) by { reveal(sp::step); }
            }
            crate::regs::op_branch(m, r, p, 0, d as isize, Ghost((bci + d) as usize), 2)
        },
        115 => {
            let d = r.ip.byte(1, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 1, bci + d, 2) })) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
            }
            crate::regs::op_branch(m, r, p, 1, d as isize, Ghost((bci + d) as usize), 2)
        },
        116 => {
            let d = r.ip.byte(1, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 2, bci + d, 2) })) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
            }
            crate::regs::op_branch(m, r, p, 2, d as isize, Ghost((bci + d) as usize), 2)
        },
        117 => {
            let d = r.ip.byte(1, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, 3, bci + d, 2) })) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
            }
            crate::regs::op_branch(m, r, p, 3, d as isize, Ghost((bci + d) as usize), 2)
        },
        118 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = r.ip.byte(1, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 0, bci - d, 2)) by { reveal(sp::step); }
                lemma_back_branch_s(p, g);
            }
            crate::regs::op_branch(m, r, p, 0, -(d as isize), Ghost((bci - d) as usize), 2)
        },
        53 => {
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::call_static(ap, g, sp::dispatch_target(ap, d as int), 3)) by {
                    reveal(sp::step);
                }
            }
            return crate::rcalls::op_invoke_static(m, r, env, cur_bci(p, r.ip), opcode, d);
        },
        58 => {
            let n = r.ip.byte(1, &p.code) as usize;
            let sel = ip_u16(p, r.ip, 2);
            proof {
                assert(sp::step(ap, g) == sp::invoke_virtual(ap, g, sel as int, n + 1, 4)) by { reveal(sp::step); }
            }
            return crate::rcalls::op_invoke_virtual(m, r, env, cur_bci(p, r.ip), opcode, sel as i64, n + 1, 4);
        },
        91 => {
            proof {
                assert(sp::step(ap, g) == (if !sp::has_slot(g, 0) { sp::stuck(toit_spec::types::Stuck::StackRange) }
                    else { sp::return_from(ap, g, sp::at(g, 0)) })) by { reveal(sp::step); }
                assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
                w0.lemma_at(p, 0);
            }
            let w = crate::regs::at(m, r, 0);
            return crate::rcalls::op_return(m, r, env, w, Ghost(sp::at(g, 0)));
        },
        92 => {
            proof {
                assert(sp::step(ap, g) == sp::return_from(ap, g, sp::null2(ap))) by { reveal(sp::step); }
                assert(const_ok(g.heap, ap.roots[0]));
            }
            return crate::rcalls::op_return(m, r, env, p.null, Ghost(sp::null2(ap)));
        },
        7 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_field(ap, g, f as int, 2)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field(m, r, env, cur_bci(p, r.ip), opcode, f, 2, false);
        },
        9 => {
            let e = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_field_local(ap, g, e as int, false)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field_local(m, r, env, cur_bci(p, r.ip), opcode, e, false, false);
        },
        10 => {
            let e = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_field_local(ap, g, e as int, true)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field_local(m, r, env, cur_bci(p, r.ip), opcode, e, true, false);
        },
        11 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 2, true)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 2, true, false);
        },
        13 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 2, false)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 2, false, false);
        },
        60 => {
            let sel = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_invoke_virtual_get(ap, g, sel as int)) by { reveal(sp::step); } }
            return crate::rfields::op_invoke_virtual_get(m, r, env, cur_bci(p, r.ip), opcode, sel, false);
        },
        61 => {
            let sel = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_invoke_virtual_set(ap, g, sel as int)) by { reveal(sp::step); } }
            return crate::rfields::op_invoke_virtual_set(m, r, env, cur_bci(p, r.ip), opcode, sel, false);
        },
        94 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_field_this(ap, g, f as int)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field_this(m, r, env, cur_bci(p, r.ip), opcode, f, false);
        },
        // The unchecked twins of the field accesses (format note 20; trusted
        // programs only): the handlers above without the field check.
        104 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_field(ap, g, f as int, 2)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field(m, r, env, cur_bci(p, r.ip), opcode, f, 2, true);
        },
        106 => {
            let e = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_field_local(ap, g, e as int, false)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field_local(m, r, env, cur_bci(p, r.ip), opcode, e, false, true);
        },
        107 => {
            let e = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_field_local(ap, g, e as int, true)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field_local(m, r, env, cur_bci(p, r.ip), opcode, e, true, true);
        },
        108 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 2, true)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 2, true, true);
        },
        110 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 2, false)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 2, false, true);
        },
        111 => {
            let sel = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_invoke_virtual_get(ap, g, sel as int)) by { reveal(sp::step); } }
            return crate::rfields::op_invoke_virtual_get(m, r, env, cur_bci(p, r.ip), opcode, sel, true);
        },
        112 => {
            let sel = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_invoke_virtual_set(ap, g, sel as int)) by { reveal(sp::step); } }
            return crate::rfields::op_invoke_virtual_set(m, r, env, cur_bci(p, r.ip), opcode, sel, true);
        },
        113 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_field_this(ap, g, f as int)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field_this(m, r, env, cur_bci(p, r.ip), opcode, f, true);
        },
        98 => {
            let f = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_field_this(ap, g, f as int)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field_this(m, r, env, cur_bci(p, r.ip), opcode, f);
        },
        44 => {
            // IS_CLASS.
            let enc = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_is(ap, g, enc as int, false, 2)) by { reveal(sp::step); } }
            return crate::rfields::op_is(m, r, env, cur_bci(p, r.ip), opcode, enc, false, 2);
        },
        48 => {
            // AS_CLASS.
            let enc = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_as(ap, g, enc as int, false, 2)) by { reveal(sp::step); } }
            return crate::rfields::op_as(m, r, env, cur_bci(p, r.ip), opcode, enc, false, 2);
        },
        50 => {
            // AS_INTERFACE.
            let enc = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_as(ap, g, enc as int, true, 2)) by { reveal(sp::step); } }
            return crate::rfields::op_as(m, r, env, cur_bci(p, r.ip), opcode, enc, true, 2);
        },
        52 => {
            // AS_LOCAL.
            let enc = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_as_local(ap, g, enc as int)) by { reveal(sp::step); } }
            return crate::rfields::op_as_local(m, r, env, cur_bci(p, r.ip), opcode, enc);
        },
        // Operators: constant opcodes, so that the inlined fast paths fold.
        62 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_eq(m, r, env, cur_bci(p, r.ip), 62);
        },
        63 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_relational(m, r, env, cur_bci(p, r.ip), 63);
        },
        64 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_relational(m, r, env, cur_bci(p, r.ip), 64);
        },
        65 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_relational(m, r, env, cur_bci(p, r.ip), 65);
        },
        66 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_relational(m, r, env, cur_bci(p, r.ip), 66);
        },
        67 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 67);
        },
        69 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 69);
        },
        71 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 71);
        },
        73 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 73);
        },
        74 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 74);
        },
        75 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 75);
        },
        5 => {
            let k = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_outer(g, k as int)) by { reveal(sp::step); } }
            crate::rblocks::op_load_outer(m, r, p, k)
        },
        6 => {
            let k = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_outer(g, k as int)) by { reveal(sp::step); } }
            crate::rblocks::op_store_outer(m, r, p, k)
        },
        38 => {
            let k = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_block(g, k as int)) by { reveal(sp::step); } }
            crate::rblocks::op_load_block(m, r, p, k)
        },
        55 => {
            let k = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_invoke_block(ap, g, k as int)) by { reveal(sp::step); } }
            return crate::rblocks::op_invoke_block(m, r, env, cur_bci(p, r.ip), opcode, k);
        },
        32 => {
            let i = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_global_lazy(ap, g, i as int, 2)) by { reveal(sp::step); } }
            return crate::rblocks::op_load_global_lazy(m, r, env, cur_bci(p, r.ip), opcode, i, 2);
        },
        78 => {
            return crate::rarrays::op_invoke_at(m, r, env, cur_bci(p, r.ip), 78);
        },
        79 => {
            return crate::rarrays::op_invoke_at_put(m, r, env, cur_bci(p, r.ip), 79);
        },
        80 => {
            let sel = ip_u16(p, r.ip, 1);
            return crate::rarrays::op_invoke_size(m, r, env, cur_bci(p, r.ip), 80, sel);
        },
        42 => {
            let c = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_allocate(ap, g, c as int, 2)) by { reveal(sp::step); } }
            return crate::rarrays::op_allocate(m, r, env, cur_bci(p, r.ip), 42, c, 2);
        },
        93 => {
            proof { assert(sp::step(ap, g) == sp::op_non_local_return(ap, g)) by { reveal(sp::step); } }
            let (r2, c2) = crate::rnonlocal::op_non_local_return_v(m, *r, env, cur_bci(p, r.ip), opcode);
            crate::regs::set_regs(r, r2);
            return c2;
        },
        101 => {
            let d = ip_u16(p, r.ip, 1);
            let n = r.ip.byte(3, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == sp::op_loop_repeat(ap, g, bci - d, n as int, 4)) by { reveal(sp::step); }
                lemma_loop_cond(p, g);
            }
            crate::rloops::op_loop_repeat(m, r, p, n, d, Ghost((bci - d) as usize))
        },
        // LOOP_ARRAY (proposal, format note 19).
        102 => {
            let d = ip_u16(p, r.ip, 1);
            let n = r.ip.byte(3, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == sp::op_loop_array(ap, g, bci - d, n as int, 4)) by { reveal(sp::step); }
                lemma_loop_cond(p, g);
                crate::arrays::lemma_heap_good(p, g);
            }
            crate::rloops::op_loop_array(m, r, p, n, d, Ghost((bci - d) as usize))
        },
        // HASH_FIND (proposal, format note 19).
        103 => {
            let d = ip_u16(p, r.ip, 1);
            let n = r.ip.byte(3, &p.code) as usize;
            let mm = r.ip.byte(4, &p.code) as usize;
            proof {
                assert(sp::step(ap, g) == sp::op_hash_find(ap, g, bci + d, n as int, mm as int, 5)) by { reveal(sp::step); }
                lemma_hash_find_cond(p, g);
                crate::arrays::lemma_heap_good(p, g);
            }
            let (r2, c2) = crate::rhash::op_hash_find_v(m, *r, p, n, mm, d, Ghost((bci + d) as usize));
            crate::regs::set_regs(r, r2);
            c2
        },
        #[cfg(not(feature = "split-loop"))]
        1 => {
            let n = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, n as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, n, 3)
        },
        #[cfg(not(feature = "split-loop"))]
        21 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_literal(ap, g, i as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_load_literal(m, r, p, i, 3)
        },
        #[cfg(not(feature = "split-loop"))]
        24 => {
            let n = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_smis_0(g, n as int)) by { reveal(sp::step); } }
            crate::regs::op_load_smis_0(m, r, p, n)
        },
        28 => {
            let v = ip_u32(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_load_smi(ap, g, v as int, 5)) by { reveal(sp::step); }
                assert(toit_spec::spec_common::smi_ok(p1(ap), v as int));
                assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 5));
            }
            crate::regs::op_load_smi(m, r, p, v, 5)
        },
        #[cfg(not(feature = "split-loop"))]
        31 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_global(g, i as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_load_global(m, r, p, i, 3)
        },
        #[cfg(not(feature = "split-loop"))]
        36 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_store_global(g, i as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_store_global(m, r, p, i, 3)
        },
        #[cfg(not(feature = "split-loop"))]
        86 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 1, bci - d, 3)) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
                lemma_back_branch(p, g);
            }
            crate::regs::op_branch(m, r, p, 1, -(d as isize), Ghost((bci - d) as usize), 3)
        },
        #[cfg(not(feature = "split-loop"))]
        87 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 2, bci - d, 3)) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
                lemma_back_branch(p, g);
            }
            crate::regs::op_branch(m, r, p, 2, -(d as isize), Ghost((bci - d) as usize), 3)
        },
        #[cfg(not(feature = "split-loop"))]
        88 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 3, bci - d, 3)) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
                lemma_back_branch(p, g);
            }
            crate::regs::op_branch(m, r, p, 3, -(d as isize), Ghost((bci - d) as usize), 3)
        },
        #[cfg(not(feature = "split-loop"))]
        59 => {
            let n = ip_u16(p, r.ip, 1);
            let sel = ip_u16(p, r.ip, 3);
            proof {
                assert(sp::step(ap, g) == sp::invoke_virtual(ap, g, sel as int, n + 1, 5)) by { reveal(sp::step); }
            }
            return crate::rcalls::op_invoke_virtual(m, r, env, cur_bci(p, r.ip), opcode, sel as i64, n + 1, 5);
        },
        #[cfg(not(feature = "split-loop"))]
        8 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_field(ap, g, f as int, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, false);
        },
        #[cfg(not(feature = "split-loop"))]
        12 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 3, true)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, true, false);
        },
        #[cfg(not(feature = "split-loop"))]
        105 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_field(ap, g, f as int, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, true);
        },
        #[cfg(not(feature = "split-loop"))]
        109 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 3, true)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, true, true);
        },
        #[cfg(not(feature = "split-loop"))]
        45 => {
            // IS_CLASS_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_is(ap, g, enc as int, false, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_is(m, r, env, cur_bci(p, r.ip), opcode, enc, false, 3);
        },
        #[cfg(not(feature = "split-loop"))]
        46 => {
            // IS_INTERFACE.
            let enc = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_is(ap, g, enc as int, true, 2)) by { reveal(sp::step); } }
            return crate::rfields::op_is(m, r, env, cur_bci(p, r.ip), opcode, enc, true, 2);
        },
        #[cfg(not(feature = "split-loop"))]
        47 => {
            // IS_INTERFACE_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_is(ap, g, enc as int, true, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_is(m, r, env, cur_bci(p, r.ip), opcode, enc, true, 3);
        },
        #[cfg(not(feature = "split-loop"))]
        49 => {
            // AS_CLASS_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_as(ap, g, enc as int, false, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_as(m, r, env, cur_bci(p, r.ip), opcode, enc, false, 3);
        },
        #[cfg(not(feature = "split-loop"))]
        51 => {
            // AS_INTERFACE_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_as(ap, g, enc as int, true, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_as(m, r, env, cur_bci(p, r.ip), opcode, enc, true, 3);
        },
        68 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 68);
        },
        70 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 70);
        },
        #[cfg(not(feature = "split-loop"))]
        72 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 72);
        },
        76 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 76);
        },
        77 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 77);
        },
        96 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_identical(m, r, env, cur_bci(p, r.ip), 96);
        },
        #[cfg(not(feature = "split-loop"))]
        39 => {
            let k = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_outer_block(g, k as int)) by { reveal(sp::step); } }
            crate::rblocks::op_load_outer_block(m, r, p, k)
        },
        54 => {
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_invoke_static_tail(ap, g, d as int)) by { reveal(sp::step); }
            }
            return crate::rblocks::op_invoke_static_tail(m, r, env, cur_bci(p, r.ip), opcode, d);
        },
        #[cfg(not(feature = "split-loop"))]
        57 => {
            proof { assert(sp::step(ap, g) == sp::op_invoke_initializer_tail(ap, g)) by { reveal(sp::step); } }
            return crate::rblocks::op_invoke_initializer_tail(m, r, env, cur_bci(p, r.ip), opcode);
        },
        #[cfg(not(feature = "split-loop"))]
        33 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_global_lazy(ap, g, i as int, 3)) by { reveal(sp::step); } }
            return crate::rblocks::op_load_global_lazy(m, r, env, cur_bci(p, r.ip), opcode, i, 3);
        },
        #[cfg(not(feature = "split-loop"))]
        34 => {
            proof { assert(sp::step(ap, g) == sp::op_load_global_dynamic(ap, g)) by { reveal(sp::step); } }
            return crate::rblocks::op_load_global_dynamic(m, r, env, cur_bci(p, r.ip), opcode);
        },
        #[cfg(not(feature = "split-loop"))]
        37 => {
            proof { assert(sp::step(ap, g) == sp::op_store_global_dynamic(ap, g)) by { reveal(sp::step); } }
            return crate::rblocks::op_store_global_dynamic(m, r, env, cur_bci(p, r.ip), opcode);
        },
        #[cfg(not(feature = "split-loop"))]
        43 => {
            let c = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_allocate(ap, g, c as int, 3)) by { reveal(sp::step); } }
            return crate::rarrays::op_allocate(m, r, env, cur_bci(p, r.ip), 43, c, 3);
        },
        89 => {
            return crate::rarrays::op_primitive(m, r, env, cur_bci(p, r.ip), 89, ab);
        },
        // Non-local control flow (rnonlocal.rs): fast paths without
        // handlers on the way and without finally records.
        #[cfg(not(feature = "split-loop"))]
        95 => {
            let hd = r.ip.byte(1, &p.code) as usize;
            let off = ip_u32(p, r.ip, 2);
            proof {
                assert(sp::step(ap, g) == sp::op_non_local_branch(ap, g, hd as int, off as int)) by { reveal(sp::step); }
            }
            let (r2, c2) = crate::rnonlocal::op_non_local_branch_v(m, *r, env, cur_bci(p, r.ip), opcode, hd, off);
            crate::regs::set_regs(r, r2);
            return c2;
        },
        97 => {
            proof { assert(sp::step(ap, g) == sp::op_try(ap, g)) by { reveal(sp::step); } }
            let (r2, c2) = crate::rnonlocal::op_try_v(m, *r, env, cur_bci(p, r.ip), opcode);
            crate::regs::set_regs(r, r2);
            return c2;
        },
        99 => {
            proof { assert(sp::step(ap, g) == sp::op_unwind(ap, g)) by { reveal(sp::step); } }
            return crate::rnonlocal::op_unwind(m, r, env, cur_bci(p, r.ip), opcode);
        },
        // Rare opcodes: the machine's handlers (`Slow::Op`). INVOKE_LAMBDA_TAIL,
        // THROW, HALT.
        #[cfg(not(feature = "split-loop"))]
        56 => { return slow0(m, r, env, Slow::Op); },
        #[cfg(not(feature = "split-loop"))]
        90 => { return slow0(m, r, env, Slow::Op); },
        #[cfg(not(feature = "split-loop"))]
        100 => { return slow0(m, r, env, Slow::Op); },
        // With the split loop (feature `split-loop`): the rare opcodes
        // (`cold_op`) out of line (`step_cold`), so that the loop's hot part
        // (IRAM on the classic ESP32) stays small. The registers go through
        // memory (the call), the request does not.
        #[cfg(feature = "split-loop")]
        1 | 8 | 12 | 21 | 24 | 31 | 33 | 34 | 36 | 37 | 39 | 43 | 45 | 46 | 47 | 49 | 51 | 56 | 57 | 59 | 72 | 86 | 87 | 88 | 90 | 95 | 100 | 105 | 109 => {
            proof { assert(cold_op(opcode)); }
            let (r2, c2) = step_cold(m, *r, env);
            crate::regs::set_regs(r, r2);
            return c2;
        },
        _ => {
            // Every opcode of format 2 (below OPCODE_COUNT2, which the
            // instruction check of the spec requires) has an arm.
            proof { assert(opcode < 119); assert(false); }
            return crate::view::proven_unreachable();
        },
    };
    proof {
        lemma_local_post(p, w0, m.with(*r), c);
        if c == Ctl::Next { lemma_room_same(p, w0, m.with(*r)); }
    }
    done(m, r, c, p)
}

/// The opcodes whose handlers are out of line (`step_cold`) in the split
/// loop (feature `split-loop`): the opcodes without a single execution in
/// the device benchmarks (hwbench, perfbench; dynamic counts of a trusted
/// format-2 build, split-option/logs/opcounts.txt) apart from a few
/// hundred (STORE_GLOBAL_VAR_DYNAMIC, INVOKE_INITIALIZER_TAIL,
/// NON_LOCAL_BRANCH): the _WIDE variants, dynamic and lazy wide globals,
/// IS/AS of interfaces and wide classes, the backward conditional
/// branches, USHR, INVOKE_LAMBDA_TAIL, THROW, HALT.
#[cfg(feature = "split-loop")]
pub open spec fn cold_op(op: u8) -> bool {
    op == 1 || op == 8 || op == 12 || op == 21 || op == 24 || op == 31 || op == 33 || op == 34 || op == 36 || op == 37 || op == 39 || op == 43 || op == 45 || op == 46 || op == 47 || op == 49 || op == 51 || op == 56 || op == 57 || op == 59 || op == 72 || op == 86 || op == 87 || op == 88 || op == 90 || op == 95 || op == 100 || op == 105 || op == 109
}

/// `step_c` out of line: the cold part of the split loop, with the slow
/// path a handler hands on (so that the loop's call site needs no request
/// in the machine).
#[cfg(feature = "split-loop")]
#[inline(never)]
pub fn step_cold(m: &mut Machine, r0: Regs, env: &Env) -> (res: (Regs, Ctl))
    requires rinv(&env.p, *old(m), r0), cold_op(env.p.ap@.bytecodes[r0.ip@]),
    ensures rpost(&env.p, *old(m), r0, *final(m), res.0, res.1), !(res.1 is Slow),
{
    let ghost m0 = *m;
    let mut r = r0;
    let c = step_c(m, &mut r, env);
    if let Ctl::Slow = c {
        let k = m.slow_k;
        let w = m.slow_w;
        let ghost v = choose|v: Value| slow_pre(&env.p, *m, r, k, w, v);
        let ghost m1 = *m;
        let (r2, c2) = slow(m, r, env, k, w, Ghost(v));
        proof {
            assert(m1.with(r).g@ == m0.with(r0).g@);
        }
        (r2, c2)
    } else {
        (r, c)
    }
}

/// One step on registers for a rare opcode (`cold_op`): the arms `step_r`
/// leaves out in the split loop, which `step_cold` runs out of line.
#[cfg(feature = "split-loop")]
#[inline(always)]
#[verifier::spinoff_prover]
#[verifier::rlimit(200)]
pub fn step_c(m: &mut Machine, r: &mut Regs, env: &Env) -> (c: Ctl)
    requires rinv(&env.p, *old(m), *old(r)),
        cold_op(env.p.ap@.bytecodes[old(r).ip@]),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        lemma_small(p, &w0);
        lemma_unchecked_ok(p, g);
        toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g);
        lemma_instr(ap, p.cert@, p.trusted@, g);
        reveal_with_fuel(opcode_length2, 1);
        lemma_room_top(p, w0);
        toit_spec::v2::sound_instr::lemma_instr_twin(ap, p.cert@, p.trusted@, g);
    }
    let ghost bci: usize = r.ip@ as usize;
    proof { crate::regs::lemma_bci(p, w0); }
    let opcode = r.ip.byte(0, &p.code);
    let c = match opcode {
        1 => {
            let n = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, n as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_load_local(m, r, p, n, 3)
        },
        21 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_literal(ap, g, i as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_load_literal(m, r, p, i, 3)
        },
        24 => {
            let n = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_smis_0(g, n as int)) by { reveal(sp::step); } }
            crate::regs::op_load_smis_0(m, r, p, n)
        },
        31 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_global(g, i as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_load_global(m, r, p, i, 3)
        },
        36 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_store_global(g, i as int, 3)) by { reveal(sp::step); } }
            crate::regs::op_store_global(m, r, p, i, 3)
        },
        86 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 1, bci - d, 3)) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
                lemma_back_branch(p, g);
            }
            crate::regs::op_branch(m, r, p, 1, -(d as isize), Ghost((bci - d) as usize), 3)
        },
        87 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 2, bci - d, 3)) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
                lemma_back_branch(p, g);
            }
            crate::regs::op_branch(m, r, p, 2, -(d as isize), Ghost((bci - d) as usize), 3)
        },
        88 => {
            if env.pre.requested() {
                env.pre.clear();
                m.sync(*r, &env.p);
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = ip_u16(p, r.ip, 1);
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, 3, bci - d, 3)) by { reveal(sp::step); }
                lemma_branch_cond(p, g);
                lemma_back_branch(p, g);
            }
            crate::regs::op_branch(m, r, p, 3, -(d as isize), Ghost((bci - d) as usize), 3)
        },
        59 => {
            let n = ip_u16(p, r.ip, 1);
            let sel = ip_u16(p, r.ip, 3);
            proof {
                assert(sp::step(ap, g) == sp::invoke_virtual(ap, g, sel as int, n + 1, 5)) by { reveal(sp::step); }
            }
            return crate::rcalls::op_invoke_virtual(m, r, env, cur_bci(p, r.ip), opcode, sel as i64, n + 1, 5);
        },
        8 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_field(ap, g, f as int, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, false);
        },
        12 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 3, true)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, true, false);
        },
        105 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_field(ap, g, f as int, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_load_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, true);
        },
        109 => {
            let f = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_store_field(ap, g, f as int, 3, true)) by { reveal(sp::step); } }
            return crate::rfields::op_store_field(m, r, env, cur_bci(p, r.ip), opcode, f, 3, true, true);
        },
        45 => {
            // IS_CLASS_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_is(ap, g, enc as int, false, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_is(m, r, env, cur_bci(p, r.ip), opcode, enc, false, 3);
        },
        46 => {
            // IS_INTERFACE.
            let enc = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_is(ap, g, enc as int, true, 2)) by { reveal(sp::step); } }
            return crate::rfields::op_is(m, r, env, cur_bci(p, r.ip), opcode, enc, true, 2);
        },
        47 => {
            // IS_INTERFACE_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_is(ap, g, enc as int, true, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_is(m, r, env, cur_bci(p, r.ip), opcode, enc, true, 3);
        },
        49 => {
            // AS_CLASS_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_as(ap, g, enc as int, false, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_as(m, r, env, cur_bci(p, r.ip), opcode, enc, false, 3);
        },
        51 => {
            // AS_INTERFACE_WIDE.
            let enc = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_as(ap, g, enc as int, true, 3)) by { reveal(sp::step); } }
            return crate::rfields::op_as(m, r, env, cur_bci(p, r.ip), opcode, enc, true, 3);
        },
        72 => {
            proof { crate::ops::lemma_step_op(p, g); }
            return crate::rops::op_invoke_arith(m, r, env, cur_bci(p, r.ip), 72);
        },
        39 => {
            let k = r.ip.byte(1, &p.code) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_outer_block(g, k as int)) by { reveal(sp::step); } }
            crate::rblocks::op_load_outer_block(m, r, p, k)
        },
        57 => {
            proof { assert(sp::step(ap, g) == sp::op_invoke_initializer_tail(ap, g)) by { reveal(sp::step); } }
            return crate::rblocks::op_invoke_initializer_tail(m, r, env, cur_bci(p, r.ip), opcode);
        },
        33 => {
            let i = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_load_global_lazy(ap, g, i as int, 3)) by { reveal(sp::step); } }
            return crate::rblocks::op_load_global_lazy(m, r, env, cur_bci(p, r.ip), opcode, i, 3);
        },
        34 => {
            proof { assert(sp::step(ap, g) == sp::op_load_global_dynamic(ap, g)) by { reveal(sp::step); } }
            return crate::rblocks::op_load_global_dynamic(m, r, env, cur_bci(p, r.ip), opcode);
        },
        37 => {
            proof { assert(sp::step(ap, g) == sp::op_store_global_dynamic(ap, g)) by { reveal(sp::step); } }
            return crate::rblocks::op_store_global_dynamic(m, r, env, cur_bci(p, r.ip), opcode);
        },
        43 => {
            let c = ip_u16(p, r.ip, 1);
            proof { assert(sp::step(ap, g) == sp::op_allocate(ap, g, c as int, 3)) by { reveal(sp::step); } }
            return crate::rarrays::op_allocate(m, r, env, cur_bci(p, r.ip), 43, c, 3);
        },
        // Non-local control flow (rnonlocal.rs): fast paths without
        // handlers on the way and without finally records.
        95 => {
            let hd = r.ip.byte(1, &p.code) as usize;
            let off = ip_u32(p, r.ip, 2);
            proof {
                assert(sp::step(ap, g) == sp::op_non_local_branch(ap, g, hd as int, off as int)) by { reveal(sp::step); }
            }
            let (r2, c2) = crate::rnonlocal::op_non_local_branch_v(m, *r, env, cur_bci(p, r.ip), opcode, hd, off);
            crate::regs::set_regs(r, r2);
            return c2;
        },
        // Rare opcodes: the machine's handlers (`Slow::Op`). INVOKE_LAMBDA_TAIL,
        // THROW, HALT.
        56 => { return slow0(m, r, env, Slow::Op); },
        90 => { return slow0(m, r, env, Slow::Op); },
        100 => { return slow0(m, r, env, Slow::Op); },
        _ => {
            // `cold_op` lists exactly the arms above.
            proof { assert(false); }
            return crate::view::proven_unreachable();
        },
    };
    proof {
        lemma_local_post(p, w0, m.with(*r), c);
        if c == Ctl::Next { lemma_room_same(p, w0, m.with(*r)); }
    }
    done(m, r, c, p)
}

// ---------------------------------------------------------------------------
// The run loop.

/// How a run ended besides its result (ghost: `run_loop`'s third result):
/// at an exit of one of its steps (`Ctl::Exit`: preempted, yielded, or the
/// process ends: exit, uncaught exception, task end, deep sleep, reset),
/// or with a stuck report of the given reason (`V2_REPORT_STUCK`, the one
/// call of `leave_stuck`; the run then returns `(RESULT_TERMINATED, 1)`).
pub enum RunEnd {
    Exit,
    Stuck(usize),
}

/// The stuck reports a run may make: the resource limit (`stuck::LIMIT`,
/// the defined out-of-memory stop: room on the object stack, a smi or
/// table encoding limit; the only stuck result `step_post` allows), and
/// the fatal path for a program heap whose address range wraps around the
/// address space (`!ro_ok`, checked before the first instruction; the C++
/// loader never makes one). Never a stuck state of the spec.
pub open spec fn stop_ok(p: &Program, reason: usize) -> bool {
    reason == stuck::LIMIT || (reason == stuck::FATAL && !ro_ok(p))
}

/// The states part of `run_post`: if the process continues later
/// (preempted or yielded), the saved machine refines a well-formed state
/// the spec reaches from the state it started in (what the theorems
/// between runs use: `theorem::theorem_next_run`, `process::scheduled`).
pub open spec fn run_states(p: &Program, m0: Machine, m1: Machine, r: (usize, i64)) -> bool {
    &&& (r.0 == RESULT_PREEMPTED || r.0 == RESULT_YIELDED) ==> m1.inv(p) && reaches(p.ap@, m0.g@, m1.g@)
}

/// What a run guarantees when it returns, with how it ended (`e`): if the
/// process continues later (preempted or yielded), the saved machine
/// refines a well-formed state the spec reaches from the state it started
/// in (`run_states`); any other result ends the process (exit, uncaught
/// exception, task end, deep sleep, reset, or out of memory). A run stops
/// on a stuck report only for the resource limit or the wrapping program
/// heap (`stop_ok`): a stuck state of the spec is never reported.
pub open spec fn run_post(p: &Program, m0: Machine, m1: Machine, r: (usize, i64), e: RunEnd) -> bool {
    &&& run_states(p, m0, m1, r)
    &&& e is Stuck ==> r == (RESULT_TERMINATED, 1i64) && stop_ok(p, e->Stuck_0)
}

/// `g1` is reachable from `g0` by spec transitions (the reflexive and
/// transitive closure of `advances`).
pub open spec fn reaches(ap: Program2, g0: State2, g1: State2) -> bool {
    exists|tr: Seq<State2>| #[trigger] chain(ap, tr) && tr.len() >= 1 && tr[0] == g0 && tr.last() == g1
}

pub open spec fn chain(ap: Program2, tr: Seq<State2>) -> bool {
    forall|i: int| 0 <= i < tr.len() - 1 ==> #[trigger] advances(ap, tr[i], tr[i + 1])
}

proof fn lemma_reaches_refl(ap: Program2, g: State2)
    ensures reaches(ap, g, g),
{
    let tr = seq![g];
    assert(chain(ap, tr));
    assert(tr.last() == g);
}

proof fn lemma_reaches_step(ap: Program2, g0: State2, g1: State2, g2: State2)
    requires reaches(ap, g0, g1), advances(ap, g1, g2),
    ensures reaches(ap, g0, g2),
{
    let tr = choose|tr: Seq<State2>| #[trigger] chain(ap, tr) && tr.len() >= 1 && tr[0] == g0 && tr.last() == g1;
    let tr2 = tr.push(g2);
    assert forall|i: int| 0 <= i < tr2.len() - 1 implies #[trigger] advances(ap, tr2[i], tr2[i + 1]) by {
        if i < tr.len() - 1 {
            assert(tr2[i] == tr[i] && tr2[i + 1] == tr[i + 1]);
        } else {
            assert(tr2[i] == g1 && tr2[i + 1] == g2);
        }
    }
    assert(chain(ap, tr2));
    assert(tr2.last() == g2);
}

proof fn lemma_reaches_trans(ap: Program2, g0: State2, g1: State2, g2: State2)
    requires reaches(ap, g0, g1), reaches(ap, g1, g2),
    ensures reaches(ap, g0, g2),
{
    let t1 = choose|tr: Seq<State2>| #[trigger] chain(ap, tr) && tr.len() >= 1 && tr[0] == g0 && tr.last() == g1;
    let t2 = choose|tr: Seq<State2>| #[trigger] chain(ap, tr) && tr.len() >= 1 && tr[0] == g1 && tr.last() == g2;
    let tr = t1 + t2.subrange(1, t2.len() as int);
    assert forall|i: int| 0 <= i < tr.len() - 1 implies #[trigger] advances(ap, tr[i], tr[i + 1]) by {
        if i < t1.len() - 1 {
            assert(tr[i] == t1[i] && tr[i + 1] == t1[i + 1]);
        } else if i == t1.len() - 1 {
            assert(tr[i] == t1.last() && tr[i] == t2[0] && tr[i + 1] == t2[1]);
        } else {
            let k = i - t1.len() + 1;
            assert(tr[i] == t2[k] && tr[i + 1] == t2[k + 1]);
        }
    }
    assert(chain(ap, tr));
    if t2.len() == 1 {
        assert(tr =~= t1);
    } else {
        assert(tr.last() == t2.last());
    }
}

/// After a step on registers that continues (`Next`, preempted, yielded),
/// the state is reached from the run's start.
proof fn lemma_rstep_reaches(p: &Program, g0: State2, m0: Machine, m1: Machine, c: Ctl)
    requires
        reaches(p.ap@, g0, m0.g@),
        step_post(p, m0, m1, c) || steps_post(p, m0, m1, c),
        c is Next || (c is Exit && (c->Exit_0 == RESULT_PREEMPTED || c->Exit_0 == RESULT_YIELDED)),
    ensures m1.inv(p), reaches(p.ap@, g0, m1.g@),
{
    if step_post(p, m0, m1, c) {
        lemma_reaches_step(p.ap@, g0, m0.g@, m1.g@);
    } else {
        lemma_reaches_trans(p.ap@, g0, m0.g@, m1.g@);
    }
}

/// Runs the current task until it is preempted, yields or ends. A program
/// may loop forever (the scheduler preempts it), so no termination is
/// claimed.
#[verifier::exec_allows_no_decreases_clause]
#[cfg_attr(target_arch = "xtensa", optimize(speed))]
pub fn run_loop(m: &mut Machine, env: &Env, accepted: &crate::ffi::Accepted) -> (r: (usize, i64, Ghost<RunEnd>))
    requires old(m).inv(&env.p),
    ensures run_post(&env.p, *old(m), *final(m), (r.0, r.1), r.2@),
{
    let ghost m0 = *m;
    proof { lemma_reaches_refl(env.p.ap@, m.g@); }
    // The program heap's range (a C++ allocation) does not wrap around
    // (`ro_ok`); checked once per run.
    if env.p.ro_start > usize::MAX - env.p.ro_size {
        return leave_stuck(m, env, stuck::FATAL, Ghost(m0));
    }
    // The room of every frame (room.rs), checked once per run, and the
    // registers: locals of this function, in machine registers.
    let mut r = match resume(m, env, Ctl::Next, Ghost(m0)) {
        (Some(r), Ctl::Next) => r,
        (_, Ctl::Exit(state, value)) => {
            m.save();
            proof {
                if state == RESULT_PREEMPTED || state == RESULT_YIELDED {
                    lemma_rstep_reaches(&env.p, m0.g@, m0, *m, Ctl::Exit(state, value));
                }
            }
            return (state as usize, value, Ghost(RunEnd::Exit));
        },
        // A stuck result of `resume` is the limit (`steps_post`).
        (_, _) => { return leave_stuck(m, env, stuck::LIMIT, Ghost(m0)); },
    };

    // A bound on the methods' arities, computed when this run switches
    // tasks often (`room::room_after_switch`).
    let mut ab = crate::room::Abound { bound: crate::room::ABOUND_NONE, scans: 0 };
    loop
        invariant
            rinv(&env.p, *m, r),
            m0 == *old(m),
            reaches(env.p.ap@, m0.g@, m.g@),
            crate::room::abound_ok(&env.p, ab),
    {
        let ghost before = m.with(r);
        let ctl = step_r(m, &mut r, env, &mut ab);
        match ctl {
            Ctl::Next => {
                proof { lemma_rstep_reaches(&env.p, m0.g@, before, m.with(r), ctl); }
            },
            Ctl::Slow => {
                // A handler's slow path: one call site for all of them.
                let k = m.slow_k;
                let w = m.slow_w;
                let ghost v = choose|v: Value| slow_pre(&env.p, *m, r, k, w, v);
                let (r2, c2) = slow(m, r, env, k, w, Ghost(v));
                r = r2;
                match c2 {
                    Ctl::Next => {
                        proof { lemma_rstep_reaches(&env.p, m0.g@, before, m.with(r), c2); }
                    },
                    Ctl::Exit(state, value) => { return leave_exit(m, state, value, Ghost(m0), Ghost(before), Ghost(&env.p)); },
                    Ctl::Stuck(reason) => { return leave_stuck(m, env, reason, Ghost(m0)); },
                    Ctl::Slow => {
                        proof { assert(false); }
                        return crate::view::proven_unreachable();
                    },
                }
            },
            // The fields, not the result: passing the result on would keep
            // it in memory, where every handler would then store it.
            Ctl::Exit(state, value) => { return leave_exit(m, state, value, Ghost(m0), Ghost(before), Ghost(&env.p)); },
            Ctl::Stuck(reason) => { return leave_stuck(m, env, reason, Ghost(m0)); },
        }
    }
}

/// Leaves the run loop after a step that exits: the machine is saved.
#[inline(never)]
fn leave_exit(m: &mut Machine, state: u32, value: i64, Ghost(m0): Ghost<Machine>, Ghost(before): Ghost<Machine>,
              Ghost(p): Ghost<&Program>) -> (r: (usize, i64, Ghost<RunEnd>))
    requires
        step_post(p, before, *old(m), Ctl::Exit(state, value)) || steps_post(p, before, *old(m), Ctl::Exit(state, value)),
        reaches(p.ap@, m0.g@, before.g@),
    ensures run_post(p, m0, *final(m), (r.0, r.1), r.2@),
{
    proof {
        if state == RESULT_PREEMPTED || state == RESULT_YIELDED {
            lemma_rstep_reaches(p, m0.g@, before, *m, Ctl::Exit(state, value));
        }
    }
    m.save();
    proof {
        if state == RESULT_PREEMPTED || state == RESULT_YIELDED {
            assert(m.refines(p));
            assert(m.inv(p));
            assert(reaches(p.ap@, m0.g@, m.g@));
        }
        assert(run_post(p, m0, *m, (state as usize, value), RunEnd::Exit));
    }
    (state as usize, value, Ghost(RunEnd::Exit))
}

/// Leaves the run loop with a stuck report (`V2_REPORT_STUCK` with
/// `reason`, the only one a run makes): after a step that is out of room
/// (the limit), or before the first instruction for a program heap whose
/// range wraps. The machine is saved.
#[inline(never)]
fn leave_stuck(m: &mut Machine, env: &Env, reason: usize, Ghost(m0): Ghost<Machine>) -> (r: (usize, i64, Ghost<RunEnd>))
    requires stop_ok(&env.p, reason),
    ensures run_post(&env.p, m0, *final(m), (r.0, r.1), r.2@),
{
    env.rt.report(V2_REPORT_STUCK, m.bci, reason);
    m.save();
    assert(run_post(&env.p, m0, *m, (RESULT_TERMINATED, 1i64), RunEnd::Stuck(reason)));
    (RESULT_TERMINATED, 1, Ghost(RunEnd::Stuck(reason)))
}

} // verus!
