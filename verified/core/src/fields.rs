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

//! Field access, verified: LOAD_FIELD*, LOAD_FIELD_THIS, STORE_FIELD*,
//! STORE_FIELD_THIS and the field-accessor fast paths of
//! INVOKE_VIRTUAL_GET/SET. Fields are read and written through the heap
//! model's accessors (view.rs). The checks of `field_readable` and
//! `field_writable` stay (the spec has them: INVALID_PROGRAM); the `this`
//! variants have none (the verifier proves the receiver's fields). Raising
//! INVALID_PROGRAM and LOOKUP_FAILED is not proven yet: those paths hand
//! the instruction to `step_unverified` before changing anything.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use crate::calls::*;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, tables_ok, task_class_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{builtin, is_instance, fields, obj, obj_id, class_of_obj, instance_field_count};

verus! {

/// The task class is the only class with the task tag (`task_class_ok`).
pub proof fn lemma_task_tag(p: &Program, cid: int)
    requires accepts(p.ap@, p.cert@, p.trusted@), 0 <= cid < p.ap@.class_bits.len(),
    ensures (tag_bits(p.ap@.class_bits, cid) == TASK_TAG as int) == (cid == builtin(p1(p.ap@), 19)),
{
    let ap = p.ap@;
    assert(tables_ok(ap, p.cert@));
    assert(task_class_ok(ap));
    let tc = builtin(p1(ap), 19);
    if cid == tc {
        assert(toit_spec::spec_common::class_tag(p1(ap), tc) == TASK_TAG as u16);
    } else if tag_bits(ap.class_bits, cid) == TASK_TAG as int {
        assert(toit_spec::spec_common::class_tag(p1(ap), cid) == TASK_TAG as u16);
    }
}

impl Machine {
    /// The value at `w` is an object of the program heap (`spec::is_ro`).
    #[inline(always)]
    pub fn is_ro_word(&self, p: &Program, w: usize, Ghost(id): Ghost<int>) -> (r: bool)
        requires
            self.refines(p),
            0 <= id < self.g@.heap.len(),
            w == self.addr()[id],
        ensures r == self.g@.heap[id].ro,
    {
        w >= p.ro_start && w - p.ro_start < p.ro_size
    }

    /// `spec::field_readable` (`write` false) or `spec::field_writable`
    /// (`write` true) of the value `v` (word `w`) and field `f`.
    #[inline(always)]
    pub fn field_access_ok(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>, f: usize, write: bool) -> (r: bool)
        requires
            self.refines(p),
            accepts(p.ap@, p.cert@, p.trusted@),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            f < 0x1_0000,
        ensures
            r == (if write { sp::field_writable(p.ap@, self.g@, v, f as int) }
                else { sp::field_readable(p.ap@, self.g@, v, f as int) }),
            r ==> v is Obj && (v->Obj_0 as int) < self.g@.heap.len()
                && self.g@.heap[v->Obj_0 as int].body is Instance
                && f < self.g@.heap[v->Obj_0 as int].body->Instance_0.len(),
    {
        let ghost ap = p.ap@;
        let ghost g = self.g@;
        proof {
            match v {
                Value::Smi(i) => { lemma_smi_word(i); },
                Value::Obj(id) => { lemma_obj_not_smi(self.heap.objs(), self.addr(), id); },
                Value::BlockRef(fr, sl) => { lemma_smi_word((fr * 0x10_0000 + sl) as i64); },
                _ => {},
            }
        }
        if w & 1 == 0 {
            return false;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(g.heap[id], self.heap.class_bits(), self.addr())); }
        let tag = self.heap.class_tag(w, Ghost(id));
        if tag != INSTANCE_TAG && tag != TASK_TAG {
            return false;
        }
        let cid = self.heap.class_id(w, Ghost(id));
        let bits = p.class_bits.at(cid);
        let size = ((bits >> 5u16) & 0x7ffu16) as usize;
        proof {
            assert(size as int - 1 == ifc_bits(p.class_bits@, cid as int));
            assert(g.heap[id].body->Instance_0.len() == size - 1);
            lemma_task_tag(p, cid as int);
        }
        if f + 1 >= size {
            return false;
        }
        if tag == TASK_TAG && f <= (if write { 1 } else { 0 }) {
            return false;
        }
        if write && self.is_ro_word(p, w, Ghost(id)) {
            return false;
        }
        true
    }

    /// Stores the value `v` (word `w`) into field `f` of the instance `o`
    /// (word `wo`): `spec::set_field2`.
    #[inline(always)]
    pub fn set_field_val(&mut self, p: &Program, wo: usize, Ghost(o): Ghost<Value>, f: usize, w: usize, Ghost(v): Ghost<Value>)
        requires
            old(self).refines(p),
            wo == enc(old(self).addr(), o),
            o is Obj,
            (o->Obj_0 as int) < old(self).g@.heap.len(),
            old(self).g@.heap[o->Obj_0 as int].body is Instance,
            f < old(self).g@.heap[o->Obj_0 as int].body->Instance_0.len(),
            !old(self).g@.heap[o->Obj_0 as int].ro,
            w == enc(old(self).addr(), v),
            encodable(old(self).addr(), v),
        ensures
            final(self).refines(p),
            final(self).g@ == sp::set_field2(old(self).g@, o, f as int, v),
            final(self).top == old(self).top,
            final(self).bci == old(self).bci,
            final(self).same_stack(old(self)),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost id = o->Obj_0 as int;
        self.heap.set_field(wo, f, w, Ghost(id), Ghost(v));
        let ghost g1 = sp::set_field2(g0, o, f as int, v);
        self.g = Ghost(g1);
        proof {
            let objs = self.heap.objs();
            let cb = self.heap.class_bits();
            let a = self.addr();
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
            assert(self.refines(p));
        }
    }

    /// Only the heap changed: the stack memory, the frame cache, the
    /// globals and the addresses are the same.
    pub open spec fn same_stack(&self, other: &Machine) -> bool {
        &&& self.mem@ == other.mem@
        &&& self.len == other.len
        &&& self.ftop == other.ftop
        &&& self.rtop == other.rtop
        &&& self.base == other.base
        &&& self.lim == other.lim
        &&& self.method == other.method
        &&& self.globals@ == other.globals@
        &&& self.heap.addrs() == other.heap.addrs()
        &&& self.heap.class_bits() == other.heap.class_bits()
    }
}

} // verus!

verus! {

/// The value of field `f` of the instance `v` (word `w`) is encodable and
/// its word is what the heap accessor returns.
proof fn lemma_field_val(p: &Program, m: &Machine, v: Value, f: int)
    requires
        m.refines(p),
        v is Obj,
        (v->Obj_0 as int) < m.g@.heap.len(),
        m.g@.heap[v->Obj_0 as int].body is Instance,
        0 <= f < m.g@.heap[v->Obj_0 as int].body->Instance_0.len(),
    ensures
        encodable(m.addr(), sp::field(m.g@, v, f)),
        sp::field(m.g@, v, f) == m.g@.heap[v->Obj_0 as int].body->Instance_0[f],
{
    let id = v->Obj_0 as int;
    assert(obj_model_ok(m.g@.heap[id], m.heap.class_bits(), m.addr()));
}

/// LOAD_FIELD(_WIDE) f (`spec::op_load_field`).
#[inline(always)]
pub fn op_load_field(m: &mut Machine, env: &Env, bci: usize, opcode: u8, f: usize, len: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_field(env.p.ap@, old(m).g@, f as int, len as int),
        f < 0x1_0000,
        bci + len < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
    }
    let w = m.at(0);
    if !m.field_access_ok(p, w, Ghost(sp::at(g, 0)), f, false) {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let ghost o = sp::at(g, 0);
    let ghost id = o->Obj_0 as int;
    proof { lemma_field_val(p, m, o, f as int); }
    let v = m.heap.field(w, f, Ghost(id));
    m.put(0, v);
    m.bci = bci + len;
    let ghost g1 = sp::goto(sp::put(g, 0, sp::field(g, o, f as int)), bci + len);
    m.g = Ghost(g1);
    proof {
        assert(m.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i != g.stack.len() - 1 { assert(g1.stack[i] == g.stack[i]); }
        }
        m0.lemma_local_step(p, m);
        lemma_matches(p, m0, *m, Ctl::Next);
    }
    Ctl::Next
}

/// LOAD_FIELD_LOCAL / POP_LOAD_FIELD_LOCAL enc (`spec::op_load_field_local`).
#[inline(always)]
pub fn op_load_field_local(m: &mut Machine, env: &Env, bci: usize, opcode: u8, enc: usize, pop: bool) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_field_local(env.p.ap@, old(m).g@, enc as int, pop),
        enc < 256,
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let local = enc % 16;
    let f = enc / 16;
    let slot = if pop { local + 1 } else { local };
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, slot as int);
    }
    let w = m.at(slot);
    if !m.field_access_ok(p, w, Ghost(sp::at(g, slot as int)), f, false) {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let ghost o = sp::at(g, slot as int);
    let ghost id = o->Obj_0 as int;
    proof { lemma_field_val(p, m, o, f as int); }
    let v = m.heap.field(w, f, Ghost(id));
    let ghost fv = sp::field(g, o, f as int);
    if pop {
        proof { m.lemma_at(p, 0); }
        m.put(0, v);
        m.bci = bci + 2;
        let ghost g1 = sp::goto(sp::put(g, 0, fv), bci + 2);
        m.g = Ghost(g1);
        proof {
            assert(m.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i != g.stack.len() - 1 { assert(g1.stack[i] == g.stack[i]); }
            }
            m0.lemma_local_step(p, m);
            lemma_matches(p, m0, *m, Ctl::Next);
        }
        Ctl::Next
    } else {
        let r = m.push_next(p, v, 2, Ghost(fv));
        proof { lemma_matches(p, m0, *m, r); }
        r
    }
}

/// STORE_FIELD(_WIDE, _POP) f (`spec::op_store_field`).
#[inline(always)]
pub fn op_store_field(m: &mut Machine, env: &Env, bci: usize, opcode: u8, f: usize, len: usize, keep: bool) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_store_field(env.p.ap@, old(m).g@, f as int, len as int, keep),
        f < 0x1_0000,
        bci + len < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
    }
    let v = m.at(0);
    let wo = m.at(1);
    let ghost val = sp::at(g, 0);
    let ghost o = sp::at(g, 1);
    if !m.field_access_ok(p, wo, Ghost(o), f, true) {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    m.set_field_val(p, wo, Ghost(o), f, v, Ghost(val));
    let ghost m1 = *m;
    let ghost g1 = m.g@;
    proof { m.lemma_frame(p); }
    m.drop(2);
    let ghost g2 = sp::drop(g1, 2);
    m.g = Ghost(g2);
    proof {
        assert(m.words() =~= enc_seq(m1.addr(), g2.stack));
        assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m1.addr(), g2.stack[i]) by {
            assert(g2.stack[i] == g1.stack[i]);
        }
        m1.lemma_local_step(p, m);
        assert(sp::set_field2(sp::drop(g, 2), o, f as int, val) == g2);
    }
    if keep {
        let r = m.push_next(p, v, len, Ghost(val));
        proof { lemma_matches(p, m0, *m, r); }
        r
    } else {
        let ghost m2 = *m;
        m.bci = bci + len;
        let ghost g3 = sp::goto(g2, bci + len);
        m.g = Ghost(g3);
        proof {
            assert(m.words() =~= enc_seq(m2.addr(), g3.stack));
            m2.lemma_local_step(p, m);
            lemma_matches(p, m0, *m, Ctl::Next);
        }
        Ctl::Next
    }
}

/// `this` (slot 0 of the top frame) of a step whose `this_ok` holds.
proof fn lemma_this(p: &Program, m: &Machine, f: int)
    requires m.refines(p), sp::this_ok(p.ap@, m.g@, f),
    ensures
        m.base < m.len,
        m.mem@[m.len - 1 - m.base] == enc(m.addr(), m.g@.stack[m.base as int]),
        encodable(m.addr(), m.g@.stack[m.base as int]),
        m.g@.stack[m.base as int] is Obj,
        (m.g@.stack[m.base as int]->Obj_0 as int) < m.g@.heap.len(),
        m.g@.heap[m.g@.stack[m.base as int]->Obj_0 as int].body is Instance,
        f < m.g@.heap[m.g@.stack[m.base as int]->Obj_0 as int].body->Instance_0.len(),
{
    let g = m.g@;
    m.lemma_frame(p);
    let i = m.base as int;
    assert(m.words()[i] == m.mem@[m.len - 1 - i]);
    assert(enc_seq(m.addr(), g.stack)[i] == enc(m.addr(), g.stack[i]));
}

/// LOAD_FIELD_THIS f (`spec::op_load_field_this`): no checks (the
/// verifier proves `this` has the field).
#[inline(always)]
pub fn op_load_field_this(m: &mut Machine, env: &Env, bci: usize, opcode: u8, f: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_field_this(env.p.ap@, old(m).g@, f as int),
        f < 256,
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        lemma_this(p, m, f as int);
    }
    let ghost o = g.stack[m.base as int];
    let ghost id = o->Obj_0 as int;
    let this = m.mem.read(m.len - 1 - m.base);
    proof { lemma_field_val(p, m, o, f as int); }
    let v = m.heap.field(this, f, Ghost(id));
    let r = m.push_next(p, v, 2, Ghost(sp::field(g, o, f as int)));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// STORE_FIELD_THIS f (`spec::op_store_field_this`): the value stays.
/// Storing into a program-heap object raises INVALID_PROGRAM (not proven
/// yet).
#[inline(always)]
pub fn op_store_field_this(m: &mut Machine, env: &Env, bci: usize, opcode: u8, f: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_store_field_this(env.p.ap@, old(m).g@, f as int),
        f < 256,
        bci + 2 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        lemma_this(p, m, f as int);
        m.lemma_at(p, 0);
    }
    let ghost o = g.stack[m.base as int];
    let ghost id = o->Obj_0 as int;
    let this = m.mem.read(m.len - 1 - m.base);
    if m.is_ro_word(p, this, Ghost(id)) {
        proof {
            assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
            lemma_source_step(ap, g);
        }
        return m.v_raise_invalid(env);
    }
    let v = m.at(0);
    m.set_field_val(p, this, Ghost(o), f, v, Ghost(sp::at(g, 0)));
    let ghost m1 = *m;
    let ghost g1 = m.g@;
    m.bci = bci + 2;
    let ghost g2 = sp::goto(g1, bci + 2);
    m.g = Ghost(g2);
    proof {
        assert(m.words() =~= enc_seq(m1.addr(), g2.stack));
        m1.lemma_local_step(p, m);
        lemma_matches(p, m0, *m, Ctl::Next);
    }
    Ctl::Next
}

/// INVOKE_VIRTUAL_GET sel (`spec::op_invoke_virtual_get`): a field
/// accessor reads the field in place; anything else is a call.
#[inline(always)]
pub fn op_invoke_virtual_get(m: &mut Machine, env: &Env, bci: usize, opcode: u8, sel: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_virtual_get(env.p.ap@, old(m).g@, sel as int),
        sel < 0x1_0000,
        bci + 3 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
    }
    let w = m.at(0);
    let ghost recv = sp::at(g, 0);
    match m.lookup(p, w, Ghost(recv), sel as i64) {
        VLookup::Missing => {
            proof {
                assert(sp::step(ap, g) == sp::raise(ap, g, sp::LOOKUP_FAILED));
                lemma_source_step(ap, g);
            }
            m.v_raise_lookup(env, w, Ghost(recv), sel as i64)
        },
        VLookup::Found(t) => {
            let info = p.methods.at(t);
            proof { assert(ap.methods[t as int] == method_info(p.methods@[t as int], p.max_height)); }
            let f = info.aux as usize;
            if info.kind == KIND_FIELD_ACCESSOR && m.field_access_ok(p, w, Ghost(recv), f, false) {
                let ghost id = recv->Obj_0 as int;
                proof { lemma_field_val(p, m, recv, f as int); }
                let v = m.heap.field(w, f, Ghost(id));
                m.put(0, v);
                m.bci = bci + 3;
                let ghost g1 = sp::goto(sp::put(g, 0, sp::field(g, recv, f as int)), bci + 3);
                m.g = Ghost(g1);
                proof {
                    assert(m.words() =~= enc_seq(m0.addr(), g1.stack));
                    assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                        if i != g.stack.len() - 1 { assert(g1.stack[i] == g.stack[i]); }
                    }
                    m0.lemma_local_step(p, m);
                    lemma_matches(p, m0, *m, Ctl::Next);
                }
                return Ctl::Next;
            }
            if let Some(c) = ensure_room(m, env) {
                return c;
            }
            let r = m.push_call(env, t, bci + 3);
            proof { lemma_matches(p, m0, *m, r); }
            r
        },
    }
}

/// INVOKE_VIRTUAL_SET sel (`spec::op_invoke_virtual_set`): a field
/// accessor writes the field in place; anything else is a call.
#[inline(always)]
pub fn op_invoke_virtual_set(m: &mut Machine, env: &Env, bci: usize, opcode: u8, sel: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_virtual_set(env.p.ap@, old(m).g@, sel as int),
        sel < 0x1_0000,
        bci + 3 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
    }
    let v = m.at(0);
    let w = m.at(1);
    let ghost val = sp::at(g, 0);
    let ghost recv = sp::at(g, 1);
    match m.lookup(p, w, Ghost(recv), sel as i64) {
        VLookup::Missing => {
            proof {
                assert(sp::step(ap, g) == sp::raise(ap, g, sp::LOOKUP_FAILED));
                lemma_source_step(ap, g);
            }
            m.v_raise_lookup(env, w, Ghost(recv), sel as i64)
        },
        VLookup::Found(t) => {
            let info = p.methods.at(t);
            proof { assert(ap.methods[t as int] == method_info(p.methods@[t as int], p.max_height)); }
            let f = info.aux as usize;
            if info.kind == KIND_FIELD_ACCESSOR && m.field_access_ok(p, w, Ghost(recv), f, true) {
                m.set_field_val(p, w, Ghost(recv), f, v, Ghost(val));
                let ghost m1 = *m;
                let ghost g1 = m.g@;
                proof { m.lemma_frame(p); }
                m.drop(1);
                m.put(0, v);
                m.bci = bci + 3;
                let ghost g2 = sp::goto(sp::push(sp::drop(g1, 2), val), bci + 3);
                m.g = Ghost(g2);
                proof {
                    assert(m.words() =~= enc_seq(m1.addr(), g2.stack));
                    assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m1.addr(), g2.stack[i]) by {
                        if i < g2.stack.len() - 1 { assert(g2.stack[i] == g1.stack[i]); }
                    }
                    m1.lemma_local_step(p, m);
                    assert(sp::push(sp::set_field2(sp::drop(g, 2), recv, f as int, val), val) == sp::push(sp::drop(g1, 2), val));
                    lemma_matches(p, m0, *m, Ctl::Next);
                }
                return Ctl::Next;
            }
            if let Some(c) = ensure_room(m, env) {
                return c;
            }
            let r = m.push_call(env, t, bci + 3);
            proof { lemma_matches(p, m0, *m, r); }
            r
        },
    }
}

} // verus!
