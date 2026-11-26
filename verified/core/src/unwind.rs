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

//! Unwinding, verified (format note 23): the loop over frames
//! (`spec::unwind`), entering finally code with the unwinding in its two
//! token slots (`Machine::enter_finally`, calls.rs), and the handlers of
//! THROW, TRY and UNWIND. Unwinding allocates nothing, so no GC point lies
//! on these paths and the words of the unwinding stay valid. Raising (which
//! allocates the exception) is raise.rs, on top of this loop; TRY never
//! raises for an accepted program (the verifier types its operand).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use crate::calls::*;
use toit_spec::types::{Value, Frame, Pending, Unwind};
use toit_spec::v2::types::{State2, Program2, Outcome2, Halt2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, bases_ok, base_step, step_ok, outcome_ok, cur_op, top_i, kinds_of, fmethod, fbase};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, cur_k, cur_m, cur_off};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_call_ops::lemma_slot_method;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, post, block_slot, kind_method};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::bytecodes::opcode_length2;

verus! {

// ---------------------------------------------------------------------------
// Unwindings as words.

/// An unwinding in progress (`types::Unwind`): the value words are object
/// references or smis, valid because unwinding has no GC point.
pub enum Unw {
    Throw(usize),
    Return(usize, usize),
    Branch(usize, usize, usize),
}

/// The words `w` represent the unwinding `u`.
pub open spec fn unw_rel(addr: Seq<usize>, w: Unw, u: Unwind) -> bool {
    match w {
        Unw::Throw(x) => u is Throw && x == enc(addr, u->Throw_0) && encodable(addr, u->Throw_0),
        Unw::Return(f, x) => u is Return && f == u->Return_0 && x == enc(addr, u->Return_1)
            && encodable(addr, u->Return_1),
        Unw::Branch(f, b, h) => u == Unwind::Branch(f, b, h),
    }
}

/// An optional unwinding (`None`: a normal completion) as words.
pub open spec fn unw_opt_rel(addr: Seq<usize>, w: Option<Unw>, u: Option<Unwind>) -> bool {
    match (w, u) {
        (None, None) => true,
        (Some(x), Some(y)) => unw_rel(addr, x, y),
        _ => false,
    }
}

/// The unwinding fits a token's words (`abs::pending_encodable`).
pub open spec fn unw_ok(u: Unwind) -> bool {
    pending_encodable(sp::pending_of(Some(u)))
}

/// A token word decodes: the first word's frame and height, the second
/// word's bci and kind.
pub proof fn lemma_token_words(f: usize, h: usize, b: usize, k: usize)
    requires f < 0x4000, h < 0x1_0000, b < 0x1000_0000, k < 4,
    ensures
        ((f << 17usize) | (h << 1usize)) as int == 2 * (f * 0x1_0000 + h),
        (f << 17usize) as int == 2 * (f * 0x1_0000),
        ((b << 3usize) | (k << 1usize)) as int == 2 * (b * 4 + k),
        ((f << 17usize) | (h << 1usize)) >> 17usize == f,
        (((f << 17usize) | (h << 1usize)) >> 1usize) & 0xffff == h,
        (((b << 3usize) | (k << 1usize)) >> 1usize) & 3 == k,
        ((b << 3usize) | (k << 1usize)) >> 3usize == b,
{
    let wa: usize = (f << 17usize) | (h << 1usize);
    let wf: usize = f << 17usize;
    let wb: usize = (b << 3usize) | (k << 1usize);
    assert(wa == (f * 0x1_0000 + h) * 2) by (bit_vector)
        requires wa == (f << 17usize) | (h << 1usize), f < 0x4000, h < 0x1_0000;
    assert(wf == (f * 0x1_0000) * 2) by (bit_vector)
        requires wf == f << 17usize, f < 0x4000;
    assert(wb == (b * 4 + k) * 2) by (bit_vector)
        requires wb == (b << 3usize) | (k << 1usize), b < 0x1000_0000, k < 4;
    assert(wa >> 17usize == f && (wa >> 1usize) & 0xffff == h) by (bit_vector)
        requires wa == (f << 17usize) | (h << 1usize), f < 0x4000, h < 0x1_0000;
    assert((wb >> 1usize) & 3 == k && wb >> 3usize == b) by (bit_vector)
        requires wb == (b << 3usize) | (k << 1usize), b < 0x1000_0000, k < 4;
}

/// The value, the two token words and the reason of the finally code of
/// unwinding `u` (`None`: a normal completion; format note 23).
#[inline(always)]
pub fn token_words(p: &Program, u: Option<Unw>, Ghost(addr): Ghost<Seq<usize>>, Ghost(gu): Ghost<Option<Unwind>>)
    -> (r: (usize, usize, usize, usize))
    requires
        unw_opt_rel(addr, u, gu),
        match gu { Some(x) => unw_ok(x), None => true },
        p.null == enc(addr, sp::null2(p.ap@)),
    ensures ({
        let d = sp::pending_of(gu);
        &&& r.0 == enc(addr, sp::value_of(p.ap@, gu))
        &&& r.1 == token_a(d)
        &&& r.2 == token_b(d)
        &&& r.3 == smi_word(sp::reason_of(gu) as i64)
    }),
{
    proof {
        lemma_smi_word(-1i64);
        lemma_smi_word(-2i64);
        lemma_token_vals(sp::pending_of(gu));
    }
    match u {
        None => {
            proof { lemma_token_words(0, 0, 0, 0); }
            (p.null, 0, 0, smi_of(-1))
        },
        Some(Unw::Throw(x)) => {
            proof { lemma_token_words(0, 0, 0, 1); }
            (x, 0, 2, smi_of(-2))
        },
        Some(Unw::Return(f, x)) => {
            proof { lemma_token_words(f, 0, 0, 2); }
            (x, f << 17usize, 4, smi_of(-1))
        },
        Some(Unw::Branch(f, b, h)) => {
            proof { lemma_token_words(f, h, b, 3); }
            (p.null, (f << 17usize) | (h << 1usize), (b << 3usize) | (3usize << 1usize), smi_of(-1))
        },
    }
}

impl Machine {
    /// `spec::unwind(g, u)`: completes a non-local return or branch in its
    /// frame, or pops frames; a try block hands the unwinding to the
    /// finally code of the frame below; an exception passing the bottom
    /// frame ends the task.
    #[inline(never)]
    pub fn do_unwind(&mut self, env: &Env, u: Unw, Ghost(gu): Ghost<Unwind>) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            shape_ok(&env.p, old(self).g@),
            unw_rel(old(self).addr(), u, gu),
            unw_ok(gu),
            !(sp::unwind(env.p.ap@, old(self).g@, gu) is Stuck),
        ensures
            matches(&env.p, sp::unwind(env.p.ap@, old(self).g@, gu), *final(self), r),
            final(self).len == old(self).len,
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost o = sp::unwind(ap, self.g@, gu);
        let ghost addr = self.addr();
        loop
            invariant
                self.refines(p),
                shape_ok(p, self.g@),
                self.addr() == addr,
                unw_rel(addr, u, gu),
                unw_ok(gu),
                sp::unwind(ap, self.g@, gu) == o,
                !(o is Stuck),
                o == sp::unwind(ap, old(self).g@, gu),
                p == (&env.p),
                ap == p.ap@,
                self.len == old(self).len,
            decreases self.g@.frames.len(),
        {
            let ghost g = self.g@;
            let ghost n = g.frames.len() as int;
            proof {
                self.lemma_frame(p);
                assert(self.ftop - FRAME_WORDS == FRAME_WORDS * (n - 1));
                assert(((self.ftop - FRAME_WORDS) as int) / (FRAME_WORDS as int) == n - 1);
                lemma_base_le_len_c(g);
            }
            let fi = (self.ftop - FRAME_WORDS) / FRAME_WORDS;
            match u {
                Unw::Return(f, x) => {
                    if f == fi {
                        proof { assert(sp::unw_target(gu) == sp::top_index(g)); }
                        return self.do_return(env, x, Ghost(gu->Return_1));
                    }
                },
                Unw::Branch(f, b, hh) => {
                    if f == fi {
                        proof { assert(sp::unw_target(gu) == sp::top_index(g)); }
                        let ghost m0 = *self;
                        self.top = self.len - hh;
                        self.bci = b;
                        let ghost g1 = State2 { stack: g.stack.subrange(0, hh as int), bci: b, ..g };
                        self.g = Ghost(g1);
                        proof {
                            assert forall|i: int| 0 <= i < hh implies #[trigger] self.words()[i] == m0.words()[i] by {}
                            assert(self.words() =~= m0.words().subrange(0, hh as int));
                            assert(self.words() =~= enc_seq(addr, g1.stack));
                            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(addr, g1.stack[i]) by {
                                assert(g1.stack[i] == g.stack[i]);
                            }
                            assert(self.refines(p));
                        }
                        return Ctl::Next;
                    }
                },
                Unw::Throw(_) => {},
            }
            proof { assert(sp::unw_target(gu) != sp::top_index(g)); }
            if self.ftop == FRAME_WORDS {
                // An exception passes the bottom frame (frame 0 is no try
                // block).
                proof {
                    assert(g.frames[0] == sp::top(g));
                    reveal_with_fuel(sp::unwind, 2);
                }
                env.rt.report(V2_REPORT_UNCAUGHT, self.bci, 0);
                return Ctl::Exit(RESULT_TERMINATED as u32, 1);
            }
            let (ret, base, handler) = self.pop_frame_v(p);
            if handler != 0 {
                proof {
                    assert(sp::top(g).handler);
                    assert(o == sp::enter_finally(ap, self.g@, sp::top(g).base as int, sp::top(g).ret as int, Some(gu)));
                    lemma_base_bound(*self, p);
                }
                return self.enter_finally_v(env, base, ret, Some(u), Ghost(Some(gu)));
            }
        }
    }
}

/// The top frame's base is at most the stack's length (and below the
/// stack length bound).
pub proof fn lemma_base_le_len_c(g: State2)
    requires bases_ok(g), g.frames.len() > 0,
    ensures g.frames.last().base <= g.stack.len(),
{}

/// Heights of a refined machine fit the stack length bound.
pub proof fn lemma_base_bound(m: Machine, p: &Program)
    requires m.refines(p),
    ensures m.g@.stack.len() < MAX_STACK_LENGTH,
{
    m.lemma_frame(p);
}

// ---------------------------------------------------------------------------
// Handlers. THROW, UNWIND, NON_LOCAL_RETURN and NON_LOCAL_BRANCH each
// prepare an unwinding (`prep_*`); `op_unwinding` runs the one unwinding
// loop for all of them, so that the loop is inlined into the run loop once
// (four copies cost about 5 percent of the instructions of richards in the
// loop head, `step.rs`).

/// What a `prep_*` function leaves: the instruction completed (`Done`), or
/// the machine is ready for `do_unwind(u)` from a state whose unwinding is
/// the spec's step.
pub enum Prep {
    Done(Ctl),
    Unwind(Unw),
}

/// `m1` is ready to run the unwinding `u` (`gu`) that is the spec's step
/// from `m0`.
pub open spec fn unwind_ready(p: &Program, m0: Machine, m1: Machine, u: Unw, gu: Unwind) -> bool {
    &&& m0.inv(p)
    &&& step_ok(p.ap@, p.cert@, m0.g@)
    &&& m1.refines(p)
    &&& shape_ok(p, m1.g@)
    &&& unw_rel(m1.addr(), u, gu)
    &&& unw_ok(gu)
    &&& sp::step(p.ap@, m0.g@) == sp::unwind(p.ap@, m1.g@, gu)
    &&& !(sp::unwind(p.ap@, m1.g@, gu) is Stuck)
}

pub open spec fn prep_post(p: &Program, m0: Machine, m1: Machine, r: (Prep, Ghost<Unwind>)) -> bool {
    match r.0 {
        Prep::Done(c) => step_post(p, m0, m1, c)
            && (c == Ctl::Next ==> frames_prefix(m0.g@, m1.g@) && m1.len == m0.len),
        Prep::Unwind(u) => unwind_ready(p, m0, m1, u, r.1@) && m1.g@.frames == m0.g@.frames && m1.len == m0.len,
    }
}

/// THROW, NON_LOCAL_RETURN, NON_LOCAL_BRANCH hd off and UNWIND.
#[inline(always)]
pub fn op_unwinding(m: &mut Machine, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        opcode == 90 || opcode == 93 || opcode == 95 || opcode == 99,
        opcode == 90 ==> sp::has_slot(old(m).g@, 0)
            && sp::step(env.p.ap@, old(m).g@) == sp::unwind(env.p.ap@, old(m).g@, Unwind::Throw(sp::at(old(m).g@, 0))),
        opcode == 93 ==> sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
        opcode == 95 ==> off < 0x1_0000_0000
            && sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
        opcode == 99 ==> bci + 1 < 0x1000_0000
            && sp::step(env.p.ap@, old(m).g@) == sp::op_unwind(env.p.ap@, old(m).g@),
    ensures
        step_post(&env.p, *old(m), *final(m), r),
        r == Ctl::Next ==> frames_prefix(old(m).g@, final(m).g@) && final(m).len == old(m).len,
{
    let ghost m0 = *m;
    let (pr, gu) = if opcode == 90 {
        prep_throw(m, env, bci, opcode)
    } else if opcode == 93 {
        prep_non_local_return(m, env, bci, opcode)
    } else if opcode == 95 {
        prep_non_local_branch(m, env, bci, opcode, hd, off)
    } else {
        prep_unwind(m, env, bci, opcode)
    };
    match pr {
        Prep::Done(c) => c,
        Prep::Unwind(u) => {
            let ghost m1 = *m;
            let r = m.do_unwind(env, u, gu);
            proof {
                lemma_matches(&env.p, m0, *m, r);
                lemma_unwind_prefix(env.p.ap@, m1.g@, gu@);
                if r == Ctl::Next {
                    assert forall|i: int| 0 <= i < m.g@.frames.len() implies #[trigger] m.g@.frames[i] == m0.g@.frames[i] by {
                        assert(m.g@.frames[i] == m1.g@.frames[i]);
                    }
                }
            }
            r
        },
    }
}

/// THROW: unwinds with the top value.
#[inline(always)]
pub fn prep_throw(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        sp::has_slot(old(m).g@, 0),
        sp::step(env.p.ap@, old(m).g@) == sp::unwind(env.p.ap@, old(m).g@, Unwind::Throw(sp::at(old(m).g@, 0))),
    ensures prep_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
        lemma_shape(p, g);
    }
    let w = m.at(0);
    (Prep::Unwind(Unw::Throw(w)), Ghost(Unwind::Throw(sp::at(g, 0))))
}

/// UNWIND: the end of finally code. A normal token continues; any other
/// token resumes its unwinding (with the value slot), read from the token's
/// two words.
#[inline(always)]
pub fn prep_unwind(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_unwind(env.p.ap@, old(m).g@),
        bci + 1 < 0x1000_0000,
    ensures prep_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost addr = m.addr();
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        m.lemma_at(p, 1);
        m.lemma_at(p, 2);
        m.lemma_at(p, 3);
        lemma_shape(p, g);
    }
    let ghost d = sp::token_at(g)->0;
    let wb = m.at(1);
    let wa = m.at(2);
    let x = m.at(3);
    let ghost v = sp::at(g, 3);
    proof {
        assert(sp::token_at(g) is Some);
        assert(sp::at(g, 2) == Value::Token(false, d, sp::at(g, 2)->Token_2, sp::at(g, 2)->Token_3));
        assert(sp::at(g, 1) == Value::Token(true, d, sp::at(g, 2)->Token_2, sp::at(g, 2)->Token_3));
        assert(wa == token_a(d) && wb == token_b(d));
        assert(pending_encodable(d));
        lemma_token_vals(d);
        match d {
            Pending::Normal => { lemma_token_words(0, 0, 0, 0); },
            Pending::Throw => { lemma_token_words(0, 0, 0, 1); },
            Pending::Return(f) => { lemma_token_words(f, 0, 0, 2); },
            Pending::Branch(f, nb, hb) => { lemma_token_words(f, hb, nb, 3); },
        }
    }
    let kind = (wb >> 1usize) & 3;
    if kind == 0 {
        proof { assert(d == Pending::Normal); assert(sp::op_unwind(ap, g) == sp::op_pop(g, 4, 1)); }
        let r = m.op_pop(p, 4, 1);
        proof { lemma_matches(p, m0, *m, r); }
        return (Prep::Done(r), Ghost(Unwind::Throw(v)));
    }
    let f = wa >> 17usize;
    let ghost gu = match d {
        Pending::Throw => Unwind::Throw(v),
        Pending::Return(f) => Unwind::Return(f, v),
        Pending::Branch(f, nb, hb) => Unwind::Branch(f, nb, hb),
        Pending::Normal => Unwind::Throw(v),
    };
    let u = if kind == 1 {
        Unw::Throw(x)
    } else if kind == 2 {
        Unw::Return(f, x)
    } else {
        Unw::Branch(f, wb >> 3usize, (wa >> 1usize) & 0xffff)
    };
    proof {
        assert(unw_rel(addr, u, gu));
        assert(sp::pending_of(Some(gu)) == d);
        assert(unw_ok(gu));
    }
    // Pop reason, token words and value.
    m.drop_vals(p, 4);
    let ghost g2 = m.g@;
    proof {
        assert(g2 == sp::drop(g, 4));
        assert(sp::op_unwind(ap, g) == sp::unwind(ap, g2, gu));
        assert forall|fi: int| 0 <= fi && fi + 1 < g2.frames.len() implies #[trigger] base_step(g2, fi) by {
            assert(base_step(g, fi));
        }
        assert(bases_ok(g2));
        assert(shape_ok(p, g2));
    }
    (Prep::Unwind(u), Ghost(gu))
}

/// The frame of the block reference word `w` of `BlockRef(f, s)`.
#[inline(always)]
pub fn ref_frame(w: usize, Ghost(f): Ghost<usize>, Ghost(s): Ghost<usize>) -> (r: usize)
    requires w == block_word(f, s), f < 0x4000, s < MAX_STACK_LENGTH,
    ensures r == f,
{
    proof {
        crate::blocks::lemma_block_decode(f, s);
        assert(w == (f * 0x1_0000 + s) * 2);
        assert(w >> 17 == f) by (bit_vector)
            requires w == (f * 0x1_0000 + s) * 2, f < 0x4000, s < 0x1_0000;
    }
    w >> 17
}

/// NON_LOCAL_RETURN: returns the value below the block reference from the
/// block's frame, running the finally code of the frames in between.
#[inline(always)]
pub fn prep_non_local_return(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_return(env.p.ap@, old(m).g@),
    ensures prep_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
        lemma_shape(p, g);
    }
    let ghost v = sp::at(g, 0);
    let w = m.at(0);
    let f = ref_frame(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let x = m.at(1);
    let ghost gu = Unwind::Return(f, sp::at(g, 1));
    proof {
        assert(sp::op_non_local_return(ap, g) == sp::unwind(ap, g, gu));
        assert(f < 0x4000);
    }
    (Prep::Unwind(Unw::Return(f, x)), Ghost(gu))
}

/// NON_LOCAL_BRANCH hd off: continues in the block's frame at `off` from
/// its method's entry, with the object stack cut to `hd` slots below the
/// end of the block's slot, running the finally code of the frames in
/// between.
#[inline(always)]
pub fn prep_non_local_branch(m: &mut Machine, env: &Env, bci: usize, opcode: u8, hd: usize, off: usize) -> (r: (Prep, Ghost<Unwind>))
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_non_local_branch(env.p.ap@, old(m).g@, hd as int, off as int),
        off < 0x1_0000_0000,
    ensures prep_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        m.lemma_at(p, 0);
        lemma_shape(p, g);
    }
    let ghost v = sp::at(g, 0);
    let w = m.at(0);
    let f = ref_frame(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    let slot = crate::blocks::ref_slot(w, Ghost(v->BlockRef_0), Ghost(v->BlockRef_1));
    proof {
        assert(f < g.frames.len());
        assert(rec(m.mem@, f as int, FRAME_METHOD) == g.frames[f as int].method);
        lemma_rec_index(g.frames.len() as int, f as int, FRAME_METHOD);
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
    proof {
        assert(sp::op_non_local_branch(ap, g, hd as int, off as int) == sp::unwind(ap, g, gu));
        assert(f < 0x4000);
        assert(h <= g.stack.len());
        assert(target < p.code@.len());
    }
    (Prep::Unwind(Unw::Branch(f, target, h)), Ghost(gu))
}

/// TRY's operand is a block method of arity 1 for an accepted program
/// (as in `sound_call_ops::lemma_step_try`): TRY never raises.
pub proof fn lemma_try_target(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        cur_op(p.ap@, g) == 97,
    ensures
        sp::has_slot(g, 0),
        sp::block_target(p.ap@, g, g.stack.len() - 1) is Some,
        sp::arity(p.ap@, sp::block_target(p.ap@, g, g.stack.len() - 1)->0) == 1,
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let m = cur_m(g);
    let off = cur_off(ap, g);
    let k = cur_k(ap, c, g);
    let h = k.len() as int;
    let t0 = top_i(g);
    assert(opcode_length2(97) == 1);
    assert(post(ap, c, m, off, k, p.trusted@) is Some);
    let tt = kind_method(k[h - 1]);
    assert(1 <= h && block_slot(ap, c, m, k, h - 1) && sp::arity(ap, tt) == 1);
    lemma_slot_method(ap, c, p.trusted@, g, t0, h - 1);
    assert(sp::block_target(ap, g, g.stack.len() - 1) == Some(tt));
}

/// Pushes the reference to the block's slot and the try block's frame
/// (with the handler flag), without the room check of a call and without
/// the preemption point: `spec::op_try`'s next state. `false` (LIMIT) if
/// the five words are not free.
#[inline(always)]
pub fn enter_try_block(m: &mut Machine, p: &Program, bci: usize) -> (ok: bool)
    requires
        old(m).inv(p),
        cur_op(p.ap@, old(m).g@) == 97,
        old(m).bci == bci, old(m).g@.bci == bci,
        bci + 1 < 0x1000_0000,
    ensures
        ok ==> final(m).refines(p) && sp::op_try(p.ap@, old(m).g@) == Outcome2::Next(final(m).g@),
        final(m).len == old(m).len,
{
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost n = g.frames.len() as int;
    proof {
        m.lemma_frame(p);
        lemma_try_target(p, g);
        lemma_frames_wf(p, g);
        m.lemma_at(p, 0);
    }
    let ghost tt = sp::block_target(ap, g, g.stack.len() - 1)->0;
    let mw = m.at(0);
    proof {
        assert(g.stack[g.stack.len() - 1] == sp::at(g, 0));
        assert(g.stack[g.stack.len() - 1] == Value::Smi(tt as i64));
        assert(0 <= tt < ap.methods.len());
        lemma_smi_word_nat(tt as i64);
        assert(mw == 2 * tt);
        assert(mw >> 1 == mw / 2) by (bit_vector);
    }
    let t = mw >> 1;
    let height = m.len - m.top;
    let rr = m.ftop - FRAME_WORDS;
    proof {
        assert(rr == FRAME_WORDS * (n - 1));
        assert(rr / FRAME_WORDS == n - 1);
    }
    let fi = rr / FRAME_WORDS;
    // The reference to the block's slot.
    let slot = height - 1;
    let ghost br = Value::BlockRef(fi, slot);
    proof { assert(fi < 0x4000 && slot < MAX_STACK_LENGTH); }
    let w = smi_of((fi * 0x1_0000 + slot) as i64);
    if !m.push_val(p, w, Ghost(br)) {
        return false;
    }
    if m.top - m.ftop < FRAME_WORDS {
        return false;
    }
    proof {
        assert(sp::top_index(g) == n - 1);
        assert(sp::op_try(ap, g) == sp::try_call(ap, sp::push(g, br), tt, g.bci + 1));
        assert(t == tt);
    }
    m.push_frame(p, t, bci + 1, 1);
    true
}

/// TRY: calls the try block, whose method is the top slot, with a
/// reference to that slot, as a try block (format note 23). Without room
/// for the call, the stack grows (and the TRY runs again); if it cannot,
/// the error is raised in the try block (`prim::resource_state`), so the
/// TRY's finally code runs.
#[inline(always)]
pub fn op_try(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        toit_spec::v2::prim::grows_stack(opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_try(env.p.ap@, old(m).g@),
        cur_op(env.p.ap@, old(m).g@) == 97,
        bci + 1 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    proof { assert(env.p.max_height < 0x1_0000); }
    // A call's room and the block reference TRY pushes first (as the
    // register path's gate, `regs::gate_ok`), so that the try block's
    // frame has its room (`room::room_ok`).
    let needed = FRAME_WORDS + env.p.max_height + STACK_RESERVE + 1;
    if m.top - m.ftop < needed {
        return try_grow(m, env, bci, needed);
    }
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof { assert(outcome_ok(ap, p.cert@, sp::step(ap, g))); }
    if !enter_try_block(m, p, bci) {
        return Ctl::Stuck(stuck::LIMIT);
    }
    let r = if env.pre.requested() {
        env.pre.clear();
        Ctl::Exit(RESULT_PREEMPTED as u32, 0)
    } else {
        Ctl::Next
    };
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// TRY without room for the call: grows the stack (a GC point; the TRY
/// runs again), or, if it cannot grow, raises the stack-overflow error or
/// throws the out-of-memory error from the try block's frame
/// (`prim::resource_state`, format note 23: the finally code runs).
#[inline(never)]
pub fn try_grow(m: &mut Machine, env: &Env, bci: usize, needed: usize) -> (r: Ctl)
    requires
        old(m).inv(&env.p),
        needed < GROW_STACK_MAX_NEEDED,
        cur_op(env.p.ap@, old(m).g@) == 97,
        old(m).bci == bci, old(m).g@.bci == bci,
        bci + 1 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        lemma_instr(ap, p.cert@, p.trusted@, g);
        assert(toit_spec::v2::prim::grows_stack(ap.bytecodes[g.bci as int]));
    }
    m.save();
    proof { crate::alloc::lemma_saved(p, *m); }
    let status = gc_grow_stack(m, env, needed, Ghost(g));
    // The collections reached `g2`; the instruction has not run.
    let ghost g2 = choose|g2: State2| #[trigger] grow_post(p, *m, g, g2, needed, status);
    crate::alloc::reload(m, p, Ghost(g2));
    let ghost m1 = *m;
    proof {
        lemma_inv_gc(p, m0, m1);
        toit_spec::v2::gc::lemma_gc_steps_refl(ap, g2);
    }
    if status == V2_OK {
        proof { lemma_advances_gc_only(ap, g, g2); }
        return Ctl::Next;
    }
    // The try block is entered first (the resource throw's state).
    if !enter_try_block(m, p, bci) {
        return Ctl::Stuck(stuck::LIMIT);
    }
    let ghost s1 = m.g@;
    proof {
        lemma_small(p, &m1);
        lemma_small(p, &*m);
        toit_spec::v2::sound_call_ops::lemma_step_try(ap, p.cert@, p.trusted@, g2);
        assert(sp::step(ap, g2) == sp::op_try(ap, g2)) by { reveal(sp::step); }
        assert(toit_spec::v2::prim::resource_state(ap, g2) == s1);
        assert(wf(ap, p.cert@, s1));
        lemma_shape(p, s1);
    }
    if status == V2_STACK_OVERFLOW {
        let ghost v = ap.roots[ROOT_STACK_OVERFLOW as int];
        proof {
            assert(toit_spec::v2::prim::resource_throw(ap, g2, Outcome2::Raise(s1, v)));
            lemma_source_resource(ap, g2, Outcome2::Raise(s1, v));
            m.lemma_root(p, ROOT_STACK_OVERFLOW as int);
        }
        let value = p.roots.at(ROOT_STACK_OVERFLOW);
        let r = m.raise_with(env, Ghost(m1), value, Ghost(v), V2_MESSAGE_NONE, [0, 0, 0, 0], 0, Ghost(Seq::empty()));
        proof {
            toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.g@);
            lemma_step_post_gc(p, m0, m1, *m, *m, r);
        }
        return r;
    }
    let ghost u = Unwind::Throw(ap.roots[ROOT_OUT_OF_MEMORY_ERROR as int]);
    let ghost o1 = sp::unwind(ap, s1, u);
    proof {
        m.lemma_root(p, ROOT_OUT_OF_MEMORY_ERROR as int);
        assert(toit_spec::v2::prim::resource_throw(ap, g2, o1));
        lemma_source_resource(ap, g2, o1);
        lemma_unwind_not_raise(ap, s1, u);
        lemma_source_outcome(p, m1, o1);
        assert(ap.roots.len() == 35);
        assert(p.roots@[ROOT_OUT_OF_MEMORY_ERROR as int] == enc(m.addr(), ap.roots[ROOT_OUT_OF_MEMORY_ERROR as int])
            && const_ok(s1.heap, ap.roots[ROOT_OUT_OF_MEMORY_ERROR as int]));
    }
    let w = p.roots.at(ROOT_OUT_OF_MEMORY_ERROR);
    let r = m.do_unwind(env, Unw::Throw(w), Ghost(u));
    proof {
        lemma_outcome_matches(p, m1, *m, r, o1);
        toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.g@);
        lemma_step_post_gc(p, m0, m1, *m, *m, r);
    }
    r
}

// ---------------------------------------------------------------------------
// The frames after an unwinding.

/// The frames of `g1` are the first frames of `g0`.
pub open spec fn frames_prefix(g0: State2, g1: State2) -> bool {
    &&& g1.frames.len() <= g0.frames.len()
    &&& forall|i: int| 0 <= i < g1.frames.len() ==> #[trigger] g1.frames[i] == g0.frames[i]
}

/// Entering a finally code keeps the frames.
pub proof fn lemma_finally_prefix(ap: Program2, s: State2, h: int, bci: int, u: Option<Unwind>)
    ensures sp::enter_finally(ap, s, h, bci, u) is Next ==> frames_prefix(s, sp::enter_finally(ap, s, h, bci, u)->Next_0),
{}

/// A return pops the top frame (and may enter the caller's finally code).
pub proof fn lemma_return_prefix(ap: Program2, s: State2, v: Value)
    ensures sp::return_from(ap, s, v) is Next ==> frames_prefix(s, sp::return_from(ap, s, v)->Next_0),
{
    if s.frames.len() > 1 && !(sp::top(s).base as int > s.stack.len()) {
        let s1 = sp::pop_frame(s);
        assert forall|i: int| 0 <= i < s1.frames.len() implies #[trigger] s1.frames[i] == s.frames[i] by {}
        lemma_finally_prefix(ap, s1, sp::top(s).base as int, sp::top(s).ret as int, None);
        if sp::enter_finally(ap, s1, sp::top(s).base as int, sp::top(s).ret as int, None) is Next {
            let g = sp::enter_finally(ap, s1, sp::top(s).base as int, sp::top(s).ret as int, None)->Next_0;
            assert forall|i: int| 0 <= i < g.frames.len() implies #[trigger] g.frames[i] == s.frames[i] by {
                assert(g.frames[i] == s1.frames[i]);
            }
        }
        let r1 = State2 {
            stack: s.stack.subrange(0, sp::top(s).base as int).push(v),
            frames: s.frames.drop_last(),
            bci: sp::top(s).ret,
            ..s
        };
        assert forall|i: int| 0 <= i < r1.frames.len() implies #[trigger] r1.frames[i] == s.frames[i] by {}
    }
}

/// An unwinding only pops frames: the state it continues in (entering
/// finally code, completing a non-local return or branch) has the first
/// frames of the state it starts from (`room::local_room` needs no rescan).
pub proof fn lemma_unwind_prefix(ap: Program2, s: State2, u: Unwind)
    ensures sp::unwind(ap, s, u) is Next ==> frames_prefix(s, sp::unwind(ap, s, u)->Next_0),
    decreases s.frames.len(),
{
    if s.frames.len() > 0 && !(sp::top(s).base as int > s.stack.len()) {
        let s1 = sp::pop_frame(s);
        if sp::unw_target(u) == sp::top_index(s) {
            match u {
                Unwind::Return(f, v) => { lemma_return_prefix(ap, s, v); },
                _ => {},
            }
        } else if sp::top(s).handler {
            lemma_finally_prefix(ap, s1, sp::top(s).base as int, sp::top(s).ret as int, Some(u));
            if sp::unwind(ap, s, u) is Next {
                let g = sp::unwind(ap, s, u)->Next_0;
                assert forall|i: int| 0 <= i < g.frames.len() implies #[trigger] g.frames[i] == s.frames[i] by {
                    assert(g.frames[i] == s1.frames[i]);
                }
            }
        } else {
            lemma_unwind_prefix(ap, s1, u);
            if sp::unwind(ap, s1, u) is Next {
                let g = sp::unwind(ap, s1, u)->Next_0;
                assert forall|i: int| 0 <= i < g.frames.len() implies #[trigger] g.frames[i] == s.frames[i] by {
                    assert(g.frames[i] == s1.frames[i]);
                    assert(s1.frames[i] == s.frames[i]);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Throwing the out-of-memory error.

/// Unwinding never raises (it allocates nothing).
pub proof fn lemma_unwind_not_raise(ap: Program2, s: State2, u: Unwind)
    ensures !(sp::unwind(ap, s, u) is Raise),
    decreases s.frames.len(),
{
    if s.frames.len() > 0 && !(sp::top(s).base as int > s.stack.len()) {
        if sp::unw_target(u) != sp::top_index(s) && !sp::top(s).handler {
            lemma_unwind_not_raise(ap, sp::pop_frame(s), u);
        }
    }
}

/// Throws the out-of-memory error (`prim::out_of_memory`, roots[4]; nothing
/// is allocated): `spec::unwind(g, Throw(out_of_memory))`, where that is a
/// source of outcomes (a resource throw).
#[inline(always)]
pub fn throw_oom(m: &mut Machine, env: &Env) -> (r: Ctl)
    requires
        old(m).inv(&env.p),
        source(env.p.ap@, old(m).g@,
            sp::unwind(env.p.ap@, old(m).g@, Unwind::Throw(toit_spec::v2::prim::out_of_memory(env.p.ap@)))),
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost u = Unwind::Throw(ap.roots[ROOT_OUT_OF_MEMORY_ERROR as int]);
    proof {
        lemma_unwind_not_raise(ap, g, u);
        lemma_source_outcome(p, m0, sp::unwind(ap, g, u));
        lemma_shape(p, g);
        assert(ap.roots.len() == 35);
        assert(p.roots@[ROOT_OUT_OF_MEMORY_ERROR as int] == enc(m0.addr(), ap.roots[ROOT_OUT_OF_MEMORY_ERROR as int])
            && const_ok(g.heap, ap.roots[ROOT_OUT_OF_MEMORY_ERROR as int]));
    }
    let w = p.roots.at(ROOT_OUT_OF_MEMORY_ERROR);
    let r = m.do_unwind(env, Unw::Throw(w), Ghost(u));
    proof { lemma_outcome_matches(p, m0, *m, r, sp::unwind(ap, g, u)); }
    r
}

} // verus!
