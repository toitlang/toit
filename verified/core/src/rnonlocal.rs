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

//! Non-local control flow on registers (the fast paths; DESIGN.md "Run
//! loop"): NON_LOCAL_RETURN and NON_LOCAL_BRANCH whose target frame is
//! reached without a handler on the way (`spec::unwind` only pops frames),
//! TRY, UNWIND after a normal completion (a null token), and a return into
//! a TRY's finally code (`spec::enter_finally` without an unwinding). All
//! of them only without finally records. Anything else (a handler on the
//! way, finally records, a non-local return to the task's bottom frame or
//! into a TRY, THROW) runs on the machine (`step::slow`).
//!
//! The paths only pop frames or push one (TRY, whose call check gives the
//! new frame its room), so the room of the remaining frames is the one they
//! had: no rescan (`room::ensure_room_all`).

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::step::*;
use crate::calls::*;
use crate::rcalls::{call_fast, push_call};
use toit_spec::types::{Value, Frame, Handler, Fin, Unwind};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, try_ok, bases_ok, base_step, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;

verus! {

/// `g1` is a state the unwinding loop of `spec::unwind` reaches from `g` by
/// popping frames (none with a handler, no finally records): the same
/// frames up to its top, the same unwinding outcome.
pub open spec fn popped(p: &Program, g: State2, g1: State2, u: Unwind) -> bool {
    &&& sp::unwind(p.ap@, g1, u) == sp::unwind(p.ap@, g, u)
    &&& shape0(p, g1)
    &&& g1.fins.len() == 0
    &&& 0 < g1.frames.len() <= g.frames.len()
    &&& forall|i: int| 0 <= i < g1.frames.len() ==> #[trigger] g1.frames[i] == g.frames[i]
}

/// The frame an unwinding of a non-local return or branch completes in.
pub open spec fn unw_frame(u: Unwind) -> int {
    match u {
        Unwind::Return(f, _) => f as int,
        Unwind::Branch(f, _, _) => f as int,
        Unwind::Throw(_) => -1,
    }
}

/// Without finally records, popping a frame pops none.
pub proof fn lemma_fins_empty(g: State2)
    requires g.fins.len() == 0,
    ensures sp::fins_popped(g) == g.fins,
{
    assert(sp::cut_fins(g.fins, sp::top_index(g), 0) == g.fins);
}

/// Pops the frames above frame `f` for the unwinding `u` of a non-local
/// return or branch to frame `f`, on a copy of the registers, while there
/// are no finally records: up to frame `f` or to the first frame with a
/// handler on the way (`f` included). `Some((r2, hd, hbci))`: then `m.with(r2)`
/// refines the state `spec::unwind` reaches by popping (`popped`), whose
/// top frame is `f` without a handler (`!hd`) or has a handler (`hd`:
/// `spec::unwind` enters its finally code). `None` (finally records):
/// nothing changed.
#[inline(always)]
pub fn pop_to(m: &mut Machine, r: &Regs, p: &Program, f: usize, Ghost(u): Ghost<Unwind>) -> (res: Option<(Regs, bool, usize)>)
    requires
        m_ok(p, *old(m), *r),
        shape_ok(p, old(m).g@),
        room_ok(p, old(m).with(*r)),
        r.sp@ >= r.fr@ + old(m).fw + STACK_RESERVE,
        unw_frame(u) == f,
        f < old(m).g@.frames.len(),
    ensures
        res is None ==> *final(m) == *old(m),
        res matches Some((r2, _, _)) ==> m_ok(p, *final(m), r2),
        res matches Some((r2, _, _)) ==> *final(m) == (Machine { g: final(m).g, ..*old(m) }),
        res matches Some((r2, _, _)) ==> final(m).fw == 0,
        res matches Some((r2, _, _)) ==> r2.sp@ >= r2.fr@ + STACK_RESERVE,
        res matches Some((r2, _, _)) ==> room_ok(p, final(m).with(r2)),
        res matches Some((r2, hd, _)) ==> !hd ==> final(m).g@.frames.len() == f + 1,
        res matches Some((r2, hd, _)) ==> final(m).g@.frames.len() >= f + 1,
        res matches Some((r2, hd, _)) ==> hd == sp::has_handler(final(m).g@),
        res matches Some((r2, hd, hb)) ==> hd ==> hb == final(m).g@.tries.last().bci,
        res matches Some((r2, _, _)) ==> popped(p, old(m).g@, final(m).g@, u),
        res matches Some((r2, _, _)) ==> r2.end == r.end,
        res matches Some((r2, _, _)) ==> final(m).g@.bci == old(m).g@.bci,
{
    if m.fw != 0 {
        return None;
    }
    let ghost m0 = *m;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        w0.lemma_frame(p);
        assert(f < 0x4000) by {
            assert(w0.ftop == FRAME_WORDS * g.frames.len());
            assert(w0.ftop <= w0.len);
        }
        assert forall|i: int| 0 <= i < g.frames.len() implies #[trigger] g.frames[i] == g.frames[i] by {}
    }
    let mut r2 = *r;
    let mut hd = false;
    // The bci of the top frame's handler: the return bci of the frame popped
    // last (format 3, note 22).
    let mut hbci: usize = 0;
    let tr = m.mem.slot(FRAME_WORDS * f);
    loop
        invariant_except_break
            !hd,
        invariant
            sp::has_handler(m.g@) ==> hbci == m.g@.tries.last().bci,
            *m == (Machine { g: m.g, ..m0 }),
            m0.fw == 0,
            m0.g@ == g,
            m0 == *old(m),
            m_ok(p, *m, r2),
            r2.end == r.end,
            r2.sp@ >= r2.fr@ + STACK_RESERVE,
            room_ok(p, m.with(r2)),
            popped(p, g, m.g@, u),
            m.g@.frames.len() >= f + 1,
            m.g@.bci == g.bci,
            tr@ == FRAME_WORDS * f,
            tr.sid() == m.mem.sid(),
            unw_frame(u) == f,
        ensures
            m_ok(p, *m, r2),
            *m == (Machine { g: m.g, ..m0 }),
            r2.end == r.end,
            r2.sp@ >= r2.fr@ + STACK_RESERVE,
            room_ok(p, m.with(r2)),
            popped(p, g, m.g@, u),
            m.g@.frames.len() >= f + 1,
            m.g@.bci == g.bci,
            hd == sp::has_handler(m.g@),
            hd ==> hbci == m.g@.tries.last().bci,
            !hd ==> m.g@.frames.len() == f + 1,
        decreases m.g@.frames.len(),
    {
        let ghost gi = m.g@;
        let ghost mi = m.with(r2);
        let ghost k = gi.frames.len() - 1;
        proof {
            mi.lemma_frame(p);
            assert(mi.ftop == FRAME_WORDS * gi.frames.len());
            lemma_rec_index(gi.frames.len() as int, k, FRAME_HANDLER);
            lemma_rec_index(gi.frames.len() as int, k, FRAME_BASE);
            lemma_handler_word(mi.mem@, gi.frames, gi.tries);
        }
        let rc = r2.fr.offset(-(FRAME_WORDS as isize));
        let h = rc.read(FRAME_HANDLER, &m.mem);
        if h != 0 {
            proof {
                assert(rc@ == FRAME_WORDS * k);
                assert(rec(mi.mem@, k, FRAME_HANDLER) == h);
                assert(sp::has_handler(gi));
            }
            hd = true;
            break;
        }
        proof {
            assert(rc@ == FRAME_WORDS * k);
            assert(rec(mi.mem@, k, FRAME_HANDLER) == h);
            assert(!sp::has_handler(gi));
        }
        if !tr.lt(rc, &m.mem) {
            proof {
                assert(FRAME_WORDS * k <= FRAME_WORDS * f);
                assert(k == f);
            }
            break;
        }
        // Pop the top frame k > f.
        proof {
            assert(k > f);
            assert(k >= 1);
            lemma_rec_index(gi.frames.len() as int, k - 1, FRAME_BASE);
            assert(rec(mi.mem@, k - 1, FRAME_BASE) == gi.frames[k - 1].base);
            assert(base_step(gi, k - 1));
            lemma_no_handler(gi);
            lemma_fins_empty(gi);
            assert(gi.frames.last().base <= gi.stack.len());
            // One level of the unwinding loop.
            assert(sp::unwind(p.ap@, gi, u) == sp::unwind(p.ap@, sp::pop_frame(gi), u));
        }
        let cbase = rc.offset(-(FRAME_WORDS as isize)).read(FRAME_BASE, &m.mem);
        let ret = rc.read(FRAME_RET, &m.mem);
        proof {
            lemma_rec_index(gi.frames.len() as int, k, FRAME_RET);
            assert(rec(mi.mem@, k, FRAME_RET) == gi.frames[k].ret);
            lemma_pop_callees(gi);
        }
        hbci = ret;
        let ghost r0 = r2;
        r2.sp = r2.fp;
        r2.fp = r2.end.offset(-(cbase as isize));
        r2.fr = rc;
        let ghost g1 = sp::pop_frame(gi);
        m.g = Ghost(g1);
        proof {
            let m1 = m.with(r2);
            let b = sp::top(gi).base as int;
            assert(b == mi.base);
            lemma_frames_pop(mi.mem@, gi.frames, gi.tries);
            assert(g1.frames.last() == gi.frames[k - 1]);
            assert(m1.method == rec(mi.mem@, k - 1, FRAME_METHOD));
            assert(rec(mi.mem@, k - 1, FRAME_METHOD) == gi.frames[k - 1].method);
            assert(sp::valid_method(p.ap@, gi.frames[k - 1].method as int));
            assert(m1.words() =~= mi.words().subrange(0, b));
            assert(enc_seq(mi.addr(), g1.stack) =~= enc_seq(mi.addr(), gi.stack).subrange(0, b));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(mi.addr(), g1.stack[i]) by {
                assert(g1.stack[i] == gi.stack[i]);
            }
            assert(m1.refines(p));
            assert forall|fi: int| 0 <= fi && fi + 1 < g1.frames.len() implies #[trigger] base_step(g1, fi) by {
                assert(base_step(gi, fi));
            }
            assert(bases_ok(g1));
            assert forall|fi: int| 0 <= fi < g1.frames.len() implies
                sp::valid_method(p.ap@, (#[trigger] g1.frames[fi]).method as int) by {
                assert(g1.frames[fi] == gi.frames[fi]);
            }
            assert(shape0(p, g1));
            assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] g1.frames[i] == g.frames[i] by {
                assert(g1.frames[i] == gi.frames[i]);
            }
            assert forall|i: int| 0 <= i < g1.frames.len() implies #[trigger] frame_room(p, m1, i) by {
                assert(g1.frames[i] == gi.frames[i]);
                assert(frame_room(p, mi, i));
            }
            assert(room_ok(p, m1));
        }
    }
    Some((r2, hd, hbci))
}

/// NON_LOCAL_RETURN (`spec::op_non_local_return`): the fast path returns
/// the value from the block's frame when `pop_to` applies and the return
/// itself is fast (`rarrays::ret_r`: not the task's bottom frame, the
/// caller not in a TRY).
#[inline(always)]
pub fn op_non_local_return(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 93,
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
        lemma_shape(p, g);
    }
    let ghost v = sp::at(g, 0);
    let w = at(m, r, 0);
    let f = crate::unwind::ref_frame(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let x = at(m, r, 1);
    let ghost gu = Unwind::Return(f, sp::at(g, 1));
    proof { assert(sp::op_non_local_return(ap, g) == sp::unwind(ap, g, gu)); }
    match pop_to(m, r, p, f, Ghost(gu)) {
        None => slow0(m, r, env, Slow::Op),
        Some((r2, true, hbci)) => {
            // A handler on the way: its finally code runs (rare for a
            // throw, common for a return out of a try/finally).
            let ghost gi = m.g@;
            proof {
                assert(sp::unwind(ap, gi, gu) == sp::enter_finally(ap, gi, gi.tries.last(), Some(gu)));
                assert(m.addr() == w0.addr());
                assert(f < 0x4000) by {
                    assert(w0.ftop == FRAME_WORDS * g.frames.len());
                    assert(w0.ftop <= w0.len);
                }
            }
            let mut r3 = r2;
            if enter_fin_r(m, &mut r3, p, x, 1 + 4 * f, 0, 0, hbci, Ghost(gu)) {
                proof { lemma_matches(p, w0, m.with(r3), Ctl::Next); }
                set_regs(r, r3);
                return Ctl::Next;
            }
            m.g = Ghost(g);
            proof {
                assert(m.g == Ghost(m.g@));
                assert(m0.g == Ghost(m0.g@));
                assert(*m == m0);
            }
            slow0(m, r, env, Slow::Op)
        },
        Some((r2, false, _)) => {
            let mut r3 = r2;
            let ghost gi = m.g@;
            proof {
                assert(sp::top_index(gi) == f);
                assert(sp::unwind(ap, gi, gu) == sp::return_from(ap, gi, sp::at(g, 1)));
                assert(m.addr() == w0.addr());
            }
            if crate::rarrays::ret_r(m, &mut r3, p, x, Ghost(sp::at(g, 1))) {
                proof { lemma_matches(p, w0, m.with(r3), Ctl::Next); }
                set_regs(r, r3);
                Ctl::Next
            } else {
                m.g = Ghost(g);
                proof { assert(*m == m0); }
                slow0(m, r, env, Slow::Op)
            }
        },
    }
}

/// NON_LOCAL_BRANCH hd off (`spec::op_non_local_branch`): the fast path
/// continues in the block's frame when `pop_to` applies.
#[inline(always)]
pub fn op_non_local_branch(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 95,
        off < 0x1_0000_0000,
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        w0.lemma_at(p, 0);
        lemma_shape(p, g);
    }
    let ghost v = sp::at(g, 0);
    let w = at(m, r, 0);
    let f = crate::unwind::ref_frame(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let slot = crate::blocks::ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    proof {
        assert(f < g.frames.len());
        lemma_rec_index(g.frames.len() as int, f as int, FRAME_METHOD);
        assert(rec(w0.mem@, f as int, FRAME_METHOD) == g.frames[f as int].method);
    }
    let method = m.mem.read(f * FRAME_WORDS + FRAME_METHOD);
    proof {
        assert(sp::valid_method(ap, method as int));
        assert(ap.methods[method as int] == method_info(p.minfo(method as int), p.max_height));
    }
    let info = p.method(method);
    let target = info.entry as usize + off;
    let h = slot + 1 - hd;
    let ghost gu = Unwind::Branch(f, target, h);
    proof { assert(sp::op_non_local_branch(ap, g, hd as int, off as int) == sp::unwind(ap, g, gu)); }
    match pop_to(m, r, p, f, Ghost(gu)) {
        None => slow0(m, r, env, Slow::Op),
        Some((r2, true, hbci)) => {
            // A handler on the way: its finally code runs.
            let ghost gi = m.g@;
            proof {
                assert(sp::unwind(ap, gi, gu) == sp::enter_finally(ap, gi, gi.tries.last(), Some(gu)));
                assert(m.addr() == w0.addr());
                assert(const_ok(g.heap, ap.roots[0]));
                assert(ap.roots[0] == sp::null2(ap));
                assert(f < 0x4000) by {
                    assert(w0.ftop == FRAME_WORDS * g.frames.len());
                    assert(w0.ftop <= w0.len);
                }
            }
            let mut r3 = r2;
            if enter_fin_r(m, &mut r3, p, p.null, 2 + 4 * f, target, h, hbci, Ghost(gu)) {
                proof { lemma_matches(p, w0, m.with(r3), Ctl::Next); }
                set_regs(r, r3);
                return Ctl::Next;
            }
            m.g = Ghost(g);
            proof {
                assert(m.g == Ghost(m.g@));
                assert(m0.g == Ghost(m0.g@));
                assert(*m == m0);
            }
            slow0(m, r, env, Slow::Op)
        },
        Some((r2, false, _)) => {
            let ghost gi = m.g@;
            let ghost mi = m.with(r2);
            let ghost g1 = State2 { stack: gi.stack.subrange(0, h as int), bci: target, ..gi };
            proof {
                mi.lemma_frame(p);
                assert(sp::top_index(gi) == f);
                assert(sp::unwind(ap, gi, gu) == sp::unwind(ap, g, gu));
                assert(sp::unwind(ap, gi, gu) == Outcome2::Next(g1));
                assert(sp::base(gi) <= h <= gi.stack.len());
                // The target is inside the bytecodes: the next state is
                // well formed.
                assert(outcome_ok(ap, p.cert@, Outcome2::Next(g1)));
                toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g1);
            }
            let mut r3 = r2;
            r3.sp = r3.end.offset(-(h as isize));
            r3.ip = p.code.cursor(target);
            m.g = Ghost(g1);
            proof {
                let m1 = m.with(r3);
                assert(m1.words() =~= mi.words().subrange(0, h as int));
                assert(enc_seq(mi.addr(), g1.stack) =~= enc_seq(mi.addr(), gi.stack).subrange(0, h as int));
                assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(mi.addr(), g1.stack[i]) by {
                    assert(g1.stack[i] == gi.stack[i]);
                }
                lemma_frames_rel_same(mi.mem@, m1.mem@, g1.frames, g1.tries);
                lemma_fins_rel_same(mi.mem@, m1.mem@, m1.ftop as int, g1.fins);
                assert(m1.refines(p));
                lemma_matches(p, w0, m1, Ctl::Next);
                lemma_room_same(p, mi, m1);
            }
            set_regs(r, r3);
            Ctl::Next
        },
    }
}

/// UNWIND (`spec::op_unwind`): the fast path is the end of finally code
/// after a normal completion (a null token): pops reason, token and value.
#[inline(always)]
pub fn op_unwind(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 99,
        bci + 1 < 0x1000_0000,
        sp::step(env.p.ap@, old(m).g@) == sp::op_unwind(env.p.ap@, old(m).g@),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, 1);
        w0.lemma_at(p, 2);
        assert(const_ok(g.heap, ap.roots[0]));
        assert(ap.roots[0] == sp::null2(ap));
        lemma_enc_inj(g.heap, w0.addr(), sp::at(g, 1), sp::null2(ap));
    }
    let token = at(m, r, 1);
    if token != p.null {
        let (r2, c2) = unwind_resume_v(m, *r, env, bci, opcode);
        set_regs(r, r2);
        return c2;
    }
    proof { assert(sp::op_unwind(ap, g) == sp::op_pop(g, 3, 1)); }
    let c = op_pop(m, r, p, 3, 1);
    proof {
        lemma_matches(p, w0, m.with(*r), c);
        lemma_room_same(p, w0, m.with(*r));
    }
    c
}

/// TRY while finally records exist (a TRY in finally code): `op_try`'s
/// fast path when the records stay (`cut_fins` keeps them: the last one is
/// not of the top frame at the TRY's block slot or above), with room for
/// the frame, the records and the block reference and no preemption
/// request; the try block's frame is pushed above the records
/// (`rfins::push_call_fins`). `false` (nothing changed) otherwise: the
/// machine's TRY, whose resume rescans every frame.
#[inline(always)]
fn try_fins(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (b: bool)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 97,
        bci + 1 < 0x1000_0000,
        sp::step(env.p.ap@, old(m).g@) == sp::op_try(env.p.ap@, old(m).g@),
    ensures
        b ==> rpost(&env.p, *old(m), *old(r), *final(m), *final(r), Ctl::Next),
        !b ==> *final(m) == *old(m) && *final(r) == *old(r),
{
    let p = &env.p;
    if m.fw == 0 || env.pre.requested() {
        return false;
    }
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    let ghost n = g.frames.len() as int;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        crate::unwind::lemma_try_target(p, g);
        lemma_tries(p, g);
        w0.lemma_at(p, 0);
        assert(w0.ftop == FRAME_WORDS * n);
        lemma_rec_index(n, n - 1, FRAME_HANDLER);
        assert(p.max_height < 0x1_0000);
    }
    let fw = m.fw;
    let free = r.sp.diff(r.fr);
    if free < FRAME_WORDS + p.max_height + STACK_RESERVE + FIN_WORDS + fw + 1 {
        return false;
    }
    let height = r.end.diff(r.sp);
    let fo = m.mem.index(r.fr);
    proof {
        assert(height == g.stack.len());
        assert(fo == FRAME_WORDS * n);
        assert(fw == FIN_WORDS * g.fins.len());
        assert(g.fins.len() > 0);
        let x = g.fins.len() - 1;
        assert(fin_rel(w0.mem@, fo as int, x, g.fins[x]));
        lemma_fin_index(fo as int, g.fins.len() as int, x, FIN_FRAME);
        lemma_fin_index(fo as int, g.fins.len() as int, x, FIN_HEIGHT);
        assert(FIN_WORDS * x + FIN_FRAME == fw - FIN_WORDS + FIN_FRAME);
        assert(FIN_WORDS * x + FIN_HEIGHT == fw - FIN_WORDS + FIN_HEIGHT);
        assert(g.stack.len() >= 1);
    }
    // The last record (records are in frame and height order).
    let lf = m.mem.read(fo + fw - FIN_WORDS + FIN_FRAME);
    let lh = m.mem.read(fo + fw - FIN_WORDS + FIN_HEIGHT);
    let fi = fo / FRAME_WORDS - 1;
    if lf > fi || (lf == fi && lh >= height - 1) {
        return false;
    }
    let ghost cut = sp::cut_fins(g.fins, n - 1, g.stack.len() - 1);
    proof {
        assert(fi == n - 1);
        assert(lf == g.fins.last().frame);
        assert(lh == g.fins.last().height);
        assert(cut == g.fins);
    }
    let ghost tt = sp::block_target(ap, g, g.stack.len() - 1)->0;
    let mw = at(m, r, 0);
    proof {
        assert(g.stack[g.stack.len() - 1] == sp::at(g, 0));
        assert(g.stack[g.stack.len() - 1] == Value::Smi(tt as i64));
        assert(0 <= tt < ap.methods.len());
        lemma_smi_word_nat(tt as i64);
        assert(mw == 2 * tt);
        assert(mw >> 1 == mw / 2) by (bit_vector);
    }
    let t = mw >> 1;
    let info = p.method(t);
    let rr = r.fr.offset(-(FRAME_WORDS as isize));
    proof { assert(rr@ == FRAME_WORDS * (n - 1)); }
    rr.write(FRAME_HANDLER, height, &mut m.mem);
    let ghost hd = Handler { frame: fi, height: height, bci: (bci + 1) as usize };
    let ghost s1 = State2 { tries: g.tries.push(hd), fins: cut, ..g };
    m.g = Ghost(s1);
    proof {
        let m1 = m.with(*r);
        assert forall|i: int| 0 <= i < FRAME_WORDS * n && i != FRAME_WORDS * (n - 1) + FRAME_HANDLER
            implies #[trigger] m1.mem@[i] == w0.mem@[i] by {}
        crate::unwind::lemma_frames_set(w0.mem@, m1.mem@, g.frames, g.tries, hd);
        assert forall|i: int| fo <= i < fo + fw implies #[trigger] m1.mem@[i] == w0.mem@[i] by {}
        lemma_fins_rel_same(w0.mem@, m1.mem@, m1.ftop as int, s1.fins);
        assert(m1.words() =~= w0.words());
        assert(m1.method == w0.method);
        assert(m1.refines(p));
        lemma_room_same(p, w0, m1);
    }
    // The reference to the block's slot.
    let slot = height - 1;
    let ghost br = Value::BlockRef(fi, slot);
    proof { assert(fi < 0x4000 && slot < MAX_STACK_LENGTH); }
    let bw = smi_of((fi * 0x1_0000 + slot) as i64);
    let ghost m2 = m.with(*r);
    push_next(m, r, p, bw, 0, Ghost(br));
    let ghost s2 = sp::push(s1, br);
    proof {
        assert(sp::goto(s2, bci as int) =~= s2);
        lemma_room_same(p, m2, m.with(*r));
        assert(sp::top_index(g) == n - 1);
        assert(sp::op_try(ap, g) == sp::call(ap, s2, tt, g.bci + 1));
        assert(t == tt);
    }
    crate::rfins::push_call_fins(m, r, p, t, info, bci + 1);
    proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    true
}

/// TRY (`spec::op_try`): the fast path, under the check of a call's fast
/// path (`call_fast`: room, no finally records, so none is cut, and no
/// preemption request), installs the handler, pushes the reference to the
/// block's slot and calls the try block.
#[inline(always)]
pub fn op_try(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        opcode == 97,
        bci + 1 < 0x1000_0000,
        sp::step(env.p.ap@, old(m).g@) == sp::op_try(env.p.ap@, old(m).g@),
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    if !call_fast(m, r, env) {
        if try_fins(m, r, env, bci, opcode) {
            return Ctl::Next;
        }
        return slow0(m, r, env, Slow::Op);
    }
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(*r);
    let ghost n = g.frames.len() as int;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        crate::unwind::lemma_try_target(p, g);
        lemma_tries(p, g);
        w0.lemma_at(p, 0);
        assert(w0.ftop == FRAME_WORDS * n);
        lemma_rec_index(n, n - 1, FRAME_HANDLER);
    }
    let ghost tt = sp::block_target(ap, g, g.stack.len() - 1)->0;
    let mw = at(m, r, 0);
    proof {
        assert(g.stack[g.stack.len() - 1] == sp::at(g, 0));
        assert(g.stack[g.stack.len() - 1] == Value::Smi(tt as i64));
        assert(0 <= tt < ap.methods.len());
        lemma_smi_word_nat(tt as i64);
        assert(mw == 2 * tt);
        assert(mw >> 1 == mw / 2) by (bit_vector);
    }
    let t = mw >> 1;
    let info = p.method(t);
    let height = r.end.diff(r.sp);
    let fi = r.fr.diff(m.mem.slot(0)) / FRAME_WORDS - 1;
    let rr = r.fr.offset(-(FRAME_WORDS as isize));
    proof {
        assert(height == g.stack.len());
        assert(fi == n - 1);
        assert(rr@ == FRAME_WORDS * (n - 1));
    }
    rr.write(FRAME_HANDLER, height, &mut m.mem);
    let ghost hd = Handler { frame: fi, height: height, bci: (bci + 1) as usize };
    let ghost cut = sp::cut_fins(g.fins, n - 1, g.stack.len() - 1);
    let ghost s1 = State2 { tries: g.tries.push(hd), fins: cut, ..g };
    m.g = Ghost(s1);
    proof {
        let m1 = m.with(*r);
        assert(g.fins.len() == 0);
        assert(cut == g.fins);
        assert forall|i: int| 0 <= i < FRAME_WORDS * n && i != FRAME_WORDS * (n - 1) + FRAME_HANDLER
            implies #[trigger] m1.mem@[i] == w0.mem@[i] by {}
        crate::unwind::lemma_frames_set(w0.mem@, m1.mem@, g.frames, g.tries, hd);
        lemma_fins_rel_same(w0.mem@, m1.mem@, m1.ftop as int, s1.fins);
        assert(m1.words() =~= w0.words());
        assert(m1.method == w0.method);
        assert(m1.refines(p));
        lemma_room_same(p, w0, m1);
    }
    // The reference to the block's slot.
    let slot = height - 1;
    let ghost br = Value::BlockRef(fi, slot);
    proof { assert(fi < 0x4000 && slot < MAX_STACK_LENGTH); }
    let bw = smi_of((fi * 0x1_0000 + slot) as i64);
    let ghost m2 = m.with(*r);
    push_next(m, r, p, bw, 0, Ghost(br));
    let ghost s2 = sp::push(s1, br);
    proof {
        assert(sp::goto(s2, bci as int) =~= s2);
        lemma_room_same(p, m2, m.with(*r));
        assert(sp::top_index(g) == n - 1);
        assert(sp::op_try(ap, g) == sp::call(ap, s2, tt, g.bci + 1));
        assert(t == tt);
    }
    push_call(m, r, p, t, info.entry as usize, info.arity as usize, bci + 1);
    proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    Ctl::Next
}

/// UNWIND with a token (`spec::op_unwind`): the end of the finally code of
/// an unwinding. The fast path: the only finally record (so the token names
/// it), a non-local return or branch (not a throw), resumed by `pop_to`
/// to its frame without another handler on the way and completed there;
/// afterwards there are no finally records. Anything else on the machine.
#[inline(never)]
pub fn unwind_resume_v(m: &mut Machine, r0: Regs, env: &Env, bci: usize, opcode: u8) -> (res: (Regs, Ctl))
    requires
        rhandler_pre(&env.p, *old(m), r0, bci, opcode),
        sp::at(old(m).g@, 1) != sp::null2(env.p.ap@),
        opcode == 99,
        bci + 1 < 0x1000_0000,
        sp::step(env.p.ap@, old(m).g@) == sp::op_unwind(env.p.ap@, old(m).g@),
    ensures rpost(&env.p, *old(m), r0, *final(m), res.0, res.1),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost w0 = m.with(r0);
    let mut r = r0;
    if m.fw != FIN_WORDS {
        let c = slow0(m, &mut r, env, Slow::Op);
        return (r, c);
    }
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        w0.lemma_at(p, 1);
        w0.lemma_at(p, 2);
        lemma_shape(p, g);
        assert(const_ok(g.heap, ap.roots[0]));
        assert(ap.roots[0] == sp::null2(ap));
        lemma_enc_inj(g.heap, w0.addr(), sp::at(g, 1), sp::null2(ap));
        assert(g.fins.len() == 1);
    }
    // The token names record 0, the only one.
    let ghost tv = sp::at(g, 1);
    let ghost k = tv->Smi_0 as int;
    proof {
        assert(sp::fin_matches(g, k));
        assert(k == 0);
        assert(fin_rel(w0.mem@, w0.ftop as int, 0, g.fins[0]));
        lemma_fin_index(w0.ftop as int, 1, 0, FIN_RESUME);
        lemma_fin_index(w0.ftop as int, 1, 0, FIN_TARGET);
        lemma_fin_index(w0.ftop as int, 1, 0, FIN_TARGET_HEIGHT);
        crate::unwind::lemma_resume_decode(g.fins[0].resume);
    }
    let rw = r.fr.read(FIN_RESUME, &m.mem);
    let tw = r.fr.read(FIN_TARGET, &m.mem);
    let th = r.fr.read(FIN_TARGET_HEIGHT, &m.mem);
    let kind = rw & 3;
    let f = rw >> 2;
    let ftop = r.fr.diff(m.mem.slot(0));
    if kind == 0 || kind == 3 || f >= ftop / FRAME_WORDS {
        // A throw (or an unwinding to no live frame: stuck, impossible).
        let c = slow0(m, &mut r, env, Slow::Op);
        return (r, c);
    }
    let x = at(m, &r, 2);
    let ghost rv = g.fins[0].resume;
    let ghost gu = sp::unwind_of(rv, sp::at(g, 2));
    let ghost g2 = State2 { fins: g.fins.subrange(0, 0), ..sp::drop(g, 3) };
    proof {
        assert(sp::op_unwind(ap, g) == sp::unwind(ap, g2, gu));
        assert(unw_frame(gu) == f);
        assert(w0.ftop == FRAME_WORDS * g.frames.len());
        assert(f < g.frames.len());
    }
    // No finally record any more: the registers without the token's three
    // slots, the gate for no records.
    let need0 = m.need;
    let bot0 = m.bot;
    proof { assert(p.max_height < 0x1_0000); }
    let mut r2 = r;
    r2.sp = r2.sp.offset(3);
    m.fw = 0;
    m.need = FRAME_WORDS + p.max_height + STACK_RESERVE + FIN_WORDS;
    m.bot = m.mem.slot(FRAME_WORDS);
    m.g = Ghost(g2);
    proof {
        let m2 = m.with(r2);
        assert(m2.words() =~= w0.words().subrange(0, w0.height() - 3));
        assert(enc_seq(w0.addr(), g2.stack) =~= enc_seq(w0.addr(), g.stack).subrange(0, g.stack.len() - 3));
        assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(w0.addr(), g2.stack[i]) by {
            assert(g2.stack[i] == g.stack[i]);
        }
        assert(fins_rel(m2.mem@, m2.ftop as int, g2.fins));
        assert(m2.refines(p));
        assert forall|fi: int| 0 <= fi && fi + 1 < g2.frames.len() implies #[trigger] base_step(g2, fi) by {
            assert(base_step(g, fi));
        }
        assert(bases_ok(g2));
        assert(shape_ok(p, g2));
        assert forall|i: int| 0 <= i < g2.frames.len() implies #[trigger] frame_room(p, m2, i) by {
            assert(frame_room(p, w0, i));
        }
        assert(room_ok(p, m2));
    }
    match pop_to(m, &r2, p, f, Ghost(gu)) {
        None | Some((_, true, _)) => {
            m.fw = FIN_WORDS;
            m.need = need0;
            m.bot = bot0;
            m.g = Ghost(g);
            proof {
                assert(m.g == Ghost(m.g@));
                assert(m0.g == Ghost(m0.g@));
                assert(*m == m0);
            }
            let c = slow0(m, &mut r, env, Slow::Op);
            (r, c)
        },
        Some((r3, false, _)) => {
            let ghost gi = m.g@;
            let ghost mi = m.with(r3);
            proof {
                mi.lemma_frame(p);
                assert(sp::top_index(gi) == f);
                assert(sp::unwind(ap, gi, gu) == sp::unwind(ap, g2, gu));
            }
            if kind == 1 {
                let mut r4 = r3;
                proof {
                    assert(gu == Unwind::Return(f, sp::at(g, 2)));
                    assert(sp::unwind(ap, gi, gu) == sp::return_from(ap, gi, sp::at(g, 2)));
                    assert(m.addr() == w0.addr());
                }
                if crate::rarrays::ret_r(m, &mut r4, p, x, Ghost(sp::at(g, 2))) {
                    proof { lemma_matches(p, w0, m.with(r4), Ctl::Next); }
                    return (r4, Ctl::Next);
                }
                m.fw = FIN_WORDS;
                m.need = need0;
                m.bot = bot0;
                m.g = Ghost(g);
                proof {
                    assert(m.g == Ghost(m.g@));
                    assert(m0.g == Ghost(m0.g@));
                    assert(*m == m0);
                }
                let c = slow0(m, &mut r, env, Slow::Op);
                return (r, c);
            }
            // A non-local branch: continue in the frame at the target.
            let ghost g1 = State2 { stack: gi.stack.subrange(0, th as int), bci: tw, ..gi };
            proof {
                assert(gu == Unwind::Branch(f, tw, th));
                assert(sp::unwind(ap, gi, gu) == Outcome2::Next(g1));
                assert(sp::base(gi) <= th <= gi.stack.len());
                assert(outcome_ok(ap, p.cert@, Outcome2::Next(g1)));
                toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g1);
            }
            let mut r4 = r3;
            r4.sp = r4.end.offset(-(th as isize));
            r4.ip = p.code.cursor(tw);
            m.g = Ghost(g1);
            proof {
                let m1 = m.with(r4);
                assert(m1.words() =~= mi.words().subrange(0, th as int));
                assert(enc_seq(mi.addr(), g1.stack) =~= enc_seq(mi.addr(), gi.stack).subrange(0, th as int));
                assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(mi.addr(), g1.stack[i]) by {
                    assert(g1.stack[i] == gi.stack[i]);
                }
                lemma_frames_rel_same(mi.mem@, m1.mem@, g1.frames, g1.tries);
                lemma_fins_rel_same(mi.mem@, m1.mem@, m1.ftop as int, g1.fins);
                assert(m1.refines(p));
                lemma_matches(p, w0, m1, Ctl::Next);
                lemma_room_same(p, mi, m1);
            }
            (r4, Ctl::Next)
        },
    }
}

// ---------------------------------------------------------------------------
// Out of line (registers by value, `set_regs` at the call site): inlined
// into the run loop, these paths changed the register allocation of the
// whole loop (+6 percent instructions on richards, which never runs them).

#[inline(never)]
pub fn op_non_local_return_v(m: &mut Machine, r0: Regs, env: &Env, bci: usize, opcode: u8) -> (res: (Regs, Ctl))
    requires
        rhandler_pre(&env.p, *old(m), r0, bci, opcode),
        opcode == 93,
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
    ensures rpost(&env.p, *old(m), r0, *final(m), res.0, res.1),
{
    let mut r = r0;
    let c = op_non_local_return(m, &mut r, env, bci, opcode);
    (r, c)
}

#[inline(never)]
pub fn op_non_local_branch_v(m: &mut Machine, r0: Regs, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (res: (Regs, Ctl))
    requires
        rhandler_pre(&env.p, *old(m), r0, bci, opcode),
        opcode == 95,
        off < 0x1_0000_0000,
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
    ensures rpost(&env.p, *old(m), r0, *final(m), res.0, res.1),
{
    let mut r = r0;
    let c = op_non_local_branch(m, &mut r, env, bci, opcode, hd, off);
    (r, c)
}

#[inline(never)]
pub fn op_try_v(m: &mut Machine, r0: Regs, env: &Env, bci: usize, opcode: u8) -> (res: (Regs, Ctl))
    requires
        rhandler_pre(&env.p, *old(m), r0, bci, opcode),
        opcode == 97,
        bci + 1 < 0x1000_0000,
        sp::step(env.p.ap@, old(m).g@) == sp::op_try(env.p.ap@, old(m).g@),
    ensures rpost(&env.p, *old(m), r0, *final(m), res.0, res.1),
{
    let mut r = r0;
    let c = op_try(m, &mut r, env, bci, opcode);
    (r, c)
}

#[inline(never)]
pub fn ret_try_v(m: &mut Machine, r0: Regs, env: &Env, Ghost(v): Ghost<Value>) -> (res: (Regs, Ctl))
    requires
        rinv(&env.p, *old(m), r0),
        r0.sp@ >= r0.fr@ + old(m).fw + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, old(m).g@),
        sp::step(env.p.ap@, old(m).g@) == sp::return_from(env.p.ap@, old(m).g@, v),
        old(m).fw == 0,
        r0.fr@ >= 2 * FRAME_WORDS,
        old(m).mem@[r0.fr@ - 2 * FRAME_WORDS + FRAME_HANDLER] != 0,
    ensures rpost(&env.p, *old(m), r0, *final(m), res.0, res.1),
{
    let mut r = r0;
    let c = ret_try_r(m, &mut r, env, Ghost(v));
    (r, c)
}

/// The handlers of a well-formed state belong to frames suspended in their
/// TRY (`sound::try_ok`: the frame above is the try block, based at the
/// TRY's height).
pub proof fn lemma_try_ok(p: &Program, g: State2)
    requires accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
    ensures forall|x: int| 0 <= x < g.tries.len() ==> #[trigger] try_ok(g, x),
{
    reveal(wf);
    toit_spec::v2::sound_local::lemma_task_basics(p.ap@, p.cert@, g);
}

/// RETURN from a try block into its TRY (`spec::return_from` followed by
/// `spec::enter_finally` without an unwinding), without finally records:
/// pops the try block's frame, cuts the object stack to the TRY's height
/// (the try block's base), clears the handler and pushes null, null and
/// -1 for the finally code.
#[inline(always)]
pub fn ret_try_r(m: &mut Machine, r: &mut Regs, env: &Env, Ghost(v): Ghost<Value>) -> (c: Ctl)
    requires
        rinv(&env.p, *old(m), *old(r)),
        old(r).sp@ >= old(r).fr@ + old(m).fw + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, old(m).g@),
        sp::step(env.p.ap@, old(m).g@) == sp::return_from(env.p.ap@, old(m).g@, v),
        old(m).fw == 0,
        old(r).fr@ >= 2 * FRAME_WORDS,
        old(m).mem@[old(r).fr@ - 2 * FRAME_WORDS + FRAME_HANDLER] != 0,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g0 = m.g@;
    let ghost m0 = m.with(*r);
    let ghost n = g0.frames.len() as int;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g0)));
        lemma_shape(p, g0);
        lemma_tries(p, g0);
        lemma_try_ok(p, g0);
        m0.lemma_frame(p);
        assert(m0.ftop == FRAME_WORDS * n);
        assert(n >= 2);
        lemma_rec_index(n, n - 2, FRAME_HANDLER);
        lemma_rec_index(n, n - 1, FRAME_RET);
        lemma_rec_index(n, n - 2, FRAME_METHOD);
        lemma_rec_index(n, n - 2, FRAME_BASE);
        lemma_rec_index(n, n - 1, FRAME_BASE);
        assert(!sp::has_handler(g0));
        lemma_no_handler(g0);
        lemma_fins_empty(g0);
        lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
        lemma_handler_word(m0.mem@, g0.frames.drop_last(), g0.tries);
        assert(g0.frames.drop_last()[n - 2] == g0.frames[n - 2]);
        assert(const_ok(g0.heap, ap.roots[0]));
        lemma_smi_word(-1i64);
    }
    let crec = r.fr.offset(-((2 * FRAME_WORDS) as isize));
    let height = crec.read(FRAME_HANDLER, &m.mem);
    // The handler's bci is the try block's return bci (format 3, note 22).
    let hbci = r.fr.offset(-(FRAME_WORDS as isize)).read(FRAME_RET, &m.mem);
    let base = crec.read(FRAME_BASE, &m.mem);
    let ghost s1 = State2 {
        stack: g0.stack.subrange(0, sp::top(g0).base as int).push(v),
        frames: g0.frames.drop_last(),
        fins: sp::fins_popped(g0),
        bci: sp::top(g0).ret,
        ..g0
    };
    let ghost h = s1.tries.last();
    let ghost x = g0.tries.len() - 1;
    proof {
        assert(sp::has_handler(s1));
        assert(h == g0.tries[x]);
        assert(h.frame == n - 2);
        assert(try_ok(g0, x));
        assert(height == h.height);
        assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
        assert(g0.frames[h.frame + 1].ret == h.bci);
        assert(hbci == h.bci);
        assert(h.height == g0.frames[n - 1].base);
        assert(sp::return_from(ap, g0, v) == sp::enter_finally(ap, s1, h, None));
        assert(sp::base(s1) <= h.height <= s1.stack.len());
        assert(rec(m0.mem@, n - 1, FRAME_BASE) == g0.frames[n - 1].base);
        assert(height <= m0.height());
        assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
        assert(base == sp::base(s1));
    }
    let null = p.null;
    let minus1 = smi_of(-1);
    let s = r.end.offset(-((height + 3) as isize));
    s.write(2, null, &mut m.mem);
    s.write(1, null, &mut m.mem);
    s.write(0, minus1, &mut m.mem);
    crec.write(FRAME_HANDLER, 0, &mut m.mem);
    r.sp = s;
    r.fp = r.end.offset(-(base as isize));
    r.fr = r.fr.offset(-(FRAME_WORDS as isize));
    proof {
        let g2x = State2 { stack: s1.stack.subrange(0, h.height as int), tries: s1.tries.drop_last(), bci: h.bci, ..s1 };
        let g2 = sp::push(sp::push(sp::push(g2x, sp::null2(ap)), sp::null2(ap)), toit_spec::spec_common::smi(-1));
        assert(sp::enter_finally(ap, s1, h, None) == Outcome2::Next(g2));
        toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g2);
    }
    r.ip = p.code.cursor(hbci);
    let ghost g2x = State2 { stack: s1.stack.subrange(0, h.height as int), tries: s1.tries.drop_last(), bci: h.bci, ..s1 };
    let ghost g2 = sp::push(sp::push(sp::push(g2x, sp::null2(ap)), sp::null2(ap)), toit_spec::spec_common::smi(-1));
    m.g = Ghost(g2);
    proof {
        let m1 = m.with(*r);
        let addr = m0.addr();
        let fr2 = g0.frames.drop_last();
        // Frame records: the try block's is gone, the TRY frame's handler cleared.
        assert forall|i: int| 0 <= i < FRAME_WORDS * fr2.len() && i != FRAME_WORDS * (fr2.len() - 1) + FRAME_HANDLER
            implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        crate::unwind::lemma_frames_clear(m0.mem@, m1.mem@, fr2, g0.tries);
        assert(g2.frames == fr2 && g2.tries == g0.tries.drop_last());
        assert(g2.fins == g0.fins);
        lemma_fins_rel_same(m0.mem@, m1.mem@, m1.ftop as int, g2.fins);
        // The object stack.
        let hh = height as int;
        assert(g2.stack.len() == hh + 3);
        assert forall|j: int| 0 <= j < hh + 3 implies #[trigger] m1.words()[j] == enc(addr, g2.stack[j]) by {
            assert(m1.words()[j] == m1.mem@[m1.len - 1 - j]);
            if j < hh {
                assert(m1.mem@[m1.len - 1 - j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == enc_seq(addr, g0.stack)[j]);
                assert(g2.stack[j] == g0.stack[j]);
            } else if j == hh {
                assert(g2.stack[j] == sp::null2(ap));
            } else if j == hh + 1 {
                assert(g2.stack[j] == sp::null2(ap));
            } else {
                assert(g2.stack[j] == toit_spec::spec_common::smi(-1));
            }
        }
        assert(m1.words() =~= enc_seq(addr, g2.stack));
        assert forall|j: int| 0 <= j < g2.stack.len() implies #[trigger] encodable(addr, g2.stack[j]) by {
            if j < hh { assert(g2.stack[j] == g0.stack[j]); }
        }
        assert(m1.method == rec(m0.mem@, n - 2, FRAME_METHOD));
        assert(sp::valid_method(ap, g0.frames[n - 2].method as int));
        assert(m1.refines(p));
        lemma_matches(p, m0, m1, Ctl::Next);
        assert forall|i: int| 0 <= i < g2.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            assert(g2.frames[i] == g0.frames[i]);
            assert(frame_room(p, m0, i));
        }
    }
    Ctl::Next
}


/// `spec::enter_finally(g, g.tries.last(), Some(u))` on the registers, for
/// a non-local return or branch `u` that `pop_to` stopped at a frame with a
/// handler (no finally records before): the handler's finally code runs
/// with the first finally record (the resume words `rw`, `tw`, `th`), the
/// object stack cut to the TRY's height and the value `x`, the token (the
/// smi 0) and the reason (the smi -1) pushed; the gate is the one for
/// records. `false` (nothing changed) when the top frame lacks room for its
/// maximal height with the record (`room::top_room`).
pub fn enter_fin_r(m: &mut Machine, r: &mut Regs, p: &Program, x: usize, rw: usize, tw: usize, th: usize,
    hbci: usize, Ghost(gu): Ghost<Unwind>) -> (b: bool)
    requires
        hbci == old(m).g@.tries.last().bci,
        m_ok(p, *old(m), *old(r)),
        old(m).fw == 0,
        old(r).sp@ >= old(r).fr@ + STACK_RESERVE,
        room_ok(p, old(m).with(*old(r))),
        shape0(p, old(m).g@),
        sp::has_handler(old(m).g@),
        !(gu is Throw),
        resume_ok(sp::resume_of(gu)),
        rw == resume_word(sp::resume_of(gu)),
        tw == target_word(sp::resume_of(gu)),
        th == target_height_word(sp::resume_of(gu)),
        x == enc(old(m).addr(), sp::value_of(p.ap@, gu)),
        encodable(old(m).addr(), sp::value_of(p.ap@, gu)),
        !(sp::enter_finally(p.ap@, old(m).g@, old(m).g@.tries.last(), Some(gu)) is Stuck),
        outcome_ok(p.ap@, p.cert@, sp::enter_finally(p.ap@, old(m).g@, old(m).g@.tries.last(), Some(gu))),
        accepts(p.ap@, p.cert@, p.trusted@),
    ensures
        !b ==> *final(m) == *old(m) && *final(r) == *old(r),
        b ==> final(m).rok(*final(r)) && ipok(p, *final(r)) && final(m).with(*final(r)).refines(p) && gate_ok(p, *final(m))
            && sp::enter_finally(p.ap@, old(m).g@, old(m).g@.tries.last(), Some(gu)) == Outcome2::Next(final(m).g@)
            && room_ok(p, final(m).with(*final(r))),
{
    let ghost ap = p.ap@;
    let ghost g0 = m.g@;
    let ghost m0 = m.with(*r);
    let ghost n = g0.frames.len() as int;
    let ghost h = g0.tries.last();
    let ghost addr = m0.addr();
    proof {
        m0.lemma_frame(p);
        assert(m0.ftop == FRAME_WORDS * n);
        assert(g0.fins.len() == 0);
        lemma_rec_index(n, n - 1, FRAME_HANDLER);
        lemma_rec_index(n, n - 1, FRAME_METHOD);
        lemma_rec_index(n, n - 1, FRAME_BASE);
        lemma_handler_word(m0.mem@, g0.frames, g0.tries);
        assert(rec(m0.mem@, n - 1, FRAME_BASE) == g0.frames[n - 1].base);
        assert(rec(m0.mem@, n - 1, FRAME_METHOD) == g0.frames[n - 1].method);
        assert(g0.tries[g0.tries.len() - 1] == h);
        assert(h.frame == n - 1);
        assert(sp::valid_method(ap, g0.frames[n - 1].method as int));
        assert(p.max_height < 0x1_0000);
    }
    let rr = r.fr.offset(-(FRAME_WORDS as isize));
    let height = rr.read(FRAME_HANDLER, &m.mem);
    let base = rr.read(FRAME_BASE, &m.mem);
    let method = rr.read(FRAME_METHOD, &m.mem);
    let fo = m.mem.index(r.fr);
    proof {
        assert(height == h.height);
        assert(hbci == h.bci);
        assert(base == g0.frames[n - 1].base);
        assert(method == g0.frames[n - 1].method);
        assert(ap.methods[method as int] == method_info(p.minfo(method as int), p.max_height));
        assert(sp::base(g0) <= h.height <= g0.stack.len());
        assert(fo == FRAME_WORDS * n);
    }
    // The top frame's room with the new record.
    let a = p.method(method).arity as usize;
    if base + a + p.max_height + fo + FIN_WORDS + STACK_RESERVE > m.len {
        return false;
    }
    let null = p.null;
    let minus1 = smi_of(-1);
    let zero = smi_of(0);
    proof {
        lemma_smi_word(-1i64);
        lemma_smi_word(0i64);
        assert(const_ok(g0.heap, ap.roots[0]));
    }
    // The record, after the frame records.
    let fr0 = r.fr;
    fr0.write(FIN_FRAME, fo / FRAME_WORDS - 1, &mut m.mem);
    fr0.write(FIN_HEIGHT, height, &mut m.mem);
    fr0.write(FIN_RESUME, rw, &mut m.mem);
    fr0.write(FIN_TARGET, tw, &mut m.mem);
    fr0.write(FIN_TARGET_HEIGHT, th, &mut m.mem);
    rr.write(FRAME_HANDLER, 0, &mut m.mem);
    let ghost mem1 = m.mem@;
    // The object stack: cut to the TRY's height, the three slots pushed.
    let s = r.end.offset(-((height + 3) as isize));
    s.write(2, x, &mut m.mem);
    s.write(1, zero, &mut m.mem);
    s.write(0, minus1, &mut m.mem);
    r.sp = s;
    r.ip = p.code.cursor(hbci);
    m.fw = FIN_WORDS;
    m.need = usize::MAX;
    m.bot = m.mem.slot(m.len);
    let ghost fin = Fin { frame: h.frame, height: h.height, resume: sp::resume_of(gu) };
    let ghost s1 = State2 {
        stack: g0.stack.subrange(0, h.height as int),
        tries: g0.tries.drop_last(),
        bci: h.bci,
        ..g0
    };
    let ghost s2 = State2 { fins: s1.fins.push(fin), ..s1 };
    let ghost g2 = sp::push(sp::push(sp::push(s2, sp::value_of(ap, gu)), toit_spec::spec_common::smi(0)),
        toit_spec::spec_common::smi(-1));
    proof {
        assert(s1.fins.len() == 0);
        assert(sp::enter_finally(ap, g0, h, Some(gu)) == Outcome2::Next(g2));
        toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g2);
    }
    m.g = Ghost(g2);
    proof {
        let m1 = m.with(*r);
        let fo2 = fo as int;
        assert(m1.ftop == fo);
        assert(m1.rtop == fo + FIN_WORDS);
        // Frame records: the top frame's handler is cleared.
        assert forall|i: int| 0 <= i < FRAME_WORDS * n && i != FRAME_WORDS * (n - 1) + FRAME_HANDLER
            implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        crate::unwind::lemma_frames_clear(m0.mem@, m1.mem@, g0.frames, g0.tries);
        assert(g2.frames == g0.frames && g2.tries == g0.tries.drop_last());
        // The finally record.
        lemma_fin_index(fo2, 1, 0, FIN_FRAME);
        assert(fin_rel(m1.mem@, fo2, 0, fin));
        assert(fins_rel(m1.mem@, fo2, Seq::<Fin>::empty()));
        crate::unwind::lemma_fins_rel_push(m1.mem@, fo2, Seq::<Fin>::empty(), fin);
        assert(Seq::<Fin>::empty().push(fin) =~= g2.fins);
        // The object stack.
        let hh = height as int;
        assert(g2.stack.len() == hh + 3);
        assert forall|j: int| 0 <= j < hh + 3 implies #[trigger] m1.words()[j] == enc(addr, g2.stack[j]) by {
            assert(m1.words()[j] == m1.mem@[m1.len - 1 - j]);
            if j < hh {
                assert(m1.mem@[m1.len - 1 - j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == enc_seq(addr, g0.stack)[j]);
                assert(g2.stack[j] == g0.stack[j]);
            } else if j == hh {
                assert(g2.stack[j] == sp::value_of(ap, gu));
            } else if j == hh + 1 {
                assert(g2.stack[j] == toit_spec::spec_common::smi(0));
            } else {
                assert(g2.stack[j] == toit_spec::spec_common::smi(-1));
            }
        }
        assert(m1.words() =~= enc_seq(addr, g2.stack));
        assert forall|j: int| 0 <= j < g2.stack.len() implies #[trigger] encodable(addr, g2.stack[j]) by {
            if j < hh { assert(g2.stack[j] == g0.stack[j]); }
        }
        assert(m1.method == m0.method);
        assert(m1.refines(p));
        assert forall|i: int| 0 <= i < g2.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            assert(g2.frames[i] == g0.frames[i]);
            assert(frame_room(p, m0, i));
        }
        assert(frame_need(p, g2, n - 1) <= m1.len);
        assert(top_room(p, m1));
    }
    true
}

} // verus!
