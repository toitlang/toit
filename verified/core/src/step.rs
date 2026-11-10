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
//! Opcodes whose handlers are not proven yet go through `step_unverified`,
//! an `external_body` bridge to the checked handlers of machine.rs: its
//! contract (the same as `step`'s) is ASSUMED, and listed in
//! verified/TRUSTED.toml and OBLIGATIONS.md.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use toit_spec::types::Value;
use toit_spec::v2::types::{State2, Program2, Outcome2, Halt2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, small, step_ok, outcome_ok, cur_op};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, lemma_at_good, cur_k, cur_m, cur_off};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, value_operands, instr_ok, is_branch, map_at, w1_of};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::p1;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::theorem::{completion, continues};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::bytecodes::opcode_length2;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{u16_at, u32_at};

verus! {

// ---------------------------------------------------------------------------
// What a step guarantees.

/// The opcodes whose handlers are proven to refine the spec.
pub open spec fn verified_op(op: u8) -> bool {
    ||| op <= 4          // LOAD_LOCAL, LOAD_LOCAL_WIDE, POP_LOAD_LOCAL, STORE_LOCAL(_POP)
    ||| 14 <= op <= 31   // LOAD_LOCAL_0..5, literals, smis, LOAD_METHOD, LOAD_GLOBAL_VAR(_WIDE)
    ||| op == 35 || op == 36  // STORE_GLOBAL_VAR(_WIDE)
    ||| op == 40 || op == 41  // POP, POP_1
    ||| 81 <= op <= 88   // BRANCH*, BRANCH_BACK*
}

/// The machine continues from a state the spec reaches from `g0`: the same
/// state (the instruction has not run: preemption before a backward
/// branch, stack growth before a call), the next state of `step`, or a
/// completion of a PRIMITIVE step (`theorem::transition` without the size
/// bound, which `refines` implies).
pub open spec fn advances(ap: Program2, g0: State2, g1: State2) -> bool {
    ||| g1 == g0
    ||| continues(sp::step(ap, g0), g1)
    ||| match sp::step(ap, g0) {
            Outcome2::Primitive(s1, module, index) =>
                exists|o: Outcome2| completion(ap, s1, module, index, o) && continues(o, g1),
            _ => false,
        }
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
    }
}

/// The refinement contract of the handlers of the opcodes not proven yet:
/// the same guarantee as a verified step. ASSUMED (external_body): their
/// run-time checks keep them memory safe for every program, but that they
/// refine the spec is tested (untrusted suite, fuzzing), not proven.
/// OBLIGATIONS.md lists the missing proofs per opcode family.
#[verifier::external_body]
#[inline(always)]
pub fn step_unverified(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        old(m).inv(env.p),
        !verified_op(opcode),
        bci == old(m).bci,
        opcode == env.p.ap@.bytecodes[bci as int],
    ensures step_post(env.p, *old(m), *final(m), r),
{
    m.dispatch_unverified(env, bci, opcode)
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

// ---------------------------------------------------------------------------
// The step.

proof fn lemma_small(p: &Program, m: &Machine)
    requires m.refines(p),
    ensures small(m.g@),
{
    let g = m.g@;
    assert(g.stack.len() == m.words().len());
    assert(g.frames.len() * 4 <= m.len);
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
        assert(outcome_ok(p.ap@, p.cert@, sp::step(p.ap@, m0.g@)));
        assert(continues(sp::step(p.ap@, m0.g@), m1.g@));
    }
}

/// The condition of a conditional branch is a value (not a block
/// reference), by the verifier's `value_operands`.
proof fn lemma_branch_cond(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        ({ let op = cur_op(p.ap@, g); (82 <= op <= 84) || (86 <= op <= 88) }),
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

/// One step: executes the instruction at the bci (`spec::step`). The
/// opcodes of the top frame (locals, constants, globals, pops, branches)
/// are verified here; the others go through `step_unverified`.
#[inline(always)]
pub fn step(m: &mut Machine, env: &Env) -> (r: Ctl)
    requires old(m).inv(env.p),
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        lemma_small(p, m);
        toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g);
        lemma_instr(ap, p.cert@, p.trusted@, g);
        reveal_with_fuel(opcode_length2, 1);
    }
    let bci = m.bci;
    let opcode = p.code.at(bci);
    let r = match opcode {
        0 => {
            let n = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, n as int, 2)) by { reveal(sp::step); } }
            m.op_load_local(p, n, 2)
        },
        1 => {
            let n = code_u16(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, n as int, 3)) by { reveal(sp::step); } }
            m.op_load_local(p, n, 3)
        },
        2 => {
            let n = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_pop_load_local(g, n as int)) by { reveal(sp::step); } }
            m.op_pop_load_local(p, n)
        },
        3 => {
            let n = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_local(g, n as int)) by { reveal(sp::step); } }
            m.op_store_local(p, n)
        },
        4 => {
            let n = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_local_pop(g, n as int)) by { reveal(sp::step); } }
            m.op_store_local_pop(p, n)
        },
        14..=19 => {
            let n = (opcode - 14) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_local(g, n as int, 1)) by { reveal(sp::step); } }
            m.op_load_local(p, n, 1)
        },
        20 => {
            let i = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_literal(ap, g, i as int, 2)) by { reveal(sp::step); } }
            m.op_load_literal(p, i, 2)
        },
        21 => {
            let i = code_u16(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::op_load_literal(ap, g, i as int, 3)) by { reveal(sp::step); } }
            m.op_load_literal(p, i, 3)
        },
        22 => {
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, sp::null2(ap)), 1)) by { reveal(sp::step); } }
            m.op_load_null(p, 1)
        },
        23 => {
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(0)), 1)) by { reveal(sp::step); } }
            m.op_load_smi(p, 0, 1)
        },
        24 => {
            let n = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_smis_0(g, n as int)) by { reveal(sp::step); } }
            m.op_load_smis_0(p, n)
        },
        25 => {
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(1)), 1)) by { reveal(sp::step); } }
            m.op_load_smi(p, 1, 1)
        },
        26 => {
            let v = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 2)) by { reveal(sp::step); } }
            m.op_load_smi(p, v, 2)
        },
        27 => {
            let v = code_u16(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 3)) by { reveal(sp::step); } }
            m.op_load_smi(p, v, 3)
        },
        28 => {
            let v = code_u32(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 5)) by { reveal(sp::step); } }
            m.op_load_smi(p, v, 5)
        },
        29 => {
            let v = code_u32(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::next(sp::push(g, Value::Smi(v as i64)), 5)) by { reveal(sp::step); } }
            m.op_load_smi(p, v, 5)
        },
        30 => {
            let i = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_load_global(g, i as int, 2)) by { reveal(sp::step); } }
            m.op_load_global(p, i, 2)
        },
        31 => {
            let i = code_u16(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::op_load_global(g, i as int, 3)) by { reveal(sp::step); } }
            m.op_load_global(p, i, 3)
        },
        35 => {
            let i = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_store_global(g, i as int, 2)) by { reveal(sp::step); } }
            m.op_store_global(p, i, 2)
        },
        36 => {
            let i = code_u16(p, bci + 1);
            proof { assert(sp::step(ap, g) == sp::op_store_global(g, i as int, 3)) by { reveal(sp::step); } }
            m.op_store_global(p, i, 3)
        },
        40 => {
            if p.preempt_a_lot { env.pre.request(); }
            let n = p.code.at(bci + 1) as usize;
            proof { assert(sp::step(ap, g) == sp::op_pop(g, n as int, 2)) by { reveal(sp::step); } }
            m.op_pop(p, n, 2)
        },
        41 => {
            if p.preempt_a_lot { env.pre.request(); }
            proof { assert(sp::step(ap, g) == sp::op_pop(g, 1, 1)) by { reveal(sp::step); } }
            m.op_pop(p, 1, 1)
        },
        81..=84 => {
            let d = code_u16(p, bci + 1);
            let kind = (opcode - 81) as usize;
            proof {
                assert(sp::step(ap, g) == (if d == 0 { sp::stuck(toit_spec::types::Stuck::BadBranch) }
                    else { sp::op_branch(ap, g, kind as int, bci + d, 3) })) by { reveal(sp::step); }
                if kind != 0 { lemma_branch_cond(p, g); }
            }
            m.op_branch(p, kind, bci + d, 3)
        },
        85..=88 => {
            // BRANCH_BACK*: the preemption point of loops.
            if env.pre.requested() {
                env.pre.clear();
                return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
            }
            let d = code_u16(p, bci + 1);
            let kind = (opcode - 85) as usize;
            proof {
                assert(sp::step(ap, g) == sp::op_branch(ap, g, kind as int, bci - d, 3)) by { reveal(sp::step); }
                if kind != 0 { lemma_branch_cond(p, g); }
                // The target's offset is mapped by the verifier, so not negative.
                lemma_back_branch(p, g);
            }
            m.op_branch(p, kind, bci - d, 3)
        },
        _ => {
            return step_unverified(m, env, bci, opcode);
        },
    };
    proof { lemma_local_post(p, m0, *m, r); }
    r
}

// ---------------------------------------------------------------------------
// The run loop.

/// What a run guarantees when it returns: if the process continues later
/// (preempted or yielded), the saved machine refines a well-formed state
/// the spec reaches from the state it started in. Any other result ends
/// the process (exit, uncaught exception, task end, deep sleep, reset, or
/// out of memory); a stuck state of the spec is never reported.
pub open spec fn run_post(p: &Program, m0: Machine, m1: Machine, r: (usize, i64)) -> bool {
    &&& (r.0 == RESULT_PREEMPTED || r.0 == RESULT_YIELDED) ==> m1.inv(p) && reaches(p.ap@, m0.g@, m1.g@)
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

/// Runs the current task until it is preempted, yields or ends. A program
/// may loop forever (the scheduler preempts it), so no termination is
/// claimed.
#[verifier::exec_allows_no_decreases_clause]
pub fn run_loop(m: &mut Machine, env: &Env) -> (r: (usize, i64))
    requires old(m).inv(env.p),
    ensures run_post(env.p, *old(m), *final(m), r),
{
    let ghost m0 = *m;
    proof { lemma_reaches_refl(env.p.ap@, m.g@); }
    loop
        invariant
            m.inv(env.p),
            m0 == *old(m),
            reaches(env.p.ap@, m0.g@, m.g@),
    {
        let ghost before = *m;
        let ctl = step(m, env);
        match ctl {
            Ctl::Next => {
                proof { lemma_reaches_step(env.p.ap@, m0.g@, before.g@, m.g@); }
            },
            Ctl::Exit(state, value) => {
                proof {
                    if state == RESULT_PREEMPTED || state == RESULT_YIELDED {
                        lemma_reaches_step(env.p.ap@, m0.g@, before.g@, m.g@);
                    }
                }
                m.save();
                proof {
                    if state == RESULT_PREEMPTED || state == RESULT_YIELDED {
                        assert(m.refines(env.p));
                        assert(m.inv(env.p));
                        assert(reaches(env.p.ap@, m0.g@, m.g@));
                    }
                    assert(run_post(env.p, m0, *m, (state as usize, value)));
                }
                return (state as usize, value);
            },
            Ctl::Stuck(reason) => {
                env.rt.report(V2_REPORT_STUCK, m.bci, reason);
                m.save();
                assert(run_post(env.p, m0, *m, (RESULT_TERMINATED, 1i64)));
                return (RESULT_TERMINATED, 1);
            },
        }
    }
}

} // verus!
