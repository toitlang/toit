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
//! variants have none (the verifier proves the receiver's fields).
//! INVALID_PROGRAM and LOOKUP_FAILED are raised by the verified raise
//! (raise.rs).

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
            self.hrefines(p),
            ro_ok(p),
            0 <= id < self.g@.heap.len(),
            w == self.addr()[id],
        ensures r == self.g@.heap[id].ro,
    {
        // One compare: below the start the difference wraps to at least
        // `usize::MAX + 1 - ro_start`, which is above the size (`ro_ok`).
        let d = w.wrapping_sub(p.ro_start);
        proof {
            if w >= p.ro_start {
                assert(d == w - p.ro_start);
            } else {
                assert(d == w - p.ro_start + usize::MAX + 1);
            }
        }
        d < p.ro_size
    }

    /// `spec::field_readable` (`write` false) or `spec::field_writable`
    /// (`write` true) of the value `v` (word `w`) and field `f`.
    #[inline(always)]
    pub fn field_access_ok(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>, f: usize, write: bool) -> (r: bool)
        requires
            self.hrefines(p),
            ro_ok(p),
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
                Value::BlockRef(fr, sl) => { lemma_smi_word((fr * 0x1_0000 + sl) as i64); },
                Value::Token(_, d, _, _) => { lemma_token_vals(d); },
                _ => {},
            }
        }
        if w & 1 == 0 {
            return false;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(g.heap[id], self.heap.class_bits(), self.addr())); }
        let tag = self.heap.class_tag(w, Ghost(id));
        if tag == INSTANCE_TAG {
            // The fast path: an instance whose class has the field.
            let cid = self.heap.class_id(w, Ghost(id));
            let bits = p.class_bits.at(cid);
            let size = ((bits >> 5u16) & 0x7ffu16) as usize;
            proof {
                assert(size as int - 1 == ifc_bits(p.class_bits@, cid as int));
                assert(g.heap[id].body->Instance_0.len() == size - 1);
                lemma_task_tag(p, cid as int);
            }
            return f + 1 < size && !(write && self.is_ro_word(p, w, Ghost(id)));
        }
        self.task_field_ok(p, w, Ghost(v), f, write, tag)
    }

    /// `field_access_ok` for an object that is not an instance: only a task
    /// has fields, of which the machine's (its stack, and its id) are not
    /// accessible to the program.
    #[inline(always)]
    fn task_field_ok(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>, f: usize, write: bool, tag: usize) -> (r: bool)
        requires
            self.hrefines(p),
            ro_ok(p),
            accepts(p.ap@, p.cert@, p.trusted@),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            f < 0x1_0000,
            v is Obj,
            (v->Obj_0 as int) < self.g@.heap.len(),
            (self.g@.heap[v->Obj_0 as int].class_id as int) < self.heap.class_bits().len(),
            tag == (self.heap.class_bits()[self.g@.heap[v->Obj_0 as int].class_id as int] & 0xf) as usize,
            tag != INSTANCE_TAG,
        ensures
            r == (if write { sp::field_writable(p.ap@, self.g@, v, f as int) }
                else { sp::field_readable(p.ap@, self.g@, v, f as int) }),
            r ==> v is Obj && (v->Obj_0 as int) < self.g@.heap.len()
                && self.g@.heap[v->Obj_0 as int].body is Instance
                && f < self.g@.heap[v->Obj_0 as int].body->Instance_0.len(),
    {
        let ghost g = self.g@;
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(g.heap[id], self.heap.class_bits(), self.addr())); }
        if tag != TASK_TAG {
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
        if f + 1 >= size || f <= (if write { 1 } else { 0 }) {
            return false;
        }
        !(write && self.is_ro_word(p, w, Ghost(id)))
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
        &&& self.ftop == other.ftop
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
pub proof fn lemma_field_val(p: &Program, m: &Machine, v: Value, f: int)
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

/// `this` (slot 0 of the top frame) of a step whose `this_ok` holds.
pub proof fn lemma_this(p: &Program, m: &Machine, f: int)
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

} // verus!
