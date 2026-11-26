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

//! Calls and returns, verified: pushing and popping frame records
//! (`spec::call`, `spec::try_call`, `spec::return_from`, entering finally
//! code), the receiver check of static calls,
//! virtual dispatch (`spec::find_method`). Failures raise through the
//! verified raise (raise.rs).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use toit_spec::types::{Value, Frame, HeapObj, Unwind};
use toit_spec::v2::types::{State2, Program2, Outcome2, Halt2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, bases_ok, base_step, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{class_id_of, class_id_ok};

verus! {

// ---------------------------------------------------------------------------
// Frame records.

/// Writing a new frame record above the existing ones.
pub proof fn lemma_frames_push(mem: Seq<usize>, mem2: Seq<usize>, frames: Seq<Frame>, fr: Frame)
    requires
        frames_rel(mem, frames),
        mem2.len() == mem.len(),
        FRAME_WORDS * (frames.len() + 1) <= mem.len(),
        forall|i: int| 0 <= i < FRAME_WORDS * frames.len() ==> #[trigger] mem2[i] == mem[i],
        rec(mem2, frames.len() as int, FRAME_METHOD) == fr.method,
        rec(mem2, frames.len() as int, FRAME_RET) == fr.ret,
        rec(mem2, frames.len() as int, FRAME_BASE) == fr.base,
        rec(mem2, frames.len() as int, FRAME_HANDLER) == handler_word(fr),
    ensures frames_rel(mem2, frames.push(fr)),
{
    let n = frames.len() as int;
    let f2 = frames.push(fr);
    assert forall|fi: int| 0 <= fi < n implies
        #[trigger] rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD)
        && rec(mem2, fi, FRAME_RET) == rec(mem, fi, FRAME_RET)
        && rec(mem2, fi, FRAME_BASE) == rec(mem, fi, FRAME_BASE)
        && rec(mem2, fi, FRAME_HANDLER) == rec(mem, fi, FRAME_HANDLER) by {
        assert(FRAME_WORDS * fi + FRAME_HANDLER < FRAME_WORDS * n) by (nonlinear_arith)
            requires 0 <= fi < n;
    }
    assert forall|fi: int| 0 <= fi < f2.len() implies #[trigger] rec(mem2, fi, FRAME_METHOD) == f2[fi].method by {
        if fi < n { assert(f2[fi] == frames[fi]); assert(rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD)); }
    }
    assert forall|fi: int| 0 <= fi < f2.len() implies #[trigger] rec(mem2, fi, FRAME_RET) == f2[fi].ret by {
        if fi < n { assert(f2[fi] == frames[fi]); assert(rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD)); }
    }
    assert forall|fi: int| 0 <= fi < f2.len() implies #[trigger] rec(mem2, fi, FRAME_BASE) == f2[fi].base by {
        if fi < n { assert(f2[fi] == frames[fi]); assert(rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD)); }
    }
    assert forall|fi: int| 0 <= fi < f2.len() implies #[trigger] rec(mem2, fi, FRAME_HANDLER) == handler_word(f2[fi]) by {
        if fi < n { assert(f2[fi] == frames[fi]); assert(rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD)); }
    }
}

/// Removing the top frame record.
pub proof fn lemma_frames_pop(mem: Seq<usize>, frames: Seq<Frame>)
    requires
        frames_rel(mem, frames),
        frames.len() > 0,
    ensures frames_rel(mem, frames.drop_last()),
{
    let f2 = frames.drop_last();
    let n = f2.len() as int;
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem, fi, FRAME_METHOD) == f2[fi].method by {
        assert(f2[fi] == frames[fi]);
        assert(rec(mem, fi, FRAME_METHOD) == frames[fi].method);
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem, fi, FRAME_RET) == f2[fi].ret by {
        assert(f2[fi] == frames[fi]);
        assert(rec(mem, fi, FRAME_RET) == frames[fi].ret);
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem, fi, FRAME_BASE) == f2[fi].base by {
        assert(f2[fi] == frames[fi]);
        assert(rec(mem, fi, FRAME_BASE) == frames[fi].base);
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem, fi, FRAME_HANDLER) == handler_word(f2[fi]) by {
        assert(f2[fi] == frames[fi]);
        assert(rec(mem, fi, FRAME_HANDLER) == handler_word(frames[fi]));
    }
    assert(FRAME_WORDS * f2.len() <= mem.len());
}

/// The shape of the frames a return and an unwinding rely on (implied by
/// `wf`): frames with valid methods and ordered bases; the bottom frame is
/// not a try block.
pub open spec fn shape_ok(p: &Program, g: State2) -> bool {
    &&& g.frames.len() > 0
    &&& bases_ok(g)
    &&& !g.frames[0].handler
    &&& forall|fi: int| 0 <= fi < g.frames.len() ==> sp::valid_method(p.ap@, (#[trigger] g.frames[fi]).method as int)
}

/// A dispatch-table entry of an accepted program is -1 or a method or an
/// accessor (`verifier::dispatch_entry_ok`), whose header has a selector
/// and a receiver range (format note 21).
pub proof fn lemma_dispatch_kind(p: &Program, objs: Seq<HeapObj>, addr: Seq<usize>, d: int)
    requires
        accepts(p.ap@, p.cert@, p.trusted@),
        prog_rel(p, objs, addr),
        0 <= d < p.dispatch@.len(),
        p.dispatch@[d] != -1,
    ensures
        0 <= p.dispatch@[d] < p.methods@.len(),
        p.minfo(p.dispatch@[d] as int).kind < 2,
{
    let ap = p.ap@;
    assert(toit_spec::v2::verifier::dispatch_entry_ok(ap, d));
    let t = p.dispatch@[d] as int;
    assert(ap.methods[t] == method_info(p.minfo(t), p.max_height));
}

/// A well-formed state has the shape.
pub proof fn lemma_shape(p: &Program, g: State2)
    requires accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
    ensures shape_ok(p, g),
{
    lemma_frames_wf(p, g);
    assert forall|fi: int| 0 <= fi < g.frames.len() implies sp::valid_method(p.ap@, (#[trigger] g.frames[fi]).method as int) by {
        reveal(wf);
        reveal(toit_spec::v2::sound::wf_task);
        reveal(toit_spec::v2::sound::frame_ok);
        assert(toit_spec::v2::sound::frame_ok(p.ap@, p.cert@, g, fi));
    }
}

/// In a well-formed state there are frames with ordered bases, and the
/// bottom frame is not a try block.
pub proof fn lemma_frames_wf(p: &Program, g: State2)
    requires accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
    ensures
        g.frames.len() > 0,
        bases_ok(g),
        !g.frames[0].handler,
{
    reveal(wf);
    reveal(toit_spec::v2::sound::wf_task);
}

// ---------------------------------------------------------------------------
// Classes and lookup.

pub enum VLookup {
    Found(usize),
    Missing,
}

impl Machine {
    /// The class id of a smi or object (`class_id_of`), below 2^16: a word,
    /// so that the range checks of 32-bit targets compare words, not
    /// 64-bit integers.
    #[inline(always)]
    pub fn class_of(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: usize)
        requires
            self.hrefines(p),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            v is Smi || v is Obj,
        ensures
            r == class_id_of(p1(p.ap@), as1(self.g@), v),
            r < 0x1_0000,
    {
        proof {
            match v {
                Value::Smi(i) => { lemma_smi_word(i); },
                Value::Obj(id) => { lemma_obj_not_smi(self.heap.objs(), self.addr(), id); },
                _ => {},
            }
        }
        if w & 1 == 0 {
            p.smi_class_id
        } else {
            let ghost id = match v { Value::Obj(id) => id as int, _ => 0 };
            self.heap.class_id(w, Ghost(id))
        }
    }

    /// `spec::find_method`, when it is not stuck. The program is accepted:
    /// a dispatch target is a method or an accessor, whose selector is read
    /// without a kind test (`lemma_dispatch_kind`).
    #[inline(always)]
    pub fn lookup(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>, sel: i64) -> (r: VLookup)
        requires
            self.hrefines(p),
            accepts(p.ap@, p.cert@, p.trusted@),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            -0x8000_0000 <= sel < 0x8000_0000,
            !(sp::find_method(p.ap@, self.g@, v, sel as int) is Stuck),
        ensures
            r == VLookup::Missing ==> sp::find_method(p.ap@, self.g@, v, sel as int) is Missing,
            r is Found ==> sp::find_method(p.ap@, self.g@, v, sel as int)
                == sp::Lookup2::Found(r->Found_0 as int),
    {
        let ghost ap = p.ap@;
        let cid = self.class_of(p, w, Ghost(v));
        if sel < 0 {
            return VLookup::Missing;
        }
        let index = cid + sel as usize;
        let entry = p.dispatch.at(index);
        if entry == -1 {
            return VLookup::Missing;
        }
        proof { lemma_dispatch_kind(p, self.g@.heap, self.addr(), index as int); }
        if p.dispatch_selector(entry as usize) as i64 != sel {
            return VLookup::Missing;
        }
        VLookup::Found(entry as usize)
    }

    // -----------------------------------------------------------------------
    // Frames.

    /// `spec::call` (`handler == 0`) or `spec::try_call` (`handler == 1`, a
    /// try block): a frame for `target`, whose arguments are the top `arity`
    /// slots, returning to `ret`; then the preemption point (as format 1,
    /// at the callee's entry).
    #[inline(never)]
    pub fn push_call(&mut self, env: &Env, target: usize, ret: usize, handler: usize) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            !(sp::call(env.p.ap@, old(self).g@, target as int, ret as int) is Stuck),
            old(self).top - old(self).ftop >= FRAME_WORDS,
            handler <= 1,
        ensures
            r == Ctl::Next || r == Ctl::Exit(RESULT_PREEMPTED as u32, 0),
            final(self).refines(&env.p),
            (if handler == 0 { sp::call(env.p.ap@, old(self).g@, target as int, ret as int) }
             else { sp::try_call(env.p.ap@, old(self).g@, target as int, ret as int) }) == Outcome2::Next(final(self).g@),
            final(self).len == old(self).len,
    {
        self.push_frame(&env.p, target, ret, handler);
        if env.pre.requested() {
            env.pre.clear();
            return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
        }
        Ctl::Next
    }

    /// `push_call` without the preemption point.
    #[inline(always)]
    pub fn push_frame(&mut self, p: &Program, target: usize, ret: usize, handler: usize)
        requires
            old(self).refines(p),
            !(sp::call(p.ap@, old(self).g@, target as int, ret as int) is Stuck),
            old(self).top - old(self).ftop >= FRAME_WORDS,
            handler <= 1,
        ensures
            final(self).refines(p),
            (if handler == 0 { sp::call(p.ap@, old(self).g@, target as int, ret as int) }
             else { sp::try_call(p.ap@, old(self).g@, target as int, ret as int) }) == Outcome2::Next(final(self).g@),
            final(self).len == old(self).len,
            final(self).addr() == old(self).addr(),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_frame(p); }
        let info = p.method(target);
        let arity = info.arity as usize;
        let height = self.len - self.top;
        let base = height - arity;
        let f = self.ftop;
        self.mem.write(f + FRAME_METHOD, target);
        self.mem.write(f + FRAME_RET, ret);
        self.mem.write(f + FRAME_BASE, base);
        self.mem.write(f + FRAME_HANDLER, handler);
        self.ftop = f + FRAME_WORDS;
        self.method = target;
        self.base = base;
        self.lim = self.len - base;
        self.bci = info.entry as usize;
        let ghost fr = Frame { method: target, ret: ret, base: base, handler: handler == 1 };
        let ghost g1 = State2 { frames: g0.frames.push(fr), bci: info.entry as usize, ..g0 };
        self.g = Ghost(g1);
        proof {
            assert(p.ap@.methods[target as int] == method_info(p.minfo(target as int), p.max_height));
            let n = g0.frames.len() as int;
            assert(f == FRAME_WORDS * n);
            assert forall|i: int| 0 <= i < FRAME_WORDS * n implies #[trigger] self.mem@[i] == m0.mem@[i] by {}
            assert forall|i: int| self.top <= i < self.len implies #[trigger] self.mem@[i] == m0.mem@[i] by {}
            assert(rec(self.mem@, n, FRAME_METHOD) == target);
            assert(rec(self.mem@, n, FRAME_RET) == ret);
            assert(rec(self.mem@, n, FRAME_BASE) == base);
            assert(rec(self.mem@, n, FRAME_HANDLER) == handler_word(fr));
            lemma_frames_push(m0.mem@, self.mem@, g0.frames, fr);
            assert(self.words() =~= m0.words());
            assert(g1.frames.last() == fr);
            let c1 = sp::call(p.ap@, g0, target as int, ret as int);
            assert(c1 == Outcome2::Next(State2 { frames: g0.frames.push(Frame { handler: false, ..fr }), ..g1 }));
            if handler == 1 {
                assert(sp::flag_top(c1->Next_0).frames =~= g1.frames);
                assert(sp::flag_top(c1->Next_0) == g1);
            } else {
                assert(fr == Frame { handler: false, ..fr });
            }
        }
    }

    /// Pops the top frame (`spec::pop_frame`): the caller becomes the top
    /// frame. Returns the popped frame's return bci, base and handler word.
    #[inline(always)]
    pub fn pop_frame_v(&mut self, p: &Program) -> (r: (usize, usize, usize))
        requires
            old(self).refines(p),
            shape_ok(p, old(self).g@),
            old(self).g@.frames.len() > 1,
        ensures
            final(self).refines(p),
            final(self).g@ == sp::pop_frame(old(self).g@),
            shape_ok(p, final(self).g@),
            final(self).addr() == old(self).addr(),
            final(self).len == old(self).len,
            final(self).bci == old(self).bci,
            final(self).top >= old(self).top,
            final(self).ftop + FRAME_WORDS == old(self).ftop,
            r.0 == sp::top(old(self).g@).ret,
            r.1 == sp::top(old(self).g@).base,
            r.2 == handler_word(sp::top(old(self).g@)),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost n = g0.frames.len() as int;
        proof { self.lemma_frame(p); }
        let r = self.ftop - FRAME_WORDS;
        let c = r - FRAME_WORDS;
        let ret = self.mem.read(r + FRAME_RET);
        let handler = self.mem.read(r + FRAME_HANDLER);
        let fbase = self.base;
        let method = self.mem.read(c + FRAME_METHOD);
        let base = self.mem.read(c + FRAME_BASE);
        proof {
            assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
            assert(rec(m0.mem@, n - 1, FRAME_HANDLER) == handler_word(g0.frames[n - 1]));
            assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
            assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
            assert(base_step(g0, n - 2));
        }
        self.ftop = r;
        self.top = self.len - fbase;
        self.method = method;
        self.base = base;
        self.lim = self.len - base;
        let ghost g1 = sp::pop_frame(g0);
        self.g = Ghost(g1);
        proof {
            let b = sp::top(g0).base as int;
            lemma_frames_pop(m0.mem@, g0.frames);
            lemma_frames_rel_same(m0.mem@, self.mem@, g1.frames);
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
            assert(g1.frames[0] == g0.frames[0]);
            assert(shape_ok(p, g1));
        }
        (ret, fbase, handler)
    }

    /// `spec::return_from(g, v)` for the result word `w`: pops the top frame
    /// and pushes the result; a try block enters the finally code of the
    /// frame below (`enter_finally` without unwinding).
    #[inline(never)]
    pub fn do_return(&mut self, env: &Env, w: usize, Ghost(v): Ghost<Value>) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            shape_ok(&env.p, old(self).g@),
            w == enc(old(self).addr(), v),
            encodable(old(self).addr(), v),
            !(sp::return_from(env.p.ap@, old(self).g@, v) is Stuck),
        ensures
            matches(&env.p, sp::return_from(env.p.ap@, old(self).g@, v), *final(self), r),
            final(self).len == old(self).len,
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_frame(p); }
        if self.ftop == FRAME_WORDS {
            env.rt.report(V2_REPORT_TASK_RETURNED, self.bci, 0);
            return Ctl::Exit(RESULT_TERMINATED as u32, 1);
        }
        let (ret, fbase, handler) = self.pop_frame_v(p);
        if handler != 0 {
            proof { assert(sp::top(g0).handler); }
            return self.enter_finally_v(env, fbase, ret, None, Ghost(None));
        }
        let ghost m1 = *self;
        let ghost g1 = self.g@;
        // Room: the callee's frame record is free now.
        self.top = self.top - 1;
        let t = self.top;
        self.mem.write(t, w);
        self.bci = ret;
        let ghost g2 = State2 {
            stack: g0.stack.subrange(0, sp::top(g0).base as int).push(v),
            frames: g0.frames.drop_last(),
            bci: sp::top(g0).ret,
            ..g0
        };
        self.g = Ghost(g2);
        proof {
            assert(!sp::top(g0).handler);
            assert(self.top >= self.ftop);
            lemma_frames_rel_same(m1.mem@, self.mem@, g2.frames);
            let b = sp::top(g0).base as int;
            assert forall|i: int| t < i < self.len implies #[trigger] self.mem@[i] == m1.mem@[i] by {}
            assert(self.words() =~= m1.words().push(w));
            assert(enc_seq(m0.addr(), g2.stack) =~= enc_seq(m0.addr(), g1.stack).push(w));
            assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m0.addr(), g2.stack[i]) by {
                if i < b { assert(g2.stack[i] == g0.stack[i]); }
            }
            assert(self.refines(p));
        }
        Ctl::Next
    }

    /// `spec::enter_finally(g, h, bci, u)`: the top frame (the frame below a
    /// try block just popped) continues in its finally code at `bci`, the
    /// object stack cut to `h`, with the value, the two token words of the
    /// unwinding (`None`: a normal completion) and the reason pushed.
    #[inline(always)]
    pub fn enter_finally_v(&mut self, env: &Env, h: usize, bci: usize, u: Option<crate::unwind::Unw>,
                         Ghost(gu): Ghost<Option<Unwind>>) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            shape_ok(&env.p, old(self).g@),
            crate::unwind::unw_opt_rel(old(self).addr(), u, gu),
            match gu { Some(x) => pending_encodable(sp::pending_of(Some(x))), None => true },
            !(sp::enter_finally(env.p.ap@, old(self).g@, h as int, bci as int, gu) is Stuck),
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(&env.p)
                && sp::enter_finally(env.p.ap@, old(self).g@, h as int, bci as int, gu) == Outcome2::Next(final(self).g@),
            final(self).len == old(self).len,
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost addr = self.addr();
        proof { self.lemma_frame(p); }
        let ghost d = sp::pending_of(gu);
        let ghost g = (g0.frames.len() - 1) as usize;
        let (value, wa, wb, reason) = crate::unwind::token_words(p, u, Ghost(addr), Ghost(gu));
        self.top = self.len - h;
        self.bci = bci;
        let ghost g1 = State2 { stack: g0.stack.subrange(0, h as int), bci: bci, ..g0 };
        self.g = Ghost(g1);
        proof {
            assert forall|i: int| 0 <= i < h implies #[trigger] self.words()[i] == m0.words()[i] by {
                assert(self.mem@[self.len - 1 - i] == m0.mem@[self.len - 1 - i]);
            }
            assert(self.words() =~= m0.words().subrange(0, h as int));
            assert(self.words() =~= enc_seq(addr, g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(addr, g1.stack[i]) by {
                assert(g1.stack[i] == g0.stack[i]);
            }
            assert(self.refines(p));
            assert(const_ok(g0.heap, ap.roots[0]));
            lemma_smi_word(-1i64);
            lemma_smi_word(-2i64);
        }
        let ghost va = Value::Token(false, d, g, h);
        let ghost vb = Value::Token(true, d, g, h);
        if !self.push_val(p, value, Ghost(sp::value_of(ap, gu))) { return Ctl::Stuck(stuck::LIMIT); }
        if !self.push_val(p, wa, Ghost(va)) { return Ctl::Stuck(stuck::LIMIT); }
        if !self.push_val(p, wb, Ghost(vb)) { return Ctl::Stuck(stuck::LIMIT); }
        if !self.push_val(p, reason, Ghost(toit_spec::spec_common::smi(sp::reason_of(gu)))) { return Ctl::Stuck(stuck::LIMIT); }
        proof { assert(g == sp::top_index(g0)); }
        Ctl::Next
    }
}

} // verus!

verus! {

// ---------------------------------------------------------------------------
// Handlers.

/// The facts every handler starts from.
pub open spec fn handler_pre(p: &Program, m: Machine, bci: usize, opcode: u8) -> bool {
    let ap = p.ap@;
    let g = m.g@;
    &&& m.inv(p)
    &&& step_ok(ap, p.cert@, g)
    &&& bci == m.bci
    &&& bci == g.bci
    &&& opcode == ap.bytecodes[bci as int]
}

/// `spec::invoke_virtual(g, sel, n, len)` where it is a source of outcomes
/// of the state (the step, or a resource throw's fallback).
#[inline(always)]
pub fn do_invoke_virtual(m: &mut Machine, env: &Env, bci: usize, opcode: u8, sel: i64, n: usize, len: usize) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        toit_spec::v2::prim::grows_stack(opcode),
        opcode != 97,
        source(env.p.ap@, old(m).g@, sp::invoke_virtual(env.p.ap@, old(m).g@, sel as int, n as int, len as int)),
        -0x8000_0000 <= sel < 0x8000_0000,
        bci + len < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    if let Some(c) = ensure_room(m, env) {
        return c;
    }
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost vo = sp::invoke_virtual(ap, g, sel as int, n as int, len as int);
    proof {
        lemma_source_not_stuck(p, m0, vo);
        m.lemma_frame(p);
        m.lemma_at(p, n - 1);
    }
    let receiver = m.at(n - 1);
    match m.lookup(p, receiver, Ghost(sp::at(g, n - 1)), sel) {
        VLookup::Missing => {
            proof { assert(vo == sp::raise(ap, g, sp::LOOKUP_FAILED)); }
            m.v_raise_lookup(env, receiver, Ghost(sp::at(g, n - 1)), sel)
        },
        VLookup::Found(t) => {
            proof { lemma_source_outcome(p, m0, vo); }
            let r = m.push_call(env, t, bci + len, 0);
            proof { lemma_outcome_matches(p, m0, *m, r, vo); }
            r
        },
    }
}

/// `spec::operator_fallback` where it is a source of outcomes (the step,
/// or the resource throw of a failed double allocation).
#[inline(always)]
pub fn fallback_src(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        toit_spec::v2::prim::grows_stack(opcode),
        opcode != 97,
        62 <= opcode <= 79,
        source(env.p.ap@, old(m).g@, sp::operator_fallback(env.p.ap@, old(m).g@, opcode)),
        bci + 1 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    proof { assert(env.p.ap@.invoke_offsets.len() == 19); }
    let sel = env.p.invoke_offsets.at((opcode - 62) as usize) as i64;
    let n = if opcode == 79 { 3 } else { 2 };
    do_invoke_virtual(m, env, bci, opcode, sel, n, 1)
}

} // verus!
