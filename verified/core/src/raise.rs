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

//! Raising, verified: `Outcome2::Raise(g, value)` completed as
//! `prim::raised` allows. The machine allocates the exception with C++
//! (`toit_v2_allocate_exception`, a GC point: it encodes the stack trace
//! and the failure message into a byte array and allocates an
//! `Exception_` holding the value and the trace), then unwinds with the
//! verified unwinding loop (`Machine::do_unwind`); if the allocation fails
//! it throws the out-of-memory error instead. The one trusted item is the
//! allocation's contract (`gc_allocate_exception`): the views afterwards
//! represent the state with the heap extended (`prim::heap_extended`: the
//! trace) and the exception `spec::exception_obj2(value, trace)` appended,
//! or only extended on failure: exactly the spec's oracle step.
//!
//! The message words are diagnostics (format 1's failure messages, part of
//! the trace); C++ reads them before its first GC point, so they must be
//! the words of values of the state (`msg_ok`).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use crate::calls::*;
use crate::alloc::reload;
#[cfg(verus_keep_ghost)]
use crate::alloc::{reloaded, saved, lemma_saved};
use crate::unwind::Unw;
use toit_spec::types::{Value, HeapObj, Unwind};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::p1;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, good, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::{heap_extended, with_heap2, raised, completes, out_of_memory};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::theorem::outcome;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::gc::gc_steps;

verus! {

/// The message words of a raise: values of the state, except the raw
/// module and index of a missing primitive (`V2_MESSAGE_PRIMITIVE`).
pub open spec fn msg_ok(addr: Seq<usize>, kind: usize, ws: Seq<usize>, vs: Seq<Value>) -> bool {
    &&& ws.len() == 4
    &&& vs.len() <= 4
    &&& kind != V2_MESSAGE_PRIMITIVE ==> forall|i: int| 0 <= i < vs.len() ==>
            #[trigger] ws[i] == enc(addr, vs[i]) && encodable(addr, vs[i])
}

/// What the exception allocation leaves: some extension `h2` of the heap
/// and trace `trace` with the exception appended (`r != 0`), or only the
/// extension (out of memory).
pub open spec fn exception_post(p: &Program, m: Machine, g: State2, v: Value, r: usize, h2: Seq<HeapObj>, trace: Value) -> bool {
    let ap = p.ap@;
    &&& heap_extended(ap, g.heap, h2)
    &&& good(h2, trace)
    &&& r == 0 ==> reloaded(m, with_heap2(g, h2)).refines(p)
    &&& r != 0 ==> reloaded(m, sp::alloc2(with_heap2(g, h2), sp::exception_obj2(ap, v, trace))).refines(p)
            && r == enc(m.addr(), sp::new_ref2(with_heap2(g, h2)))
}

/// TRUSTED (TRUSTED.md, "GC and allocation"): `toit_v2_allocate_exception`
/// (may GC). Before, the views represent `g`. After, they represent a
/// state `g2` that collections reach from `g`
/// (`toit_spec::v2::gc::gc_steps`) with its heap extended by the encoded
/// trace (a byte array, or nothing if encoding or allocating it failed;
/// trace null) and the exception `exception_obj2(v, trace)` appended, the
/// result being its address; or, if allocating the exception failed
/// (result 0), `g2` with the extended heap. The value is a program-heap
/// object or a smi (every collection keeps it: unmoved, same id).
#[verifier::external_body]
#[inline(always)]
pub fn gc_allocate_exception(m: &mut Machine, env: &Env, value: usize, kind: usize, ws: [usize; 4], count: usize,
    Ghost(g): Ghost<State2>, Ghost(v): Ghost<Value>, Ghost(vs): Ghost<Seq<Value>>) -> (r: usize)
    requires
        reloaded(*old(m), g).refines(&env.p),
        value == enc(old(m).addr(), v),
        const_ok(g.heap, v),
        count == vs.len(),
        msg_ok(old(m).addr(), kind, ws@, vs),
    ensures
        exists|g2: State2, h2: Seq<HeapObj>, trace: Value| gc_steps(env.p.ap@, g, g2)
            && #[trigger] exception_post(&env.p, *final(m), g2, v, r, h2, trace),
{
    m.allocate_exception_raw(env, value, kind, &ws, count)
}

/// Pushing onto the stack keeps the shape.
pub proof fn lemma_shape_stack(p: &Program, g: State2, g2: State2)
    requires
        shape_ok(p, g),
        g2.frames == g.frames, g2.stack.len() >= g.stack.len(),
    ensures shape_ok(p, g2),
{
    assert forall|fi: int| 0 <= fi && fi + 1 < g2.frames.len() implies #[trigger] toit_spec::v2::sound::base_step(g2, fi) by {
        assert(toit_spec::v2::sound::base_step(g, fi));
    }
}

/// Same frames, handlers, records and stack: the shape is kept.
pub proof fn lemma_shape_same(p: &Program, g: State2, g2: State2)
    requires
        shape_ok(p, g),
        g2.stack == g.stack, g2.frames == g.frames,
    ensures shape_ok(p, g2),
{
    assert forall|fi: int| 0 <= fi && fi + 1 < g2.frames.len() implies #[trigger] toit_spec::v2::sound::base_step(g2, fi) by {
        assert(toit_spec::v2::sound::base_step(g, fi));
    }
}

impl Machine {
    /// Raises `v` (word `value`) in the machine's state `g`, where
    /// `Raise(g, v)` is a source of outcomes of the state of `src` (the
    /// machine the instruction started from: the step's raise, or a
    /// resource throw's stack overflow): allocates the exception and
    /// unwinds, or throws out of memory.
    pub fn raise_with(&mut self, env: &Env, Ghost(src): Ghost<Machine>, value: usize, Ghost(v): Ghost<Value>,
        kind: usize, ws: [usize; 4], count: usize, Ghost(vs): Ghost<Seq<Value>>) -> (r: Ctl)
        requires
            src_ok(&env.p, src),
            old(self).refines(&env.p),
            shape_ok(&env.p, old(self).g@),
            source(env.p.ap@, src.g@, Outcome2::Raise(old(self).g@, v)),
            value == enc(old(self).addr(), v),
            const_ok(old(self).g@.heap, v),
            count == vs.len(),
            msg_ok(old(self).addr(), kind, ws@, vs),
            old(self).bci < 0x1000_0000,
        ensures step_post(&env.p, src, *final(self), r),
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        let ghost g = self.g@;
        let ghost m0 = src;
        let ghost gs = src.g@;
        proof { assert(ap.roots.len() == 35); }
        self.save();
        proof { lemma_saved(p, *self); }
        let w = gc_allocate_exception(self, env, value, kind, ws, count, Ghost(g), Ghost(v), Ghost(vs));
        // The allocation collected to `g2` (`raised`'s completion after
        // collections, `prim::raised_gc`).
        let ghost (g2, h2, trace) = choose|g2: State2, h2: Seq<HeapObj>, trace: Value| gc_steps(ap, g, g2)
            && #[trigger] exception_post(p, *self, g2, v, w, h2, trace);
        let ghost gh = with_heap2(g2, h2);
        proof {
            toit_spec::v2::gc::lemma_gc_steps_shape(ap, g, g2);
            assert(toit_spec::v2::gc::kept(g.heap, v));
        }
        if w == 0 {
            reload(self, p, Ghost(gh));
            let ghost u = Unwind::Throw(out_of_memory(ap));
            let ghost o2 = sp::unwind(ap, gh, u);
            proof {
                assert(toit_spec::v2::prim::raised_now(ap, g2, v, o2));
                reveal(toit_spec::v2::prim::raised_gc);
                assert(toit_spec::v2::prim::raised_gc(ap, g, v, o2));
                assert(raised(ap, g, v, o2));
                assert(completes(ap, Outcome2::Raise(g, v), o2));
                assert(outcome(ap, gs, o2));
                crate::unwind::lemma_unwind_not_raise(ap, gh, u);
                lemma_src_ok(p, m0);
                crate::step::lemma_unchecked_ok(p, gs);
                toit_spec::v2::theorem::lemma_outcome_ok(ap, p.cert@, p.trusted@, gs, o2);
                lemma_shape_stack(p, g, gh);
                self.lemma_root(p, ROOT_OUT_OF_MEMORY_ERROR as int);
            }
            let oom = p.roots.at(ROOT_OUT_OF_MEMORY_ERROR);
            let r = self.do_unwind(env, Unw::Throw(oom), Ghost(u));
            proof { lemma_outcome_matches(p, m0, *self, r, o2); }
            return r;
        }
        let ghost g1 = sp::alloc2(gh, sp::exception_obj2(ap, v, trace));
        reload(self, p, Ghost(g1));
        let ghost u = Unwind::Throw(sp::new_ref2(gh));
        let ghost o2 = sp::throw_exception(ap, gh, v, trace);
        proof {
            assert(toit_spec::v2::prim::raised_now(ap, g2, v, o2));
            reveal(toit_spec::v2::prim::raised_gc);
            assert(toit_spec::v2::prim::raised_gc(ap, g, v, o2));
            assert(raised(ap, g, v, o2));
            assert(completes(ap, Outcome2::Raise(g, v), o2));
            assert(outcome(ap, gs, o2));
            lemma_src_ok(p, m0);
            crate::step::lemma_unchecked_ok(p, gs);
            toit_spec::v2::theorem::lemma_outcome_ok(ap, p.cert@, p.trusted@, gs, o2);
            assert(o2 == sp::unwind(ap, g1, u));
            lemma_shape_stack(p, g, g1);
            assert(self.addr().len() == g1.heap.len());
        }
        let r = self.do_unwind(env, Unw::Throw(w), Ghost(u));
        proof { lemma_outcome_matches(p, m0, *self, r, o2); }
        r
    }
}

/// The word of the smi `v` as a value.
#[inline(always)]
pub fn smi_value_word(v: i64, Ghost(addr): Ghost<Seq<usize>>) -> (r: usize)
    requires smi_range(v as int),
    ensures r == enc(addr, Value::Smi(v)), encodable(addr, Value::Smi(v)),
{
    smi_of(v)
}

impl Machine {
    /// Raises failure `k` (`spec::raise(g, k)`, value `literals[2 + k]`)
    /// where that raise is a source of outcomes, with message words `ws`.
    #[inline(always)]
    pub fn raise_k(&mut self, env: &Env, k: usize, kind: usize, ws: [usize; 4], count: usize,
        Ghost(vs): Ghost<Seq<Value>>) -> (r: Ctl)
        requires
            old(self).inv(&env.p),
            k < 5,
            source(env.p.ap@, old(self).g@, sp::raise(env.p.ap@, old(self).g@, k as int)),
            count == vs.len(),
            msg_ok(old(self).addr(), kind, ws@, vs),
            old(self).bci < 0x1000_0000,
        ensures step_post(&env.p, *old(self), *final(self), r),
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        proof {
            assert(ap.literals.len() >= 7);
            let i = 2 + k as int;
            assert(p.literals@[i] == enc(self.addr(), ap.literals[i]) && const_ok(self.g@.heap, ap.literals[i]));
        }
        let value = p.literals.at(2 + k);
        let ghost m0 = *self;
        proof { lemma_shape(p, self.g@); }
        self.raise_with(env, Ghost(m0), value, Ghost(ap.literals[2 + k as int]), kind, ws, count, Ghost(vs))
    }

    /// Failure `k` without a message.
    #[inline(always)]
    pub fn v_raise_none(&mut self, env: &Env, k: usize) -> (r: Ctl)
        requires
            old(self).inv(&env.p),
            k < 5,
            source(env.p.ap@, old(self).g@, sp::raise(env.p.ap@, old(self).g@, k as int)),
            old(self).bci < 0x1000_0000,
        ensures step_post(&env.p, *old(self), *final(self), r),
    {
        self.raise_k(env, k, V2_MESSAGE_NONE, [0, 0, 0, 0], 0, Ghost(Seq::empty()))
    }

    /// Failure `k` without a message, raised in the machine's state where
    /// it is a source of outcomes of the state of `src`.
    #[inline(always)]
    pub fn v_raise_none_from(&mut self, env: &Env, Ghost(src): Ghost<Machine>, k: usize) -> (r: Ctl)
        requires
            src.inv(&env.p),
            old(self).refines(&env.p),
            shape_ok(&env.p, old(self).g@),
            k < 5,
            source(env.p.ap@, src.g@, sp::raise(env.p.ap@, old(self).g@, k as int)),
            old(self).bci < 0x1000_0000,
        ensures step_post(&env.p, src, *final(self), r),
    {
        let p = &env.p;
        let ghost ap = p.ap@;
        proof {
            assert(ap.literals.len() >= 7);
            let i = 2 + k as int;
            assert(p.literals@[i] == enc(self.addr(), ap.literals[i]) && const_ok(self.g@.heap, ap.literals[i]));
        }
        let value = p.literals.at(2 + k);
        self.raise_with(env, Ghost(src), value, Ghost(ap.literals[2 + k as int]), V2_MESSAGE_NONE, [0, 0, 0, 0], 0,
            Ghost(Seq::empty()))
    }

    /// INVALID_PROGRAM, with the bci as message (format 1's).
    #[inline(always)]
    pub fn v_raise_invalid(&mut self, env: &Env) -> (r: Ctl)
        requires
            old(self).inv(&env.p),
            source(env.p.ap@, old(self).g@, sp::raise(env.p.ap@, old(self).g@, sp::INVALID_PROGRAM)),
            old(self).bci < 0x1000_0000,
        ensures step_post(&env.p, *old(self), *final(self), r),
    {
        let ghost addr = self.addr();
        let w = smi_value_word(self.bci as i64, Ghost(addr));
        let ghost vs = seq![Value::Smi(self.bci as i64)];
        proof { assert([w, 0usize, 0usize, 0usize]@[0] == w); }
        self.raise_k(env, 3, V2_MESSAGE_WORD, [w, 0, 0, 0], 1, Ghost(vs))
    }

    /// AS_CHECK_FAILED for the value `v` (word `w`), with the value and the
    /// absolute bci after the check (where the compiler records the class
    /// name) as message.
    #[inline(always)]
    pub fn v_raise_as(&mut self, env: &Env, w: usize, Ghost(v): Ghost<Value>, len: usize) -> (r: Ctl)
        requires
            old(self).inv(&env.p),
            source(env.p.ap@, old(self).g@, sp::raise(env.p.ap@, old(self).g@, sp::AS_CHECK_FAILED)),
            old(self).bci + len < 0x1000_0000,
            w == enc(old(self).addr(), v), encodable(old(self).addr(), v),
        ensures step_post(&env.p, *old(self), *final(self), r),
    {
        let ghost addr = self.addr();
        let after = smi_value_word((self.bci + len) as i64, Ghost(addr));
        let ghost vs = seq![v, Value::Smi((self.bci + len) as i64)];
        let ws = [w, after, 0, 0];
        proof { assert(ws@[0] == w && ws@[1] == after); }
        self.raise_k(env, 1, V2_MESSAGE_ARRAY, ws, 2, Ghost(vs))
    }

    /// LOOKUP_FAILED for the receiver `rv` (word `rw`) and selector `sel`,
    /// with the selector, the receiver's class id and the receiver as
    /// message.
    #[inline(always)]
    pub fn v_raise_lookup(&mut self, env: &Env, rw: usize, Ghost(rv): Ghost<Value>, sel: i64) -> (r: Ctl)
        requires
            old(self).inv(&env.p),
            source(env.p.ap@, old(self).g@, sp::raise(env.p.ap@, old(self).g@, sp::LOOKUP_FAILED)),
            old(self).bci < 0x1000_0000,
            rw == enc(old(self).addr(), rv), encodable(old(self).addr(), rv), rv is Smi || rv is Obj,
            -0x8000_0000 <= sel < 0x8000_0000,
        ensures step_post(&env.p, *old(self), *final(self), r),
    {
        let p = &env.p;
        let ghost addr = self.addr();
        let cid = self.class_of(p, rw, Ghost(rv)) as i64;
        let cid = if -0x8000_0000 <= cid && cid < 0x8000_0000 && MIN_SMI <= cid && cid <= MAX_SMI { cid } else { -1 };
        // 32-bit targets: message words that are no smi are reported as -1.
        let sel = if MIN_SMI <= sel && sel <= MAX_SMI { sel } else { -1 };
        let sw = smi_value_word(sel, Ghost(addr));
        let cw = smi_value_word(cid, Ghost(addr));
        let ghost vs = seq![Value::Smi(sel), Value::Smi(cid), rv];
        let ws = [sw, cw, rw, 0];
        proof { assert(ws@[0] == sw && ws@[1] == cw && ws@[2] == rw); }
        self.raise_k(env, 0, V2_MESSAGE_ARRAY, ws, 3, Ghost(vs))
    }

    /// CODE_INVOCATION_FAILED, with whether a block was invoked, the
    /// expected and provided argument counts and the target's entry as
    /// message.
    #[inline(always)]
    pub fn v_raise_code(&mut self, env: &Env, is_block: bool, expected: usize, provided: usize, target: usize) -> (r: Ctl)
        requires
            old(self).inv(&env.p),
            source(env.p.ap@, old(self).g@, sp::raise(env.p.ap@, old(self).g@, sp::CODE_INVOCATION_FAILED)),
            old(self).bci < 0x1000_0000,
            expected < 0x1_0000, provided < 0x1_0000, target < env.p.methods@.len(),
        ensures step_post(&env.p, *old(self), *final(self), r),
    {
        let p = &env.p;
        let ghost addr = self.addr();
        let ghost m0 = *self;
        let bw = crate::ops::bool_word(p, is_block, Ghost(m0));
        let entry = p.method(target).entry as i64;
        let entry = if entry <= MAX_SMI { entry } else { -1 };
        let ew = smi_value_word(entry, Ghost(addr));
        let xw = smi_value_word(expected as i64, Ghost(addr));
        let pw = smi_value_word(provided as i64, Ghost(addr));
        let ghost vs = seq![sp::boolean2(p.ap@, is_block), Value::Smi(expected as i64), Value::Smi(provided as i64), Value::Smi(entry)];
        let ws = [bw, xw, pw, ew];
        proof { assert(ws@[0] == bw && ws@[1] == xw && ws@[2] == pw && ws@[3] == ew); }
        self.raise_k(env, 2, V2_MESSAGE_ARRAY, ws, 4, Ghost(vs))
    }
}

} // verus!
