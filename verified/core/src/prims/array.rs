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

//! Array primitives: `array_length`, `array_at`, `array_at_put`,
//! `array_new`, `array_expand`, `array_replace`, `list_add` (small- and
//! large-array backings), `rebuild_hash_index`
//! (src/primitive_core.cc).
//!
//! Arrays are in the heap model (`abs::obj_model_ok`: the array tag is
//! exactly `Body::Array`). The primitive contracts specify indexing, updates,
//! allocation, expansion and overlapping slice replacements.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::view::*;
use crate::prims::*;
use crate::prims::index as ix;
use toit_spec::types::{Value, HeapObj, Body};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{good, basic_obj_ok, task_class, task_fields_kept};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::task_class_ok;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::p1;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::class_tag;

verus! {

/// The elements of the array `v`, if it is one.
pub open spec fn array_val(objs: Seq<HeapObj>, v: Value) -> Option<Seq<Value>> {
    match v {
        Value::Obj(id) => if (id as int) < objs.len() && objs[id as int].body is Array {
            Some(objs[id as int].body->Array_0)
        } else {
            None
        },
        _ => None,
    }
}

// ---------------------------------------------------------------------------
// Arguments.

/// `w` is an array (`is_array`): its object id.
#[inline(always)]
pub fn array_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<Ghost<int>>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r is Some == (array_val(h.objs(), v) is Some),
        r is Some ==> v is Obj && r->Some_0@ == v->Obj_0 as int
            && 0 <= r->Some_0@ < h.objs().len() && w == h.addrs()[r->Some_0@]
            && h.objs()[r->Some_0@].body is Array,
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 {
        return None;
    }
    let ghost id = v->Obj_0 as int;
    proof { assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs())); }
    if h.class_tag(w, Ghost(id)) == ARRAY_TAG { Some(Ghost(id)) } else { None }
}

/// A `word` argument: a smi (else WRONG_OBJECT_TYPE).
#[inline(always)]
pub fn word_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<i64>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r == (match v { Value::Smi(i) => Some(i), _ => None }),
        r is Some ==> smi_range(r->Some_0 as int),
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 { Some(smi_of_word(w)) } else { None }
}

/// An `int` argument: a smi in 32-bit range; a large integer or a smi
/// outside fails with OUT_OF_RANGE, anything else with WRONG_OBJECT_TYPE
/// (`_A_T_int`, `Primitive::return_not_a_smi`).
#[inline(always)]
pub fn int32_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Result<i64, usize>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r is Ok ==> v == Value::Smi(r->Ok_0) && -0x8000_0000 <= r->Ok_0 < 0x8000_0000,
        r is Err ==> r->Err_0 == ROOT_OUT_OF_RANGE || r->Err_0 == ROOT_WRONG_OBJECT_TYPE,
        r is Err ==> r->Err_0 as int == toit_spec::v2::prim_core::int32_error(h.objs(), v),
        (v is Smi && -0x8000_0000 <= v->Smi_0 < 0x8000_0000) ==> r is Ok,
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 {
        let x = smi_of_word(w);
        if -0x8000_0000 <= x && x < 0x8000_0000 { Ok(x) } else { Err(ROOT_OUT_OF_RANGE) }
    } else {
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs())); }
        if h.class_tag(w, Ghost(id)) == LARGE_INTEGER_TAG { Err(ROOT_OUT_OF_RANGE) } else { Err(ROOT_WRONG_OBJECT_TYPE) }
    }
}

/// The object at `w` lies in the program heap.
#[inline(always)]
pub fn is_ro(p: &Program, w: usize) -> (r: bool)
    ensures r == in_ro(p, w),
{
    w >= p.ro_start && w - p.ro_start < p.ro_size
}

// ---------------------------------------------------------------------------
// Heap lemmas for arrays and instances.

/// Element `i` of array `id` is a value of the heap.
pub proof fn lemma_element_good(p: &Program, h: &Heap, id: int, i: int)
    requires
        heap_inv(p, h), 0 <= id < h.objs().len(), h.objs()[id].body is Array,
        0 <= i < h.objs()[id].body->Array_0.len(),
    ensures ({
        let v = h.objs()[id].body->Array_0[i];
        good(h.objs(), v) && encodable(h.addrs(), v)
    }),
{
    let o = h.objs()[id];
    assert(heap_model_ok(h.objs(), h.addrs(), h.class_bits()));
    assert(obj_model_ok(o, h.class_bits(), h.addrs()));
    assert(basic_obj_ok(p.ap@, h.objs(), o));
    let e = o.body->Array_0;
    assert(encodable(h.addrs(), e[i]));
    assert(good(h.objs(), e[i]));
}

/// Field `i` of instance `id` is a value of the heap.
pub proof fn lemma_field_good(p: &Program, h: &Heap, id: int, i: int)
    requires
        heap_inv(p, h), 0 <= id < h.objs().len(), h.objs()[id].body is Instance,
        0 <= i < h.objs()[id].body->Instance_0.len(),
    ensures ({
        let v = h.objs()[id].body->Instance_0[i];
        good(h.objs(), v) && encodable(h.addrs(), v)
    }),
{
    let o = h.objs()[id];
    assert(heap_model_ok(h.objs(), h.addrs(), h.class_bits()));
    assert(obj_model_ok(o, h.class_bits(), h.addrs()));
    assert(basic_obj_ok(p.ap@, h.objs(), o));
    let f = o.body->Instance_0;
    assert(encodable(h.addrs(), f[i]));
    assert(good(h.objs(), f[i]));
}

/// Writing a value of the heap into a mutable array keeps the heap
/// invariant.
pub proof fn lemma_post_set_element(p: &Program, h0: &Heap, h1: &Heap, id: int, i: int, v: Value)
    requires
        heap_inv(p, h0), 0 <= id < h0.objs().len(), h0.objs()[id].body is Array,
        !h0.objs()[id].ro,
        0 <= i < h0.objs()[id].body->Array_0.len(),
        good(h0.objs(), v), encodable(h0.addrs(), v),
        h1.objs() == h0.objs().update(id, HeapObj {
            body: Body::Array(h0.objs()[id].body->Array_0.update(i, v)), ..h0.objs()[id] }),
        h1.addrs() == h0.addrs(),
        h1.class_bits() == h0.class_bits(),
    ensures heap_post(p, h0, h1),
{
    let o = h0.objs()[id];
    let e = o.body->Array_0;
    let e2 = e.update(i, v);
    let o2 = HeapObj { body: Body::Array(e2), ..o };
    assert forall|k: int| 0 <= k < e2.len() implies good(h1.objs(), #[trigger] e2[k]) && encodable(h1.addrs(), e2[k]) by {
        if k != i { lemma_element_good(p, h0, id, k); }
    }
    lemma_post_update(p, h0, h1, id, o2);
}

/// Writing a value of the heap into field `i` of a mutable instance of a
/// class other than the task class keeps the heap invariant.
pub proof fn lemma_post_set_field(p: &Program, h0: &Heap, h1: &Heap, id: int, i: int, v: Value)
    requires
        heap_inv(p, h0), 0 <= id < h0.objs().len(), h0.objs()[id].body is Instance,
        !h0.objs()[id].ro,
        0 <= i < h0.objs()[id].body->Instance_0.len(),
        h0.objs()[id].class_id as int != task_class(p.ap@),
        good(h0.objs(), v), encodable(h0.addrs(), v),
        h1.objs() == h0.objs().update(id, HeapObj {
            body: Body::Instance(h0.objs()[id].body->Instance_0.update(i, v)), ..h0.objs()[id] }),
        h1.addrs() == h0.addrs(),
        h1.class_bits() == h0.class_bits(),
    ensures heap_post(p, h0, h1),
{
    let o = h0.objs()[id];
    let f = o.body->Instance_0;
    let f2 = f.update(i, v);
    let o2 = HeapObj { body: Body::Instance(f2), ..o };
    assert forall|k: int| 0 <= k < f2.len() implies good(h1.objs(), #[trigger] f2[k]) && encodable(h1.addrs(), f2[k]) by {
        if k != i { lemma_field_good(p, h0, id, k); }
    }
    lemma_post_update(p, h0, h1, id, o2);
}

// ---------------------------------------------------------------------------
// The primitives.

/// `array_length`.
pub fn array_length(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        completes(r.0),
        toit_spec::v2::prim_core::array_length_contract(c.p.ap@, a.vs@, old(heap).objs(), final(heap).objs(),
            ret_of(c.p, r.0, r.1@)),
{
    let w = a.w[0];
    let id = match array_arg(heap, w, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    proof { assert(obj_model_ok(heap.objs()[id@], heap.class_bits(), heap.addrs())); }
    let len = heap.array_length(w, id);
    let (rw, rv) = smi_res(heap, len as i64);
    ok(c.p, heap, rw, rv)
}

/// `array_at`.
pub fn array_at(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        completes(r.0),
        toit_spec::v2::prim_core::array_at_contract(c.p.ap@, a.vs@, old(heap).objs(), final(heap).objs(),
            ret_of(c.p, r.0, r.1@)),
{
    let w = a.w[0];
    let id = match array_arg(heap, w, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    proof { assert(obj_model_ok(heap.objs()[id@], heap.class_bits(), heap.addrs())); }
    let i = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(i) => i,
        Err(k) => return fail(c.p, heap, k),
    };
    let len = heap.array_length(w, id);
    if i < 0 || i as usize >= len {
        return fail(c.p, heap, ROOT_OUT_OF_BOUNDS);
    }
    proof { lemma_element_good(c.p, heap, id@, i as int); }
    let e = heap.element(w, i as usize, id);
    ok(c.p, heap, e, Ghost(heap.objs()[id@].body->Array_0[i as int]))
}

/// `array_at_put`.
pub fn array_at_put(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 3,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        completes(r.0),
        toit_spec::v2::prim_core::array_at_put_contract(c.p.ap@, a.vs@, old(heap).objs(), final(heap).objs(),
            ret_of(c.p, r.0, r.1@)),
{
    let w = a.w[0];
    let id = match array_arg(heap, w, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let i = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(i) => i,
        Err(k) => return fail(c.p, heap, k),
    };
    if is_ro(c.p, w) {
        return fail(c.p, heap, ROOT_PERMISSION_DENIED);
    }
    proof {
        assert(obj_model_ok(heap.objs()[id@], heap.class_bits(), heap.addrs()));
        assert(heap.objs()[id@].ro == in_ro(c.p, heap.addrs()[id@]));
    }
    let len = heap.array_length(w, id);
    if i < 0 || i as usize >= len {
        return fail(c.p, heap, ROOT_OUT_OF_BOUNDS);
    }
    let ghost h0 = *heap;
    let ghost v = a.vs@[2];
    heap.set_element(w, i as usize, a.w[2], id, Ghost(v));
    proof {
        lemma_post_set_element(c.p, &h0, heap, id@, i as int, v);
        lemma_good_mono(h0.objs(), heap.objs(), h0.addrs(), heap.addrs(), v);
        assert(heap.addrs().subrange(0, h0.addrs().len() as int) == h0.addrs());
    }
    (PrimOutcome::Success(a.w[2]), Ghost(v))
}

/// A new array of `len` elements, each `fv` (encoded by `filler`).
fn new_array(heap: &mut Heap, c: &Ctx, len: usize, filler: usize, Ghost(fv): Ghost<Value>) -> (r: (PrimOutcome, Ghost<Value>))
    requires
        heap_inv(c.p, old(heap)), len <= ARRAYLET_SIZE,
        filler == enc(old(heap).addrs(), fv), good(old(heap).objs(), fv), encodable(old(heap).addrs(), fv),
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> toit_spec::v2::prim_core::boxed_result(c.p.ap@, old(heap).objs(),
            final(heap).objs(), ret_of(c.p, r.0, r.1@), toit_spec::spec_common::ARRAY_CLASS,
            Body::Array(Seq::new(len as nat, |i: int| fv))),
        !(r.0 is Failure),
        r.0 is Success ==> array_val(final(heap).objs(), r.1@) == Some(Seq::new(len as nat, |i: int| fv))
            && r.1@ == Value::Obj(old(heap).objs().len() as usize)
            && final(heap).objs().len() == old(heap).objs().len() + 1
            && final(heap).objs().subrange(0, old(heap).objs().len() as int) == old(heap).objs()
            && final(heap).addrs().subrange(0, old(heap).addrs().len() as int) == old(heap).addrs()
            && !final(heap).objs()[old(heap).objs().len() as int].ro,
{
    if builtin_with_tag(c.p, heap, BUILTIN_ARRAY, ARRAY_TAG).is_none() {
        return (PrimOutcome::NotPorted, Ghost(Value::Smi(0)));
    }
    let ghost h0 = *heap;
    let w = c.al.array(heap, c.p, len, filler, Ghost(fv));
    if w == 0 {
        proof { lemma_post_refl(c.p, heap); }
        return (PrimOutcome::NeedsGc, Ghost(Value::Smi(0)));
    }
    let ghost id = h0.objs().len() as int;
    proof {
        let o = heap.objs().last();
        assert(heap.objs()[id] == o);
        let e = o.body->Array_0;
        lemma_good_mono(h0.objs(), heap.objs(), h0.addrs(), heap.addrs(), fv);
        assert forall|k: int| 0 <= k < e.len() implies good(heap.objs(), #[trigger] e[k]) && encodable(heap.addrs(), e[k]) by {
            assert(e[k] == fv);
        }
        assert(heap.objs() =~= h0.objs().push(o));
        lemma_post_append(c.p, &h0, heap, w);
    }
    (PrimOutcome::Success(w), Ghost(Value::Obj(id as usize)))
}

/// `array_new`.
pub fn array_new(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, ix::ARRAY_NEW as int, a, old(heap), final(heap), r.0, r.1@),
{
    let len = match int32_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Ok(n) => n,
        Err(k) => return fail(c.p, heap, k),
    };
    if len == 0 {
        let (w, v) = root(c.p, heap, ROOT_EMPTY_ARRAY);
        return ok(c.p, heap, w, v);
    }
    if len < 0 { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    if len as usize > ARRAYLET_SIZE { return fail(c.p, heap, ROOT_OUT_OF_RANGE); }
    new_array(heap, c, len as usize, a.w[1], Ghost(a.vs@[1]))
}

/// `array_expand`: a new array of `length` elements with the first
/// `min(length, old_length)` of `old` and the rest `filler`.
pub fn array_expand(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 4,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, ix::ARRAY_EXPAND as int, a, old(heap), final(heap), r.0, r.1@),
{
    let w = a.w[0];
    let oid = match array_arg(heap, w, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let old_length = match word_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let length = match word_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if length == 0 {
        let (rw, rv) = root(c.p, heap, ROOT_EMPTY_ARRAY);
        return ok(c.p, heap, rw, rv);
    }
    if length < 0 { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    if length as usize > ARRAYLET_SIZE { return fail(c.p, heap, ROOT_OUT_OF_RANGE); }
    proof { assert(obj_model_ok(heap.objs()[oid@], heap.class_bits(), heap.addrs())); }
    let olen = heap.array_length(w, oid);
    if old_length < 0 || old_length as usize > olen { return fail(c.p, heap, ROOT_OUT_OF_RANGE); }
    let ghost h0 = *heap;
    let r = new_array(heap, c, length as usize, a.w[3], Ghost(a.vs@[3]));
    let nw = match r.0 {
        PrimOutcome::Success(nw) => nw,
        _ => return r,
    };
    let ghost h1 = *heap;
    let ghost nid = h0.objs().len() as int;
    let n = if (length as usize) < (old_length as usize) { length as usize } else { old_length as usize };
    proof {
        assert(h1.objs()[oid@] == h0.objs()[oid@]) by {
            assert(h1.objs().subrange(0, h0.objs().len() as int)[oid@] == h0.objs()[oid@]);
        }
        assert(h1.addrs()[oid@] == h0.addrs()[oid@]) by {
            assert(h1.addrs().subrange(0, h0.addrs().len() as int)[oid@] == h0.addrs()[oid@]);
        }
        assert(nw == h1.addrs()[nid]);
        assert(h1.addrs().len() == h1.objs().len()) by {
            assert(heap_model_ok(h1.objs(), h1.addrs(), h1.class_bits()));
        }
    }
    heap.array_copy(nw, 0, w, 0, n, Ghost(nid), oid);
    proof {
        let o2 = heap.objs()[nid];
        let e2 = o2.body->Array_0;
        assert(heap.objs() == h1.objs().update(nid, o2));
        assert forall|k: int| 0 <= k < e2.len() implies good(heap.objs(), #[trigger] e2[k]) && encodable(heap.addrs(), e2[k]) by {
            if k < n { lemma_element_good(c.p, &h1, oid@, k); } else { lemma_element_good(c.p, &h1, nid, k); }
        }
        lemma_post_update(c.p, &h1, heap, nid, o2);
        assert(e2 =~= Seq::new(length as nat, |i: int|
            if i < old_length { h0.objs()[oid@].body->Array_0[i] } else { a.vs@[3] }));
        assert(heap.objs() =~= h0.objs().push(o2));
        lemma_post_trans(c.p, &h0, &h1, heap);
        assert(heap.addrs() == h1.addrs());
    }
    (PrimOutcome::Success(nw), r.1)
}

/// `array_replace`: memmove of `source[from..to]` to `dest[index..]`.
pub fn array_replace(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 5,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, ix::ARRAY_REPLACE as int, a, old(heap), final(heap), r.0, r.1@),
        completes(r.0),
{
    let dw = a.w[0];
    let did = match array_arg(heap, dw, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let index = match word_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let sw = a.w[2];
    let sid = match array_arg(heap, sw, Ghost(a.vs@[2])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let from = match word_arg(heap, a.w[3], Ghost(a.vs@[3])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let to = match word_arg(heap, a.w[4], Ghost(a.vs@[4])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    proof {
        assert(obj_model_ok(heap.objs()[did@], heap.class_bits(), heap.addrs()));
        assert(obj_model_ok(heap.objs()[sid@], heap.class_bits(), heap.addrs()));
        assert(heap.objs()[did@].ro == in_ro(c.p, heap.addrs()[did@]));
    }
    let dlen = heap.array_length(dw, did);
    let slen = heap.array_length(sw, sid);
    if index < 0 || from < 0 || from > to || to as usize > slen { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    let len = (to - from) as usize;
    if index as usize + len > dlen { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    if is_ro(c.p, dw) { return fail(c.p, heap, ROOT_PERMISSION_DENIED); }
    let ghost h0 = *heap;
    heap.array_copy(dw, index as usize, sw, from as usize, len, did, sid);
    proof {
        let o2 = heap.objs()[did@];
        let e2 = o2.body->Array_0;
        let to2 = index as int;
        let from2 = from as int;
        assert(heap.objs() == h0.objs().update(did@, o2));
        assert forall|k: int| 0 <= k < e2.len() implies good(heap.objs(), #[trigger] e2[k]) && encodable(heap.addrs(), e2[k]) by {
            if to2 <= k < to2 + len { lemma_element_good(c.p, &h0, sid@, k - to2 + from2); }
            else { lemma_element_good(c.p, &h0, did@, k); }
        }
        let dst = h0.objs()[did@].body->Array_0;
        let src = h0.objs()[sid@].body->Array_0;
        assert(e2 =~= dst.subrange(0, to2) + src.subrange(from2, to as int)
            + dst.subrange(to2 + len, dst.len() as int));
        lemma_post_update(c.p, &h0, heap, did@, o2);
    }
    let (nw, nv) = root(c.p, heap, ROOT_NULL);
    (PrimOutcome::Success(nw), nv)
}

/// The number of nested vectors `large_slot` follows: a large array below
/// 2^30 elements nests at most four deep (500^4 > 2^30).
pub const LARGE_SLOT_FUEL: usize = 8;

/// `v` (word `w`) is an instance of the large-array class (`LargeArray_`)
/// with its two fields (size, vector): its object id.
#[inline(always)]
pub fn large_array_arg(h: &Heap, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<Ghost<int>>)
    requires
        heap_inv(p, h),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r is Some ==> v is Obj && r->Some_0@ == v->Obj_0 as int
            && 0 <= r->Some_0@ < h.objs().len() && w == h.addrs()[r->Some_0@]
            && h.addrs().len() == h.objs().len()
            && h.objs()[r->Some_0@].body is Instance
            && h.objs()[r->Some_0@].body->Instance_0.len() >= 2
            && h.objs()[r->Some_0@].class_id as int != task_class(p.ap@),
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 { return None; }
    let ghost id = v->Obj_0 as int;
    proof {
        assert(heap_model_ok(h.objs(), h.addrs(), h.class_bits()));
        assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
        assert(prog_rel(p, h.objs(), h.addrs()));
        assert(task_class_ok(p.ap@));
    }
    if h.class_tag(w, Ghost(id)) != INSTANCE_TAG { return None; }
    let cid = h.class_id(w, Ghost(id));
    if cid != p.large_array_class_id { return None; }
    if cid >= p.class_bits.len() { return None; }
    let bits = p.class_bits.at(cid);
    let fields = ((bits >> 5u16) & 0x7ffu16) as usize;
    if fields < 3 { return None; }
    proof {
        assert(h.objs()[id].body->Instance_0.len() == ifc_bits(h.class_bits(), cid as int));
        // The class has the instance tag, the task class the task tag.
        assert(class_tag(p1(p.ap@), task_class(p.ap@)) == TASK_TAG);
        assert(class_tag(p1(p.ap@), cid as int) == h.class_bits()[cid as int] & 0xf);
    }
    Some(Ghost(id))
}

/// The slot of element `n` of the large array `v` (word `w`), as
/// `Interpreter::fast_at` finds it for `list_add`: the arraylet (an array:
/// its word and id) and the index in it. `None` where the C++ `fast_at`
/// fails, and also below `fuel` nested vectors: the C++ followed a chain of
/// large arrays of decreasing sizes without a bound, so a program whose
/// own library made a deep one overflowed the native stack (a VM crash;
/// the C++ now gives up after 8 nested vectors, one more than this);
/// real large arrays nest at most four deep. `list_add` then fails with
/// INVALID_ARGUMENT and its Toit code grows the list.
pub fn large_slot(h: &Heap, p: &Program, w: usize, Ghost(v): Ghost<Value>, n: usize, fuel: usize)
    -> (r: Option<(usize, Ghost<int>, usize)>)
    requires
        heap_inv(p, h),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r is Some ==> ({
            let (aw, aid, j) = r->Some_0;
            &&& 0 <= aid@ < h.objs().len()
            &&& h.addrs().len() == h.objs().len()
            &&& aw == h.addrs()[aid@]
            &&& h.objs()[aid@].body is Array
            &&& j < h.objs()[aid@].body->Array_0.len()
        }),
    decreases fuel,
{
    let id = match large_array_arg(h, p, w, Ghost(v)) {
        Some(id) => id,
        None => return None,
    };
    proof {
        lemma_field_good(p, h, id@, 0);
        lemma_field_good(p, h, id@, 1);
    }
    let size_w = h.field(w, 0, id);
    let ghost sv = h.objs()[id@].body->Instance_0[0];
    let vector = h.field(w, 1, id);
    let ghost vv = h.objs()[id@].body->Instance_0[1];
    let size = match word_arg(h, size_w, Ghost(sv)) {
        Some(x) => x,
        None => return None,
    };
    if size < 0 || (n as u64) >= (size as u64) { return None; }
    if fuel == 0 { return None; }
    let idx = n / 500;
    // The arraylet: element `n / 500` of the vector, an array or (for very
    // large arrays) a smaller large array.
    let (arraylet, Ghost(alv)) = match array_arg(h, vector, Ghost(vv)) {
        Some(vid) => {
            proof { assert(obj_model_ok(h.objs()[vid@], h.class_bits(), h.addrs())); }
            let vlen = h.array_length(vector, vid);
            if idx >= vlen { return None; }
            proof { lemma_element_good(p, h, vid@, idx as int); }
            (h.element(vector, idx, vid), Ghost(h.objs()[vid@].body->Array_0[idx as int]))
        },
        None => {
            let vid = match large_array_arg(h, p, vector, Ghost(vv)) {
                Some(vid) => vid,
                None => return None,
            };
            proof { lemma_field_good(p, h, vid@, 0); }
            let vs_w = h.field(vector, 0, vid);
            let ghost vsv = h.objs()[vid@].body->Instance_0[0];
            match word_arg(h, vs_w, Ghost(vsv)) {
                Some(vs) => { if vs >= size { return None; } },
                None => return None,
            }
            let (aw2, aid2, i2) = match large_slot(h, p, vector, Ghost(vv), idx, fuel - 1) {
                Some(x) => x,
                None => return None,
            };
            proof { lemma_element_good(p, h, aid2@, i2 as int); }
            (h.element(aw2, i2, aid2), Ghost(h.objs()[aid2@].body->Array_0[i2 as int]))
        },
    };
    let aid = match array_arg(h, arraylet, Ghost(alv)) {
        Some(aid) => aid,
        None => return None,
    };
    proof { assert(obj_model_ok(h.objs()[aid@], h.class_bits(), h.addrs())); }
    let alen = h.array_length(arraylet, aid);
    let j = n % 500;
    if j >= alen { return None; }
    Some((arraylet, aid, j))
}

/// `list_add`: stores `value` at `size` and increments the list's size.
/// With a small-array backing directly; with a large-array backing in the
/// arraylet `large_slot` finds (as the C++ `Interpreter::fast_at`, but with
/// a bound on the nesting). Anything else fails with INVALID_ARGUMENT (the
/// Toit code then grows the list; the C++ also stores into the other kinds
/// `fast_at` knows, a list, a byte array or slice, which only a program's
/// own library makes a list's backing, with the same effect as the Toit
/// code's). Never falls back to C++.
pub fn list_add(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        completes(r.0),
{
    let p = c.p;
    let w = a.w[0];
    let ghost lv = a.vs@[0];
    proof { lemma_word(heap, w, lv); }
    if w & 1 == 0 { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    let ghost lid = lv->Obj_0 as int;
    proof {
        assert(obj_model_ok(heap.objs()[lid], heap.class_bits(), heap.addrs()));
        assert(heap.objs()[lid].ro == in_ro(p, heap.addrs()[lid]));
        assert(prog_rel(p, heap.objs(), heap.addrs()));
        assert(task_class_ok(p.ap@));
    }
    if heap.class_tag(w, Ghost(lid)) != INSTANCE_TAG { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    if is_ro(p, w) { return fail(p, heap, ROOT_PERMISSION_DENIED); }
    let cid = heap.class_id(w, Ghost(lid));
    if cid != p.list_class_id { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    // The list has its two fields (backing, size).
    if cid >= p.class_bits.len() { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    let bits = p.class_bits.at(cid);
    let fields = ((bits >> 5u16) & 0x7ffu16) as usize;
    if fields < 3 { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    proof {
        assert(heap.objs()[lid].body->Instance_0.len() == ifc_bits(heap.class_bits(), cid as int));
        lemma_field_good(p, heap, lid, 0);
        lemma_field_good(p, heap, lid, 1);
        // The list class has the instance tag, the task class the task tag.
        assert(class_tag(p1(p.ap@), task_class(p.ap@)) == TASK_TAG);
        assert(class_tag(p1(p.ap@), cid as int) == heap.class_bits()[cid as int] & 0xf);
    }
    let backing = heap.field(w, 0, Ghost(lid));
    let ghost bv = heap.objs()[lid].body->Instance_0[0];
    let aid = match array_arg(heap, backing, Ghost(bv)) {
        Some(id) => id,
        None => return list_add_large(a, heap, c, w, Ghost(lid), backing, Ghost(bv)),
    };
    let size_w = heap.field(w, 1, Ghost(lid));
    let ghost sv = heap.objs()[lid].body->Instance_0[1];
    let size = match word_arg(heap, size_w, Ghost(sv)) {
        Some(n) => n,
        None => return fail(p, heap, ROOT_INVALID_ARGUMENT),
    };
    proof {
        assert(obj_model_ok(heap.objs()[aid@], heap.class_bits(), heap.addrs()));
        assert(heap.objs()[aid@].ro == in_ro(p, heap.addrs()[aid@]));
    }
    let alen = heap.array_length(backing, aid);
    if size < 0 || size as usize >= alen || is_ro(p, backing) { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    let ghost h0 = *heap;
    let (nw, nv) = smi_res(heap, size + 1);
    heap.set_field(w, 1, nw, Ghost(lid), nv);
    let ghost h1 = *heap;
    proof {
        lemma_post_set_field(p, &h0, &h1, lid, 1, nv@);
        assert(h1.objs()[aid@] == h0.objs()[aid@]);
    }
    let ghost v = a.vs@[1];
    proof {
        lemma_good_mono(h0.objs(), h1.objs(), h0.addrs(), h1.addrs(), v);
        assert(h1.addrs().subrange(0, h0.addrs().len() as int) =~= h0.addrs());
    }
    heap.set_element(backing, size as usize, a.w[1], aid, Ghost(v));
    proof {
        lemma_post_set_element(p, &h1, heap, aid@, size as int, v);
        lemma_post_trans(p, &h0, &h1, heap);
    }
    let (rw, rv) = root(p, heap, ROOT_NULL);
    (PrimOutcome::Success(rw), rv)
}

/// `list_add` of a list (`w`, object `lid`, mutable, of the list class with
/// its two fields) whose backing (`backing`, value `bv`) is not an array:
/// the C++ large-array case (`Smi::is_valid(size + 1)`, then
/// `Interpreter::fast_at(process, backing, size, true, &value)`, then the
/// size), for a `LargeArray_` backing.
fn list_add_large(a: &Args, heap: &mut Heap, c: &Ctx, w: usize, Ghost(lid): Ghost<int>,
    backing: usize, Ghost(bv): Ghost<Value>) -> (r: (PrimOutcome, Ghost<Value>))
    requires
        heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
        0 <= lid < old(heap).objs().len(),
        old(heap).addrs().len() == old(heap).objs().len(),
        w == old(heap).addrs()[lid],
        old(heap).objs()[lid].body is Instance,
        old(heap).objs()[lid].body->Instance_0.len() >= 2,
        old(heap).objs()[lid].class_id as int != task_class(c.p.ap@),
        !old(heap).objs()[lid].ro,
        bv == old(heap).objs()[lid].body->Instance_0[0],
        backing == enc(old(heap).addrs(), bv),
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        completes(r.0),
{
    let p = c.p;
    proof {
        lemma_field_good(p, heap, lid, 0);
        lemma_field_good(p, heap, lid, 1);
    }
    let size_w = heap.field(w, 1, Ghost(lid));
    let ghost sv = heap.objs()[lid].body->Instance_0[1];
    let size = match word_arg(heap, size_w, Ghost(sv)) {
        Some(n) => n,
        None => return fail(p, heap, ROOT_INVALID_ARGUMENT),
    };
    // `Smi::is_valid(size + 1)`, then `fast_at` fails for a negative index.
    if size >= MAX_SMI as i64 || size < 0 { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    let (aw, aid, j) = match large_slot(heap, p, backing, Ghost(bv), size as usize, LARGE_SLOT_FUEL) {
        Some(x) => x,
        None => return fail(p, heap, ROOT_INVALID_ARGUMENT),
    };
    // Objects on the program heap are read-only (`fast_at` fails for a put).
    proof {
        assert(obj_model_ok(heap.objs()[aid@], heap.class_bits(), heap.addrs()));
        assert(heap.objs()[aid@].ro == in_ro(p, heap.addrs()[aid@]));
    }
    if is_ro(p, aw) { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    let ghost h0 = *heap;
    let ghost v = a.vs@[1];
    heap.set_element(aw, j, a.w[1], aid, Ghost(v));
    let ghost h1 = *heap;
    proof {
        lemma_post_set_element(p, &h0, &h1, aid@, j as int, v);
        assert(h1.objs()[lid] == h0.objs()[lid]);
    }
    let (nw, nv) = smi_res(heap, size + 1);
    heap.set_field(w, 1, nw, Ghost(lid), nv);
    proof {
        lemma_post_set_field(p, &h1, heap, lid, 1, nv@);
        lemma_post_trans(p, &h0, &h1, heap);
    }
    let (rw, rv) = root(p, heap, ROOT_NULL);
    (PrimOutcome::Success(rw), rv)
}

/// `rebuild_hash_index(old, new)`: inserts every hash-and-position of
/// `old` into the power-of-two index array `new` by triangular probing.
pub fn rebuild_hash_index(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        completes(r.0),
{
    let p = c.p;
    let ow = a.w[0];
    let nw = a.w[1];
    let oid = match array_arg(heap, ow, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(p, heap, ROOT_OUT_OF_RANGE),
    };
    let nid = match array_arg(heap, nw, Ghost(a.vs@[1])) {
        Some(id) => id,
        None => return fail(p, heap, ROOT_OUT_OF_RANGE),
    };
    proof {
        assert(obj_model_ok(heap.objs()[oid@], heap.class_bits(), heap.addrs()));
        assert(obj_model_ok(heap.objs()[nid@], heap.class_bits(), heap.addrs()));
        assert(heap.objs()[nid@].ro == in_ro(p, heap.addrs()[nid@]));
    }
    let new_length = heap.array_length(nw, nid);
    if new_length == 0 || (new_length & (new_length - 1)) != 0 { return fail(p, heap, ROOT_INVALID_ARGUMENT); }
    if is_ro(p, nw) { return fail(p, heap, ROOT_PERMISSION_DENIED); }
    let mask = new_length - 1;
    let length = heap.array_length(ow, oid);
    let ghost h0 = *heap;
    proof { lemma_post_refl(p, heap); }
    let mut i: usize = 0;
    while i < length
        invariant
            heap_inv(p, heap), heap_post(p, &h0, heap), h0 == *old(heap), p == c.p,
            new_length < 0x4000_0000,
            heap.addrs() == h0.addrs(),
            heap.objs().len() == h0.objs().len(),
            0 <= oid@ < heap.objs().len(), 0 <= nid@ < heap.objs().len(),
            ow == heap.addrs()[oid@], nw == heap.addrs()[nid@],
            heap.objs()[oid@].body is Array, heap.objs()[nid@].body is Array,
            heap.objs()[oid@].body->Array_0.len() == length,
            heap.objs()[nid@].body->Array_0.len() == new_length,
            !heap.objs()[nid@].ro,
            new_length > 0, mask == new_length - 1,
        decreases length - i,
    {
        proof {
            assert(heap.addrs().len() == heap.objs().len()) by {
                assert(heap_model_ok(heap.objs(), heap.addrs(), heap.class_bits()));
            }
            lemma_element_good(p, heap, oid@, i as int);
        }
        let e = heap.element(ow, i, oid);
        let x = match ints::int_arg(heap, e, Ghost(heap.objs()[oid@].body->Array_0[i as int])) {
            Some(x) => x,
            None => {
                let r = fail_post(p, Ghost(h0), heap, ROOT_INVALID_ARGUMENT);
                proof { assert(h0 == *old(heap)); assert(prim_post(p, &h0, heap, r.0, r.1@)); assert(prim_post(c.p, old(heap), heap, r.0, r.1@)); }
                return r;
            },
        };
        // `Smi::from` of the word: the low `WORD_BITS - 1` bits, sign-extended.
        let low = x & MAX_SMI;
        let hp = if x & (MAX_SMI + 1) != 0 { low | MIN_SMI } else { low };
        proof {
            assert(MIN_SMI <= (x & MAX_SMI) | MIN_SMI <= MAX_SMI) by (bit_vector);
            assert(MIN_SMI <= x & MAX_SMI <= MAX_SMI) by (bit_vector);
        }
        let mut slot = ((x as u64) & (mask as u64)) as usize;
        let mut step: usize = 1;
        proof { assert(((x as u64) & (mask as u64)) <= mask as u64) by (bit_vector); }
        loop
            invariant
                heap_inv(p, heap), heap_post(p, &h0, heap), h0 == *old(heap), p == c.p,
                new_length < 0x4000_0000,
                slot < new_length, 1 <= step <= new_length + 1,
                heap.objs()[nid@].body->Array_0.len() == new_length,
                0 <= nid@ < heap.objs().len(), nw == heap.addrs()[nid@],
                heap.objs()[nid@].body is Array,
                heap.addrs().len() == heap.objs().len(),
                new_length > 0, mask == new_length - 1,
            decreases new_length + 1 - step,
        {
            if heap.element(nw, slot, nid) == 0 { break; }
            if step > new_length { return fail_post(p, Ghost(h0), heap, ROOT_INVALID_ARGUMENT); }
            let s2: usize = slot + step;
            slot = s2 & mask;
            proof { assert((s2 & mask) <= mask) by (bit_vector); }
            step += 1;
        }
        let ghost h1 = *heap;
        let (sw, sv) = smi_res(heap, hp);
        heap.set_element(nw, slot, sw, nid, sv);
        proof {
            lemma_post_set_element(p, &h1, heap, nid@, slot as int, sv@);
            lemma_post_trans(p, &h0, &h1, heap);
        }
        i += 1;
    }
    let (rw, rv) = root(p, heap, ROOT_NULL);
    (PrimOutcome::Success(rw), rv)
}

/// The array family of the dispatch table.
#[inline(always)]
pub fn dispatch(i: usize, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)),
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@), contract(c.p, i as int, a, old(heap), final(heap), r.0, r.1@),
        never_falls_back_arrays(i as int, a.n as int) ==> completes(r.0),
{
    let n = a.n;
    match i {
        ix::ARRAY_LENGTH if n == 1 => array_length(a, heap, c),
        ix::ARRAY_AT if n == 2 => array_at(a, heap, c),
        ix::ARRAY_AT_PUT if n == 3 => array_at_put(a, heap, c),
        ix::ARRAY_NEW if n == 2 => array_new(a, heap, c),
        ix::ARRAY_EXPAND if n == 4 => array_expand(a, heap, c),
        ix::ARRAY_REPLACE if n == 5 => array_replace(a, heap, c),
        ix::LIST_ADD if n == 2 => list_add(a, heap, c),
        ix::REBUILD_HASH_INDEX if n == 2 => rebuild_hash_index(a, heap, c),
        _ => (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    }
}

} // verus!
