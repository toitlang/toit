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
//! (`spec::call`, `spec::return_from`), the receiver check of static calls,
//! virtual dispatch (`spec::find_method`). Failures raise through the
//! verified raise (raise.rs).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use toit_spec::types::{Value, Frame, Handler, Fin, HeapObj};
use toit_spec::v2::types::{State2, Program2, Outcome2, Halt2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, try_ok, bases_ok, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{class_id_of, class_id_ok};

verus! {

// ---------------------------------------------------------------------------
// Frame records.

/// Writing a new frame record above the existing ones.
pub proof fn lemma_frames_push(mem: Seq<usize>, mem2: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>, fr: Frame)
    requires
        frames_rel(mem, frames, tries),
        mem2.len() == mem.len(),
        FRAME_WORDS * (frames.len() + 1) <= mem.len(),
        forall|i: int| 0 <= i < FRAME_WORDS * frames.len() ==> #[trigger] mem2[i] == mem[i],
        rec(mem2, frames.len() as int, FRAME_METHOD) == fr.method,
        rec(mem2, frames.len() as int, FRAME_RET) == fr.ret,
        rec(mem2, frames.len() as int, FRAME_BASE) == fr.base,
        rec(mem2, frames.len() as int, FRAME_HANDLER) == 0,
    ensures frames_rel(mem2, frames.push(fr), tries),
{
    let n = frames.len() as int;
    let f2 = frames.push(fr);
    assert forall|fi: int| 0 <= fi < n implies
        #[trigger] rec(mem2, fi, FRAME_METHOD) == rec(mem, fi, FRAME_METHOD)
        && rec(mem2, fi, FRAME_RET) == rec(mem, fi, FRAME_RET)
        && rec(mem2, fi, FRAME_BASE) == rec(mem, fi, FRAME_BASE)
        && rec(mem2, fi, FRAME_HANDLER) == rec(mem, fi, FRAME_HANDLER)
        && rec(mem2, fi, FRAME_HANDLER_BCI) == rec(mem, fi, FRAME_HANDLER_BCI) by {
        assert(FRAME_WORDS * fi + FRAME_HANDLER_BCI < FRAME_WORDS * n) by (nonlinear_arith)
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
    assert forall|x: int| 0 <= x < tries.len() implies
        rec(mem2, (#[trigger] tries[x]).frame as int, FRAME_HANDLER) == handler_word(tries[x])
        && rec(mem2, tries[x].frame as int, FRAME_HANDLER_BCI) == tries[x].bci by {
        assert(rec(mem2, tries[x].frame as int, FRAME_HANDLER) == rec(mem, tries[x].frame as int, FRAME_HANDLER));
        assert(rec(mem2, tries[x].frame as int, FRAME_HANDLER_BCI) == rec(mem, tries[x].frame as int, FRAME_HANDLER_BCI));
    }
    assert forall|fi: int| 0 <= fi < f2.len() && #[trigger] rec(mem2, fi, FRAME_HANDLER) != 0
            implies exists|x: int| 0 <= x < tries.len() && tries[x].frame == fi by {
        assert(rec(mem2, fi, FRAME_HANDLER) == rec(mem, fi, FRAME_HANDLER));
    }
}

/// Removing the top frame record (no handler belongs to it).
pub proof fn lemma_frames_pop(mem: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>)
    requires
        frames_rel(mem, frames, tries),
        frames.len() > 0,
        forall|x: int| 0 <= x < tries.len() ==> (#[trigger] tries[x]).frame + 1 < frames.len(),
        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
    ensures frames_rel(mem, frames.drop_last(), tries),
{
    lemma_tries_len(tries, frames.len() - 1);
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
    assert forall|x: int| 0 <= x < tries.len() implies {
        &&& (#[trigger] tries[x]).frame < f2.len()
        &&& 0 < tries[x].height < 0x1_0000_0000
        &&& tries[x].bci < 0x1_0000_0000
        &&& rec(mem, tries[x].frame as int, FRAME_HANDLER) == handler_word(tries[x])
        &&& rec(mem, tries[x].frame as int, FRAME_HANDLER_BCI) == tries[x].bci
    } by {}
    assert forall|fi: int| 0 <= fi < n && #[trigger] rec(mem, fi, FRAME_HANDLER) != 0
            implies exists|x: int| 0 <= x < tries.len() && tries[x].frame == fi by {}
    assert(FRAME_WORDS * f2.len() <= mem.len());
}

/// Cutting finally records never adds any.
pub proof fn lemma_cut_fins_len(fins: Seq<toit_spec::types::Fin>, g: int, lim: int)
    ensures sp::cut_fins(fins, g, lim).len() <= fins.len(),
    decreases fins.len(),
{
    if fins.len() > 0 && (fins.last().frame as int > g || (fins.last().frame as int == g && fins.last().height as int >= lim)) {
        lemma_cut_fins_len(fins.drop_last(), g, lim);
    }
}

/// Handlers of distinct frames below `m`: at most `m` of them.
pub proof fn lemma_tries_len(tries: Seq<Handler>, m: int)
    requires
        m >= 0,
        forall|x: int| 0 <= x < tries.len() ==> (#[trigger] tries[x]).frame < m,
        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
    ensures tries.len() <= m,
{
    if tries.len() > 0 {
        lemma_tries_frame(tries, tries.len() - 1);
        assert(tries[tries.len() - 1].frame < m);
    }
}

proof fn lemma_tries_frame(tries: Seq<Handler>, x: int)
    requires
        0 <= x < tries.len(),
        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
    ensures tries[x].frame >= x,
    decreases x,
{
    if x > 0 {
        lemma_tries_frame(tries, x - 1);
        assert(tries[x - 1].frame < tries[x].frame);
    }
}

/// The handlers belong to frames up to the top one, in increasing order.
pub open spec fn tries_ok(g: State2) -> bool {
    &&& forall|x: int| 0 <= x < g.tries.len() ==> (#[trigger] g.tries[x]).frame + 1 <= g.frames.len()
    &&& forall|x: int, y: int| 0 <= x < y < g.tries.len() ==> (#[trigger] g.tries[x]).frame < (#[trigger] g.tries[y]).frame
}

/// The shape of the frames a return and an unwinding rely on (implied by
/// `wf`, kept while frames are popped): frames with valid methods and
/// ordered bases, handlers of frames up to the top.
pub open spec fn shape_ok(p: &Program, g: State2) -> bool {
    &&& g.frames.len() > 0
    &&& bases_ok(g)
    &&& tries_ok(g)
    &&& forall|fi: int| 0 <= fi < g.frames.len() ==> sp::valid_method(p.ap@, (#[trigger] g.frames[fi]).method as int)
}

/// Without a handler of the top frame, the handlers belong to frames below it.
pub proof fn lemma_no_handler(g: State2)
    requires tries_ok(g), g.frames.len() > 0, !sp::has_handler(g),
    ensures forall|x: int| 0 <= x < g.tries.len() ==> (#[trigger] g.tries[x]).frame + 1 < g.frames.len(),
{
    assert forall|x: int| 0 <= x < g.tries.len() implies (#[trigger] g.tries[x]).frame + 1 < g.frames.len() by {
        let l = g.tries.len() - 1;
        assert(g.tries[l] == g.tries.last());
        if x < l {
            assert(g.tries[x].frame < g.tries[l].frame);
        }
    }
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
    lemma_tries(p, g);
    assert forall|fi: int| 0 <= fi < g.frames.len() implies sp::valid_method(p.ap@, (#[trigger] g.frames[fi]).method as int) by {
        reveal(wf);
        reveal(toit_spec::v2::sound::wf_task);
        reveal(toit_spec::v2::sound::frame_ok);
        assert(toit_spec::v2::sound::frame_ok(p.ap@, p.cert@, g, fi));
    }
}

/// In a well-formed state the handlers belong to frames below the top,
/// in increasing order.
pub proof fn lemma_tries(p: &Program, g: State2)
    requires accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
    ensures
        g.frames.len() > 0,
        bases_ok(g),
        forall|x: int| 0 <= x < g.tries.len() ==> (#[trigger] g.tries[x]).frame + 1 < g.frames.len(),
        forall|x: int, y: int| 0 <= x < y < g.tries.len() ==> (#[trigger] g.tries[x]).frame < (#[trigger] g.tries[y]).frame,
{
    let ap = p.ap@;
    let c = p.cert@;
    reveal(wf);
    toit_spec::v2::sound_local::lemma_task_basics(ap, c, g);
    assert forall|x: int| 0 <= x < g.tries.len() implies (#[trigger] g.tries[x]).frame + 1 < g.frames.len() by {
        assert(try_ok(g, x));
    }
    assert forall|x: int, y: int| 0 <= x < y < g.tries.len()
        implies (#[trigger] g.tries[x]).frame < (#[trigger] g.tries[y]).frame by {
        lemma_tries_sorted(g, x, y);
    }
}

proof fn lemma_tries_sorted(g: State2, x: int, y: int)
    requires 0 <= x < y < g.tries.len(), forall|z: int| 0 <= z < g.tries.len() ==> #[trigger] try_ok(g, z),
    ensures g.tries[x].frame < g.tries[y].frame,
    decreases y - x,
{
    assert(try_ok(g, y));
    if x + 1 < y {
        lemma_tries_sorted(g, x, y - 1);
    }
}

/// The handler word of the top frame of `frames` says whether its handler
/// is the last one (`spec::has_handler`), when no handler belongs to a
/// frame above it and the handlers are sorted.
pub proof fn lemma_handler_word(mem: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>)
    requires
        frames_rel(mem, frames, tries),
        frames.len() > 0,
        forall|x: int| 0 <= x < tries.len() ==> (#[trigger] tries[x]).frame + 1 <= frames.len(),
        forall|x: int, y: int| 0 <= x < y < tries.len() ==> (#[trigger] tries[x]).frame < (#[trigger] tries[y]).frame,
    ensures
        (rec(mem, frames.len() - 1, FRAME_HANDLER) != 0)
            == (tries.len() > 0 && tries.last().frame == frames.len() - 1),
        tries.len() > 0 && tries.last().frame == frames.len() - 1 ==>
            rec(mem, frames.len() - 1, FRAME_HANDLER) == handler_word(tries.last())
            && rec(mem, frames.len() - 1, FRAME_HANDLER_BCI) == tries.last().bci,
{
    let fi = frames.len() - 1;
    if rec(mem, fi, FRAME_HANDLER) != 0 {
        let x = choose|x: int| 0 <= x < tries.len() && tries[x].frame == fi;
        if x < tries.len() - 1 {
            assert(tries[x].frame < tries[tries.len() - 1].frame);
        }
    }
    if tries.len() > 0 && tries.last().frame == fi {
        let h = tries.last();
        assert(tries[tries.len() - 1] == h);
    }
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

    /// `spec::call`: a frame for `target`, whose arguments are the top
    /// `arity` slots, returning to `ret`; then the preemption point (as
    /// format 1, at the callee's entry). The finally records (rare: only
    /// during an unwinding's finally code) move up to make room for the
    /// frame record.
    #[inline(never)]
    pub fn push_call(&mut self, env: &Env, target: usize, ret: usize) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            !(sp::call(env.p.ap@, old(self).g@, target as int, ret as int) is Stuck),
            old(self).top - old(self).rtop >= FRAME_WORDS,
        ensures
            r == Ctl::Next || r == Ctl::Exit(RESULT_PREEMPTED as u32, 0),
            final(self).refines(&env.p),
            sp::call(env.p.ap@, old(self).g@, target as int, ret as int) == Outcome2::Next(final(self).g@),
            final(self).len == old(self).len,
    {
        let p = &env.p;
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_frame(p); }
        let info = p.method(target);
        let arity = info.arity as usize;
        let height = self.len - self.top;
        let base = height - arity;
        let f = self.ftop;
        let e = self.rtop;
        if e > f {
            self.mem.copy_within(f, f + FRAME_WORDS, e - f);
        }
        let ghost mem1 = self.mem@;
        self.mem.write(f + FRAME_METHOD, target);
        self.mem.write(f + FRAME_RET, ret);
        self.mem.write(f + FRAME_BASE, base);
        self.mem.write(f + FRAME_HANDLER, 0);
        self.ftop = f + FRAME_WORDS;
        self.rtop = e + FRAME_WORDS;
        self.method = target;
        self.base = base;
        self.lim = self.len - base;
        self.bci = info.entry as usize;
        let ghost fr = Frame { method: target, ret: ret, base: base };
        let ghost g1 = State2 { frames: g0.frames.push(fr), bci: info.entry as usize, ..g0 };
        self.g = Ghost(g1);
        proof {
            assert(p.ap@.methods[target as int] == method_info(p.minfo(target as int), p.max_height));
            let n = g0.frames.len() as int;
            assert(f == FRAME_WORDS * n);
            // The records moved up by one frame record; the rest is unchanged.
            assert forall|i: int| 0 <= i < self.mem@.len() && !(f <= i < e + FRAME_WORDS)
                implies #[trigger] mem1[i] == m0.mem@[i] by {}
            assert forall|i: int| f + FRAME_WORDS <= i < e + FRAME_WORDS
                implies #[trigger] mem1[i] == m0.mem@[i - FRAME_WORDS] by {}
            assert forall|i: int| 0 <= i < FRAME_WORDS * n implies #[trigger] self.mem@[i] == m0.mem@[i] by {
                assert(mem1[i] == m0.mem@[i]);
            }
            assert forall|i: int| 0 <= i < FIN_WORDS * g0.fins.len()
                implies #[trigger] self.mem@[f + FRAME_WORDS + i] == m0.mem@[f + i] by {
                assert(mem1[f + FRAME_WORDS + i] == m0.mem@[f + FRAME_WORDS + i - FRAME_WORDS]);
            }
            lemma_fins_rel_move(m0.mem@, self.mem@, f as int, (f + FRAME_WORDS) as int, g0.fins, g0.fins.len() as int);
            assert(g0.fins.subrange(0, g0.fins.len() as int) =~= g0.fins);
            assert forall|i: int| self.top <= i < self.len implies #[trigger] self.mem@[i] == m0.mem@[i] by {
                assert(mem1[i] == m0.mem@[i]);
            }
            assert(rec(self.mem@, n, FRAME_METHOD) == target);
            assert(rec(self.mem@, n, FRAME_RET) == ret);
            assert(rec(self.mem@, n, FRAME_BASE) == base);
            assert(rec(self.mem@, n, FRAME_HANDLER) == 0);
            lemma_frames_push(m0.mem@, self.mem@, g0.frames, g0.tries, fr);
            assert(self.words() =~= m0.words());
            assert(g1.frames.last() == fr);
        }
        if env.pre.requested() {
            env.pre.clear();
            return Ctl::Exit(RESULT_PREEMPTED as u32, 0);
        }
        Ctl::Next
    }

    /// The trailing finally record `k - 1` (records `[ftop, ftop + 4k)`) is
    /// dropped by `cut_fins(_, g, lim)`.
    #[inline(always)]
    pub fn fin_cut(&self, e: usize, g: usize, lim: usize, Ghost(fins): Ghost<Seq<Fin>>, Ghost(k): Ghost<int>) -> (r: bool)
        requires
            self.stack_ok(),
            fins_rel(self.mem@, self.ftop as int, fins),
            0 < k <= fins.len(),
            e == self.ftop + FIN_WORDS * k,
        ensures
            r == (fins[k - 1].frame as int > g as int
                || (fins[k - 1].frame as int == g as int && fins[k - 1].height as int >= lim as int)),
    {
        proof {
            assert(fin_rel(self.mem@, self.ftop as int, k - 1, fins[k - 1]));
            lemma_fin_index(self.ftop as int, fins.len() as int, k - 1, FIN_HEIGHT);
        }
        let frame = self.mem.read(e - FIN_WORDS + FIN_FRAME);
        frame > g || (frame == g && self.mem.read(e - FIN_WORDS + FIN_HEIGHT) >= lim)
    }

    /// `spec::cut_fins(fins, g, lim)`: drops trailing finally records (only
    /// `rtop` changes).
    #[inline(always)]
    pub fn cut_records(&mut self, g: usize, lim: usize, Ghost(fins): Ghost<Seq<Fin>>)
        requires
            old(self).stack_ok(),
            old(self).rtop == old(self).ftop + FIN_WORDS * fins.len(),
            fins_rel(old(self).mem@, old(self).ftop as int, fins),
        ensures
            final(self).rtop == final(self).ftop + FIN_WORDS * sp::cut_fins(fins, g as int, lim as int).len(),
            final(self).rtop <= old(self).rtop,
            sp::cut_fins(fins, g as int, lim as int).len() <= fins.len(),
            fins_rel(final(self).mem@, final(self).ftop as int, sp::cut_fins(fins, g as int, lim as int)),
            final(self).stack_ok(),
            final(self).mem@ == old(self).mem@,
            final(self).ftop == old(self).ftop,
            final(self).top == old(self).top,
            final(self).len == old(self).len,
            final(self).bci == old(self).bci,
            final(self).base == old(self).base,
            final(self).lim == old(self).lim,
            final(self).method == old(self).method,
            final(self).globals == old(self).globals,
            final(self).heap == old(self).heap,
            final(self).g == old(self).g,
    {
        let ghost m0 = *self;
        let ftop = self.ftop;
        let mut e = self.rtop;
        let ghost mut k: int = fins.len() as int;
        proof { assert(fins.subrange(0, k) =~= fins); }
        while e > ftop && self.fin_cut(e, g, lim, Ghost(fins), Ghost(k))
            invariant
                *self == m0,
                ftop == m0.ftop,
                m0.stack_ok(),
                fins_rel(m0.mem@, ftop as int, fins),
                0 <= k <= fins.len(),
                e == ftop + FIN_WORDS * k,
                sp::cut_fins(fins, g as int, lim as int) == sp::cut_fins(fins.subrange(0, k), g as int, lim as int),
            decreases e,
        {
            proof {
                let fs = fins.subrange(0, k);
                assert(fs.last() == fins[k - 1]);
                assert(fs.drop_last() =~= fins.subrange(0, k - 1));
            }
            e = e - FIN_WORDS;
            proof { k = k - 1; }
        }
        proof {
            let fs = fins.subrange(0, k);
            if k > 0 {
                assert(fs.last() == fins[k - 1]);
            }
            assert(sp::cut_fins(fs, g as int, lim as int) == fs);
            lemma_fins_rel_move(m0.mem@, m0.mem@, ftop as int, ftop as int, fins, k);
        }
        self.rtop = e;
    }

    /// Pops the top frame's record and its finally records (`fins_popped`,
    /// the last ones); the remaining finally records move down over the
    /// frame record.
    #[inline(always)]
    pub fn pop_records(&mut self, Ghost(g): Ghost<State2>)
        requires
            old(self).stack_ok(),
            g.frames.len() >= 1,
            old(self).ftop == FRAME_WORDS * g.frames.len(),
            old(self).rtop == old(self).ftop + FIN_WORDS * g.fins.len(),
            fins_rel(old(self).mem@, old(self).ftop as int, g.fins),
        ensures
            final(self).ftop == old(self).ftop - FRAME_WORDS,
            final(self).rtop == final(self).ftop + FIN_WORDS * sp::fins_popped(g).len(),
            final(self).rtop + FRAME_WORDS <= old(self).rtop,
            fins_rel(final(self).mem@, final(self).ftop as int, sp::fins_popped(g)),
            final(self).mem@.len() == old(self).mem@.len(),
            forall|i: int| 0 <= i < final(self).ftop ==> #[trigger] final(self).mem@[i] == old(self).mem@[i],
            forall|i: int| old(self).rtop <= i < old(self).mem@.len() ==> #[trigger] final(self).mem@[i] == old(self).mem@[i],
            final(self).top == old(self).top,
            final(self).len == old(self).len,
            final(self).bci == old(self).bci,
            final(self).base == old(self).base,
            final(self).lim == old(self).lim,
            final(self).method == old(self).method,
            final(self).globals == old(self).globals,
            final(self).heap == old(self).heap,
            final(self).g == old(self).g,
    {
        let ghost m0 = *self;
        let ftop = self.ftop;
        let r = ftop - FRAME_WORDS;
        proof {
            assert(r == FRAME_WORDS * (g.frames.len() - 1));
            assert(r / FRAME_WORDS == g.frames.len() - 1);
        }
        self.cut_records(r / FRAME_WORDS, 0, Ghost(g.fins));
        let e = self.rtop;
        let ghost k = sp::fins_popped(g).len() as int;
        let ghost m1 = *self;
        if e > ftop {
            self.mem.copy_within(ftop, r, e - ftop);
        }
        proof {
            assert forall|i: int| 0 <= i < self.mem@.len() && !(r <= i < e - FRAME_WORDS)
                implies #[trigger] self.mem@[i] == m0.mem@[i] by {}
            assert forall|i: int| 0 <= i < FIN_WORDS * k implies #[trigger] self.mem@[r + i] == m1.mem@[ftop + i] by {
                assert(self.mem@[r + i] == m1.mem@[r + i - r + ftop]);
            }
            lemma_fins_rel_move(m1.mem@, self.mem@, ftop as int, r as int, sp::fins_popped(g), k);
            assert(sp::fins_popped(g).subrange(0, k) =~= sp::fins_popped(g));
        }
        self.ftop = r;
        self.rtop = e - FRAME_WORDS;
    }

    /// `spec::return_from(g, v)` for the result word `w`: pops the top frame
    /// and its finally records (the last ones), moves the remaining records
    /// down over the popped frame record and pushes the result; a caller
    /// suspended in a TRY enters its finally code (`enter_finally` without
    /// unwinding).
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
        proof {
            self.lemma_frame(p);
            lemma_no_handler(g0);
        }
        if self.ftop == FRAME_WORDS {
            env.rt.report(V2_REPORT_TASK_RETURNED, self.bci, 0);
            return Ctl::Exit(RESULT_TERMINATED as u32, 1);
        }
        let r = self.ftop - FRAME_WORDS;
        let ret = self.mem.read(r + FRAME_RET);
        // The caller's frame record.
        let c = r - FRAME_WORDS;
        let method = self.mem.read(c + FRAME_METHOD);
        let base = self.mem.read(c + FRAME_BASE);
        let handler = self.mem.read(c + FRAME_HANDLER);
        let ghost n = g0.frames.len() as int;
        proof {
            assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
            assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
            assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
            assert(toit_spec::v2::sound::base_step(g0, n - 2));
        }
        self.pop_records(Ghost(g0));
        let ghost mem1 = self.mem@;
        self.top = self.len - self.base;
        self.method = method;
        self.base = base;
        self.lim = self.len - base;
        // Room: the callee's frame record is free now.
        self.top = self.top - 1;
        let t = self.top;
        self.mem.write(t, w);
        self.bci = ret;
        let ghost g1 = State2 {
            stack: g0.stack.subrange(0, sp::top(g0).base as int).push(v),
            frames: g0.frames.drop_last(),
            fins: sp::fins_popped(g0),
            bci: sp::top(g0).ret,
            ..g0
        };
        self.g = Ghost(g1);
        proof {
            assert(rec(m0.mem@, n - 1, FRAME_RET) == g0.frames[n - 1].ret);
            assert(rec(m0.mem@, n - 2, FRAME_METHOD) == g0.frames[n - 2].method);
            assert(rec(m0.mem@, n - 2, FRAME_BASE) == g0.frames[n - 2].base);
            assert(sp::base(g1) == g0.frames[n - 2].base);
            assert(toit_spec::v2::sound::base_step(g0, n - 2));
            lemma_frames_pop(m0.mem@, g0.frames, g0.tries);
            assert forall|i: int| 0 <= i < FRAME_WORDS * g1.frames.len() implies #[trigger] self.mem@[i] == m0.mem@[i] by {
                assert(mem1[i] == m0.mem@[i]);
            }
            lemma_frames_rel_same(m0.mem@, self.mem@, g1.frames, g1.tries);
            assert forall|i: int| self.ftop <= i < self.ftop + FIN_WORDS * g1.fins.len()
                implies #[trigger] self.mem@[i] == mem1[i] by {}
            lemma_fins_rel_same(mem1, self.mem@, self.ftop as int, g1.fins);
            let b = sp::top(g0).base as int;
            assert forall|i: int| t < i < self.len implies #[trigger] self.mem@[i] == m0.mem@[i] by {
                assert(mem1[i] == m0.mem@[i]);
            }
            assert(self.words() =~= m0.words().subrange(0, b).push(w));
            assert(enc_seq(m0.addr(), g1.stack) =~= enc_seq(m0.addr(), g0.stack).subrange(0, b).push(w));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i < b { assert(g1.stack[i] == g0.stack[i]); }
            }
            assert(self.method < p.methods@.len()) by {
                assert(sp::valid_method(ap, g0.frames[n - 2].method as int));
            }
            assert(self.refines(p));
        }
        proof {
            assert(handler == rec(m0.mem@, n - 2, FRAME_HANDLER));
            assert(rec(self.mem@, n - 2, FRAME_HANDLER) == handler);
            lemma_handler_word(self.mem@, g1.frames, g1.tries);
        }
        if handler != 0 {
            return self.enter_finally_normal(env, handler);
        }
        Ctl::Next
    }

    /// `spec::enter_finally(g, g.tries.last(), None)`: the top frame's handler
    /// (word `handler`) runs its finally code after a normal completion.
    #[inline(always)]
    pub fn enter_finally_normal(&mut self, env: &Env, handler: usize) -> (r: Ctl)
        requires
            old(self).refines(&env.p),
            sp::has_handler(old(self).g@),
            handler == handler_word(old(self).g@.tries.last()),
            forall|x: int| 0 <= x < old(self).g@.tries.len() ==>
                (#[trigger] old(self).g@.tries[x]).frame + 1 <= old(self).g@.frames.len(),
            forall|x: int, y: int| 0 <= x < y < old(self).g@.tries.len() ==>
                (#[trigger] old(self).g@.tries[x]).frame < (#[trigger] old(self).g@.tries[y]).frame,
            !(sp::enter_finally(env.p.ap@, old(self).g@, old(self).g@.tries.last(), None) is Stuck),
        ensures
            r == Ctl::Next || is_limit(r),
            r == Ctl::Next ==> final(self).refines(&env.p)
                && sp::enter_finally(env.p.ap@, old(self).g@, old(self).g@.tries.last(), None)
                    == Outcome2::Next(final(self).g@),
            final(self).len == old(self).len,
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost h = g0.tries.last();
        proof {
            self.lemma_frame(p);
            assert(g0.tries[g0.tries.len() - 1] == h);
            assert(FRAME_WORDS * (g0.frames.len() - 1) + FRAME_HANDLER_BCI == self.ftop - FRAME_WORDS + FRAME_HANDLER_BCI);
        }
        let height = handler;
        let rr = self.ftop - FRAME_WORDS;
        let hbci = self.mem.read(rr + FRAME_HANDLER_BCI);
        self.top = self.len - height;
        self.mem.write(rr + FRAME_HANDLER, 0);
        self.bci = hbci;
        let ghost g2 = State2 { stack: g0.stack.subrange(0, height as int), tries: g0.tries.drop_last(), bci: hbci, ..g0 };
        self.g = Ghost(g2);
        proof {
            let n = g0.frames.len() as int;
            let t2 = g2.tries;
            let m1 = self.mem@;
            // The frame records: the top's handler word is cleared with its handler.
            assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(m1, fi, FRAME_METHOD) == g2.frames[fi].method by {
                assert(rec(m1, fi, FRAME_METHOD) == rec(m0.mem@, fi, FRAME_METHOD));
            }
            assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(m1, fi, FRAME_RET) == g2.frames[fi].ret by {
                assert(rec(m1, fi, FRAME_RET) == rec(m0.mem@, fi, FRAME_RET));
            }
            assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(m1, fi, FRAME_BASE) == g2.frames[fi].base by {
                assert(rec(m1, fi, FRAME_BASE) == rec(m0.mem@, fi, FRAME_BASE));
            }
            assert forall|x: int| 0 <= x < t2.len() implies {
                &&& (#[trigger] t2[x]).frame < g2.frames.len()
                &&& 0 < t2[x].height < 0x1_0000_0000
                &&& t2[x].bci < 0x1_0000_0000
                &&& rec(m1, t2[x].frame as int, FRAME_HANDLER) == handler_word(t2[x])
                &&& rec(m1, t2[x].frame as int, FRAME_HANDLER_BCI) == t2[x].bci
            } by {
                assert(t2[x] == g0.tries[x]);
                assert(g0.tries[x].frame < h.frame);
                assert(rec(m1, t2[x].frame as int, FRAME_HANDLER) == rec(m0.mem@, t2[x].frame as int, FRAME_HANDLER));
                assert(rec(m1, t2[x].frame as int, FRAME_HANDLER_BCI) == rec(m0.mem@, t2[x].frame as int, FRAME_HANDLER_BCI));
            }
            assert forall|fi: int| 0 <= fi < n && #[trigger] rec(m1, fi, FRAME_HANDLER) != 0
                    implies exists|x: int| 0 <= x < t2.len() && t2[x].frame == fi by {
                assert(fi != n - 1);
                assert(rec(m1, fi, FRAME_HANDLER) == rec(m0.mem@, fi, FRAME_HANDLER));
                let x = choose|x: int| 0 <= x < g0.tries.len() && g0.tries[x].frame == fi;
                assert(x != g0.tries.len() - 1);
                assert(t2[x] == g0.tries[x]);
            }
            assert(frames_rel(m1, g2.frames, g2.tries));
            assert forall|i: int| self.ftop <= i < self.ftop + FIN_WORDS * g0.fins.len()
                implies #[trigger] m1[i] == m0.mem@[i] by {}
            lemma_fins_rel_same(m0.mem@, m1, self.ftop as int, g0.fins);
            assert(height as int == h.height);
            assert(h.height <= g0.stack.len());
            assert forall|i: int| 0 <= i < height implies #[trigger] self.words()[i] == m0.words()[i] by {
                assert(self.mem@[self.len - 1 - i] == m0.mem@[self.len - 1 - i]);
            }
            assert(self.words() =~= m0.words().subrange(0, height as int));
            assert(self.words() =~= enc_seq(m0.addr(), g2.stack));
            assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m0.addr(), g2.stack[i]) by {
                assert(g2.stack[i] == g0.stack[i]);
            }
            assert(self.refines(p));
            assert(const_ok(g0.heap, ap.roots[0]));
            lemma_smi_word(-1i64);
        }
        let null = p.null;
        if !self.push_val(p, null, Ghost(sp::null2(ap))) { return Ctl::Stuck(stuck::LIMIT); }
        if !self.push_val(p, null, Ghost(sp::null2(ap))) { return Ctl::Stuck(stuck::LIMIT); }
        let minus1 = smi_of(-1);
        if !self.push_val(p, minus1, Ghost(Value::Smi(-1i64))) { return Ctl::Stuck(stuck::LIMIT); }
        proof { assert(toit_spec::spec_common::smi(-1) == Value::Smi(-1i64)); }
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
            let r = m.push_call(env, t, bci + len);
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
