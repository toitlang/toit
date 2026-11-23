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

//! Field access and type tests on registers (the fast paths; DESIGN.md
//! "Run loop"): LOAD_FIELD*, LOAD_FIELD_THIS, STORE_FIELD*,
//! STORE_FIELD_THIS, INVOKE_VIRTUAL_GET/SET, IS_*, AS_*.
//!
//! The fast paths read and write instance fields and do the type checks
//! natively, through the heap model's accessors and the helpers of
//! `fields.rs`/`types.rs` (which only need `hrefines`). A raise (an
//! invalid field access, a store into the program heap, a failed lookup or
//! AS check) and an accessor call without the fast call's room run the
//! instruction on the machine's handler (`step::bridge_r`).

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::step::*;
use crate::calls::*;
use crate::rcalls::{call_fast, push_call};
#[cfg(verus_keep_ghost)]
use crate::fields::{lemma_field_val, lemma_this};
#[cfg(verus_keep_ghost)]
use crate::types::lemma_put_rel;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok};

verus! {

// ---------------------------------------------------------------------------
// Common steps.

/// A handler that ends in the spec's next state inside the top frame
/// (`rnext` of the step, `rsame`) establishes `rpost`.
pub proof fn lemma_rpost_next(p: &Program, m0: Machine, r0: Regs, m1: Machine, r1: Regs)
    requires
        rinv(p, m0, r0),
        step_ok(p.ap@, p.cert@, m0.g@),
        rnext(p, m1, r1, sp::step(p.ap@, m0.g@)),
        rsame(m0, m1),
    ensures rpost(p, m0, r0, m1, r1, Ctl::Next),
{
    lemma_matches(p, m0.with(r0), m1.with(r1), Ctl::Next);
    lemma_room_same(p, m0.with(r0), m1.with(r1));
}

/// Replaces slot 0 by the encoding `w` of `v` and continues at
/// `bci + len`: refines `goto(put(g, 0, v), bci + len)`.
#[inline(always)]
pub fn put0_next(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, len: usize, Ghost(v): Ghost<Value>)
    requires
        m_ok(p, *old(m), *old(r)),
        sp::has_slot(old(m).g@, 0),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
        old(r).ip@ + len < 0x1000_0000,
    ensures
        rnext(p, *final(m), *final(r), Outcome2::Next(sp::goto(sp::put(old(m).g@, 0, v), old(r).ip@ + len))),
        rsame(*old(m), *final(m)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, 0); }
    r.sp.write(0, w, &mut m.mem);
    r.ip = r.ip.offset(len as isize);
    let ghost g1 = sp::goto(sp::put(g0, 0, v), g0.bci + len);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= m0.words().update(m0.height() - 1, w));
        lemma_put_rel(p, m0, m1, 0, w, v);
        lemma_local(p, m0, m1, g1);
    }
}

/// Continues at `bci + len`: refines `goto(g, bci + len)`.
#[inline(always)]
pub fn goto_next(m: &mut Machine, r: &mut Regs, p: &Program, len: usize)
    requires
        m_ok(p, *old(m), *old(r)),
        old(r).ip@ + len < 0x1000_0000,
    ensures
        rnext(p, *final(m), *final(r), Outcome2::Next(sp::goto(old(m).g@, old(r).ip@ + len))),
        rsame(*old(m), *final(m)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    r.ip = r.ip.offset(len as isize);
    let ghost g1 = sp::goto(g0, g0.bci + len);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        lemma_local(p, m0, m1, g1);
    }
}

/// `Machine::set_field_val` for the machine the registers describe: stores
/// the value `v` (word `w`) into field `f` of the instance `o` (word `wo`),
/// `spec::set_field2`; only the heap and the ghost state change.
#[inline(always)]
pub fn set_field_r(m: &mut Machine, r: &Regs, p: &Program, wo: usize, Ghost(o): Ghost<Value>, f: usize, w: usize, Ghost(v): Ghost<Value>)
    requires
        m_ok(p, *old(m), *r),
        wo == enc(old(m).addr(), o),
        o is Obj,
        (o->Obj_0 as int) < old(m).g@.heap.len(),
        old(m).g@.heap[o->Obj_0 as int].body is Instance,
        f < old(m).g@.heap[o->Obj_0 as int].body->Instance_0.len(),
        !old(m).g@.heap[o->Obj_0 as int].ro,
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
    ensures
        m_ok(p, *final(m), *r),
        final(m).g@ == sp::set_field2(old(m).g@, o, f as int, v),
        *final(m) == (Machine { heap: final(m).heap, g: final(m).g, ..*old(m) }),
        final(m).addr() == old(m).addr(),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    let ghost id = o->Obj_0 as int;
    m.heap.set_field(wo, f, w, Ghost(id), Ghost(v));
    let ghost g1 = sp::set_field2(g0, o, f as int, v);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let objs = m.heap.objs();
        let cb = m.heap.class_bits();
        let a = m.addr();
        assert(objs == g1.heap);
        assert forall|i: int| 0 <= i < objs.len() implies #[trigger] obj_model_ok(objs[i], cb, a) by {
            assert(obj_model_ok(g0.heap[i], cb, a));
            if i == id {
                let fs = g0.heap[id].body->Instance_0.update(f as int, v);
                assert forall|j: int| 0 <= j < fs.len() implies #[trigger] encodable(a, fs[j]) by {
                    if j != f { assert(fs[j] == g0.heap[id].body->Instance_0[j]); }
                }
            }
        }
        assert(heap_model_ok(objs, a, cb));
        assert forall|i: int| 0 <= i < g1.heap.len() implies #[trigger] g1.heap[i].ro == in_ro(p, a[i]) by {
            assert(g0.heap[i].ro == in_ro(p, a[i]));
        }
        crate::arrays::lemma_prog_rel_update(p, g0.heap, a, id, g1.heap[id]);
        assert(g1.heap == g0.heap.update(id, g1.heap[id]));
        assert(prog_rel(p, g1.heap, a));
        assert(m1.words() == m0.words());
        assert(m1.refines(p));
    }
}

// ---------------------------------------------------------------------------
// Fields.

/// LOAD_FIELD(_WIDE) f (`spec::op_load_field`).
#[inline(always)]
pub fn op_load_field(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, f: usize, len: usize, u: bool) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        u == sp::twin_at(env.p.ap@, old(m).g@), u ==> env.p.ap@.unchecked,
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_field(env.p.ap@, old(m).g@, f as int, len as int),
        f < 0x1_0000,
        bci + len < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, 0);
    }
    let w = at(m, r, 0);
    // Trusted programs in the unchecked mode skip the check: the step is not
    // stuck (`step_ok`), so the access is valid (`spec::unchecked_fail`).
    if !u && !m.field_access_ok(p, w, Ghost(sp::at(g, 0)), f, false) {
        proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); }
        return slow0(m, r, env, Slow::Invalid);
    }
    let ghost o = sp::at(g, 0);
    let ghost id = o->Obj_0 as int;
    proof { lemma_field_val(p, &w0, o, f as int); }
    let v = m.heap.field(w, f, Ghost(id));
    put0_next(m, r, p, v, len, Ghost(sp::field(g, o, f as int)));
    proof { lemma_rpost_next(p, m0, r0, *m, *r); }
    Ctl::Next
}

/// LOAD_FIELD_LOCAL / POP_LOAD_FIELD_LOCAL enc (`spec::op_load_field_local`).
#[inline(always)]
pub fn op_load_field_local(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, enc: usize, pop: bool, u: bool) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        u == sp::twin_at(env.p.ap@, old(m).g@), u ==> env.p.ap@.unchecked,
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_field_local(env.p.ap@, old(m).g@, enc as int, pop),
        enc < 256,
        bci + 2 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    let local = enc % 16;
    let f = enc / 16;
    let slot = if pop { local + 1 } else { local };
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, slot as int);
    }
    let w = at(m, r, slot);
    if !u && !m.field_access_ok(p, w, Ghost(sp::at(g, slot as int)), f, false) {
        proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); }
        return slow0(m, r, env, Slow::Invalid);
    }
    let ghost o = sp::at(g, slot as int);
    let ghost id = o->Obj_0 as int;
    proof { lemma_field_val(p, &w0, o, f as int); }
    let v = m.heap.field(w, f, Ghost(id));
    let ghost fv = sp::field(g, o, f as int);
    if pop {
        put0_next(m, r, p, v, 2, Ghost(fv));
    } else {
        push_next(m, r, p, v, 2, Ghost(fv));
    }
    proof { lemma_rpost_next(p, m0, r0, *m, *r); }
    Ctl::Next
}

/// STORE_FIELD(_WIDE, _POP) f (`spec::op_store_field`).
#[inline(always)]
pub fn op_store_field(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, f: usize, len: usize, keep: bool, u: bool) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        u == sp::twin_at(env.p.ap@, old(m).g@), u ==> env.p.ap@.unchecked,
        sp::step(env.p.ap@, old(m).g@) == sp::op_store_field(env.p.ap@, old(m).g@, f as int, len as int, keep),
        f < 0x1_0000,
        bci + len < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
    }
    let v = at(m, r, 0);
    let wo = at(m, r, 1);
    let ghost val = sp::at(g, 0);
    let ghost o = sp::at(g, 1);
    if !u && !m.field_access_ok(p, wo, Ghost(o), f, true) {
        proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); }
        return slow0(m, r, env, Slow::Invalid);
    }
    set_field_r(m, r, p, wo, Ghost(o), f, v, Ghost(val));
    let ghost m1 = m.with(*r);
    let ghost g1 = m.g@;
    proof { m1.lemma_frame(p); }
    if keep {
        let s = r.sp.offset(1);
        s.write(0, v, &mut m.mem);
        r.sp = s;
    } else {
        r.sp = r.sp.offset(2);
    }
    r.ip = r.ip.offset(len as isize);
    let ghost g2 = if keep { sp::goto(sp::push(sp::drop(g1, 2), val), bci + len) } else { sp::goto(sp::drop(g1, 2), bci + len) };
    m.g = Ghost(g2);
    proof {
        let m2 = m.with(*r);
        let h = g.stack.len() as int;
        if keep {
            assert(m2.words() =~= m1.words().subrange(0, h - 2).push(v));
        } else {
            assert(m2.words() =~= m1.words().subrange(0, h - 2));
        }
        assert(m2.words() =~= enc_seq(m1.addr(), g2.stack));
        assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m1.addr(), g2.stack[i]) by {
            if i < h - 2 { assert(g2.stack[i] == g1.stack[i]); }
        }
        lemma_local(p, m1, m2, g2);
        assert(sp::set_field2(sp::drop(g, 2), o, f as int, val) == sp::drop(g1, 2));
        lemma_rpost_next(p, m0, r0, *m, *r);
    }
    Ctl::Next
}

/// LOAD_FIELD_THIS f (`spec::op_load_field_this`): no checks (the
/// verifier proves `this` has the field). `this` is the slot below the
/// top frame's limit.
#[inline(always)]
pub fn op_load_field_this(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, f: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_field_this(env.p.ap@, old(m).g@, f as int),
        f < 256,
        bci + 2 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        lemma_this(p, &w0, f as int);
    }
    let ghost o = g.stack[w0.base as int];
    let ghost id = o->Obj_0 as int;
    let this = r.fp.offset(-1).read(0, &m.mem);
    proof { lemma_field_val(p, &w0, o, f as int); }
    let v = m.heap.field(this, f, Ghost(id));
    push_next(m, r, p, v, 2, Ghost(sp::field(g, o, f as int)));
    proof { lemma_rpost_next(p, m0, r0, *m, *r); }
    Ctl::Next
}

/// STORE_FIELD_THIS f (`spec::op_store_field_this`): the value stays. A
/// store into a program-heap object (INVALID_PROGRAM) takes the bridge.
#[inline(always)]
pub fn op_store_field_this(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, f: usize, u: bool) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        u == sp::twin_at(env.p.ap@, old(m).g@), u ==> env.p.ap@.unchecked,
        sp::step(env.p.ap@, old(m).g@) == sp::op_store_field_this(env.p.ap@, old(m).g@, f as int),
        f < 256,
        bci + 2 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        lemma_this(p, &w0, f as int);
        w0.lemma_at(p, 0);
    }
    let ghost o = g.stack[w0.base as int];
    let ghost id = o->Obj_0 as int;
    let this = r.fp.offset(-1).read(0, &m.mem);
    if !u && m.is_ro_word(p, this, Ghost(id)) {
        proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM)); }
        return slow0(m, r, env, Slow::Invalid);
    }
    let v = at(m, r, 0);
    set_field_r(m, r, p, this, Ghost(o), f, v, Ghost(sp::at(g, 0)));
    goto_next(m, r, p, 2);
    proof { lemma_rpost_next(p, m0, r0, *m, *r); }
    Ctl::Next
}

/// INVOKE_VIRTUAL_GET sel (`spec::op_invoke_virtual_get`): a field
/// accessor reads the field in place; anything else is a call.
#[inline(always)]
pub fn op_invoke_virtual_get(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, sel: usize, u: bool) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        u == sp::twin_at(env.p.ap@, old(m).g@), u ==> env.p.ap@.unchecked,
        toit_spec::v2::prim::grows_stack(opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_virtual_get(env.p.ap@, old(m).g@, sel as int),
        sel < 0x1_0000,
        bci + 3 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, 0);
    }
    let w = at(m, r, 0);
    let ghost recv = sp::at(g, 0);
    match m.lookup(p, w, Ghost(recv), sel as i64) {
        VLookup::Missing => {
            proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::LOOKUP_FAILED)); }
            slow_r(m, r, env, Slow::Lookup(sel as i64), w, Ghost(recv))
        },
        VLookup::Found(t) => {
            let info = p.method(t);
            proof { assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height)); }
            let f = info.aux as usize;
            if p.is_kind(t, KIND_FIELD_ACCESSOR) && (u || m.field_access_ok(p, w, Ghost(recv), f, false)) {
                let ghost id = recv->Obj_0 as int;
                proof { lemma_field_val(p, &w0, recv, f as int); }
                let v = m.heap.field(w, f, Ghost(id));
                put0_next(m, r, p, v, 3, Ghost(sp::field(g, recv, f as int)));
                proof { lemma_rpost_next(p, m0, r0, *m, *r); }
                return Ctl::Next;
            }
            if !call_fast(m, r, env) {
                proof { assert(sp::step(ap, g) == sp::call(ap, g, t as int, bci + 3)); }
                return slow0(m, r, env, Slow::Call(t, bci + 3));
            }
            proof { w0.lemma_frame(p); }
            proof { assert(sp::arity(ap, t as int) == 1); }
            push_call(m, r, p, t, info.entry as usize, 1, bci + 3);
            proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
            Ctl::Next
        },
    }
}

/// INVOKE_VIRTUAL_SET sel (`spec::op_invoke_virtual_set`): a field
/// accessor writes the field in place; anything else is a call.
#[inline(always)]
pub fn op_invoke_virtual_set(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, sel: usize, u: bool) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        u == sp::twin_at(env.p.ap@, old(m).g@), u ==> env.p.ap@.unchecked,
        toit_spec::v2::prim::grows_stack(opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_virtual_set(env.p.ap@, old(m).g@, sel as int),
        sel < 0x1_0000,
        bci + 3 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
    }
    let v = at(m, r, 0);
    let w = at(m, r, 1);
    let ghost val = sp::at(g, 0);
    let ghost recv = sp::at(g, 1);
    match m.lookup(p, w, Ghost(recv), sel as i64) {
        VLookup::Missing => {
            proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::LOOKUP_FAILED)); }
            slow_r(m, r, env, Slow::Lookup(sel as i64), w, Ghost(recv))
        },
        VLookup::Found(t) => {
            let info = p.method(t);
            proof { assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height)); }
            let f = info.aux as usize;
            if p.is_kind(t, KIND_FIELD_ACCESSOR) && (u || m.field_access_ok(p, w, Ghost(recv), f, true)) {
                set_field_r(m, r, p, w, Ghost(recv), f, v, Ghost(val));
                let ghost m1 = m.with(*r);
                let ghost g1 = m.g@;
                proof { m1.lemma_frame(p); }
                let s = r.sp.offset(1);
                s.write(0, v, &mut m.mem);
                r.sp = s;
                r.ip = r.ip.offset(3);
                let ghost g2 = sp::goto(sp::push(sp::drop(g1, 2), val), bci + 3);
                m.g = Ghost(g2);
                proof {
                    let m2 = m.with(*r);
                    let h = g.stack.len() as int;
                    assert(m2.words() =~= m1.words().subrange(0, h - 2).push(v));
                    assert(m2.words() =~= enc_seq(m1.addr(), g2.stack));
                    assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m1.addr(), g2.stack[i]) by {
                        if i < h - 2 { assert(g2.stack[i] == g1.stack[i]); }
                    }
                    lemma_local(p, m1, m2, g2);
                    assert(sp::push(sp::set_field2(sp::drop(g, 2), recv, f as int, val), val) == sp::push(sp::drop(g1, 2), val));
                    lemma_rpost_next(p, m0, r0, *m, *r);
                }
                return Ctl::Next;
            }
            if !call_fast(m, r, env) {
                proof { assert(sp::step(ap, g) == sp::call(ap, g, t as int, bci + 3)); }
                return slow0(m, r, env, Slow::Call(t, bci + 3));
            }
            proof { w0.lemma_frame(p); }
            proof { assert(sp::arity(ap, t as int) == 2); }
            push_call(m, r, p, t, info.entry as usize, 2, bci + 3);
            proof { lemma_matches(p, w0, m.with(*r), Ctl::Next); }
            Ctl::Next
        },
    }
}

// ---------------------------------------------------------------------------
// Type tests.

/// IS_CLASS(_WIDE), IS_INTERFACE(_WIDE) enc (`spec::op_is`): replaces the
/// top of the stack by true or false.
#[inline(always)]
pub fn op_is(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, enc: usize, interface: bool, len: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_is(env.p.ap@, old(m).g@, enc as int, interface, len as int),
        enc < 0x1_0000,
        bci + len < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, 0);
    }
    let w = at(m, r, 0);
    let yes = m.check_type(p, w, Ghost(sp::at(g, 0)), enc / 2, enc % 2 == 1, interface);
    let result = if yes { p.true_ } else { p.false_ };
    let ghost rv = if yes { sp::true2(ap) } else { sp::false2(ap) };
    proof {
        assert(const_ok(g.heap, ap.roots[1]));
        assert(const_ok(g.heap, ap.roots[2]));
    }
    put0_next(m, r, p, result, len, Ghost(rv));
    proof { lemma_rpost_next(p, m0, r0, *m, *r); }
    Ctl::Next
}

/// AS_CLASS(_WIDE), AS_INTERFACE(_WIDE) enc (`spec::op_as`): continues if
/// the top of the stack passes the check; a failure raises (bridge).
#[inline(always)]
pub fn op_as(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, enc: usize, interface: bool, len: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_as(env.p.ap@, old(m).g@, enc as int, interface, len as int),
        enc < 0x1_0000,
        bci + len < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, 0);
    }
    let w = at(m, r, 0);
    if !m.check_type(p, w, Ghost(sp::at(g, 0)), enc / 2, enc % 2 == 1, interface) {
        proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::AS_CHECK_FAILED)); }
        return slow_r(m, r, env, Slow::As(len), w, Ghost(sp::at(g, 0)));
    }
    goto_next(m, r, p, len);
    proof { lemma_rpost_next(p, m0, r0, *m, *r); }
    Ctl::Next
}

/// AS_LOCAL enc (`spec::op_as_local`): continues if local `enc / 32`
/// passes class check `enc % 32`; a failure raises (bridge).
#[inline(always)]
pub fn op_as_local(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8, enc: usize) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_as_local(env.p.ap@, old(m).g@, enc as int),
        enc < 0x100,
        bci + 2 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    let n = enc / 32;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        w0.lemma_at(p, n as int);
    }
    let w = at(m, r, n);
    if !m.check_type(p, w, Ghost(sp::at(g, n as int)), enc % 32, false, false) {
        proof { assert(sp::step(ap, g) == sp::raise(ap, g, sp::AS_CHECK_FAILED)); }
        return slow_r(m, r, env, Slow::As(2), w, Ghost(sp::at(g, n as int)));
    }
    goto_next(m, r, p, 2);
    proof { lemma_rpost_next(p, m0, r0, *m, *r); }
    Ctl::Next
}

} // verus!
