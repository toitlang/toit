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
//! (the precondition, the reload, the push) is proven. Out of memory is
//! the instruction's resource throw (`prim::resource_throw`): the
//! out-of-memory error is thrown (`unwind::throw_oom`).
//!
//! The verifier proves the class instantiable (`is_instance_class`,
//! `ifc >= 0`), so the handler checks nothing.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::calls::{handler_pre, lemma_frames_wf};
use toit_spec::types::{Value, HeapObj, Body, Unwind};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{class_tag, instance_field_count, new_double};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::gc::gc_steps;

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

/// The task state is saved in the Stack header (`Machine::save`).
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
    assert(r.ftop == m.ftop);
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
    let r = ftop - FRAME_WORDS;
    let method = m.mem.read(r + FRAME_METHOD);
    let base = m.mem.read(r + FRAME_BASE);
    m.len = len;
    m.top = top;
    m.ftop = ftop;
    m.bci = m.mem.header(STACK_BCI_WORD);
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

/// What an allocation that may collect leaves (`gc_allocate_instance`,
/// `gc_allocate_double`): collections from `g` to `g2`
/// (`toit_spec::v2::gc::gc_steps`; none if the heap's epoch did not
/// change), then the views represent `g2` with the new object `o`
/// appended, the result being its (tagged) address; or, out of memory
/// (result 0), `g2` itself.
pub open spec fn gc_alloc_post(p: &Program, m: Machine, g: State2, g2: State2, o: HeapObj, r: usize, moved: bool) -> bool {
    &&& gc_steps(p.ap@, g, g2)
    &&& !moved ==> g2 == g
    &&& r == 0 ==> reloaded(m, g2).refines(p)
    &&& r != 0 ==> reloaded(m, sp::alloc2(g2, o)).refines(p) && r == enc(m.addr(), sp::new_ref2(g2))
}

/// TRUSTED (TRUSTED.md, "GC and allocation"): allocates an instance of
/// class `c` (C++ `toit_v2_allocate_instance`, which may GC). Before, the
/// stack view, the Stack header, the globals and the heap model represent
/// `g`. After, `gc_alloc_post`: they represent a state `g2` that
/// collections reach from `g` (garbage gone, live objects renumbered,
/// weak maps processed; every root updated: the object stack, the
/// globals; frame records and the header are not references and are
/// kept) with the new instance appended, the result being its (tagged)
/// address; or, out of memory (result 0), `g2` itself. The allocation
/// adds exactly the spec's object. The cached fields of the machine are
/// stale afterwards (`reload`).
#[verifier::external_body]
#[inline(always)]
pub fn gc_allocate_instance(m: &mut Machine, env: &Env, c: usize, Ghost(g): Ghost<State2>) -> (r: (usize, bool))
    requires
        reloaded(*old(m), g).refines(&env.p),
        c < env.p.ap@.class_bits.len(),
        class_tag(p1(env.p.ap@), c as int) == INSTANCE_TAG,
        instance_field_count(p1(env.p.ap@), c as int) >= 0,
    ensures
        exists|g2: State2| #[trigger] gc_alloc_post(&env.p, *final(m), g, g2, new_instance(env.p.ap@, c as int), r.0, r.1),
        // The epoch contract (TRUSTED.md, "Epoch"): nothing moved.
        !r.1 ==> crate::primitive::unmoved(*final(m), *old(m)),
{
    m.allocate_instance_raw(env, c)
}

/// Allocates an instance of
/// class `c` inline, with the new-space fast path of the C++ allocator
/// (`Runtime::bump`, `SemiSpace::try_allocate`), and initializes it as
/// `ObjectHeap::allocate_instance` does (header with class id and tag,
/// every field null). No GC: nothing moves, no state needs saving. On
/// success the machine the registers `r` describe represents `g` with the
/// new instance appended (the contract of `gc_allocate_instance` without
/// the GC), the result being its tagged address. If the inline path declines
/// the allocation, it returns 0 with the heap unchanged and the caller takes
/// the C++ path.
#[inline(always)]
pub fn bump_instance(m: &mut Machine, env: &Env, c: usize, Ghost(r): Ghost<crate::regs::Regs>, Ghost(g): Ghost<State2>) -> (w: usize)
    requires
        old(m).with(r).inv(&env.p), crate::exec::ro_ok(&env.p),
        old(m).g@ == g,
        c < env.p.ap@.class_bits.len(),
        class_tag(p1(env.p.ap@), c as int) == INSTANCE_TAG,
    ensures
        w == 0 ==> *final(m) == *old(m),
        w != 0 ==> *final(m) == (Machine { heap: final(m).heap, ..*old(m) })
            && (Machine { g: Ghost(sp::alloc2(g, new_instance(env.p.ap@, c as int))), ..*final(m) }).with(r).refines(&env.p)
            && w == enc(final(m).addr(), sp::new_ref2(g)),
{
    env.rt.bump(m, &env.p, crate::ffi::InlineRequest::Instance(c), Ghost(r))
}

/// A double with the given bits,
/// allocated inline as `bump_instance` does (`ObjectHeap::allocate_double`:
/// the header of the program's double class, then the 64-bit value), with
/// the contract of `gc_allocate_double` without the GC.
#[inline(always)]
pub fn bump_double(m: &mut Machine, env: &Env, bits: u64, Ghost(r): Ghost<crate::regs::Regs>, Ghost(g): Ghost<State2>) -> (w: usize)
    requires
        old(m).with(r).inv(&env.p), crate::exec::ro_ok(&env.p),
        old(m).g@ == g,
    ensures
        w == 0 ==> *final(m) == *old(m),
        w != 0 ==> *final(m) == (Machine { heap: final(m).heap, ..*old(m) })
            && (Machine { g: Ghost(sp::alloc2(g, new_double(as1(g), p1(env.p.ap@), bits))), ..*final(m) }).with(r).refines(&env.p)
            && w == enc(final(m).addr(), sp::new_ref2(g)),
{
    env.rt.bump(m, &env.p, crate::ffi::InlineRequest::Double(bits), Ghost(r))
}

/// TRUSTED (TRUSTED.md, "GC and allocation"): allocates a double with the
/// given bits (C++ `toit_v2_allocate_double`, which may GC): the contract
/// of `gc_allocate_instance` with the spec's double
/// (`spec_common::new_double`) as the new object.
#[verifier::external_body]
#[inline(always)]
pub fn gc_allocate_double(m: &mut Machine, env: &Env, bits: u64, Ghost(g): Ghost<State2>) -> (r: (usize, bool))
    requires reloaded(*old(m), g).refines(&env.p),
    ensures
        exists|g2: State2| #[trigger] gc_alloc_post(&env.p, *final(m), g, g2, new_double(as1(g), p1(env.p.ap@), bits), r.0, r.1),
        !r.1 ==> crate::primitive::unmoved(*final(m), *old(m)),
{
    m.allocate_double_raw(env, bits)
}

} // verus!
