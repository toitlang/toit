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
use crate::calls::{handler_pre, lemma_tries};
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

verus! {

// ---------------------------------------------------------------------------
// Reloading the machine from the stack view.

/// The Stack header's record-top word: the record top and, above
/// `STACK_FRAME_TOP_SHIFT` bits, the frame top (both below
/// `MAX_STACK_LENGTH`).
pub open spec fn records_word(rtop: usize, ftop: usize) -> usize {
    rtop | (ftop << 16usize)
}

pub proof fn lemma_records_word(rtop: usize, ftop: usize)
    requires rtop < MAX_STACK_LENGTH, ftop < MAX_STACK_LENGTH,
    ensures
        records_word(rtop, ftop) & 0xffff == rtop,
        records_word(rtop, ftop) >> 16usize == ftop,
{
    assert((rtop | (ftop << 16usize)) & 0xffff == rtop && (rtop | (ftop << 16usize)) >> 16usize == ftop)
        by (bit_vector)
        requires rtop < 0x1_0000, ftop < 0x1_0000;
}

/// The machine with its cached fields re-derived from the stack view and
/// the Stack header (what `reload` computes), and ghost state `g`.
pub open spec fn reloaded(m: Machine, g: State2) -> Machine {
    let len = m.mem@.len();
    let word = m.mem.hdr(STACK_RECORD_TOP_WORD);
    let ftop = word >> 16usize;
    let r = ftop - FRAME_WORDS;
    let base = m.mem@[r + FRAME_BASE];
    Machine {
        len: len as usize,
        top: m.mem.hdr(STACK_TOP_WORD),
        rtop: word & 0xffff,
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
    &&& m.mem.hdr(STACK_RECORD_TOP_WORD) == records_word(m.rtop, m.ftop)
    &&& m.mem.hdr(STACK_BCI_WORD) == m.bci
}

/// A machine whose state is saved is its own reload.
pub proof fn lemma_saved(p: &Program, m: Machine)
    requires m.refines(p), saved(m),
    ensures reloaded(m, m.g@) == m,
{
    let g = m.g@;
    let n = g.frames.len() as int;
    lemma_records_word(m.rtop, m.ftop);
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
    let word = m.mem.header(STACK_RECORD_TOP_WORD);
    let ftop = word >> 16usize;
    let r = ftop - FRAME_WORDS;
    let method = m.mem.read(r + FRAME_METHOD);
    let base = m.mem.read(r + FRAME_BASE);
    m.len = len;
    m.top = top;
    m.rtop = word & 0xffff;
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
pub fn gc_allocate_instance(m: &mut Machine, env: &Env, c: usize, Ghost(g): Ghost<State2>) -> (r: (usize, bool))
    requires
        reloaded(*old(m), g).refines(&env.p),
        c < env.p.ap@.class_bits.len(),
        class_tag(p1(env.p.ap@), c as int) == INSTANCE_TAG,
        instance_field_count(p1(env.p.ap@), c as int) >= 0,
    ensures
        r.0 == 0 ==> reloaded(*final(m), g).refines(&env.p),
        r.0 != 0 ==> reloaded(*final(m), sp::alloc2(g, new_instance(env.p.ap@, c as int))).refines(&env.p)
            && r.0 == enc(final(m).addr(), sp::new_ref2(g)),
        // The epoch contract (TRUSTED.md, "Epoch"): nothing moved.
        !r.1 ==> crate::primitive::unmoved(*final(m), *old(m)),
{
    m.allocate_instance_raw(env, c)
}

/// A machine whose heap got the object `o` appended (`view::appended`,
/// nothing else changed) refines the state with `o` allocated.
pub proof fn lemma_refines_append(p: &Program, m0: Machine, m1: Machine, o: HeapObj, a: usize)
    requires
        m0.refines(p),
        crate::view::appended(&m0.heap, &m1.heap, a, p.ro_start, p.ro_size),
        m1.heap.objs() == m0.heap.objs().push(o),
        m1.heap.class_bits() == m0.heap.class_bits(),
        m1 == (Machine { heap: m1.heap, g: Ghost(sp::alloc2(m0.g@, o)), ..m0 }),
        obj_model_ok(o, m0.heap.class_bits(), m1.heap.addrs()),
        !o.ro,
    ensures m1.refines(p),
{
    let g0 = m0.g@;
    let o0 = m0.heap.objs(); let a0 = m0.heap.addrs();
    let o1 = m1.heap.objs(); let a1 = m1.heap.addrs();
    let cb = m0.heap.class_bits();
    let n = o0.len() as int;
    assert(heap_model_ok(o0, a0, cb));
    assert forall|i: int| 0 <= i < n implies #[trigger] o1[i] == o0[i] && a1[i] == a0[i] by {
        assert(o1.subrange(0, n)[i] == o0[i]);
        assert(a1.subrange(0, n)[i] == a0[i]);
    }
    assert(a1[n] == a);
    assert forall|i: int, j: int| 0 <= i < a1.len() && 0 <= j < a1.len() && i != j
            implies #[trigger] a1[i] != #[trigger] a1[j] by {
        if i < n && j < n { assert(a0[i] != a0[j]); }
        else if i < n { assert(a0[i] != a); }
        else if j < n { assert(a0[j] != a); }
    }
    assert forall|i: int| 0 <= i < a1.len() implies #[trigger] a1[i] & 3 == 1 by {
        if i < n { assert(a0[i] & 3 == 1); }
    }
    assert(addrs_ok(o1, a1));
    assert forall|v: Value| encodable(a0, v) implies #[trigger] encodable(a1, v) && enc(a1, v) == enc(a0, v) by {
        crate::fresh::lemma_enc_push(a0, a, v);
        assert(a1 == a0.push(a));
    }
    assert forall|i: int| 0 <= i < o1.len() implies #[trigger] obj_model_ok(o1[i], cb, a1) by {
        if i < n {
            assert(obj_model_ok(o0[i], cb, a0));
            match o0[i].body {
                Body::Instance(f) => {
                    assert forall|k: int| 0 <= k < f.len() implies #[trigger] encodable(a1, f[k]) by {
                        assert(encodable(a0, f[k]));
                    }
                },
                Body::Array(e) => {
                    assert forall|k: int| 0 <= k < e.len() implies #[trigger] encodable(a1, e[k]) by {
                        assert(encodable(a0, e[k]));
                    }
                },
                _ => {},
            }
        }
    }
    assert(heap_model_ok(o1, a1, cb));
    assert forall|i: int| 0 <= i < o1.len() implies #[trigger] m1.g@.heap[i].ro == in_ro(p, a1[i]) by {
        if i < n { assert(g0.heap[i].ro == in_ro(p, a0[i])); }
    }
    assert forall|i: int| 0 <= i < n implies (#[trigger] o1[i]).ro == o0[i].ro by {}
    crate::prims::lemma_prog_rel_mono(p, &m0.heap, &m1.heap);
    assert forall|i: int| 0 <= i < g0.stack.len() implies
        enc(a1, #[trigger] g0.stack[i]) == enc(a0, g0.stack[i]) && encodable(a1, g0.stack[i]) by {
        assert(encodable(a0, g0.stack[i]));
    }
    assert(m1.words() =~= enc_seq(a1, m1.g@.stack));
    assert forall|i: int| 0 <= i < g0.globals.len() implies
        enc(a1, #[trigger] g0.globals[i]) == enc(a0, g0.globals[i]) && encodable(a1, g0.globals[i]) by {
        assert(encodable(a0, g0.globals[i]));
    }
    assert(m1.globals@ =~= enc_seq(a1, m1.g@.globals));
}

/// The header word of an object of class `c` with tag `t`
/// (`HeapObject::header`: the smi `c << CLASS_ID_OFFSET | t`).
pub proof fn lemma_header(c: usize, t: usize)
    requires c < 0x1_0000, t < 16,
    ensures
        crate::view::hdr_class_id(((c << 5usize) | t) << 1usize) == c,
        crate::view::hdr_class_tag(((c << 5usize) | t) << 1usize) == t,
{
    assert(CLASS_ID_OFFSET == 5 && CLASS_TAG_MASK == 15);
    assert((((((((c << 5usize) | t) << 1usize) as isize) >> 1usize) as usize) >> 5usize) == c) by (bit_vector)
        requires c < 0x1_0000, t < 16;
    assert((((((((c << 5usize) | t) << 1usize) as isize) >> 1usize) as usize) & 15usize) == t) by (bit_vector)
        requires c < 0x1_0000, t < 16;
}

/// Allocates an instance of class `c` inline, with the new-space fast path
/// of the C++ allocator (`Runtime::bump`, `SemiSpace::try_allocate`: the
/// trusted part), and initializes it as `ObjectHeap::allocate_instance`
/// does (header with class id and tag, every field null), through the
/// permissions of the fresh words; the model gets the instance appended
/// (`Heap::append`). No GC: nothing moves, no state needs saving. On
/// success the machine the registers `r` describe represents `g` with the
/// new instance appended (the contract of `gc_allocate_instance` without
/// the GC), the result being its tagged address; 0 if new space is full
/// or the class id does not fit the model (nothing changed; the caller
/// then takes the C++ path).
#[inline(always)]
pub fn bump_instance(m: &mut Machine, env: &Env, c: usize, Ghost(r): Ghost<crate::regs::Regs>, Ghost(g): Ghost<State2>) -> (w: usize)
    requires
        old(m).with(r).refines(&env.p),
        old(m).g@ == g,
        c < env.p.ap@.class_bits.len(),
        class_tag(p1(env.p.ap@), c as int) == INSTANCE_TAG,
    ensures
        w == 0 ==> *final(m) == *old(m),
        w != 0 ==> *final(m) == (Machine { heap: final(m).heap, ..*old(m) })
            && (Machine { g: Ghost(sp::alloc2(g, new_instance(env.p.ap@, c as int))), ..*final(m) }).with(r).refines(&env.p)
            && w == enc(final(m).addr(), sp::new_ref2(g)),
{
    let ghost ap = env.p.ap@;
    let ghost m0 = *m;
    let ghost w0 = m.with(r);
    proof { assert(env.p.class_bits@ == ap.class_bits); }
    let bits = env.p.class_bits.at(c);
    let words = ((bits >> 5u16) & 0x7ffu16) as usize;
    proof { assert(((bits >> 5u16) & 0x7ffu16) <= 0x7ffu16) by (bit_vector); }
    if words == 0 || c >= 0x1_0000 {
        return 0;
    }
    let ghost cb = m.heap.class_bits();
    let ghost o = new_instance(ap, c as int);
    proof {
        assert(cb == ap.class_bits);
        assert(instance_field_count(p1(ap), c as int) == words - 1);
        assert(crate::view::obj_words(o) == words);
    }
    let (a, mut perms) = env.rt.bump(words * WORD_SIZE, &m.heap, Ghost(env.p.ro_start), Ghost(env.p.ro_size));
    if a == 0 {
        return 0;
    }
    let header = ((c << 5usize) | INSTANCE_TAG) << 1usize;
    m.heap.write_fresh(a, Tracked(perms.borrow_mut()), 0, header, Ghost(words as int));
    let null = env.p.null;
    let ghost a1 = m.heap.addrs().push((a + HEAP_TAG) as usize);
    proof {
        lemma_header(c, INSTANCE_TAG);
        assert(const_ok(m.heap.objs(), ap.roots[0]));
        crate::fresh::lemma_enc_push(m.heap.addrs(), (a + HEAP_TAG) as usize, ap.roots[0]);
        assert(null == enc(a1, sp::null2(ap)));
    }
    let mut i: usize = 1;
    while i < words
        invariant
            1 <= i <= words, words <= 0x7ff,
            a + WORD_SIZE * words <= usize::MAX,
            crate::fresh::fresh_perms(perms@, m.heap.prov(), a, words as int),
            perms@[0].is_init() && perms@[0].value() == header,
            forall|k: int| 1 <= k < i ==> #[trigger] perms@[k].is_init() && perms@[k].value() == null,
            *m == m0,
        decreases words - i,
    {
        m.heap.write_fresh(a, Tracked(perms.borrow_mut()), i, null, Ghost(words as int));
        i += 1;
    }
    proof {
        assert forall|k: int| 0 <= k < crate::view::obj_words(o) implies #[trigger] perms@[k].is_init()
            && crate::view::word_val(o, cb, a1, k, perms@[k].value()) by {
            if k == 0 {
                assert(o.class_id == c as u16);
            } else {
                assert(o.body->Instance_0[k - INSTANCE_FIELDS_WORD] == sp::null2(ap));
            }
        }
        assert forall|k: int| #[trigger] crate::view::is_word(o, k) <==> 0 <= k < crate::view::obj_words(o) by {}
        assert((cb[c as int] & 0xf) as usize == INSTANCE_TAG);
    }
    m.heap.append(a, perms, Ghost(o), Ghost(env.p.ro_start), Ghost(env.p.ro_size));
    proof {
        let m1 = Machine { g: Ghost(sp::alloc2(g, o)), ..*m }.with(r);
        assert(m.heap.addrs() == a1);
        assert(obj_model_ok(o, cb, a1)) by {
            assert forall|k: int| 0 <= k < o.body->Instance_0.len() implies #[trigger] encodable(a1, o.body->Instance_0[k]) by {
                assert(o.body->Instance_0[k] == ap.roots[0]);
            }
        }
        lemma_refines_append(&env.p, w0, m1, o, (a + HEAP_TAG) as usize);
        assert(((a + 1) as usize) == (a | 1usize)) by (bit_vector) requires a % 4 == 0, a < usize::MAX;
        assert(enc(m.addr(), sp::new_ref2(g)) == a1[g.heap.len() as int]);
    }
    a | HEAP_TAG
}

/// A double with the given bits, allocated inline as `bump_instance` does
/// (`ObjectHeap::allocate_double`: the header of the program's double
/// class, then the 64-bit value, as one or two words): the contract of
/// `gc_allocate_double` without the GC. 0 (the C++ path) unless the
/// program's double class has the double tag.
#[inline(always)]
pub fn bump_double(m: &mut Machine, env: &Env, bits: u64, Ghost(r): Ghost<crate::regs::Regs>, Ghost(g): Ghost<State2>) -> (w: usize)
    requires
        old(m).with(r).refines(&env.p),
        old(m).g@ == g,
    ensures
        w == 0 ==> *final(m) == *old(m),
        w != 0 ==> *final(m) == (Machine { heap: final(m).heap, ..*old(m) })
            && (Machine { g: Ghost(sp::alloc2(g, new_double(as1(g), p1(env.p.ap@), bits))), ..*final(m) }).with(r).refines(&env.p)
            && w == enc(final(m).addr(), sp::new_ref2(g)),
{
    let ghost ap = env.p.ap@;
    let ghost m0 = *m;
    let ghost w0 = m.with(r);
    proof { assert(env.p.class_bits@ == ap.class_bits); }
    if BUILTIN_DOUBLE >= env.p.builtin.len() {
        return 0;
    }
    proof {
        assert(env.p.builtin@[BUILTIN_DOUBLE as int] == smi_word(ap.builtin[BUILTIN_DOUBLE as int] as i64));
        lemma_smi_word(ap.builtin[BUILTIN_DOUBLE as int] as i64);
    }
    let cid = env.p.builtin.at(BUILTIN_DOUBLE) >> SMI_TAG_SIZE;
    if cid >= env.p.class_bits.len() || (env.p.class_bits.at(cid) & 0xfu16) as usize != DOUBLE_TAG {
        return 0;
    }
    let ghost cb = m.heap.class_bits();
    let ghost o = new_double(as1(g), p1(ap), bits);
    proof {
        assert(cid == ap.builtin[BUILTIN_DOUBLE as int]);
        assert(o.class_id == cid as u16);
        assert(crate::view::obj_words(o) == 1 + VALUE_WORDS);
    }
    let (a, mut perms) = env.rt.bump((1 + VALUE_WORDS) * WORD_SIZE, &m.heap, Ghost(env.p.ro_start), Ghost(env.p.ro_size));
    if a == 0 {
        return 0;
    }
    let header = ((cid << 5usize) | DOUBLE_TAG) << 1usize;
    m.heap.write_fresh(a, Tracked(perms.borrow_mut()), 0, header, Ghost((1 + VALUE_WORDS) as int));
    let w0v = crate::fresh::value_word_x(bits, 0);
    m.heap.write_fresh(a, Tracked(perms.borrow_mut()), 1, w0v, Ghost((1 + VALUE_WORDS) as int));
    if VALUE_WORDS == 2 {
        let w1v = crate::fresh::value_word_x(bits, 1);
        m.heap.write_fresh(a, Tracked(perms.borrow_mut()), 2, w1v, Ghost((1 + VALUE_WORDS) as int));
    }
    let ghost a1 = m.heap.addrs().push((a + HEAP_TAG) as usize);
    proof {
        lemma_header(cid, DOUBLE_TAG);
        assert forall|k: int| 0 <= k < crate::view::obj_words(o) implies #[trigger] perms@[k].is_init()
            && crate::view::word_val(o, cb, a1, k, perms@[k].value()) by {
            if k == 0 { assert(o.class_id == cid as u16); }
        }
        assert forall|k: int| #[trigger] crate::view::is_word(o, k) <==> 0 <= k < crate::view::obj_words(o) by {}
    }
    m.heap.append(a, perms, Ghost(o), Ghost(env.p.ro_start), Ghost(env.p.ro_size));
    proof {
        let m1 = Machine { g: Ghost(sp::alloc2(g, o)), ..*m }.with(r);
        assert(m.heap.addrs() == a1);
        lemma_refines_append(&env.p, w0, m1, o, (a + HEAP_TAG) as usize);
        assert(((a + 1) as usize) == (a | 1usize)) by (bit_vector) requires a % 4 == 0, a < usize::MAX;
        assert(enc(m.addr(), sp::new_ref2(g)) == a1[g.heap.len() as int]);
    }
    a | HEAP_TAG
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
        r.0 == 0 ==> reloaded(*final(m), g).refines(&env.p),
        r.0 != 0 ==> reloaded(*final(m), sp::alloc2(g, new_double(as1(g), p1(env.p.ap@), bits))).refines(&env.p)
            && r.0 == enc(final(m).addr(), sp::new_ref2(g)),
        !r.1 ==> crate::primitive::unmoved(*final(m), *old(m)),
{
    m.allocate_double_raw(env, bits)
}

} // verus!
