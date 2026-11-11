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

//! The register part of the machine (DESIGN.md, "Run loop").
//!
//! The run loop keeps the state that changes with nearly every
//! instruction in locals (`Regs`): cursors (`view::Slot`, pointers into the
//! stack array) for the object-stack top, the top frame's limit, the frame
//! top and the record top, and the bci. Inlined handlers take them by
//! `&mut` (a local whose address never escapes, so LLVM keeps the fields
//! in registers), out-of-line paths by value. The rest of the machine (the
//! views, the stack length, the top frame's method, the ghost state) stays
//! behind the `&mut Machine` pointer.
//!
//! While the loop runs, the machine's fields `top`, `lim`, `base`, `ftop`,
//! `rtop` and `bci` are stale; the machine the registers describe is
//! `m.with(r)`, and the abstraction of the pair is `m.with(r).refines(p)`:
//! the refinement relation is the one of `exec.rs`, unchanged. `sync`
//! writes the registers back (before a path that works on the machine
//! alone), `regs` derives them from the machine.

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use toit_spec::types::{Value, HeapObj};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;

verus! {

/// The hot part of the machine: cursors at the object-stack top (`sp`,
/// index `top`), at the top frame's limit (`fp`, index `lim`: slot `n`
/// exists iff `top + n < lim`), at the frame-record top (`fr`, `ftop`) and
/// at the record top (`rt`, `rtop`), and the bci.
#[derive(Clone, Copy)]
pub struct Regs {
    pub sp: Slot,
    pub fp: Slot,
    pub fr: Slot,
    pub rt: Slot,
    pub bci: usize,
}

impl Machine {
    /// The machine the registers `r` describe: `self` with its register
    /// fields replaced.
    pub open spec fn with(&self, r: Regs) -> Machine {
        Machine {
            top: r.sp@ as usize,
            lim: r.fp@ as usize,
            base: (self.len - r.fp@) as usize,
            ftop: r.fr@ as usize,
            rtop: r.rt@ as usize,
            bci: r.bci,
            ..*self
        }
    }

    /// The registers are cursors into this machine's stack view, inside
    /// its array.
    pub open spec fn rok(&self, r: Regs) -> bool {
        &&& r.sp.sid() == self.mem.sid()
        &&& r.fp.sid() == self.mem.sid()
        &&& r.fr.sid() == self.mem.sid()
        &&& r.rt.sid() == self.mem.sid()
        &&& 0 <= r.sp@ <= self.len
        &&& 0 <= r.fp@ <= self.len
        &&& 0 <= r.fr@ <= self.len
        &&& 0 <= r.rt@ <= self.len
    }

    /// The registers of this machine (`self.with(r) == self`).
    #[inline(always)]
    pub fn regs(&self) -> (r: Regs)
        requires self.stack_ok(),
        ensures self.rok(r), self.with(r) == *self,
    {
        let r = Regs {
            sp: self.mem.slot(self.top),
            fp: self.mem.slot(self.lim),
            fr: self.mem.slot(self.ftop),
            rt: self.mem.slot(self.rtop),
            bci: self.bci,
        };
        proof { assert(self.with(r) =~= *self); }
        r
    }

    /// Writes the registers back into the machine.
    #[inline(always)]
    pub fn sync(&mut self, r: Regs)
        requires old(self).rok(r), old(self).with(r).stack_ok(),
        ensures *final(self) == old(self).with(r),
    {
        let ghost m0 = *self;
        let lim = self.mem.index(r.fp);
        self.top = self.mem.index(r.sp);
        self.lim = lim;
        self.base = self.len - lim;
        self.ftop = self.mem.index(r.fr);
        self.rtop = self.mem.index(r.rt);
        self.bci = r.bci;
        proof { assert(*self =~= m0.with(r)); }
    }
}

/// The facts the register handlers start from: the registers are cursors
/// of the machine, which refines its ghost state with them.
pub open spec fn rpre(p: &Program, m: Machine, r: Regs) -> bool {
    m.rok(r) && m.with(r).refines(p)
}

/// A register handler's result for the instruction: `Next` with the spec's
/// next state `o` (as `exec.rs`'s handlers state it for the machine).
pub open spec fn rnext(p: &Program, m1: Machine, r1: Regs, o: Outcome2) -> bool {
    &&& m1.rok(r1)
    &&& m1.with(r1).refines(p)
    &&& o == Outcome2::Next(m1.g@)
}

// ---------------------------------------------------------------------------
// The object stack through the registers.

/// `STACK_AT(n)` of the top frame.
#[inline(always)]
pub fn at(m: &Machine, r: &Regs, n: usize) -> (w: usize)
    requires m.rok(*r), m.with(*r).stack_ok(), r.sp@ + n < r.fp@,
    ensures w == m.mem@[r.sp@ + n],
{
    r.sp.read(n, &m.mem)
}

/// Pushes the encoding `w` of `v` and continues at `bci + len`: refines
/// `goto(push(g, v), bci + len)`. Fails only for lack of room.
#[inline(always)]
pub fn push_next(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, len: usize, Ghost(v): Ghost<Value>) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
        old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next || is_limit(c),
        c != Ctl::Next ==> *final(m) == *old(m) && *final(r) == *old(r),
        c == Ctl::Next ==> rnext(p, *final(m), *final(r),
            Outcome2::Next(sp::goto(sp::push(old(m).g@, v), old(r).bci + len))),
{
    let ghost m0 = m.with(*r);
    if r.sp.diff(r.rt) == 0 {
        return Ctl::Stuck(stuck::LIMIT);
    }
    let s = r.sp.offset(-1);
    s.write(0, w, &mut m.mem);
    r.sp = s;
    r.bci = r.bci + len;
    let ghost g1 = sp::goto(sp::push(m0.g@, v), m0.bci + len);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().push(w));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < m0.g@.stack.len() { assert(g1.stack[i] == m0.g@.stack[i]); }
        }
        m0.lemma_local_step(p, &m1);
    }
    Ctl::Next
}

/// The machine after a step inside the top frame that replaced the object
/// stack by `m1`'s words and the ghost state by `g1` (same frames, records
/// and heap): it refines `g1`.
pub proof fn lemma_local(p: &Program, m0: Machine, m1: Machine, g1: State2)
    requires
        m0.refines(p),
        m1.stack_ok(),
        m1.len == m0.len, m1.ftop == m0.ftop, m1.rtop == m0.rtop,
        m1.base == m0.base, m1.lim == m0.lim, m1.method == m0.method,
        m1.heap == m0.heap,
        forall|i: int| 0 <= i < m0.rtop ==> #[trigger] m1.mem@[i] == m0.mem@[i],
        g1.heap == m0.g@.heap, g1.frames == m0.g@.frames, g1.tries == m0.g@.tries, g1.fins == m0.g@.fins,
        m1.words() == enc_seq(m0.addr(), g1.stack),
        forall|i: int| 0 <= i < g1.stack.len() ==> #[trigger] encodable(m0.addr(), g1.stack[i]),
        m1.bci == g1.bci,
        m1.globals@ == enc_seq(m0.addr(), g1.globals),
        forall|i: int| 0 <= i < g1.globals.len() ==> #[trigger] encodable(m0.addr(), g1.globals[i]),
        m1.g@ == g1,
    ensures m1.refines(p),
{
    m0.lemma_local_step(p, &m1);
}

/// LOAD_LOCAL, LOAD_LOCAL_WIDE, LOAD_LOCAL_0..5.
#[inline(always)]
pub fn op_load_local(m: &mut Machine, r: &mut Regs, p: &Program, n: usize, len: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_load_local(old(m).g@, n as int, len as int) is Stuck),
        old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next || is_limit(c),
        c != Ctl::Next ==> *final(m) == *old(m) && *final(r) == *old(r),
        c == Ctl::Next ==> rnext(p, *final(m), *final(r), sp::op_load_local(old(m).g@, n as int, len as int)),
{
    proof { m.with(*r).lemma_at(p, n as int); }
    let v = at(m, r, n);
    push_next(m, r, p, v, len, Ghost(sp::at(m.g@, n as int)))
}

/// POP_LOAD_LOCAL n.
#[inline(always)]
pub fn op_pop_load_local(m: &mut Machine, r: &mut Regs, p: &Program, n: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_pop_load_local(old(m).g@, n as int) is Stuck),
        old(r).bci + 2 < 0x1000_0000,
        n < 256,
    ensures
        c == Ctl::Next,
        rnext(p, *final(m), *final(r), sp::op_pop_load_local(old(m).g@, n as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, n + 1); m0.lemma_at(p, 0); }
    let v = at(m, r, n + 1);
    r.sp.write(0, v, &mut m.mem);
    r.bci = r.bci + 2;
    let ghost g1 = sp::goto(sp::put(g0, 0, sp::at(g0, n + 1)), g0.bci + 2);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().update(m0.height() - 1, v));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i != g0.stack.len() - 1 { assert(g1.stack[i] == g0.stack[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// STORE_LOCAL n.
#[inline(always)]
pub fn op_store_local(m: &mut Machine, r: &mut Regs, p: &Program, n: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_store_local(old(m).g@, n as int) is Stuck),
        old(r).bci + 2 < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rnext(p, *final(m), *final(r), sp::op_store_local(old(m).g@, n as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, n as int); m0.lemma_at(p, 0); }
    let v = at(m, r, 0);
    r.sp.write(n, v, &mut m.mem);
    r.bci = r.bci + 2;
    let ghost g1 = sp::goto(sp::put(g0, n as int, sp::at(g0, 0)), g0.bci + 2);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().update(m0.height() - 1 - n, v));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i != g0.stack.len() - 1 - n { assert(g1.stack[i] == g0.stack[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// STORE_LOCAL_POP n.
#[inline(always)]
pub fn op_store_local_pop(m: &mut Machine, r: &mut Regs, p: &Program, n: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_store_local_pop(old(m).g@, n as int) is Stuck),
        old(r).bci + 2 < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rnext(p, *final(m), *final(r), sp::op_store_local_pop(old(m).g@, n as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, n as int); m0.lemma_at(p, 0); }
    let v = at(m, r, 0);
    r.sp.write(n, v, &mut m.mem);
    r.sp = r.sp.offset(1);
    r.bci = r.bci + 2;
    let ghost g1 = sp::goto(sp::put(sp::drop(g0, 1), n - 1, sp::at(g0, 0)), g0.bci + 2);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let h = g0.stack.len();
        assert(g1.stack == g0.stack.subrange(0, h - 1).update(h - 1 - n, sp::at(g0, 0)));
        assert(m1.words() =~= m0.words().subrange(0, h - 1).update(h - 1 - n, v));
        assert forall|i: int| 0 <= i < h - 1 implies #[trigger] m1.words()[i] == enc(m0.addr(), g1.stack[i]) by {
            if i != h - 1 - n {
                assert(m1.words()[i] == m0.words()[i]);
                assert(m0.words()[i] == enc_seq(m0.addr(), g0.stack)[i]);
            }
        }
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i != g0.stack.len() - 1 - n { assert(g1.stack[i] == g0.stack[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// POP n, POP_1.
#[inline(always)]
pub fn op_pop(m: &mut Machine, r: &mut Regs, p: &Program, n: usize, len: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_pop(old(m).g@, n as int, len as int) is Stuck),
        old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rnext(p, *final(m), *final(r), sp::op_pop(old(m).g@, n as int, len as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_frame(p); }
    r.sp = r.sp.offset(n as isize);
    r.bci = r.bci + len;
    let ghost g1 = sp::goto(sp::drop(g0, n as int), g0.bci + len);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().subrange(0, m0.height() - n));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            assert(g1.stack[i] == g0.stack[i]);
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// LOAD_SMIS_0 n: pushes n zeros.
#[inline(always)]
pub fn op_load_smis_0(m: &mut Machine, r: &mut Regs, p: &Program, n: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        old(r).bci + 2 < 0x1000_0000,
    ensures
        c == Ctl::Next || is_limit(c),
        c != Ctl::Next ==> *final(m) == *old(m) && *final(r) == *old(r),
        c == Ctl::Next ==> rnext(p, *final(m), *final(r), sp::op_load_smis_0(old(m).g@, n as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    if r.sp.diff(r.rt) < n {
        return Ctl::Stuck(stuck::LIMIT);
    }
    proof { lemma_smi_word_nat(0); }
    let mut i: usize = 0;
    while i < n
        invariant
            m.rok(*r),
            i <= n,
            r.sp@ == m0.top - i,
            r.fp == old(r).fp, r.fr == old(r).fr, r.rt == old(r).rt, r.bci == old(r).bci,
            m.mem.sid() == m0.mem.sid(),
            m.mem@.len() == m0.mem@.len(),
            m.len == m0.len, m.heap == m0.heap, m.globals == m0.globals, m.g == m0.g, m.method == m0.method,
            m0.stack_ok(),
            m0.top >= m0.rtop + n,
            forall|j: int| 0 <= j < m0.rtop ==> #[trigger] m.mem@[j] == m0.mem@[j],
            m.with(*r).words() == m0.words() + Seq::new(i as nat, |j: int| 0usize),
        decreases n - i,
    {
        let ghost w0 = m.with(*r).words();
        let s = r.sp.offset(-1);
        s.write(0, 0, &mut m.mem);
        r.sp = s;
        i = i + 1;
        assert(m.with(*r).words() =~= w0.push(0usize));
        assert(m.with(*r).words() =~= m0.words() + Seq::new(i as nat, |j: int| 0usize));
    }
    r.bci = r.bci + 2;
    let ghost g1 = sp::goto(State2 { stack: g0.stack + Seq::new(n as nat, |j: int| Value::Smi(0)), ..g0 }, g0.bci + 2);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < g0.stack.len() { assert(g1.stack[i] == g0.stack[i]); }
        }
        assert(sp::op_load_smis_0(g0, n as int) == Outcome2::Next(g1)) by {
            assert(g1 == sp::goto(State2 { stack: g0.stack + Seq::new(n as nat, |j: int| Value::Smi(0)), ..g0 }, g0.bci + 2));
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// LOAD_LITERAL(_WIDE) i.
#[inline(always)]
pub fn op_load_literal(m: &mut Machine, r: &mut Regs, p: &Program, i: usize, len: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_load_literal(p.ap@, old(m).g@, i as int, len as int) is Stuck),
        old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next || is_limit(c),
        c != Ctl::Next ==> *final(m) == *old(m) && *final(r) == *old(r),
        c == Ctl::Next ==> rnext(p, *final(m), *final(r), sp::op_load_literal(p.ap@, old(m).g@, i as int, len as int)),
{
    let ghost v = p.ap@.literals[i as int];
    proof { assert(p.literals@[i as int] == enc(m.addr(), v) && const_ok(m.g@.heap, v)); }
    let w = p.literals.at(i);
    push_next(m, r, p, w, len, Ghost(v))
}

/// LOAD_NULL.
#[inline(always)]
pub fn op_load_null(m: &mut Machine, r: &mut Regs, p: &Program, len: usize) -> (c: Ctl)
    requires rpre(p, *old(m), *old(r)), old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next || is_limit(c),
        c != Ctl::Next ==> *final(m) == *old(m) && *final(r) == *old(r),
        c == Ctl::Next ==> rnext(p, *final(m), *final(r), sp::next(sp::push(old(m).g@, sp::null2(p.ap@)), len as int)),
{
    let ghost v = p.ap@.roots[0];
    proof { assert(const_ok(m.g@.heap, v)); }
    let w = p.null;
    push_next(m, r, p, w, len, Ghost(v))
}

/// LOAD_SMI_0, LOAD_SMI_1, LOAD_SMI_U8, LOAD_SMI_U16, LOAD_SMI_U32 and
/// LOAD_METHOD: push the smi `v`.
#[inline(always)]
pub fn op_load_smi(m: &mut Machine, r: &mut Regs, p: &Program, v: usize, len: usize) -> (c: Ctl)
    requires rpre(p, *old(m), *old(r)), old(r).bci + len < 0x1000_0000, v as int <= MAX_SMI,
    ensures
        c == Ctl::Next || is_limit(c),
        c != Ctl::Next ==> *final(m) == *old(m) && *final(r) == *old(r),
        c == Ctl::Next ==> rnext(p, *final(m), *final(r), sp::next(sp::push(old(m).g@, Value::Smi(v as i64)), len as int)),
{
    let w = smi_of(v as i64);
    push_next(m, r, p, w, len, Ghost(Value::Smi(v as i64)))
}

/// LOAD_GLOBAL_VAR(_WIDE) g.
#[inline(always)]
pub fn op_load_global(m: &mut Machine, r: &mut Regs, p: &Program, gi: usize, len: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_load_global(old(m).g@, gi as int, len as int) is Stuck),
        old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next || is_limit(c),
        c != Ctl::Next ==> *final(m) == *old(m) && *final(r) == *old(r),
        c == Ctl::Next ==> rnext(p, *final(m), *final(r), sp::op_load_global(old(m).g@, gi as int, len as int)),
{
    let ghost g0 = m.g@;
    proof {
        assert(enc_seq(m.addr(), g0.globals)[gi as int] == enc(m.addr(), g0.globals[gi as int]));
    }
    let v = m.globals.at(gi);
    push_next(m, r, p, v, len, Ghost(g0.globals[gi as int]))
}

/// STORE_GLOBAL_VAR(_WIDE) g.
#[inline(always)]
pub fn op_store_global(m: &mut Machine, r: &mut Regs, p: &Program, gi: usize, len: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_store_global(old(m).g@, gi as int, len as int) is Stuck),
        old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rnext(p, *final(m), *final(r), sp::op_store_global(old(m).g@, gi as int, len as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, 0); }
    let v = at(m, r, 0);
    m.globals.set(gi, v);
    r.bci = r.bci + len;
    let ghost g1 = sp::goto(State2 { globals: g0.globals.update(gi as int, sp::at(g0, 0)), ..g0 }, g0.bci + len);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(enc_seq(m0.addr(), g1.globals) =~= enc_seq(m0.addr(), g0.globals).update(gi as int, v));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.globals.len() implies #[trigger] encodable(m0.addr(), g1.globals[i]) by {
            if i != gi { assert(g1.globals[i] == g0.globals[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
    Ctl::Next
}

/// BRANCH*, BRANCH_BACK*: `kind` 0 always, 1 if true, 2 if false, 3 if
/// not null. The target is inside the method (from the spec).
#[inline(always)]
pub fn op_branch(m: &mut Machine, r: &mut Regs, p: &Program, kind: usize, target: usize, len: usize) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        kind <= 3,
        !(sp::op_branch(p.ap@, old(m).g@, kind as int, target as int, len as int) is Stuck),
        kind != 0 ==> !(sp::at(old(m).g@, 0) is BlockRef),
        old(r).bci + len < 0x1000_0000,
    ensures
        c == Ctl::Next,
        rnext(p, *final(m), *final(r), sp::op_branch(p.ap@, old(m).g@, kind as int, target as int, len as int)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    let ghost ap = p.ap@;
    if kind != 0 {
        proof { m0.lemma_at(p, 0); }
        let v = at(m, r, 0);
        r.sp = r.sp.offset(1);
        proof {
            let a = sp::at(g0, 0);
            let addr = m0.addr();
            assert(ap.roots[0] == sp::null2(ap) && ap.roots[2] == sp::false2(ap));
            assert(encodable(addr, ap.roots[0])) by { assert(const_ok(g0.heap, ap.roots[0])); }
            assert(encodable(addr, ap.roots[2])) by { assert(const_ok(g0.heap, ap.roots[2])); }
            lemma_enc_inj(g0.heap, addr, a, sp::null2(ap));
            lemma_enc_inj(g0.heap, addr, a, sp::false2(ap));
            assert((v == p.null) == (a == sp::null2(ap)));
            assert((v == p.false_) == (a == sp::false2(ap)));
        }
        let taken = Machine::taken(p, kind, v);
        let ghost t = if taken { target as int } else { g0.bci + len };
        if !taken {
            r.bci = r.bci + len;
        } else {
            r.bci = target;
        }
        let ghost g1 = sp::goto(sp::drop(g0, 1), t);
        m.g = Ghost(g1);
        proof {
            m0.lemma_frame(p);
            let m1 = m.with(*r);
            assert(g1.stack =~= g0.stack.subrange(0, g0.stack.len() - 1));
            assert(m1.words() =~= m0.words().subrange(0, m0.height() - 1));
            assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                assert(g1.stack[i] == g0.stack[i]);
            }
            lemma_local(p, m0, m1, g1);
        }
        Ctl::Next
    } else {
        r.bci = target;
        let ghost g1 = sp::goto(g0, target as int);
        m.g = Ghost(g1);
        proof {
            let m1 = m.with(*r);
            assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
            lemma_local(p, m0, m1, g1);
        }
        Ctl::Next
    }
}

} // verus!
