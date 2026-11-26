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

//! The connection to the core and the spec (Verus only; check.sh verifies
//! it with the spec and core crates imported, `--cfg toit_gc_bridge`).
//!
//! `lemma_bridge`: the collector's statement (`statement::collected`)
//! implies the core's `gcbridge::collected` (verified/core/src/
//! gcbridge.rs, the real definition, imported) for the spec's heap, and
//! that every word of every copy is the core's word of its object
//! (`view::word_val`) under the new address map. `lemma_spec_collection`
//! composes it with the core's `gcbridge::lemma_collected`: the state the
//! collector leaves, renumbered, is a collection of the spec
//! (`toit_spec::v2::gc::collection`) that the core's heap model
//! represents.
//!
//! What ties the collector's heap to the spec's (`rep`), stated per object
//! and for any address map: every reference the spec object holds is in a
//! reference slot of the collector's object, and every word the core
//! models (`view::is_word`) is the core's word of it (`view::word_val`).
//! M1's layout is not the VM's, so `rep` is a hypothesis here; milestone
//! M2 (the VM's layouts) proves it for the real object layouts.

use vstd::prelude::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::cheney::*;
use crate::statement::*;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2};
use toit_spec::v2::gc::{obj_vals, zapped, collection, renamed};
use toit_verified_core::abs::{obj_model_ok, heap_model_ok, encodable, enc_seq};
use toit_verified_core::view::{word_val, is_word};
use toit_verified_core::gcbridge;

verus! {

/// The collector's object `a` represents the spec's object `o` (class
/// bits `cb`, `n` objects).
pub open spec fn obj_rep(o: HeapObj, a: AObj, cb: Seq<u16>, n: int) -> bool {
    &&& forall|j: int| 0 <= j < obj_vals(o).len() && (#[trigger] obj_vals(o)[j]) is Obj ==>
            exists|k: int| is_ref(a, k) && #[trigger] a.words[k] == AVal::Ref(obj_vals(o)[j]->Obj_0 as int)
    &&& forall|k: int| #[trigger] is_word(o, k) ==> 0 <= k < a.words.len() && word_rep(o, a, cb, n, k)
}

/// Word `k` of `a` is the core's word `k` of `o` under every address map.
pub open spec fn word_rep(o: HeapObj, a: AObj, cb: Seq<u16>, n: int, k: int) -> bool {
    forall|addr: Seq<usize>| addr.len() == n ==> #[trigger] word_val(o, cb, addr, k, wval(a, addr, k))
}

pub open spec fn rep(sh: Seq<HeapObj>, h: H, cb: Seq<u16>) -> bool {
    &&& h.objs.len() == sh.len()
    &&& forall|i: int| 0 <= i < sh.len() ==> #[trigger] obj_rep(sh[i], h.objs[i], cb, sh.len() as int)
}

/// The roots the collector was given include the state's: the object
/// stack, the globals and the running task (milestone M3 makes this the
/// completeness obligation of the root interface).
pub open spec fn roots_cover(s: State2, rv: Seq<AVal>) -> bool {
    &&& forall|j: int| 0 <= j < s.stack.len() && (#[trigger] s.stack[j]) is Obj ==>
            exists|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(s.stack[j]->Obj_0 as int)
    &&& forall|j: int| 0 <= j < s.globals.len() && (#[trigger] s.globals[j]) is Obj ==>
            exists|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(s.globals[j]->Obj_0 as int)
    &&& exists|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(s.task as int)
}

/// The live set as the core's `collected` takes it.
pub open spec fn live_seq(h: H, st: St) -> Seq<bool> {
    Seq::new(h.objs.len(), |i: int| live(h, st, i))
}

/// `obj_model_ok` depends on the address map only through its length.
pub proof fn lemma_obj_model_addr(o: HeapObj, cb: Seq<u16>, a1: Seq<usize>, a2: Seq<usize>)
    requires obj_model_ok(o, cb, a1), a1.len() == a2.len(),
    ensures obj_model_ok(o, cb, a2),
{
    match o.body {
        Body::Instance(f) => {
            assert forall|i: int| 0 <= i < f.len() implies #[trigger] encodable(a2, f[i]) by {
                assert(encodable(a1, f[i]));
            }
        },
        Body::Array(e) => {
            assert forall|i: int| 0 <= i < e.len() implies #[trigger] encodable(a2, e[i]) by {
                assert(encodable(a1, e[i]));
            }
        },
        _ => {},
    }
}

/// A live value of the collector is a live value of the core's `collected`.
proof fn lemma_val_live(h: H, st: St, rv: Seq<AVal>, v: Value)
    requires
        v is Obj ==> exists|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(v->Obj_0 as int),
        forall|i: int| 0 <= i < rv.len() ==> #[trigger] val_live(h, st, rv[i]),
    ensures gcbridge::val_live_in(live_seq(h, st), v),
{
    if v is Obj {
        let i = choose|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(v->Obj_0 as int);
        assert(val_live(h, st, rv[i]));
    }
}

/// THE BRIDGE. The collector's statement, for a heap that represents the
/// spec state `s1`'s heap (the state after weak processing; M1 does none,
/// so `s1` is the state before the collection) whose from-space is exactly
/// the non-program heap and whose roots include the state's, implies the
/// core's `gcbridge::collected` with the live set (outside from-space or
/// copied) and the collector's new address map; and every word the core
/// models of every copy is the core's word of its object under that map.
pub proof fn lemma_bridge(ap: Program2, cb: Seq<u16>, s1: State2, n0: int,
                          c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, ttab: *mut usize, tused: *mut usize, w: Window)
    requires
        heap_ok(c, h),
        collected(c, h, st, rptr, rv, ttab, tused, w),
        rep(s1.heap, h, cb),
        heap_model_ok(s1.heap, h.addr, cb),
        0 <= n0 <= s1.heap.len(),
        forall|i: int| 0 <= i < s1.heap.len() ==> (#[trigger] s1.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s1.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s1.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s1.heap, #[trigger] ap.literals[i]),
        roots_cover(s1, rv),
    ensures
        gcbridge::collected(ap, cb, s1, live_seq(h, st), st.addr2, n0),
        forall|i: int, k: int| 0 <= i < s1.heap.len() && copied(st, i) && #[trigger] is_word(s1.heap[i], k) ==>
            0 <= k < size(h, i)
            && word_val(s1.heap[i], cb, st.addr2, k, st.tp[(cpg(st, i), coff(st, i) + k)].value()),
{
    let sh = s1.heap;
    let n = sh.len() as int;
    assert forall|i: int| 0 <= i < rv.len() implies #[trigger] val_live(h, st, rv[i]) by {
        assert(wperm_ok(st.rp, i, rptr, i));
    }
    let lv = live_seq(h, st);
    assert forall|i: int| 0 <= i < n0 implies #[trigger] lv[i] by {
        assert(!from(h, i));
    }
    assert forall|j: int| 0 <= j < s1.stack.len() implies gcbridge::val_live_in(lv, #[trigger] s1.stack[j]) by {
        lemma_val_live(h, st, rv, s1.stack[j]);
    }
    assert forall|j: int| 0 <= j < s1.globals.len() implies gcbridge::val_live_in(lv, #[trigger] s1.globals[j]) by {
        lemma_val_live(h, st, rv, s1.globals[j]);
    }
    lemma_val_live(h, st, rv, Value::Obj(s1.task));
    assert forall|i: int, j: int| 0 <= i < n && lv[i] && 0 <= j < obj_vals(sh[i]).len()
        implies gcbridge::val_live_in(lv, #[trigger] obj_vals(sh[i])[j]) by {
        assert(obj_rep(sh[i], h.objs[i], cb, n));
        let v = obj_vals(sh[i])[j];
        if v is Obj {
            let k = choose|k: int| is_ref(h.objs[i], k) && #[trigger] h.objs[i].words[k] == AVal::Ref(v->Obj_0 as int);
            assert(live(h, st, i));
            assert(val_live(h, st, obj(h, i).words[k]));
        }
    }
    assert forall|i: int| 0 <= i < n && #[trigger] lv[i] implies st.addr2[i] & 3 == 1 && obj_model_ok(sh[i], cb, st.addr2) by {
        assert(live(h, st, i));
        assert(st.addr2[i] % 4 == 1);
        let a = st.addr2[i];
        assert(a % 4 == 1 ==> a & 3 == 1) by (bit_vector);
        assert(obj_model_ok(sh[i], cb, h.addr));
        lemma_obj_model_addr(sh[i], cb, h.addr, st.addr2);
    }
    assert forall|i: int, j: int| 0 <= i < n && 0 <= j < n && lv[i] && lv[j] && i != j
        implies #[trigger] st.addr2[i] != #[trigger] st.addr2[j] by {
        assert(live(h, st, i) && live(h, st, j));
    }
    assert(gcbridge::collected(ap, cb, s1, lv, st.addr2, n0));
    assert forall|i: int, k: int| 0 <= i < s1.heap.len() && copied(st, i) && #[trigger] is_word(s1.heap[i], k) implies
        0 <= k < size(h, i) && word_val(s1.heap[i], cb, st.addr2, k, st.tp[(cpg(st, i), coff(st, i) + k)].value()) by {
        assert(0 <= i < h.objs.len() && copied(st, i));
        assert(0 <= cpg(st, i) < w.pages);
        assert(obj_rep(sh[i], h.objs[i], cb, n));
        assert(is_word(sh[i], k));
        assert(0 <= k < h.objs[i].words.len() && word_rep(sh[i], h.objs[i], cb, n, k));
        assert(word_val(sh[i], cb, st.addr2, k, wval(h.objs[i], st.addr2, k)));
        assert(obj_ok(obj(h, i)));
        assert(0 <= k < size(h, i));
        assert(collected_objs(c, h, st, rptr, rv, w.pages as int));
        assert(st.tp[(cpg(st, i), coff(st, i) + k)].value() == wval(obj(h, i), st.addr2, k));
    }
}

/// The collection the collector performs is one of the spec: renumbering
/// the live objects (the core's `gcbridge::lemma_collected`) gives a state
/// `s2` with `collection(ap, s, s2)` that the core's heap model represents
/// at the collector's addresses, with every modelled word of every object
/// equal to the collector's word of it. (M1 does no weak processing, so
/// the state before weak processing is `s` itself: `zapped(ap, s, s)`.)
pub proof fn lemma_spec_collection(ap: Program2, cb: Seq<u16>, s: State2, n0: int,
                                   c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, ttab: *mut usize, tused: *mut usize,
                                   w: Window)
    requires
        heap_ok(c, h),
        collected(c, h, st, rptr, rv, ttab, tused, w),
        rep(s.heap, h, cb),
        heap_model_ok(s.heap, h.addr, cb),
        0 <= n0 <= s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.literals[i]),
        roots_cover(s, rv),
    ensures ({
        let lv = live_seq(h, st);
        let ren = gcbridge::ren_of(lv);
        let back = gcbridge::back_of(lv);
        let s2 = renamed(s, ren, back);
        let a2 = Seq::new(back.len(), |k: int| st.addr2[back[k]]);
        &&& collection(ap, s, s2)
        &&& heap_model_ok(s2.heap, a2, cb)
        &&& enc_seq(a2, s2.stack) == enc_seq(st.addr2, s.stack)
        &&& enc_seq(a2, s2.globals) == enc_seq(st.addr2, s.globals)
    }),
{
    lemma_bridge(ap, cb, s, n0, c, h, st, rptr, rv, ttab, tused, w);
    assert(zapped(ap, s, s)) by {
        assert(s == (State2 { heap: s.heap, ..s }));
        assert forall|i: int| 0 <= i < s.heap.len() implies #[trigger] toit_spec::v2::gc::weak_change(ap, s.heap, i, s.heap[i]) by {}
    }
    gcbridge::lemma_collected(ap, cb, s, s, live_seq(h, st), st.addr2, n0);
}

} // verus!
