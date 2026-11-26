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

//! Unwinding, verified (format note 17): the loop over frames
//! (`spec::unwind`), entering finally code with a finally record
//! (`spec::enter_finally` with an unwinding), and the handlers of THROW,
//! TRY and UNWIND. Unwinding allocates nothing, so no GC point lies on
//! these paths and the words of the unwinding stay valid. Raising (which
//! allocates the exception) is raise.rs, on top of this loop; TRY
//! never raises for an accepted program (the verifier types its operand).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use crate::calls::*;
use toit_spec::types::{Value, Frame, Handler, Fin, Resume, Unwind};
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

/// The resume and target words (bci, height) of the finally record of
/// unwinding `u`.
#[inline(always)]
pub fn fin_words(u: &Unw, Ghost(addr): Ghost<Seq<usize>>, Ghost(gu): Ghost<Unwind>) -> (r: (usize, usize, usize))
    requires unw_rel(addr, *u, gu), resume_ok(sp::resume_of(gu)),
    ensures
        r.0 == resume_word(sp::resume_of(gu)),
        r.1 == target_word(sp::resume_of(gu)),
        r.2 == target_height_word(sp::resume_of(gu)),
{
    match u {
        Unw::Throw(_) => (0, 0, 0),
        Unw::Return(f, _) => (1 + 4 * *f, 0, 0),
        Unw::Branch(f, b, h) => (2 + 4 * *f, *b, *h),
    }
}

/// The words of a finally record decode to its resume.
pub proof fn lemma_resume_decode(r: Resume)
    requires resume_ok(r),
    ensures
        r is Throw ==> resume_word(r) & 3 == 0,
        r is Return ==> resume_word(r) & 3 == 1 && resume_word(r) >> 2 == r->Return_0,
        r is Branch ==> resume_word(r) & 3 == 2 && resume_word(r) >> 2 == r->Branch_0
            && target_word(r) == r->Branch_1 && target_height_word(r) == r->Branch_2,
{
    match r {
        Resume::Throw => {
            assert((0usize & 3) == 0) by (bit_vector);
        },
        Resume::Return(f) => {
            let w = resume_word(r);
            assert(w == 1 + 4 * f);
            assert((w & 3) == 1 && (w >> 2) == f) by (bit_vector)
                requires w == 1 + 4 * f, f < 0x1000_0000;
        },
        Resume::Branch(f, b, h) => {
            let w = resume_word(r);
            assert(w == 2 + 4 * f);
            assert((w & 3) == 2 && (w >> 2) == f) by (bit_vector)
                requires w == 2 + 4 * f, f < 0x1000_0000;
        },
    }
}

// ---------------------------------------------------------------------------
// Records.

/// A new finally record after the others.
pub proof fn lemma_fins_rel_push(mem: Seq<usize>, ftop: int, fins: Seq<Fin>, f: Fin)
    requires
        fins_rel(mem, ftop, fins),
        fin_rel(mem, ftop, fins.len() as int, f),
        ftop + FIN_WORDS * (fins.len() + 1) <= mem.len(),
    ensures fins_rel(mem, ftop, fins.push(f)),
{
    let f2 = fins.push(f);
    assert forall|x: int| 0 <= x < f2.len() implies #[trigger] fin_rel(mem, ftop, x, f2[x]) by {
        if x < fins.len() { assert(f2[x] == fins[x]); }
    }
}

/// Clearing the top frame's handler word drops its handler (the last).
pub proof fn lemma_frames_clear(mem: Seq<usize>, mem2: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>)
    requires
        frames_rel(mem, frames, tries),
        frames.len() > 0,
        tries.len() > 0,
        tries.last().frame == frames.len() - 1,
        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
        mem2.len() == mem.len(),
        forall|i: int| 0 <= i < FRAME_WORDS * frames.len() && i != FRAME_WORDS * (frames.len() - 1) + FRAME_HANDLER
            ==> #[trigger] mem2[i] == mem[i],
        rec(mem2, frames.len() - 1, FRAME_HANDLER) == 0,
    ensures frames_rel(mem2, frames, tries.drop_last()),
{
    let n = frames.len() as int;
    let t2 = tries.drop_last();
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_METHOD) == frames[fi].method by {
        lemma_rec_index(n, fi, FRAME_METHOD);
        assert(rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD));
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_RET) == frames[fi].ret by {
        lemma_rec_index(n, fi, FRAME_RET);
        assert(rec(mem2, fi, FRAME_RET) == rec(mem, fi, FRAME_RET));
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_BASE) == frames[fi].base by {
        lemma_rec_index(n, fi, FRAME_BASE);
        assert(rec(mem2, fi, FRAME_BASE) == rec(mem, fi, FRAME_BASE));
    }
    assert forall|x: int| 0 <= x < t2.len() implies {
        &&& (#[trigger] t2[x]).frame < frames.len()
        &&& 0 < t2[x].height < 0x1_0000_0000
        &&& t2[x].bci < 0x1_0000_0000
        &&& rec(mem2, t2[x].frame as int, FRAME_HANDLER) == handler_word(t2[x])
    } by {
        assert(t2[x] == tries[x]);
        assert(tries[x].frame < tries[tries.len() - 1].frame);
        lemma_rec_index(n, tries[x].frame as int, FRAME_HANDLER);
        assert(rec(mem2, t2[x].frame as int, FRAME_HANDLER) == rec(mem, t2[x].frame as int, FRAME_HANDLER));
    }
    assert forall|fi: int| 0 <= fi < n && #[trigger] rec(mem2, fi, FRAME_HANDLER) != 0
            implies exists|x: int| 0 <= x < t2.len() && t2[x].frame == fi by {
        assert(fi != n - 1);
        lemma_rec_index(n, fi, FRAME_HANDLER);
        assert(rec(mem2, fi, FRAME_HANDLER) == rec(mem, fi, FRAME_HANDLER));
        let x = choose|x: int| 0 <= x < tries.len() && tries[x].frame == fi;
        assert(x != tries.len() - 1);
        assert(t2[x] == tries[x]);
    }
}

/// Setting the top frame's handler word installs handler `h` (the
/// handlers of the other frames stay).
pub proof fn lemma_frames_set(mem: Seq<usize>, mem2: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>, h: Handler)
    requires
        frames_rel(mem, frames, tries),
        frames.len() > 0,
        forall|x: int| 0 <= x < tries.len() ==> (#[trigger] tries[x]).frame + 1 < frames.len(),
        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
        h.frame == frames.len() - 1,
        0 < h.height < 0x1_0000_0000,
        h.bci < 0x1_0000_0000,
        mem2.len() == mem.len(),
        forall|i: int| 0 <= i < FRAME_WORDS * frames.len() && i != FRAME_WORDS * (frames.len() - 1) + FRAME_HANDLER
            ==> #[trigger] mem2[i] == mem[i],
        rec(mem2, frames.len() - 1, FRAME_HANDLER) == handler_word(h),
    ensures frames_rel(mem2, frames, tries.push(h)),
{
    let n = frames.len() as int;
    let t2 = tries.push(h);
    lemma_tries_len(tries, n - 1);
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_METHOD) == frames[fi].method by {
        lemma_rec_index(n, fi, FRAME_METHOD);
        assert(rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD));
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_RET) == frames[fi].ret by {
        lemma_rec_index(n, fi, FRAME_RET);
        assert(rec(mem2, fi, FRAME_RET) == rec(mem, fi, FRAME_RET));
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_BASE) == frames[fi].base by {
        lemma_rec_index(n, fi, FRAME_BASE);
        assert(rec(mem2, fi, FRAME_BASE) == rec(mem, fi, FRAME_BASE));
    }
    assert forall|x: int| 0 <= x < t2.len() implies {
        &&& (#[trigger] t2[x]).frame < frames.len()
        &&& 0 < t2[x].height < 0x1_0000_0000
        &&& t2[x].bci < 0x1_0000_0000
        &&& rec(mem2, t2[x].frame as int, FRAME_HANDLER) == handler_word(t2[x])
    } by {
        if x < tries.len() {
            assert(t2[x] == tries[x]);
            lemma_rec_index(n, tries[x].frame as int, FRAME_HANDLER);
                assert(rec(mem2, t2[x].frame as int, FRAME_HANDLER) == rec(mem, t2[x].frame as int, FRAME_HANDLER));
            }
    }
    assert forall|fi: int| 0 <= fi < n && #[trigger] rec(mem2, fi, FRAME_HANDLER) != 0
            implies exists|x: int| 0 <= x < t2.len() && t2[x].frame == fi by {
        if fi == n - 1 {
            let x = tries.len() as int;
            assert(t2[x] == h);
            assert(0 <= x < t2.len() && t2[x].frame == fi);
        } else {
            lemma_rec_index(n, fi, FRAME_HANDLER);
            assert(rec(mem2, fi, FRAME_HANDLER) == rec(mem, fi, FRAME_HANDLER));
            let x = choose|x: int| 0 <= x < tries.len() && tries[x].frame == fi;
            assert(t2[x] == tries[x]);
        }
    }
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

impl Machine {
    /// `spec::enter_finally(g, g.tries.last(), Some(u))`: the top frame's
    /// handler runs its finally code for the unwinding `u`. A finally record
    /// takes the handler's place; the slots are the value, the token (the
    /// record's index) and the reason.
    #[inline(always)]
    pub fn enter_finally_unwind(&mut self, env: &Env, handler: usize, hbci: usize, u: Unw, Ghost(gu): Ghost<Unwind>) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            sp::has_handler(old(self).g@),
            handler == handler_word(old(self).g@.tries.last()),
            hbci == old(self).g@.tries.last().bci,
            tries_ok(old(self).g@),
            unw_rel(old(self).addr(), u, gu),
            resume_ok(sp::resume_of(gu)),
            !(sp::enter_finally(env.p.ap@, old(self).g@, old(self).g@.tries.last(), Some(gu)) is Stuck),
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(&env.p)
                && sp::enter_finally(env.p.ap@, old(self).g@, old(self).g@.tries.last(), Some(gu))
                    == Outcome2::Next(final(self).g@),
            final(self).len == old(self).len,
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost addr = self.addr();
        let ghost h = g0.tries.last();
        let ghost n = g0.frames.len() as int;
        proof {
            self.lemma_frame(p);
            assert(g0.tries[g0.tries.len() - 1] == h);
        }
        let height = handler;
        // Room for the record and the three slots.
        if self.len - height - self.rtop < FIN_WORDS + 3 {
            return Ctl::Stuck(stuck::LIMIT);
        }
        let (resume, target, target_height) = fin_words(&u, Ghost(addr), Ghost(gu));
        let null = p.null;
        let value = match u {
            Unw::Throw(x) => x,
            Unw::Return(_, x) => x,
            Unw::Branch(_, _, _) => null,
        };
        let reason = match u {
            Unw::Throw(_) => smi_of(-2),
            _ => smi_of(-1),
        };
        let e = self.rtop;
        let rr = self.ftop - FRAME_WORDS;
        proof {
            assert(e - self.ftop == FIN_WORDS * g0.fins.len());
            let nf = g0.fins.len() as int;
            assert((FIN_WORDS as int * nf) / FIN_WORDS as int == nf) by (nonlinear_arith) requires nf >= 0;
            assert(rr == FRAME_WORDS * (n - 1));
            assert(rr / FRAME_WORDS == n - 1);
        }
        let k = (e - self.ftop) / FIN_WORDS;
        self.top = self.len - height;
        self.mem.write(rr + FRAME_HANDLER, 0);
        self.mem.write(e + FIN_FRAME, rr / FRAME_WORDS);
        self.mem.write(e + FIN_HEIGHT, height);
        self.mem.write(e + FIN_RESUME, resume);
        self.mem.write(e + FIN_TARGET, target);
        self.mem.write(e + FIN_TARGET_HEIGHT, target_height);
        self.rtop = e + FIN_WORDS;
        self.bci = hbci;
        let ghost fin = Fin { frame: h.frame, height: h.height, resume: sp::resume_of(gu) };
        let ghost g2 = State2 {
            stack: g0.stack.subrange(0, h.height as int),
            tries: g0.tries.drop_last(),
            bci: h.bci,
            fins: g0.fins.push(fin),
            ..g0
        };
        self.g = Ghost(g2);
        proof {
            let m1 = self.mem@;
            let ftop = self.ftop as int;
            // Frames: the top frame's handler is gone.
            assert forall|i: int| 0 <= i < FRAME_WORDS * n && i != FRAME_WORDS * (n - 1) + FRAME_HANDLER
                implies #[trigger] m1[i] == m0.mem@[i] by {}
            lemma_frames_clear(m0.mem@, m1, g0.frames, g0.tries);
            // Finally records: the old ones stay, the new one follows.
            assert forall|i: int| ftop <= i < ftop + FIN_WORDS * g0.fins.len()
                implies #[trigger] m1[i] == m0.mem@[i] by {}
            lemma_fins_rel_same(m0.mem@, m1, ftop, g0.fins);
            assert(h.frame == n - 1);
            assert(fin_rel(m1, ftop, g0.fins.len() as int, fin));
            lemma_fins_rel_push(m1, ftop, g0.fins, fin);
            // The object stack is cut to the handler's height.
            assert(height as int == h.height);
            assert forall|i: int| 0 <= i < height implies #[trigger] self.words()[i] == m0.words()[i] by {
                assert(self.mem@[self.len - 1 - i] == m0.mem@[self.len - 1 - i]);
            }
            assert(self.words() =~= m0.words().subrange(0, height as int));
            assert(self.words() =~= enc_seq(addr, g2.stack));
            assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(addr, g2.stack[i]) by {
                assert(g2.stack[i] == g0.stack[i]);
            }
            assert(self.refines(p));
            assert(const_ok(g0.heap, ap.roots[0]));
            lemma_smi_word(-1i64);
            lemma_smi_word(-2i64);
            lemma_smi_word(k as i64);
        }
        let ghost v = sp::value_of(ap, gu);
        if !self.push_val(p, value, Ghost(v)) { return Ctl::Stuck(stuck::LIMIT); }
        let token = smi_of(k as i64);
        if !self.push_val(p, token, Ghost(toit_spec::spec_common::smi(k as int))) { return Ctl::Stuck(stuck::LIMIT); }
        let ghost rv = match gu { Unwind::Throw(_) => -2int, _ => -1int };
        if !self.push_val(p, reason, Ghost(toit_spec::spec_common::smi(rv))) { return Ctl::Stuck(stuck::LIMIT); }
        Ctl::Next
    }

    /// `spec::pop_frame` of a frame without a handler. Returns the popped
    /// frame's return bci: the bci of the new top frame's handler, if it has
    /// one (`callees_ok`).
    #[inline(always)]
    pub fn pop_frame_v(&mut self, p: &Program) -> (ret: usize)
        requires
            old(self).refines(p),
            shape_ok(p, old(self).g@),
            old(self).g@.frames.len() > 1,
            !sp::has_handler(old(self).g@),
        ensures
            final(self).refines(p),
            final(self).g@ == sp::pop_frame(old(self).g@),
            shape0(p, final(self).g@),
            final(self).addr() == old(self).addr(),
            final(self).len == old(self).len,
            sp::has_handler(final(self).g@) ==> ret == final(self).g@.tries.last().bci,
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost n = g0.frames.len() as int;
        proof {
            self.lemma_frame(p);
            lemma_no_handler(g0);
        }
        let r = self.ftop - FRAME_WORDS;
        let c = r - FRAME_WORDS;
        let ret = self.mem.read(r + FRAME_RET);
        let method = self.mem.read(c + FRAME_METHOD);
        let base = self.mem.read(c + FRAME_BASE);
        proof {
            assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
            assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
            assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
            assert(base_step(g0, n - 2));
        }
        self.pop_records(Ghost(g0));
        let ghost mem1 = self.mem@;
        self.top = self.len - self.base;
        self.method = method;
        self.base = base;
        self.lim = self.len - base;
        let ghost g1 = sp::pop_frame(g0);
        self.g = Ghost(g1);
        proof {
            let b = sp::top(g0).base as int;
            lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
            assert forall|i: int| 0 <= i < FRAME_WORDS * g1.frames.len() implies #[trigger] self.mem@[i] == m0.mem@[i] by {}
            lemma_frames_rel_same(m0.mem@, self.mem@, g1.frames, g1.tries);
            assert forall|i: int| self.top <= i < self.len implies #[trigger] self.mem@[i] == m0.mem@[i] by {}
            assert forall|i: int| 0 <= i < b implies #[trigger] self.words()[i] == m0.words()[i] by {
                assert(self.mem@[self.len - 1 - i] == m0.mem@[self.len - 1 - i]);
            }
            assert(self.words() =~= m0.words().subrange(0, b));
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                assert(g1.stack[i] == g0.stack[i]);
            }
            assert(g1.frames.last() == g0.frames[n - 2]);
            assert(sp::valid_method(p.ap@, g0.frames[n - 2].method as int));
            assert(self.refines(p));
            assert forall|fi: int| 0 <= fi && fi + 1 < g1.frames.len() implies #[trigger] base_step(g1, fi) by {
                assert(base_step(g0, fi));
            }
            assert(bases_ok(g1));
            assert forall|fi: int| 0 <= fi < g1.frames.len() implies
                sp::valid_method(p.ap@, (#[trigger] g1.frames[fi]).method as int) by {
                assert(g1.frames[fi] == g0.frames[fi]);
            }
            lemma_pop_callees(g0);
            assert(shape0(p, g1));
        }
        ret
    }

    /// `spec::unwind(g, u)`: enters the innermost finally code, completes a
    /// non-local return or branch in its frame, or pops frames; an
    /// exception passing the bottom frame ends the task.
    #[inline(never)]
    pub fn do_unwind(&mut self, env: &Env, u: Unw, Ghost(gu): Ghost<Unwind>) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            shape_ok(&env.p, old(self).g@),
            unw_rel(old(self).addr(), u, gu),
            resume_ok(sp::resume_of(gu)),
            !(sp::unwind(env.p.ap@, old(self).g@, gu) is Stuck),
        ensures
            matches(&env.p, sp::unwind(env.p.ap@, old(self).g@, gu), *final(self), r),
            final(self).len == old(self).len,
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost o = sp::unwind(ap, self.g@, gu);
        let ghost addr = self.addr();
        // The bci of the top frame's handler: the return bci of the frame
        // popped last (the try block's; format 3, note 22).
        let mut hbci: usize = 0;
        loop
            invariant
                self.refines(p),
                shape0(p, self.g@),
                sp::has_handler(self.g@) ==> hbci == self.g@.tries.last().bci,
                self.addr() == addr,
                unw_rel(addr, u, gu),
                resume_ok(sp::resume_of(gu)),
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
                lemma_handler_word(self.mem@, g.frames, g.tries);
            }
            let r = self.ftop - FRAME_WORDS;
            let handler = self.mem.read(r + FRAME_HANDLER);
            if handler != 0 {
                proof {
                    assert(self.g@ == g);
                    assert(o == sp::enter_finally(ap, g, g.tries.last(), Some(gu)));
                }
                return self.enter_finally_unwind(env, handler, hbci, u, Ghost(gu));
            }
            proof {
                lemma_no_handler(g);
                assert(r == FRAME_WORDS * (n - 1));
                assert(r / FRAME_WORDS == n - 1);
            }
            let fi = r / FRAME_WORDS;
            match u {
                Unw::Return(f, x) => {
                    if f == fi {
                        return self.do_return(env, x, Ghost(gu->Return_1));
                    }
                },
                Unw::Branch(f, b, hh) => {
                    if f == fi {
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
            if self.ftop == FRAME_WORDS {
                // An exception passes the bottom frame.
                proof { reveal_with_fuel(sp::unwind, 2); }
                env.rt.report(V2_REPORT_UNCAUGHT, self.bci, 0);
                return Ctl::Exit(RESULT_TERMINATED as u32, 1);
            }
            hbci = self.pop_frame_v(p);
        }
    }
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
    &&& resume_ok(sp::resume_of(gu))
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

/// UNWIND: the end of finally code. A null token continues; a token names
/// the finally record whose unwinding resumes (with the value slot).
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
        lemma_shape(p, g);
    }
    let ghost tv = sp::at(g, 1);
    let token = m.at(1);
    proof {
        assert(const_ok(g.heap, ap.roots[0]));
        assert(ap.roots[0] == sp::null2(ap));
        lemma_enc_inj(g.heap, addr, tv, sp::null2(ap));
    }
    if token == p.null {
        proof { assert(sp::op_unwind(ap, g) == sp::op_pop(g, 3, 1)); }
        let r = m.op_pop(p, 3, 1);
        proof { lemma_matches(p, m0, *m, r); }
        return (Prep::Done(r), Ghost(Unwind::Throw(tv)));
    }
    // The token is the smi index of a matching finally record.
    let ghost k = tv->Smi_0 as int;
    proof {
        assert(sp::fin_matches(g, k));
        lemma_smi_word_nat(tv->Smi_0);
        assert(token >> 1 == token / 2) by (bit_vector);
        assert(fin_rel(m.mem@, m.ftop as int, k, g.fins[k]));
        lemma_fin_index(m.ftop as int, g.fins.len() as int, k, FIN_TARGET);
        lemma_fin_index(m.ftop as int, g.fins.len() as int, k, FIN_TARGET_HEIGHT);
        lemma_resume_decode(g.fins[k].resume);
    }
    let ki = token >> 1;
    let e = m.ftop + ki * FIN_WORDS;
    let rw = m.mem.read(e + FIN_RESUME);
    let tw = m.mem.read(e + FIN_TARGET);
    let th = m.mem.read(e + FIN_TARGET_HEIGHT);
    let x = m.at(2);
    let ghost rv = g.fins[k].resume;
    let ghost gu = sp::unwind_of(rv, sp::at(g, 2));
    let kind = rw & 3;
    let f = rw >> 2;
    let u = if kind == 0 {
        Unw::Throw(x)
    } else if kind == 1 {
        Unw::Return(f, x)
    } else {
        Unw::Branch(f, tw, th)
    };
    proof {
        assert(unw_rel(addr, u, gu));
        assert(sp::resume_of(gu) == rv);
    }
    // Pop reason, token and value; records k and above go.
    m.drop_vals(p, 3);
    let ghost g1 = m.g@;
    proof {
        assert(fins_rel(m.mem@, m.ftop as int, g1.fins));
        assert forall|i: int| 0 <= i < FIN_WORDS * k implies #[trigger] m.mem@[m.ftop + i] == m.mem@[m.ftop + i] by {}
        lemma_fins_rel_move(m.mem@, m.mem@, m.ftop as int, m.ftop as int, g1.fins, k);
    }
    m.rtop = e;
    let ghost g2 = State2 { fins: g.fins.subrange(0, k), ..g1 };
    m.g = Ghost(g2);
    proof {
        assert(g2.fins == g1.fins.subrange(0, k));
        assert(m.refines(p));
        assert(g2 == State2 { fins: g.fins.subrange(0, k), ..sp::drop(g, 3) });
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
        assert(f < 0x1_0000_0000);
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
        assert(f < 0x1_0000_0000);
    }
    (Prep::Unwind(Unw::Branch(f, target, h)), Ghost(gu))
}

/// TRY: installs a handler of the top frame (after dropping the frame's
/// stale finally records) and calls the try block, whose method is the top
/// slot, with a reference to that slot.
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
    if let Some(c) = ensure_room(m, env) {
        return c;
    }
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost addr = m.addr();
    let ghost n = g.frames.len() as int;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        lemma_try_target(p, g);
        lemma_tries(p, g);
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
    // The frame's stale finally records go.
    m.cut_records(fi, height - 1, Ghost(g.fins));
    let ghost cut = sp::cut_fins(g.fins, n - 1, g.stack.len() - 1);
    let ghost mem1 = m.mem@;
    // The handler.
    m.mem.write(rr + FRAME_HANDLER, height);
    let ghost hd = Handler { frame: fi, height: height, bci: (bci + 1) as usize };
    let ghost s1 = State2 { tries: g.tries.push(hd), fins: cut, ..g };
    m.g = Ghost(s1);
    proof {
        let m1 = m.mem@;
        assert forall|i: int| 0 <= i < FRAME_WORDS * n && i != FRAME_WORDS * (n - 1) + FRAME_HANDLER
            implies #[trigger] m1[i] == m0.mem@[i] by {}
        lemma_frames_set(m0.mem@, m1, g.frames, g.tries, hd);
        assert forall|i: int| m.ftop <= i < m.ftop + FIN_WORDS * cut.len()
            implies #[trigger] m1[i] == mem1[i] by {}
        lemma_fins_rel_same(mem1, m1, m.ftop as int, cut);
        assert(m.words() =~= m0.words());
        assert(m.refines(p));
    }
    // The reference to the block's slot.
    let slot = height - 1;
    let ghost br = Value::BlockRef(fi, slot);
    proof { assert(fi < 0x4000 && slot < MAX_STACK_LENGTH); }
    let w = smi_of((fi * 0x1_0000 + slot) as i64);
    if !m.push_val(p, w, Ghost(br)) {
        return Ctl::Stuck(stuck::LIMIT);
    }
    proof {
        assert(sp::top_index(g) == n - 1);
        assert(sp::op_try(ap, g) == sp::call(ap, sp::push(s1, br), tt, g.bci + 1));
        assert(t == tt);
    }
    let r = m.push_call(env, t, bci + 1);
    proof { lemma_matches(p, m0, *m, r); }
    r
}

// ---------------------------------------------------------------------------
// The frames after an unwinding.

/// The frames of `g1` are the first frames of `g0`.
pub open spec fn frames_prefix(g0: State2, g1: State2) -> bool {
    &&& g1.frames.len() <= g0.frames.len()
    &&& forall|i: int| 0 <= i < g1.frames.len() ==> #[trigger] g1.frames[i] == g0.frames[i]
}

/// An unwinding only pops frames: the state it continues in (entering
/// finally code, completing a non-local return or branch) has the first
/// frames of the state it starts from (`room::local_room` needs no rescan).
pub proof fn lemma_unwind_prefix(ap: Program2, s: State2, u: Unwind)
    ensures sp::unwind(ap, s, u) is Next ==> frames_prefix(s, sp::unwind(ap, s, u)->Next_0),
    decreases s.frames.len(),
{
    if s.frames.len() > 0 && !sp::has_handler(s) && !(sp::top(s).base as int > s.stack.len()) {
        let s1 = sp::pop_frame(s);
        lemma_unwind_prefix(ap, s1, u);
        if sp::unwind(ap, s1, u) is Next {
            let g = sp::unwind(ap, s1, u)->Next_0;
            assert forall|i: int| 0 <= i < g.frames.len() implies #[trigger] g.frames[i] == s.frames[i] by {
                assert(g.frames[i] == s1.frames[i]);
                assert(s1.frames[i] == s.frames[i]);
            }
        }
        match u {
            Unwind::Return(f, v) => {
                if f as int == sp::top_index(s) && s.frames.len() > 1 {
                    let r1 = State2 {
                        stack: s.stack.subrange(0, sp::top(s).base as int).push(v),
                        frames: s.frames.drop_last(),
                        fins: sp::fins_popped(s),
                        bci: sp::top(s).ret,
                        ..s
                    };
                    assert forall|i: int| 0 <= i < r1.frames.len() implies #[trigger] r1.frames[i] == s.frames[i] by {}
                }
            },
            _ => {},
        }
    }
}

/// A return pops the top frame (and may enter the caller's finally code).
pub proof fn lemma_return_prefix(ap: Program2, s: State2, v: Value)
    ensures sp::return_from(ap, s, v) is Next ==> frames_prefix(s, sp::return_from(ap, s, v)->Next_0),
{
    if s.frames.len() > 1 && !sp::has_handler(s) && !(sp::top(s).base as int > s.stack.len()) {
        let r1 = State2 {
            stack: s.stack.subrange(0, sp::top(s).base as int).push(v),
            frames: s.frames.drop_last(),
            fins: sp::fins_popped(s),
            bci: sp::top(s).ret,
            ..s
        };
        assert forall|i: int| 0 <= i < r1.frames.len() implies #[trigger] r1.frames[i] == s.frames[i] by {}
    }
}

// ---------------------------------------------------------------------------
// Throwing the out-of-memory error.

/// Unwinding never raises (it allocates nothing).
pub proof fn lemma_unwind_not_raise(ap: Program2, s: State2, u: Unwind)
    ensures !(sp::unwind(ap, s, u) is Raise),
    decreases s.frames.len(),
{
    if s.frames.len() > 0 && !sp::has_handler(s) && !(sp::top(s).base as int > s.stack.len()) {
        lemma_unwind_not_raise(ap, sp::pop_frame(s), u);
        match u {
            Unwind::Return(f, v) => {
                if f as int == sp::top_index(s) {
                    let s1 = State2 {
                        stack: s.stack.subrange(0, sp::top(s).base as int).push(v),
                        frames: s.frames.drop_last(),
                        fins: sp::fins_popped(s),
                        bci: sp::top(s).ret,
                        ..s
                    };
                    assert(!(sp::return_from(ap, s, v) is Raise));
                }
            },
            _ => {},
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
