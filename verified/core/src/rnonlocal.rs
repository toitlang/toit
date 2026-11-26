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
//! loop", format note 23): NON_LOCAL_RETURN and NON_LOCAL_BRANCH, which pop
//! frames up to their target frame or up to a try block on the way, whose
//! finally code they enter; TRY (a block call with the handler flag);
//! UNWIND after a normal completion and, for a non-local return or branch,
//! its resumption; a return from a try block into its TRY's finally code.
//! Anything else (THROW, the resumption of an exception, a non-local return
//! to the task's bottom frame, a call without room) runs on the machine
//! (`step::slow`).
//!
//! The paths only pop frames or push one (TRY, whose call check gives the
//! new frame its room); the finally code's slots are within the frame's
//! room (the verifier counts them in the TRY's successor map), so the room
//! of the remaining frames is the one they had: no rescan
//! (`room::ensure_room_all`).

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::step::*;
use crate::calls::*;
use crate::unwind::Unw;
#[cfg(verus_keep_ghost)]
use crate::unwind::{unw_rel, unw_ok, lemma_token_words};
use crate::rcalls::{call_fast, push_call};
use toit_spec::types::{Value, Frame, Pending, Unwind};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, bases_ok, base_step, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;

verus! {

/// `g1` is a state the unwinding loop of `spec::unwind` reaches from `g` by
/// popping frames that are neither the target nor try blocks: the same
/// frames up to its top, the same unwinding outcome.
pub open spec fn popped(p: &Program, g: State2, g1: State2, u: Unwind) -> bool {
    &&& sp::unwind(p.ap@, g1, u) == sp::unwind(p.ap@, g, u)
    &&& shape_ok(p, g1)
    &&& 0 < g1.frames.len() <= g.frames.len()
    &&& forall|i: int| 0 <= i < g1.frames.len() ==> #[trigger] g1.frames[i] == g.frames[i]
}

/// Pops the frames above frame `f` for the unwinding `u` of a non-local
/// return or branch to frame `f`, on a copy of the registers: up to frame
/// `f` or to the first try block on the way (not `f`). The result
/// `(r2, hd)`: `m.with(r2)` refines the state `spec::unwind` reaches by
/// popping (`popped`), whose top frame is `f` (`!hd`) or a try block above
/// `f` (`hd`: `spec::unwind` pops it and enters the finally code below).
#[inline(always)]
pub fn pop_to(m: &mut Machine, r: &Regs, p: &Program, f: usize, Ghost(u): Ghost<Unwind>) -> (res: (Regs, bool))
    requires
        m_ok(p, *old(m), *r),
        shape_ok(p, old(m).g@),
        room_ok(p, old(m).with(*r)),
        r.sp@ >= r.fr@ + STACK_RESERVE,
        sp::unw_target(u) == f,
        f < old(m).g@.frames.len(),
    ensures ({
        let (r2, hd) = res;
        &&& m_ok(p, *final(m), r2)
        &&& *final(m) == (Machine { g: final(m).g, ..*old(m) })
        &&& r2.sp@ >= r2.fr@ + STACK_RESERVE
        &&& room_ok(p, final(m).with(r2))
        &&& (!hd ==> final(m).g@.frames.len() == f + 1)
        &&& final(m).g@.frames.len() >= f + 1
        &&& (hd ==> final(m).g@.frames.len() > f + 1 && sp::top(final(m).g@).handler)
        &&& popped(p, old(m).g@, final(m).g@, u)
        &&& r2.end == r.end
        &&& final(m).g@.bci == old(m).g@.bci
    }),
{
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
    let tr = m.mem.slot(FRAME_WORDS * f);
    loop
        invariant_except_break
            !hd,
        invariant
            *m == (Machine { g: m.g, ..m0 }),
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
            sp::unw_target(u) == f,
        ensures
            m_ok(p, *m, r2),
            *m == (Machine { g: m.g, ..m0 }),
            r2.end == r.end,
            r2.sp@ >= r2.fr@ + STACK_RESERVE,
            room_ok(p, m.with(r2)),
            popped(p, g, m.g@, u),
            m.g@.frames.len() >= f + 1,
            m.g@.bci == g.bci,
            !hd ==> m.g@.frames.len() == f + 1,
            hd ==> m.g@.frames.len() > f + 1 && sp::top(m.g@).handler,
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
        }
        let rc = r2.fr.offset(-(FRAME_WORDS as isize));
        if !tr.lt(rc, &m.mem) {
            proof {
                assert(rc@ == FRAME_WORDS * k);
                assert(FRAME_WORDS * k <= FRAME_WORDS * f);
                assert(k == f);
            }
            break;
        }
        let h = rc.read(FRAME_HANDLER, &m.mem);
        proof {
            assert(rc@ == FRAME_WORDS * k);
            assert(rec(mi.mem@, k, FRAME_HANDLER) == h);
            assert(rec(mi.mem@, k, FRAME_HANDLER) == handler_word(gi.frames[k]));
            assert(gi.frames[k] == sp::top(gi));
            assert(k > f);
        }
        if h != 0 {
            hd = true;
            break;
        }
        // Pop the top frame k > f, not a try block.
        proof {
            assert(k >= 1);
            lemma_rec_index(gi.frames.len() as int, k - 1, FRAME_BASE);
            assert(rec(mi.mem@, k - 1, FRAME_BASE) == gi.frames[k - 1].base);
            assert(base_step(gi, k - 1));
            assert(gi.frames.last().base <= gi.stack.len());
            // One level of the unwinding loop.
            assert(sp::unw_target(u) != sp::top_index(gi));
            assert(sp::unwind(p.ap@, gi, u) == sp::unwind(p.ap@, sp::pop_frame(gi), u));
        }
        let cbase = rc.offset(-(FRAME_WORDS as isize)).read(FRAME_BASE, &m.mem);
        r2.sp = r2.fp;
        r2.fp = r2.end.offset(-(cbase as isize));
        r2.fr = rc;
        let ghost g1 = sp::pop_frame(gi);
        m.g = Ghost(g1);
        proof {
            let m1 = m.with(r2);
            let b = sp::top(gi).base as int;
            assert(b == mi.base);
            lemma_frames_pop(mi.mem@, gi.frames);
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
            assert(g1.frames[0] == gi.frames[0]);
            assert(shape_ok(p, g1));
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
    (r2, hd)
}

/// NON_LOCAL_RETURN (`spec::op_non_local_return`): the fast path returns
/// the value from the block's frame when the return itself is fast
/// (`rarrays::ret_r`: not the task's bottom frame, not a try block), or
/// enters the finally code of a try block on the way.
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
    let (r2, hd) = pop_to(m, r, p, f, Ghost(gu));
    let ghost gi = m.g@;
    if hd {
        // A try block on the way: its caller's finally code runs (rare for
        // a throw, common for a return out of a try/finally).
        proof {
            assert(sp::unw_target(gu) != sp::top_index(gi));
            assert(sp::unwind(ap, gi, gu) == sp::enter_finally(ap, sp::pop_frame(gi), sp::top(gi).base as int,
                sp::top(gi).ret as int, Some(gu)));
            assert(m.addr() == w0.addr());
            assert(f < 0x4000) by {
                assert(w0.ftop == FRAME_WORDS * g.frames.len());
                assert(w0.ftop <= w0.len);
            }
        }
        let mut r3 = r2;
        enter_fin_r(m, &mut r3, p, Some(Unw::Return(f, x)), Ghost(Some(gu)));
        proof { lemma_matches(p, w0, m.with(r3), Ctl::Next); }
        set_regs(r, r3);
        return Ctl::Next;
    }
    let mut r3 = r2;
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
}

/// NON_LOCAL_BRANCH hd off (`spec::op_non_local_branch`): the fast path
/// continues in the block's frame, or enters the finally code of a try
/// block on the way.
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
    let (r2, hdl) = pop_to(m, r, p, f, Ghost(gu));
    let ghost gi = m.g@;
    if hdl {
        // A try block on the way: its caller's finally code runs.
        proof {
            assert(sp::unw_target(gu) != sp::top_index(gi));
            assert(sp::unwind(ap, gi, gu) == sp::enter_finally(ap, sp::pop_frame(gi), sp::top(gi).base as int,
                sp::top(gi).ret as int, Some(gu)));
            assert(m.addr() == w0.addr());
            assert(f < 0x4000) by {
                assert(w0.ftop == FRAME_WORDS * g.frames.len());
                assert(w0.ftop <= w0.len);
            }
            assert(h <= g.stack.len());
            assert(target < p.code@.len());
        }
        let mut r3 = r2;
        enter_fin_r(m, &mut r3, p, Some(Unw::Branch(f, target, h)), Ghost(Some(gu)));
        proof { lemma_matches(p, w0, m.with(r3), Ctl::Next); }
        set_regs(r, r3);
        return Ctl::Next;
    }
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
        lemma_frames_rel_same(mi.mem@, m1.mem@, g1.frames);
        assert(m1.refines(p));
        lemma_matches(p, w0, m1, Ctl::Next);
        lemma_room_same(p, mi, m1);
    }
    set_regs(r, r3);
    Ctl::Next
}

/// UNWIND (`spec::op_unwind`): the fast path is the end of finally code
/// after a normal completion (the token's second word is the smi 0): pops
/// the reason, the token and the value. Otherwise `unwind_resume_v`.
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
    }
    let ghost d = sp::token_at(g)->0;
    let wb = at(m, r, 1);
    proof {
        assert(sp::token_at(g) is Some);
        assert(sp::at(g, 1) == Value::Token(true, d, sp::at(g, 2)->Token_2, sp::at(g, 2)->Token_3));
        assert(wb == token_b(d));
        assert(pending_encodable(d));
        lemma_token_vals(d);
        match d {
            Pending::Normal => { lemma_token_words(0, 0, 0, 0); },
            Pending::Throw => { lemma_token_words(0, 0, 0, 1); lemma_smi_word_nat(1); },
            Pending::Return(f) => { lemma_token_words(f, 0, 0, 2); lemma_smi_word_nat(2); },
            Pending::Branch(f, nb, hb) => {
                lemma_token_words(f, hb, nb, 3);
                assert(((nb << 3usize) | (3usize << 1usize)) != 0) by (bit_vector);
            },
        }
    }
    if wb != 0 {
        let (r2, c2) = unwind_resume_v(m, *r, env, bci, opcode);
        set_regs(r, r2);
        return c2;
    }
    proof { assert(d == Pending::Normal); assert(sp::op_unwind(ap, g) == sp::op_pop(g, 4, 1)); }
    let c = op_pop(m, r, p, 4, 1);
    proof {
        lemma_matches(p, w0, m.with(*r), c);
        lemma_room_same(p, w0, m.with(*r));
    }
    c
}

/// TRY (`spec::op_try`): under the check of a call's fast path
/// (`call_fast`: room and no preemption request), pushes the reference to
/// the block's slot and calls the try block with the handler flag.
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
        lemma_frames_wf(p, g);
        w0.lemma_at(p, 0);
        assert(w0.ftop == FRAME_WORDS * n);
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
    proof {
        assert(height == g.stack.len());
        assert(fi == n - 1);
    }
    // The reference to the block's slot.
    let slot = height - 1;
    let ghost br = Value::BlockRef(fi, slot);
    proof { assert(fi < 0x4000 && slot < MAX_STACK_LENGTH); }
    let bw = smi_of((fi * 0x1_0000 + slot) as i64);
    let ghost m2 = m.with(*r);
    push_next(m, r, p, bw, 0, Ghost(br));
    let ghost s2 = sp::push(g, br);
    proof {
        assert(sp::goto(s2, bci as int) =~= s2);
        lemma_room_same(p, m2, m.with(*r));
        assert(sp::top_index(g) == n - 1);
        assert(sp::op_try(ap, g) == sp::try_call(ap, s2, tt, g.bci + 1));
        assert(t == tt);
    }
    push_call(m, r, p, t, info.entry as usize, info.arity as usize, bci + 1, 1);
    proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
    Ctl::Next
}

/// UNWIND with the token of an unwinding (`spec::op_unwind`): the end of
/// the finally code of an unwinding. The fast path: a non-local return or
/// branch (not a throw), resumed by `pop_to` to its frame and completed
/// there, or entering the finally code of a try block on the way.
/// Anything else on the machine.
#[inline(never)]
pub fn unwind_resume_v(m: &mut Machine, r0: Regs, env: &Env, bci: usize, opcode: u8) -> (res: (Regs, Ctl))
    requires
        rhandler_pre(&env.p, *old(m), r0, bci, opcode),
        sp::token_at(old(m).g@) is Some,
        sp::token_at(old(m).g@)->0 != Pending::Normal,
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
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_frame(p);
        w0.lemma_at(p, 1);
        w0.lemma_at(p, 2);
        w0.lemma_at(p, 3);
        lemma_shape(p, g);
    }
    let ghost d = sp::token_at(g)->0;
    let wb = at(m, &r, 1);
    let wa = at(m, &r, 2);
    let x = at(m, &r, 3);
    proof {
        assert(sp::at(g, 2) == Value::Token(false, d, sp::at(g, 2)->Token_2, sp::at(g, 2)->Token_3));
        assert(sp::at(g, 1) == Value::Token(true, d, sp::at(g, 2)->Token_2, sp::at(g, 2)->Token_3));
        assert(wa == token_a(d) && wb == token_b(d));
        assert(pending_encodable(d));
        lemma_token_vals(d);
        match d {
            Pending::Normal => {},
            Pending::Throw => { lemma_token_words(0, 0, 0, 1); },
            Pending::Return(f) => { lemma_token_words(f, 0, 0, 2); },
            Pending::Branch(f, nb, hb) => { lemma_token_words(f, hb, nb, 3); },
        }
    }
    let kind = (wb >> 1usize) & 3;
    let f = wa >> 17usize;
    let ftop = r.fr.diff(m.mem.slot(0));
    if kind == 1 || f >= ftop / FRAME_WORDS {
        // A throw (or an unwinding to no live frame: stuck, impossible).
        let c = slow0(m, &mut r, env, Slow::Op);
        return (r, c);
    }
    let ghost v = sp::at(g, 3);
    let ghost gu = match d {
        Pending::Return(f) => Unwind::Return(f, v),
        Pending::Branch(f, nb, hb) => Unwind::Branch(f, nb, hb),
        _ => Unwind::Throw(v),
    };
    let tw = wb >> 3usize;
    let th = (wa >> 1usize) & 0xffff;
    let ghost g2 = sp::drop(g, 4);
    proof {
        assert(kind == 2 || kind == 3);
        assert(sp::op_unwind(ap, g) == sp::unwind(ap, g2, gu));
        assert(sp::unw_target(gu) == f);
        assert(w0.ftop == FRAME_WORDS * g.frames.len());
        assert(f < g.frames.len());
    }
    // Without the finally code's four slots.
    let mut r2 = r;
    r2.sp = r2.sp.offset(4);
    m.g = Ghost(g2);
    proof {
        let m2 = m.with(r2);
        assert(m2.words() =~= w0.words().subrange(0, w0.height() - 4));
        assert(enc_seq(w0.addr(), g2.stack) =~= enc_seq(w0.addr(), g.stack).subrange(0, g.stack.len() - 4));
        assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(w0.addr(), g2.stack[i]) by {
            assert(g2.stack[i] == g.stack[i]);
        }
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
    let (r3, hd) = pop_to(m, &r2, p, f, Ghost(gu));
    let ghost gi = m.g@;
    let ghost mi = m.with(r3);
    proof { mi.lemma_frame(p); }
    if hd {
        // A try block on the way: its caller's finally code runs.
        proof {
            assert(sp::unwind(ap, gi, gu) == sp::unwind(ap, g2, gu));
            assert(sp::unw_target(gu) != sp::top_index(gi));
            assert(sp::unwind(ap, gi, gu) == sp::enter_finally(ap, sp::pop_frame(gi), sp::top(gi).base as int,
                sp::top(gi).ret as int, Some(gu)));
            assert(m.addr() == w0.addr());
        }
        let u = if kind == 2 { Unw::Return(f, x) } else { Unw::Branch(f, tw, th) };
        proof { assert(unw_rel(m.addr(), u, gu)); assert(unw_ok(gu)); }
        let mut r4 = r3;
        enter_fin_r(m, &mut r4, p, Some(u), Ghost(Some(gu)));
        proof { lemma_matches(p, w0, m.with(r4), Ctl::Next); }
        return (r4, Ctl::Next);
    }
    proof {
        assert(sp::top_index(gi) == f);
        assert(sp::unwind(ap, gi, gu) == sp::unwind(ap, g2, gu));
    }
    if kind == 2 {
        let mut r4 = r3;
        proof {
            assert(gu == Unwind::Return(f, sp::at(g, 3)));
            assert(sp::unwind(ap, gi, gu) == sp::return_from(ap, gi, sp::at(g, 3)));
            assert(m.addr() == w0.addr());
        }
        if crate::rarrays::ret_r(m, &mut r4, p, x, Ghost(sp::at(g, 3))) {
            proof { lemma_matches(p, w0, m.with(r4), Ctl::Next); }
            return (r4, Ctl::Next);
        }
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
        lemma_frames_rel_same(mi.mem@, m1.mem@, g1.frames);
        assert(m1.refines(p));
        lemma_matches(p, w0, m1, Ctl::Next);
        lemma_room_same(p, mi, m1);
    }
    (r4, Ctl::Next)
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
        r0.sp@ >= r0.fr@ + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, old(m).g@),
        sp::step(env.p.ap@, old(m).g@) == sp::return_from(env.p.ap@, old(m).g@, v),
        r0.fr@ >= 2 * FRAME_WORDS,
        sp::top(old(m).g@).handler,
    ensures rpost(&env.p, *old(m), r0, *final(m), res.0, res.1),
{
    let mut r = r0;
    let c = ret_try_r(m, &mut r, env, Ghost(v));
    (r, c)
}

/// RETURN from a try block into its TRY (`spec::return_from`, which enters
/// the finally code of the frame below without an unwinding).
#[inline(always)]
pub fn ret_try_r(m: &mut Machine, r: &mut Regs, env: &Env, Ghost(v): Ghost<Value>) -> (c: Ctl)
    requires
        rinv(&env.p, *old(m), *old(r)),
        old(r).sp@ >= old(r).fr@ + STACK_RESERVE,
        step_ok(env.p.ap@, env.p.cert@, old(m).g@),
        sp::step(env.p.ap@, old(m).g@) == sp::return_from(env.p.ap@, old(m).g@, v),
        old(r).fr@ >= 2 * FRAME_WORDS,
        sp::top(old(m).g@).handler,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g0 = m.g@;
    let ghost m0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g0)));
        lemma_shape(p, g0);
        m0.lemma_frame(p);
        assert(g0.frames.len() > 1) by {
            assert(m0.ftop == FRAME_WORDS * g0.frames.len());
        }
        assert(sp::return_from(ap, g0, v) == sp::enter_finally(ap, sp::pop_frame(g0), sp::top(g0).base as int,
            sp::top(g0).ret as int, None));
    }
    enter_fin_r(m, r, p, None, Ghost(None));
    proof { lemma_matches(p, m0, m.with(*r), Ctl::Next); }
    Ctl::Next
}

/// `spec::enter_finally(pop_frame(g), base, ret, u)` on the registers: pops
/// the top frame (a try block), cuts the object stack to its base and
/// pushes the finally code's four slots (format note 23); the code
/// continues at the try block's return bci. The slots fit: the popped
/// frame's record and slots are free.
#[inline(never)]
pub fn enter_fin_r(m: &mut Machine, r: &mut Regs, p: &Program, u: Option<Unw>, Ghost(gu): Ghost<Option<Unwind>>)
    requires
        m_ok(p, *old(m), *old(r)),
        old(r).sp@ >= old(r).fr@ + STACK_RESERVE,
        room_ok(p, old(m).with(*old(r))),
        shape_ok(p, old(m).g@),
        old(m).g@.frames.len() > 1,
        sp::top(old(m).g@).handler,
        crate::unwind::unw_opt_rel(old(m).addr(), u, gu),
        match gu { Some(x) => unw_ok(x), None => true },
        outcome_ok(p.ap@, p.cert@, sp::enter_finally(p.ap@, sp::pop_frame(old(m).g@), sp::top(old(m).g@).base as int,
            sp::top(old(m).g@).ret as int, gu)),
        accepts(p.ap@, p.cert@, p.trusted@),
    ensures
        final(m).rok(*final(r)), ipok(p, *final(r)), final(m).with(*final(r)).refines(p), gate_ok(p, *final(m)),
        sp::enter_finally(p.ap@, sp::pop_frame(old(m).g@), sp::top(old(m).g@).base as int,
            sp::top(old(m).g@).ret as int, gu) == Outcome2::Next(final(m).g@),
        room_ok(p, final(m).with(*final(r))),
{
    let ghost ap = p.ap@;
    let ghost g0 = m.g@;
    let ghost m0 = m.with(*r);
    let ghost n = g0.frames.len() as int;
    let ghost addr = m0.addr();
    proof {
        m0.lemma_frame(p);
        assert(m0.ftop == FRAME_WORDS * n);
        lemma_rec_index(n, n - 1, FRAME_RET);
        lemma_rec_index(n, n - 1, FRAME_BASE);
        lemma_rec_index(n, n - 2, FRAME_METHOD);
        lemma_rec_index(n, n - 2, FRAME_BASE);
        assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
        assert(rec(m0.mem@, n - 1, FRAME_BASE) == g0.frames[n - 1].base);
        assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
        assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
        assert(base_step(g0, n - 2));
        assert(sp::valid_method(ap, g0.frames[n - 2].method as int));
        assert(const_ok(g0.heap, ap.roots[0]));
    }
    let rec_ = r.fr.offset(-(FRAME_WORDS as isize));
    let crec = r.fr.offset(-((2 * FRAME_WORDS) as isize));
    let ret = rec_.read(FRAME_RET, &m.mem);
    let height = rec_.read(FRAME_BASE, &m.mem);
    let base = crec.read(FRAME_BASE, &m.mem);
    let (value, wa, wb, reason) = crate::unwind::token_words(p, u, Ghost(addr), Ghost(gu));
    let ghost s1 = sp::pop_frame(g0);
    let ghost d = sp::pending_of(gu);
    let ghost gi = (n - 2) as usize;
    let ghost hh = height as int;
    proof {
        assert(ret == sp::top(g0).ret && height == sp::top(g0).base);
        assert(sp::base(s1) == base);
        assert(height <= g0.stack.len());
        // The four slots fit above the remaining frame records.
        assert(m0.top <= m0.len - hh);
        assert(m0.ftop <= m0.top);
        assert(m0.len - hh - 4 >= m0.ftop - FRAME_WORDS);
    }
    let s = r.end.offset(-((height + 4) as isize));
    s.write(3, value, &mut m.mem);
    s.write(2, wa, &mut m.mem);
    s.write(1, wb, &mut m.mem);
    s.write(0, reason, &mut m.mem);
    r.sp = s;
    r.fp = r.end.offset(-(base as isize));
    r.fr = rec_;
    r.ip = p.code.cursor(ret);
    let ghost s1c = State2 { stack: s1.stack.subrange(0, hh), bci: ret, ..s1 };
    let ghost g2 = sp::push(sp::push(sp::push(sp::push(s1c, sp::value_of(ap, gu)),
        Value::Token(false, d, gi, height)), Value::Token(true, d, gi, height)),
        toit_spec::spec_common::smi(sp::reason_of(gu)));
    proof {
        assert(sp::top_index(s1) == gi);
        assert(sp::enter_finally(ap, s1, hh, ret as int, gu) == Outcome2::Next(g2));
        toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g2);
    }
    m.g = Ghost(g2);
    proof {
        let m1 = m.with(*r);
        let fr2 = g0.frames.drop_last();
        lemma_frames_pop(m0.mem@, g0.frames);
        assert forall|i: int| 0 <= i < FRAME_WORDS * fr2.len() implies #[trigger] m1.mem@[i] == m0.mem@[i] by {}
        lemma_frames_rel_same(m0.mem@, m1.mem@, fr2);
        assert(g2.frames == fr2);
        // The object stack.
        assert(g2.stack.len() == hh + 4);
        assert forall|j: int| 0 <= j < hh + 4 implies #[trigger] m1.words()[j] == enc(addr, g2.stack[j]) by {
            assert(m1.words()[j] == m1.mem@[m1.len - 1 - j]);
            if j < hh {
                assert(m1.mem@[m1.len - 1 - j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == m0.mem@[m0.len - 1 - j]);
                assert(m0.words()[j] == enc_seq(addr, g0.stack)[j]);
                assert(g2.stack[j] == g0.stack[j]);
            } else if j == hh {
                assert(g2.stack[j] == sp::value_of(ap, gu));
            } else if j == hh + 1 {
                assert(g2.stack[j] == Value::Token(false, d, gi, height));
            } else if j == hh + 2 {
                assert(g2.stack[j] == Value::Token(true, d, gi, height));
            } else {
                assert(g2.stack[j] == toit_spec::spec_common::smi(sp::reason_of(gu)));
            }
        }
        assert(m1.words() =~= enc_seq(addr, g2.stack));
        assert forall|j: int| 0 <= j < g2.stack.len() implies #[trigger] encodable(addr, g2.stack[j]) by {
            if j < hh { assert(g2.stack[j] == g0.stack[j]); }
        }
        assert(m1.method == rec(m0.mem@, n - 2, FRAME_METHOD));
        assert(m1.refines(p));
        assert forall|i: int| 0 <= i < g2.frames.len() implies #[trigger] frame_room(p, m1, i) by {
            assert(g2.frames[i] == g0.frames[i]);
            assert(frame_room(p, m0, i));
        }
    }
}

} // verus!
