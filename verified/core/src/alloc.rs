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

//! Allocation, verified: ALLOCATE(_WIDE) (`spec::op_allocate`), the first
//! verified GC point.
//!
//! Across a call that may GC the machine's cached fields (length, top,
//! frame top, bci, and the top frame's base, limit and method) are stale:
//! the Stack object may move or shrink and every object reference may
//! change. The handler stores the task state into the Stack header
//! (`Machine::save`), calls C++, and re-derives every cached field from the
//! stack view and its header (`reload`). `reloaded(m, g)` is the machine
//! that re-derivation yields, with ghost state `g`; "the views (stack,
//! globals, heap model) represent `g`" is `reloaded(m, g).refines(p)`.
//!
//! The one trusted item is the contract of the allocation itself
//! (`gc_allocate_instance`): if the views represent `g` before, they
//! represent `g` with the new instance appended afterwards (or `g` itself
//! if the allocation failed). That is "the GC preserves the abstraction"
//! plus the allocation, stated on the views only; everything else
//! (the precondition, the reload, the push) is proven. Out of memory:
//! the instruction goes to `step_unverified`, whose checked handler
//! retries the allocation and throws the out-of-memory error
//! (`resource_throw`).
//!
//! The verifier proves the class instantiable (`is_instance_class`,
//! `ifc >= 0`), so the handler checks nothing.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::calls::{handler_pre, lemma_tries};
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::p1;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{class_tag, instance_field_count};

verus! {

// ---------------------------------------------------------------------------
// Reloading the machine from the stack view.

/// The machine with its cached fields re-derived from the stack view and
/// the Stack header (what `reload` computes), and ghost state `g`.
pub open spec fn reloaded(m: Machine, g: State2) -> Machine {
    let len = m.mem@.len();
    let ftop = m.mem.hdr(STACK_FRAME_TOP_WORD);
    let r = ftop - FRAME_WORDS;
    let base = m.mem@[r + FRAME_BASE];
    Machine {
        len: len as usize,
        top: m.mem.hdr(STACK_TOP_WORD),
        ftop: ftop,
        bci: m.mem.hdr(STACK_BCI_WORD),
        base: base,
        lim: (len - base) as usize,
        method: m.mem@[r + FRAME_METHOD],
        g: Ghost(g),
        ..m
    }
}

/// The task state is saved in the Stack header.
pub open spec fn saved(m: Machine) -> bool {
    &&& m.mem.hdr(STACK_TOP_WORD) == m.top
    &&& m.mem.hdr(STACK_FRAME_TOP_WORD) == m.ftop
    &&& m.mem.hdr(STACK_BCI_WORD) == m.bci
}

/// A machine whose state is saved is its own reload.
pub proof fn lemma_saved(p: &Program, m: Machine)
    requires m.refines(p), saved(m),
    ensures reloaded(m, m.g@) == m,
{
    let g = m.g@;
    let n = g.frames.len() as int;
    assert(rec(m.mem@, n - 1, FRAME_METHOD) == g.frames[n - 1].method);
    assert(rec(m.mem@, n - 1, FRAME_BASE) == g.frames[n - 1].base);
    assert(FRAME_WORDS * (n - 1) == m.ftop - FRAME_WORDS);
    let r = reloaded(m, g);
    assert(r.g == m.g);
}

/// Re-derives the cached fields from the stack view (`reloaded`). No
/// run-time checks: the views represent `g`.
#[inline(always)]
pub fn reload(m: &mut Machine, p: &Program, Ghost(g): Ghost<State2>)
    requires reloaded(*old(m), g).refines(p),
    ensures *final(m) == reloaded(*old(m), g),
{
    let ghost m0 = *m;
    let ghost r0 = reloaded(m0, g);
    proof {
        assert(r0.ftop == FRAME_WORDS * g.frames.len());
        assert(r0.len == m0.mem@.len());
    }
    let len = m.mem.len();
    let top = m.mem.header(STACK_TOP_WORD);
    let ftop = m.mem.header(STACK_FRAME_TOP_WORD);
    let bci = m.mem.header(STACK_BCI_WORD);
    let r = ftop - FRAME_WORDS;
    let method = m.mem.read(r + FRAME_METHOD);
    let base = m.mem.read(r + FRAME_BASE);
    m.len = len;
    m.top = top;
    m.ftop = ftop;
    m.bci = bci;
    m.method = method;
    m.base = base;
    m.lim = len - base;
    m.g = Ghost(g);
}

// ---------------------------------------------------------------------------
// The allocation.

/// The instance ALLOCATE creates (`spec::op_allocate`): class `c`, every
/// field null, not in the program heap.
pub open spec fn new_instance(ap: Program2, c: int) -> HeapObj {
    HeapObj {
        class_id: c as u16,
        ro: false,
        body: Body::Instance(Seq::new(instance_field_count(p1(ap), c) as nat, |i: int| sp::null2(ap))),
    }
}

/// TRUSTED (TRUSTED.md, "GC and allocation"): allocates an instance of
/// class `c` (C++ `toit_v2_allocate_instance`, which may GC). Before, the
/// stack view, the Stack header, the globals and the heap model represent
/// `g`. After, they represent `g` with the new instance appended, the
/// result being its (tagged) address; or, out of memory (result 0), `g`
/// itself. That is: the GC moves objects and updates every root (the
/// object stack, the globals; frame records and the header are not
/// references and are kept) without changing the abstract state, and the
/// allocation adds exactly the spec's object. The cached fields of the
/// machine are stale afterwards (`reload`).
#[verifier::external_body]
#[inline(always)]
pub fn gc_allocate_instance(m: &mut Machine, env: &Env, c: usize, Ghost(g): Ghost<State2>) -> (r: usize)
    requires
        reloaded(*old(m), g).refines(env.p),
        c < env.p.ap@.class_bits.len(),
        class_tag(p1(env.p.ap@), c as int) == INSTANCE_TAG,
        instance_field_count(p1(env.p.ap@), c as int) >= 0,
    ensures
        r == 0 ==> reloaded(*final(m), g).refines(env.p),
        r != 0 ==> reloaded(*final(m), sp::alloc2(g, new_instance(env.p.ap@, c as int))).refines(env.p)
            && r == enc(final(m).addr(), sp::new_ref2(g)),
{
    m.allocate_instance_raw(env, c)
}

/// ALLOCATE(_WIDE) c (`spec::op_allocate`).
#[inline(always)]
pub fn op_allocate(m: &mut Machine, env: &Env, bci: usize, opcode: u8, c: usize, len: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_allocate(env.p.ap@, old(m).g@, c as int, len as int),
        bci + len < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof { assert(outcome_ok(ap, p.cert@, sp::step(ap, g))); }
    m.save();
    proof { lemma_saved(p, *m); }
    let w = gc_allocate_instance(m, env, c, Ghost(g));
    if w == 0 {
        // Out of memory: the checked handler retries and throws.
        reload(m, p, Ghost(g));
        return step_unverified(m, env, bci, opcode, false);
    }
    let ghost o = new_instance(ap, c as int);
    let ghost g1 = sp::alloc2(g, o);
    reload(m, p, Ghost(g1));
    proof {
        assert(m.addr().len() == g1.heap.len());
    }
    let r = m.push_next(p, w, len, Ghost(sp::new_ref2(g)));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

} // verus!
