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
//! `lemma_rep_vm` proves `rep` for the VM's layouts (milestone M2) from a
//! structural description of each object (`obj_struct`: its header, an
//! instance's fields, an array's length and elements, a payload, a stack's
//! references) and the core's `heap_model_ok`; `lemma_layout_constants`
//! proves the layout facts the collector shares with the core equal to
//! the core's.

use vstd::prelude::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::cheney::*;
use crate::statement::*;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2};
use toit_spec::v2::gc::{obj_vals, zapped, collection, renamed, is_map, reset_map};
use toit_spec::v2::spec::null2;
use crate::fin::*;
use crate::shrink::cimg;
use crate::weak::*;
#[cfg(verus_keep_ghost)]
use crate::copy::lemma_from_obj;
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

/// The values of the state survive the collection: the object stack, the
/// globals and the running task (what the core's `collected` asks of them).
pub open spec fn state_live(s: State2, h: H, st: St) -> bool {
    &&& forall|j: int| 0 <= j < s.stack.len() && (#[trigger] s.stack[j]) is Obj ==> val_live(h, st, aval(s.stack[j]))
    &&& forall|j: int| 0 <= j < s.globals.len() && (#[trigger] s.globals[j]) is Obj ==> val_live(h, st, aval(s.globals[j]))
    &&& val_live(h, st, AVal::Ref(s.task as int))
}

/// A root value is live after the collection.
proof fn lemma_root_live(c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, rvp: Seq<AVal>, tn: int, i: int)
    requires collected_objs(c, h, st, rptr, rv, rvp, tn), 0 <= i < rv.len(),
    ensures val_live(h, st, rv[i]),
{
    assert(wperm_ok(st.rp, i, rptr, i));
}

/// With every value of the state among the roots (`roots_cover`), the
/// state's values survive.
pub proof fn lemma_roots_cover_live(c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, rvp: Seq<AVal>, tn: int, s: State2)
    requires collected_objs(c, h, st, rptr, rv, rvp, tn), roots_cover(s, rv),
    ensures state_live(s, h, st),
{
    assert forall|j: int| 0 <= j < s.stack.len() && (#[trigger] s.stack[j]) is Obj implies val_live(h, st, aval(s.stack[j])) by {
        let i = choose|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(s.stack[j]->Obj_0 as int);
        lemma_root_live(c, h, st, rptr, rv, rvp, tn, i);
    }
    assert forall|j: int| 0 <= j < s.globals.len() && (#[trigger] s.globals[j]) is Obj implies val_live(h, st, aval(s.globals[j])) by {
        let i = choose|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(s.globals[j]->Obj_0 as int);
        lemma_root_live(c, h, st, rptr, rv, rvp, tn, i);
    }
    let i = choose|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(s.task as int);
    lemma_root_live(c, h, st, rptr, rv, rvp, tn, i);
}

// ---------------------------------------------------------------------------
// The roots as the C++ runtime holds them (milestone M3).

/// The running task's stack object (the task's stack field, `v2::sound::
/// running_ok`).
pub open spec fn running_stack(s: State2) -> int {
    s.heap[s.task as int].body->Instance_0[0]->Obj_0 as int
}

/// The state with the running task's stack written into its stack object,
/// as `task_transfer_step` saves it: what the process heap holds at a
/// collection point (the core runs on that object). In `s` itself the
/// running task's stack object still has the contents of its last
/// suspension (README, "The spec").
pub open spec fn saved(s: State2) -> State2 {
    let sid = running_stack(s);
    State2 {
        heap: s.heap.update(sid, HeapObj { body: Body::Stack2(s.stack, s.frames, s.tries, s.fins, s.bci), ..s.heap[sid] }),
        ..s
    }
}

/// The first roots the C++ enumerates (`ObjectHeap::iterate_roots`): the
/// running task (`task_`), then the globals (`global_variables_`) in
/// order. The rest of the roots (external roots, object notifiers,
/// finalizer nodes) follow; the C++ root obligation (TRUSTED.md section 5)
/// is that they are all the heap references the C++ holds.
pub open spec fn roots_core(s: State2, rv: Seq<AVal>) -> bool {
    &&& rv.len() >= 1 + s.globals.len()
    &&& rv[0] == AVal::Ref(s.task as int)
    &&& forall|j: int| 0 <= j < s.globals.len() ==> #[trigger] rv[1 + j] == aval(s.globals[j])
}

/// The saved state's heap model is the state's: only the running stack
/// object's contents change, and a stack object's contents are not part of
/// the model.
pub proof fn lemma_saved_model(ap: Program2, s: State2, addr: Seq<usize>, cb: Seq<u16>)
    requires toit_spec::v2::sound::running_ok(ap, s), heap_model_ok(s.heap, addr, cb),
    ensures
        heap_model_ok(saved(s).heap, addr, cb),
        saved(s).heap.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] saved(s).heap[i].ro == s.heap[i].ro,
        forall|i: int| 0 <= i < s.heap.len() && i != running_stack(s) ==> #[trigger] saved(s).heap[i] == s.heap[i],
        saved(s).stack == s.stack, saved(s).globals == s.globals, saved(s).task == s.task,
        0 <= running_stack(s) < s.heap.len(), running_stack(s) != s.task as int,
        s.heap[s.task as int].body is Instance,
        s.heap[s.task as int].body->Instance_0.len() >= 1,
        s.heap[s.task as int].body->Instance_0[0] == Value::Obj(running_stack(s) as usize),
{
    let sid = running_stack(s);
    let f = s.heap[s.task as int].body->Instance_0;
    assert(toit_spec::v2::sound::stack_ref(s.heap, f[0]));
    assert(s.heap[sid].body is Stack2);
    let h2 = saved(s).heap;
    assert forall|i: int| 0 <= i < h2.len() implies #[trigger] obj_model_ok(h2[i], cb, addr) by {
        assert(obj_model_ok(s.heap[i], cb, addr));
    }
}

/// With the C++ roots starting with the running task and the globals, and
/// the running stack in its stack object (the saved state's heap
/// represented), the state's values survive: the task and the globals are
/// roots; the stack's values are in the reference slots of the running
/// stack object, which the task's stack field refers to.
pub proof fn lemma_roots_core_live(ap: Program2, cb: Seq<u16>, s: State2,
                                   c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, rvp: Seq<AVal>, tn: int)
    requires
        collected_objs(c, h, st, rptr, rv, rvp, tn),
        roots_core(s, rv),
        toit_spec::v2::sound::running_ok(ap, s),
        h.objs.len() == saved(s).heap.len(),
        obj_rep(saved(s).heap[s.task as int], h.objs[s.task as int], cb, h.objs.len() as int),
        obj_rep(saved(s).heap[running_stack(s)], h.objs[running_stack(s)], cb, h.objs.len() as int),
    ensures state_live(s, h, st),
{
    let n = h.objs.len() as int;
    let sh = saved(s).heap;
    let t = s.task as int;
    let sid = running_stack(s);
    let f = s.heap[t].body->Instance_0;
    assert(toit_spec::v2::sound::stack_ref(s.heap, f[0]));
    assert(sid != t);
    lemma_root_live(c, h, st, rptr, rv, rvp, tn, 0);
    assert(val_live(h, st, AVal::Ref(t)));
    assert forall|j: int| 0 <= j < s.globals.len() && (#[trigger] s.globals[j]) is Obj implies val_live(h, st, aval(s.globals[j])) by {
        lemma_root_live(c, h, st, rptr, rv, rvp, tn, 1 + j);
    }
    // The task's stack field: a reference slot of the task holds the stack object.
    assert(sh[t] == s.heap[t]);
    assert(obj_rep(sh[t], h.objs[t], cb, sh.len() as int));
    assert(obj_vals(sh[t])[0] == Value::Obj(sid as usize));
    let k0 = choose|k: int| is_ref(h.objs[t], k) && #[trigger] h.objs[t].words[k] == AVal::Ref(obj_vals(sh[t])[0]->Obj_0 as int);
    assert(live(h, st, t));
    assert(val_live(h, st, obj(h, t).words[k0]));
    assert(live(h, st, sid));
    // The stack's values: reference slots of the stack object.
    assert(sh[sid].body == Body::Stack2(s.stack, s.frames, s.tries, s.fins, s.bci));
    assert(obj_rep(sh[sid], h.objs[sid], cb, sh.len() as int));
    assert forall|j: int| 0 <= j < s.stack.len() && (#[trigger] s.stack[j]) is Obj implies val_live(h, st, aval(s.stack[j])) by {
        assert(obj_vals(sh[sid])[j] == s.stack[j]);
        let k = choose|k: int| is_ref(h.objs[sid], k) && #[trigger] h.objs[sid].words[k] == AVal::Ref(obj_vals(sh[sid])[j]->Obj_0 as int);
        assert(val_live(h, st, obj(h, sid).words[k]));
    }
}

/// THE BRIDGE. The collector's statement, for a heap that represents the
/// spec state `s1`'s heap (the state after weak processing; there is none before M4,
/// so `s1` is the state before the collection) whose from-space is exactly
/// the non-program heap and whose roots include the state's, implies the
/// core's `gcbridge::collected` with the live set (outside from-space or
/// copied) and the collector's new address map; and every word the core
/// models of every copy is the core's word of its object under that map.
pub proof fn lemma_bridge(ap: Program2, cb: Seq<u16>, s1: State2, n0: int,
                          c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, rvp: Seq<AVal>, ttab: *mut usize, tused: *mut usize, w: Window)
    requires
        heap_ok(c, h),
        collected(c, h, st, rptr, rv, rvp, ttab, tused, w),
        rep(s1.heap, h, cb),
        heap_model_ok(s1.heap, h.addr, cb),
        0 <= n0 <= s1.heap.len(),
        forall|i: int| 0 <= i < s1.heap.len() ==> (#[trigger] s1.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s1.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s1.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s1.heap, #[trigger] ap.literals[i]),
        state_live(s1, h, st),
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
        if s1.stack[j] is Obj { assert(val_live(h, st, aval(s1.stack[j]))); }
    }
    assert forall|j: int| 0 <= j < s1.globals.len() implies gcbridge::val_live_in(lv, #[trigger] s1.globals[j]) by {
        if s1.globals[j] is Obj { assert(val_live(h, st, aval(s1.globals[j]))); }
    }
    assert(val_live(h, st, AVal::Ref(s1.task as int)));
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
        assert(collected_objs(c, h, st, rptr, rv, rvp, w.pages as int));
        assert(st.tp[(cpg(st, i), coff(st, i) + k)].value() == wval(cimg(c, obj(h, i)), st.addr2, k));
        if k > 0 {
            // Not a stack: its spec object has words beyond the header.
            assert(obj_model_ok(sh[i], cb, h.addr));
            assert(is_word(sh[i], 0));
            assert(word_rep(sh[i], h.objs[i], cb, n, 0));
            assert(word_val(sh[i], cb, h.addr, 0, wval(h.objs[i], h.addr, 0)));
            assert(h.objs[i].words[0] is Raw);
            lemma_htag(hdr(obj(h, i)));
            assert(htag(hdr(obj(h, i))) != STACK_TAG);
        }
        crate::shrink::lemma_cimg_word(c, obj(h, i), k);
        assert(wval(cimg(c, obj(h, i)), st.addr2, k) == wval(obj(h, i), st.addr2, k));
    }
}

/// The collection the collector performs is one of the spec: renumbering
/// the live objects (the core's `gcbridge::lemma_collected`) gives a state
/// `s2` with `collection(ap, s, s2)` that the core's heap model represents
/// at the collector's addresses, with every modelled word of every object
/// equal to the collector's word of it. (No weak processing before M4, so
/// the state before weak processing is `s` itself: `zapped(ap, s, s)`.)
pub proof fn lemma_spec_collection(ap: Program2, cb: Seq<u16>, s: State2, n0: int,
                                   c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, rvp: Seq<AVal>, ttab: *mut usize, tused: *mut usize,
                                   w: Window)
    requires
        heap_ok(c, h),
        collected(c, h, st, rptr, rv, rvp, ttab, tused, w),
        rep(s.heap, h, cb),
        heap_model_ok(s.heap, h.addr, cb),
        0 <= n0 <= s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.literals[i]),
        state_live(s, h, st),
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
    lemma_bridge(ap, cb, s, n0, c, h, st, rptr, rv, rvp, ttab, tused, w);
    assert(zapped(ap, s, s)) by {
        assert(s == (State2 { heap: s.heap, ..s }));
        assert forall|i: int| 0 <= i < s.heap.len() implies #[trigger] toit_spec::v2::gc::weak_change(ap, s.heap, i, s.heap[i]) by {}
    }
    gcbridge::lemma_collected(ap, cb, s, s, live_seq(h, st), st.addr2, n0);
}

// ---------------------------------------------------------------------------
// The collection from the core's state (milestone M3).

/// THE BRIDGE FROM THE CORE'S STATE. For the state `s` of the core at a
/// collection point (`running_ok`: the running task's stack field refers
/// to its stack object), with the C++ roots starting with the running task
/// and the globals (`roots_core`) and the process heap representing the
/// saved state (the running stack in its stack object), the collector's
/// result renumbered is a collection of the spec from the saved state,
/// represented by the core's heap model at the collector's addresses.
pub proof fn lemma_spec_collection_core(ap: Program2, cb: Seq<u16>, s: State2, n0: int,
                                        c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, rvp: Seq<AVal>, ttab: *mut usize, tused: *mut usize,
                                        w: Window)
    requires
        heap_ok(c, h),
        collected(c, h, st, rptr, rv, rvp, ttab, tused, w),
        toit_spec::v2::sound::running_ok(ap, s),
        roots_core(s, rv),
        rep(saved(s).heap, h, cb),
        heap_model_ok(s.heap, h.addr, cb),
        0 <= n0 <= s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.literals[i]),
    ensures ({
        let lv = live_seq(h, st);
        let ren = gcbridge::ren_of(lv);
        let back = gcbridge::back_of(lv);
        let s2 = renamed(saved(s), ren, back);
        let a2 = Seq::new(back.len(), |k: int| st.addr2[back[k]]);
        &&& collection(ap, saved(s), s2)
        &&& heap_model_ok(s2.heap, a2, cb)
        &&& enc_seq(a2, s2.stack) == enc_seq(st.addr2, s.stack)
        &&& enc_seq(a2, s2.globals) == enc_seq(st.addr2, s.globals)
    }),
{
    let s0 = saved(s);
    lemma_saved_model(ap, s, h.addr, cb);
    assert(obj_rep(s0.heap[s.task as int], h.objs[s.task as int], cb, h.objs.len() as int));
    assert(obj_rep(s0.heap[running_stack(s)], h.objs[running_stack(s)], cb, h.objs.len() as int));
    lemma_roots_core_live(ap, cb, s, c, h, st, rptr, rv, rvp, w.pages as int);
    assert(state_live(s0, h, st));
    assert forall|i: int| 0 <= i < s0.heap.len() implies (#[trigger] s0.heap[i].ro <==> i < n0) by {
        assert(s0.heap[i].ro == s.heap[i].ro);
    }
    assert forall|i: int| 0 <= i < s0.heap.len() implies (#[trigger] from(h, i) <==> i >= n0) by {}
    assert forall|i: int| 0 <= i < ap.roots.len() implies gcbridge::ro_const(s0.heap, #[trigger] ap.roots[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.roots[i]));
        if ap.roots[i] is Obj { assert(s0.heap[ap.roots[i]->Obj_0 as int].ro == s.heap[ap.roots[i]->Obj_0 as int].ro); }
    }
    assert forall|i: int| 0 <= i < ap.literals.len() implies gcbridge::ro_const(s0.heap, #[trigger] ap.literals[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.literals[i]));
        if ap.literals[i] is Obj { assert(s0.heap[ap.literals[i]->Obj_0 as int].ro == s.heap[ap.literals[i]->Obj_0 as int].ro); }
    }
    lemma_spec_collection(ap, cb, s0, n0, c, h, st, rptr, rv, rvp, ttab, tused, w);
}

// ---------------------------------------------------------------------------
// The VM's layouts (milestone M2): `rep` from the objects' structure.

/// The layout facts the collector shares with the core are the core's
/// (verified/core/src/layout.rs, which verified/LAYOUT.toml checks against
/// the C++ headers).
pub proof fn lemma_layout_constants()
    ensures
        W == toit_verified_core::layout::WORD_SIZE,
        ARRAY_TAG == toit_verified_core::layout::ARRAY_TAG,
        STRING_TAG == toit_verified_core::layout::STRING_TAG,
        INSTANCE_TAG == toit_verified_core::layout::INSTANCE_TAG,
        ODDBALL_TAG == toit_verified_core::layout::ODDBALL_TAG,
        DOUBLE_TAG == toit_verified_core::layout::DOUBLE_TAG,
        BYTE_ARRAY_TAG == toit_verified_core::layout::BYTE_ARRAY_TAG,
        LARGE_INTEGER_TAG == toit_verified_core::layout::LARGE_INTEGER_TAG,
        STACK_TAG == toit_verified_core::layout::STACK_TAG,
        TASK_TAG == toit_verified_core::layout::TASK_TAG,
        ARRAY_LENGTH_WORD == toit_verified_core::layout::ARRAY_LENGTH_WORD,
        ARRAY_ELEMENTS_WORD == toit_verified_core::layout::ARRAY_ELEMENTS_WORD,
        INSTANCE_FIELDS_WORD == toit_verified_core::layout::INSTANCE_FIELDS_WORD,
        STACK_LENGTH_WORD == toit_verified_core::layout::STACK_LENGTH_WORD,
        STACK_TOP_WORD == toit_verified_core::layout::STACK_TOP_WORD,
        VALUE_WORDS == toit_verified_core::layout::VALUE_WORDS,
        1 == toit_verified_core::layout::DOUBLE_VALUE_WORD,
        1 == toit_verified_core::layout::LARGE_INTEGER_VALUE_WORD,
        1 == toit_verified_core::layout::BYTE_ARRAY_LENGTH_WORD,
        CONTENT_BYTE == toit_verified_core::layout::BYTE_ARRAY_CONTENT_BYTE,
        CONTENT_BYTE == toit_verified_core::layout::STRING_CONTENT_BYTE,
        STRING_SENTINEL == toit_verified_core::layout::STRING_SENTINEL,
        STRING_LENGTH_SHIFT == 8 * (toit_verified_core::layout::STRING_INTERNAL_LENGTH_BYTE - toit_verified_core::layout::WORD_SIZE),
        EXTERNAL_WORDS == toit_verified_core::layout::STRING_EXTERNAL_ADDRESS_WORD + 1,
        EXTERNAL_WORDS == toit_verified_core::layout::BYTE_ARRAY_EXTERNAL_TAG_WORD + 1,
        STACK_MIN_ARRAY_WORD == toit_verified_core::layout::STACK_BCI_WORD + 1,
        toit_verified_core::layout::CLASS_ID_OFFSET == 5,
        toit_verified_core::layout::INSTANCE_SIZE_MASK == 0x7ff,
{
}

/// The collector's value of a spec value (the core's `abs::enc` as a word:
/// objects by id, smis and block references as their words).
pub open spec fn aval(v: Value) -> AVal {
    match v {
        Value::Obj(id) => AVal::Ref(id as int),
        Value::Smi(i) => AVal::Raw(toit_verified_core::abs::smi_word(i)),
        Value::BlockRef(f, s) => AVal::Raw(toit_verified_core::abs::block_word(f, s)),
        _ => AVal::Raw(0),
    }
}

/// The collector's object `a` is the spec object `o` in the VM's layout:
/// its header encodes the object's class (the core's header clause of
/// `view::word_val`); an instance's fields, an array's length and elements,
/// a double's or large integer's payload words are the words the core
/// models; the references of a stack's object stack are among its
/// reference slots. Strings, byte arrays and oddballs: the header only
/// (their other words are raw, the core models them through `HeapMem`'s
/// byte and half-word permissions).
pub open spec fn obj_struct(o: HeapObj, a: AObj, cb: Seq<u16>) -> bool {
    &&& a.words.len() >= 1
    &&& a.words[0] is Raw
    &&& toit_verified_core::view::hdr_class_id(raw(a.words[0])) == o.class_id
    &&& (o.class_id as int) < cb.len()
    &&& toit_verified_core::view::hdr_class_tag(raw(a.words[0])) == (cb[o.class_id as int] & 0xf) as usize
    &&& a.cbits == cb[o.class_id as int]
    &&& match o.body {
        Body::Instance(f) => forall|i: int| 0 <= i < f.len() ==> #[trigger] a.words[1 + i] == aval(f[i]),
        Body::Array(e) => a.words[1] == AVal::Raw(e.len() as usize)
            && forall|i: int| 0 <= i < e.len() ==> #[trigger] a.words[2 + i] == aval(e[i]),
        Body::Double(_) | Body::LargeInt(_) => forall|j: int| 0 <= j < VALUE_WORDS ==>
            #[trigger] a.words[1 + j] == AVal::Raw(toit_verified_core::view::value_word(toit_verified_core::view::value64(o), j)),
        Body::Stack(w, _) => forall|j: int| 0 <= j < w.len() && (#[trigger] w[j]) is Obj ==>
            exists|k: int| is_ref(a, k) && #[trigger] a.words[k] == AVal::Ref(w[j]->Obj_0 as int),
        Body::Stack2(w, _, _, _, _) => forall|j: int| 0 <= j < w.len() && (#[trigger] w[j]) is Obj ==>
            exists|k: int| is_ref(a, k) && #[trigger] a.words[k] == AVal::Ref(w[j]->Obj_0 as int),
        _ => true,
    }
}

/// The core's class tag of a header is the collector's.
pub proof fn lemma_htag(h: usize)
    ensures toit_verified_core::view::hdr_class_tag(h) == htag(h),
{
    assert(toit_verified_core::layout::CLASS_TAG_MASK == 15);
    assert((((h as isize) >> 1usize) as usize) & 15usize == (h >> 1usize) & 15usize) by (bit_vector);
}

/// An encodable value's word is the same in both encodings.
pub proof fn lemma_aval_enc(addr: Seq<usize>, v: Value)
    requires encodable(addr, v),
    ensures wval(AObj { words: seq![aval(v)], cbits: 0, sw: 0 }, addr, 0) == toit_verified_core::abs::enc(addr, v),
{
}

/// A word the core models of an object in the VM's layout is the core's
/// word of it under every address map.
pub proof fn lemma_struct_words(o: HeapObj, a: AObj, cb: Seq<u16>, n: int, z: Seq<usize>)
    requires
        obj_struct(o, a, cb), obj_ok(a),
        obj_model_ok(o, cb, z), z.len() == n,
    ensures obj_rep(o, a, cb, n),
{
    let h = raw(a.words[0]);
    let cid = o.class_id as int;
    lemma_htag(h);
    lemma_layout_constants();
    let l = lay(a);
    // The kind of the object decides its layout.
    match o.body {
        Body::Instance(f) => {
            assert(htag(h) == INSTANCE_TAG || htag(h) == TASK_TAG);
            assert(l.lo == 1 && l.hi == isize_bits(a.cbits) && l.size == a.words.len());
            assert(f.len() == toit_verified_core::abs::ifc_bits(cb, cid));
            assert(isize_bits(a.cbits) == toit_verified_core::abs::ifc_bits(cb, cid) + 1) by {
                let b = cb[cid];
                assert(((b >> 5u16) & 0x7ffu16) as int == ((b >> 5u16) & 0x7ffu16) as int);
            }
        },
        Body::Array(e) => {
            assert(htag(h) == ARRAY_TAG);
            assert(l.lo == 2 && l.hi == 2 + e.len());
        },
        Body::Double(_) => {
            assert(htag(h) == DOUBLE_TAG);
            assert(l.size == 1 + VALUE_WORDS);
        },
        Body::LargeInt(_) => {
            assert(htag(h) == LARGE_INTEGER_TAG);
            assert(l.size == 1 + VALUE_WORDS);
        },
        _ => {},
    }
    assert forall|j: int| 0 <= j < obj_vals(o).len() && (#[trigger] obj_vals(o)[j]) is Obj implies
        exists|k: int| is_ref(a, k) && #[trigger] a.words[k] == AVal::Ref(obj_vals(o)[j]->Obj_0 as int) by {
        match o.body {
            Body::Instance(f) => {
                assert(a.words[1 + j] == aval(f[j]));
                assert(is_ref(a, 1 + j));
            },
            Body::Array(e) => {
                assert(a.words[2 + j] == aval(e[j]));
                assert(is_ref(a, 2 + j));
            },
            _ => {},
        }
    }
    assert forall|k: int| #[trigger] toit_verified_core::view::is_word(o, k) implies 0 <= k < a.words.len() && word_rep(o, a, cb, n, k) by {
        assert forall|addr: Seq<usize>| addr.len() == n implies #[trigger] word_val(o, cb, addr, k, wval(a, addr, k)) by {
            lemma_obj_model_addr(o, cb, z, addr);
            if k > 0 {
                match o.body {
                    Body::Instance(f) => {
                        assert(encodable(addr, f[k - 1]));
                        assert(a.words[1 + (k - 1)] == aval(f[k - 1]));
                        lemma_aval_enc(addr, f[k - 1]);
                    },
                    Body::Array(e) => {
                        if k >= 2 {
                            assert(encodable(addr, e[k - 2]));
                            assert(a.words[2 + (k - 2)] == aval(e[k - 2]));
                            lemma_aval_enc(addr, e[k - 2]);
                        }
                    },
                    Body::Double(_) | Body::LargeInt(_) => {
                        assert(a.words[1 + (k - 1)] == AVal::Raw(toit_verified_core::view::value_word(toit_verified_core::view::value64(o), k - 1)));
                    },
                    _ => {},
                }
            }
        }
    }
}

/// `rep` for heaps in the VM's layout: each object of the collector's heap
/// is its spec object in the VM's layout (and agrees with that layout), and
/// the spec heap is the core's well-formed heap model.
pub proof fn lemma_rep_vm(sh: Seq<HeapObj>, h: H, cb: Seq<u16>, addr: Seq<usize>)
    requires
        h.objs.len() == sh.len(),
        heap_model_ok(sh, addr, cb),
        forall|i: int| 0 <= i < sh.len() ==> #[trigger] obj_struct(sh[i], h.objs[i], cb) && obj_ok(h.objs[i]),
    ensures rep(sh, h, cb),
{
    let n = sh.len() as int;
    assert forall|i: int| 0 <= i < n implies #[trigger] obj_rep(sh[i], h.objs[i], cb, n) by {
        assert(obj_model_ok(sh[i], cb, addr));
        assert(obj_struct(sh[i], h.objs[i], cb));
        assert(obj_ok(h.objs[i]));
        lemma_struct_words(sh[i], h.objs[i], cb, n, addr);
    }
}


// ---------------------------------------------------------------------------
// Weak processing (milestone M4).

/// The spec heap after the finalizer pass: the weak maps the collector
/// reset are reset maps (`gc::reset_map`); every other object is the same
/// spec object (a cleared finalizer bit is not part of the spec's object).
pub open spec fn fin_heap(ap: Program2, c: Ctx, sh: Seq<HeapObj>, h: H, hf: H) -> Seq<HeapObj> {
    Seq::new(sh.len(), |i: int|
        if is_map(ap, sh[i]) && obj(hf, i) != obj(h, i) && obj(hf, i) == killed(obj(h, i), c.nullid@, true) {
            reset_map(ap, sh[i])
        } else {
            sh[i]
        })
}

pub open spec fn fin_state(ap: Program2, c: Ctx, s: State2, h: H, hf: H) -> State2 {
    State2 { heap: fin_heap(ap, c, s.heap, h, hf), ..s }
}

/// The keys of the weak-map nodes (and of every node but a registered Toit
/// finalizer) in from-space are maps (`add_finalizer` registers a weak-map
/// node only for an instance of the map class; a queued Toit finalizer's
/// key is null).
pub open spec fn weak_keys_maps(ap: Program2, s: State2, h: H, nodes: Seq<Node>, ncb: int) -> bool {
    forall|m: int| 0 <= m < ncb && (#[trigger] nodes[m]).kind != KIND_TOIT && nodes[m].key is Ref
        && from(h, nodes[m].key->Ref_0) ==> is_map(ap, s.heap[nodes[m].key->Ref_0])
}

/// Clearing the finalizer bit keeps the core's class id and tag.
pub proof fn lemma_clear_hdr(h: usize)
    requires h & 32 == 32,
    ensures
        toit_verified_core::view::hdr_class_id((h - 32) as usize) == toit_verified_core::view::hdr_class_id(h),
        toit_verified_core::view::hdr_class_tag((h - 32) as usize) == toit_verified_core::view::hdr_class_tag(h),
{
    assert(toit_verified_core::layout::CLASS_ID_OFFSET == 5);
    assert(toit_verified_core::layout::CLASS_TAG_MASK == 15);
    assert(h & 32 == 32 ==> (((((h - 32) as usize) as isize) >> 1usize) as usize) >> 5usize
        == (((h as isize) >> 1usize) as usize) >> 5usize) by (bit_vector);
    assert(h & 32 == 32 ==> (((((h - 32) as usize) as isize) >> 1usize) as usize) & 15usize
        == (((h as isize) >> 1usize) as usize) & 15usize) by (bit_vector);
}

/// A key with its finalizer bit cleared is the same spec object.
pub proof fn lemma_struct_cleared(o: HeapObj, a: AObj, cb: Seq<u16>)
    requires obj_struct(o, a, cb), obj_ok(a), active(a),
    ensures obj_struct(o, cleared(a), cb), obj_ok(cleared(a)),
{
    let h = hdr(a);
    lemma_clear_bit(h);
    lemma_clear_hdr(h);
    let a2 = cleared(a);
    assert(hdr(a2) == (h - 32) as usize);
    assert(lay(a2) == lay(a));
    assert forall|k: int| 1 <= k < a.words.len() implies #[trigger] a2.words[k] == a.words[k] by {}
    assert(is_ref(a2, 0) == is_ref(a, 0));
    assert forall|k: int| #[trigger] is_ref(a2, k) == is_ref(a, k) by {}
    match o.body {
        Body::Stack(w, _) => {
            assert forall|j: int| 0 <= j < w.len() && (#[trigger] w[j]) is Obj implies
                exists|k: int| is_ref(a2, k) && #[trigger] a2.words[k] == AVal::Ref(w[j]->Obj_0 as int) by {
                let k = choose|k: int| is_ref(a, k) && #[trigger] a.words[k] == AVal::Ref(w[j]->Obj_0 as int);
                assert(is_ref(a2, k) && a2.words[k] == a.words[k]);
            }
        },
        Body::Stack2(w, _, _, _, _) => {
            assert forall|j: int| 0 <= j < w.len() && (#[trigger] w[j]) is Obj implies
                exists|k: int| is_ref(a2, k) && #[trigger] a2.words[k] == AVal::Ref(w[j]->Obj_0 as int) by {
                let k = choose|k: int| is_ref(a, k) && #[trigger] a.words[k] == AVal::Ref(w[j]->Obj_0 as int);
                assert(is_ref(a2, k) && a2.words[k] == a.words[k]);
            }
        },
        Body::Instance(f) => {
            assert forall|i: int| 0 <= i < f.len() implies #[trigger] a2.words[1 + i] == aval(f[i]) by {
                assert(a.words[1 + i] == aval(f[i]));
            }
        },
        Body::Array(e) => {
            assert(a2.words[1] == a.words[1]);
            assert forall|i: int| 0 <= i < e.len() implies #[trigger] a2.words[2 + i] == aval(e[i]) by {
                assert(a.words[2 + i] == aval(e[i]));
            }
        },
        Body::Double(_) | Body::LargeInt(_) => {
            assert forall|j: int| 0 <= j < VALUE_WORDS implies
                #[trigger] a2.words[1 + j] == AVal::Raw(toit_verified_core::view::value_word(toit_verified_core::view::value64(o), j)) by {
                assert(a.words[1 + j] == AVal::Raw(toit_verified_core::view::value_word(toit_verified_core::view::value64(o), j)));
            }
        },
        _ => {},
    }
}

/// A map in the VM's layout can be reset (an instance with at least four
/// fields), and the reset key is the reset map.
pub proof fn lemma_struct_reset(ap: Program2, o: HeapObj, a: AObj, cb: Seq<u16>, addr: Seq<usize>, nullid: int)
    requires
        obj_struct(o, a, cb), obj_ok(a), active(a), is_map(ap, o), obj_model_ok(o, cb, addr),
        null2(ap) == Value::Obj(nullid as usize), 0 <= nullid < addr.len(), addr.len() < 0x4000_0000,
    ensures
        resettable(a),
        obj_struct(reset_map(ap, o), killed(a, nullid, true), cb),
        obj_model_ok(reset_map(ap, o), cb, addr),
{
    let f = o.body->Instance_0;
    let cid = o.class_id as int;
    lemma_htag(hdr(a));
    lemma_layout_constants();
    assert(htag(hdr(a)) == INSTANCE_TAG || htag(hdr(a)) == TASK_TAG);
    assert(f.len() == toit_verified_core::abs::ifc_bits(cb, cid));
    assert(isize_bits(a.cbits) == toit_verified_core::abs::ifc_bits(cb, cid) + 1) by {
        let b = cb[cid];
        assert(((b >> 5u16) & 0x7ffu16) as int == ((b >> 5u16) & 0x7ffu16) as int);
    }
    assert(lay(a).lo == 1 && lay(a).hi == f.len() + 1);
    assert(resettable(a));
    let r = reset(a, nullid);
    assert(hdr(r) == hdr(a));
    assert(r.cbits == a.cbits);
    assert(lay(r) == lay(a));
    assert(obj_struct(o, a, cb));
    let o2 = reset_map(ap, o);
    let f2 = o2.body->Instance_0;
    assert(toit_verified_core::abs::smi_word(0) == 0);
    assert(aval(Value::Smi(0)) == AVal::Raw(0));
    assert(aval(null2(ap)) == AVal::Ref(nullid));
    assert forall|i: int| 0 <= i < f2.len() implies #[trigger] r.words[1 + i] == aval(f2[i]) by {
        if i >= 4 { assert(a.words[1 + i] == aval(f[i])); }
    }
    assert(obj_struct(o2, r, cb));
    // The reset object agrees with its layout.
    assert forall|k: int| 0 <= k < lay(r).size && !(lay(r).lo <= k < lay(r).hi) implies #[trigger] r.words[k] is Raw by {
        assert(a.words[k] is Raw);
    }
    assert(obj_ok(r));
    assert(active(r));
    lemma_struct_cleared(o2, r, cb);
    assert forall|i: int| 0 <= i < f2.len() implies #[trigger] toit_verified_core::abs::encodable(addr, f2[i]) by {
        if i >= 4 { assert(toit_verified_core::abs::encodable(addr, f[i])); }
        else if i < 2 { assert(toit_verified_core::abs::smi_range(0)); }
    }
}

/// The spec heap after the finalizer pass is represented by the
/// collector's heap after it, and weak processing as the spec allows it.
pub proof fn lemma_fin_rep(ap: Program2, cb: Seq<u16>, s: State2, c: Ctx, h: H, hf: H, st: St, rv: Seq<AVal>,
                           nodes: Seq<Node>, nm: Map<int, PointsTo<usize>>, ncb: int, nn: int, main: Set<int>)
    requires
        heap_ok(c, h), heap_ok(c, hf),
        fin_done(c, h, hf, st, rv, nodes, nm, ncb, nn, main),
        h.objs.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] obj_struct(s.heap[i], h.objs[i], cb),
        heap_model_ok(s.heap, h.addr, cb),
        null2(ap) == Value::Obj(c.nullid@ as usize),
        weak_keys_maps(ap, s, h, nodes, ncb),
    ensures ({
        let s1 = fin_state(ap, c, s, h, hf);
        &&& zapped(ap, s, s1)
        &&& rep(s1.heap, hf, cb)
        &&& heap_model_ok(s1.heap, hf.addr, cb)
        &&& forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s1.heap[i]).ro == s.heap[i].ro
        &&& forall|i: int| 0 <= i < s.heap.len() && !is_map(ap, s.heap[i]) ==> #[trigger] s1.heap[i] == s.heap[i]
    }),
{
    let s1 = fin_state(ap, c, s, h, hf);
    let sh = s.heap;
    let n = sh.len() as int;
    assert forall|i: int| 0 <= i < n implies #[trigger] obj_struct(s1.heap[i], hf.objs[i], cb) && obj_ok(hf.objs[i])
        && obj_model_ok(s1.heap[i], cb, hf.addr) by {
        assert(obj_struct(sh[i], h.objs[i], cb));
        assert(obj_model_ok(sh[i], cb, h.addr));
        assert(obj_ok(obj(hf, i)));
        assert(toit_verified_core::abs::addrs_ok(sh, h.addr));
        assert(c.nullid@ < h.addr.len());
        assert(obj_ok(obj(h, i)));
        assert(changed_ok(c, h, hf, nodes, ncb, main, i));
        if obj(hf, i) != obj(h, i) {
            let m = choose|m: int| 0 <= m < ncb && #[trigger] nodes[m].key == AVal::Ref(i) && nodes[m].kind <= KIND_WEAK_QUEUED
                && obj(hf, i) == killed(obj(h, i), c.nullid@, nodes[m].kind != KIND_TOIT);
            assert(active(obj(h, i)) && from(h, i));
            if is_map(ap, sh[i]) {
                lemma_struct_reset(ap, sh[i], obj(h, i), cb, h.addr, c.nullid@);
                if obj(hf, i) == killed(obj(h, i), c.nullid@, true) {
                    assert(s1.heap[i] == reset_map(ap, sh[i]));
                } else {
                    // A registered Toit finalizer's key: the bit cleared.
                    assert(nodes[m].kind == KIND_TOIT);
                    assert(s1.heap[i] == sh[i]);
                    lemma_struct_cleared(sh[i], obj(h, i), cb);
                }
            } else {
                assert(s1.heap[i] == sh[i]);
                if nodes[m].kind != KIND_TOIT {
                    assert(nodes[m].key is Ref && nodes[m].key->Ref_0 == i);
                    assert(is_map(ap, sh[i]));
                }
                assert(obj(hf, i) == cleared(obj(h, i)));
                lemma_struct_cleared(sh[i], obj(h, i), cb);
            }
        } else {
            assert(s1.heap[i] == sh[i]);
        }
    }
    assert(toit_verified_core::abs::addrs_ok(sh, h.addr));
    assert(hf.addr == h.addr && s1.heap.len() == n);
    assert(toit_verified_core::abs::addrs_ok(s1.heap, hf.addr));
    assert forall|i: int| 0 <= i < s1.heap.len() implies #[trigger] obj_model_ok(s1.heap[i], cb, hf.addr) by {
        assert(obj_struct(s1.heap[i], hf.objs[i], cb));
    }
    assert(heap_model_ok(s1.heap, hf.addr, cb));
    lemma_rep_vm(s1.heap, hf, cb, hf.addr);
    assert(zapped(ap, s, s1)) by {
        assert(s1 == (State2 { heap: s1.heap, ..s }));
        assert forall|i: int| 0 <= i < n implies #[trigger] toit_spec::v2::gc::weak_change(ap, sh, i, s1.heap[i]) by {}
    }
}

/// THE BRIDGE WITH WEAK PROCESSING. The collector's statement with the
/// finalizer pass (`fin_done`): the reset weak maps are the spec's weak
/// processing (`zapped`) and the renumbered result a collection of the
/// spec from `s`.
pub proof fn lemma_spec_collection_fin(ap: Program2, cb: Seq<u16>, s: State2, n0: int,
                                       c: Ctx, h: H, hf: H, st: St, rptr: *mut usize, rv: Seq<AVal>,
                                       nodes: Seq<Node>, nm: Map<int, PointsTo<usize>>, ncb: int, nn: int, main: Set<int>,
                                       ttab: *mut usize, tused: *mut usize, w: Window)
    requires
        heap_ok(c, h), heap_ok(c, hf),
        collected(c, hf, st, rptr, rv, fin_roots(rv, nodes), ttab, tused, w),
        fin_done(c, h, hf, st, rv, nodes, nm, ncb, nn, main),
        h.objs.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] obj_struct(s.heap[i], h.objs[i], cb),
        heap_model_ok(s.heap, h.addr, cb),
        0 <= n0 <= s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.literals[i]),
        state_live(s, hf, st),
        null2(ap) == Value::Obj(c.nullid@ as usize),
        weak_keys_maps(ap, s, h, nodes, ncb),
    ensures ({
        let s1 = fin_state(ap, c, s, h, hf);
        let lv = live_seq(hf, st);
        let ren = gcbridge::ren_of(lv);
        let back = gcbridge::back_of(lv);
        let s2 = renamed(s1, ren, back);
        let a2 = Seq::new(back.len(), |k: int| st.addr2[back[k]]);
        &&& zapped(ap, s, s1)
        &&& collection(ap, s, s2)
        &&& heap_model_ok(s2.heap, a2, cb)
        &&& enc_seq(a2, s2.stack) == enc_seq(st.addr2, s.stack)
        &&& enc_seq(a2, s2.globals) == enc_seq(st.addr2, s.globals)
    }),
{
    let s1 = fin_state(ap, c, s, h, hf);
    lemma_fin_rep(ap, cb, s, c, h, hf, st, rv, nodes, nm, ncb, nn, main);
    assert forall|i: int| 0 <= i < s1.heap.len() implies (#[trigger] s1.heap[i].ro <==> i < n0) by {
        assert(s1.heap[i].ro == s.heap[i].ro);
    }
    assert forall|i: int| 0 <= i < s1.heap.len() implies (#[trigger] from(hf, i) <==> i >= n0) by {
        assert(from(h, i) == from(hf, i));
    }
    assert forall|i: int| 0 <= i < ap.roots.len() implies gcbridge::ro_const(s1.heap, #[trigger] ap.roots[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.roots[i]));
        if ap.roots[i] is Obj { assert(s1.heap[ap.roots[i]->Obj_0 as int].ro == s.heap[ap.roots[i]->Obj_0 as int].ro); }
    }
    assert forall|i: int| 0 <= i < ap.literals.len() implies gcbridge::ro_const(s1.heap, #[trigger] ap.literals[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.literals[i]));
        if ap.literals[i] is Obj { assert(s1.heap[ap.literals[i]->Obj_0 as int].ro == s.heap[ap.literals[i]->Obj_0 as int].ro); }
    }
    assert(state_live(s1, hf, st));
    lemma_bridge(ap, cb, s1, n0, c, hf, st, rptr, rv, fin_roots(rv, nodes), ttab, tused, w);
    gcbridge::lemma_collected(ap, cb, s, s1, live_seq(hf, st), st.addr2, n0);
}

/// THE BRIDGE FROM THE CORE'S STATE WITH WEAK PROCESSING: the C++ roots
/// start with the running task and the globals, the process heap is the
/// saved state's in the VM's layout; the collection (finalizer pass
/// included) is one of the spec from the saved state.
pub proof fn lemma_spec_collection_core_fin(ap: Program2, cb: Seq<u16>, s: State2, n0: int,
                                            c: Ctx, h: H, hf: H, st: St, rptr: *mut usize, rv: Seq<AVal>,
                                            nodes: Seq<Node>, nm: Map<int, PointsTo<usize>>, ncb: int, nn: int, main: Set<int>,
                                            ttab: *mut usize, tused: *mut usize, w: Window)
    requires
        heap_ok(c, h), heap_ok(c, hf),
        collected(c, hf, st, rptr, rv, fin_roots(rv, nodes), ttab, tused, w),
        fin_done(c, h, hf, st, rv, nodes, nm, ncb, nn, main),
        toit_spec::v2::sound::running_ok(ap, s),
        roots_core(s, rv),
        h.objs.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] obj_struct(saved(s).heap[i], h.objs[i], cb),
        heap_model_ok(s.heap, h.addr, cb),
        0 <= n0 <= s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.literals[i]),
        null2(ap) == Value::Obj(c.nullid@ as usize),
        weak_keys_maps(ap, saved(s), h, nodes, ncb),
    ensures ({
        let s1 = fin_state(ap, c, saved(s), h, hf);
        let lv = live_seq(hf, st);
        let ren = gcbridge::ren_of(lv);
        let back = gcbridge::back_of(lv);
        let s2 = renamed(s1, ren, back);
        let a2 = Seq::new(back.len(), |k: int| st.addr2[back[k]]);
        &&& zapped(ap, saved(s), s1)
        &&& collection(ap, saved(s), s2)
        &&& heap_model_ok(s2.heap, a2, cb)
        &&& enc_seq(a2, s2.stack) == enc_seq(st.addr2, s.stack)
        &&& enc_seq(a2, s2.globals) == enc_seq(st.addr2, s.globals)
    }),
{
    let s0 = saved(s);
    let t = s.task as int;
    let sid = running_stack(s);
    lemma_saved_model(ap, s, h.addr, cb);
    lemma_fin_rep(ap, cb, s0, c, h, hf, st, rv, nodes, nm, ncb, nn, main);
    let s1 = fin_state(ap, c, s0, h, hf);
    // The task and its stack object are no maps: the spec objects stay.
    assert(!is_map(ap, s0.heap[t]));
    assert(s0.heap[sid].body is Stack2);
    assert(!is_map(ap, s0.heap[sid]));
    assert(s1.heap[t] == s0.heap[t] && s1.heap[sid] == s0.heap[sid]);
    assert(obj_rep(s1.heap[t], hf.objs[t], cb, hf.objs.len() as int));
    assert(obj_rep(s1.heap[sid], hf.objs[sid], cb, hf.objs.len() as int));
    lemma_roots_core_live(ap, cb, s, c, hf, st, rptr, rv, fin_roots(rv, nodes), w.pages as int);
    assert(state_live(s0, hf, st));
    assert forall|i: int| 0 <= i < s0.heap.len() implies (#[trigger] s0.heap[i].ro <==> i < n0) by {
        assert(s0.heap[i].ro == s.heap[i].ro);
    }
    assert forall|i: int| 0 <= i < ap.roots.len() implies gcbridge::ro_const(s0.heap, #[trigger] ap.roots[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.roots[i]));
        if ap.roots[i] is Obj { assert(s0.heap[ap.roots[i]->Obj_0 as int].ro == s.heap[ap.roots[i]->Obj_0 as int].ro); }
    }
    assert forall|i: int| 0 <= i < ap.literals.len() implies gcbridge::ro_const(s0.heap, #[trigger] ap.literals[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.literals[i]));
        if ap.literals[i] is Obj { assert(s0.heap[ap.literals[i]->Obj_0 as int].ro == s.heap[ap.literals[i]->Obj_0 as int].ro); }
    }
    lemma_spec_collection_fin(ap, cb, s0, n0, c, h, hf, st, rptr, rv, nodes, nm, ncb, nn, main, ttab, tused, w);
}


// ---------------------------------------------------------------------------
// Live weak maps (zapping, `weak.rs`).

/// A zapped array in the spec: the elements the collector nulled are null.
pub open spec fn zap_spec(ap: Program2, o: HeapObj, a: AObj, a2: AObj) -> HeapObj {
    let e = o.body->Array_0;
    HeapObj { body: Body::Array(Seq::new(e.len(), |q: int| if a2.words[2 + q] != a.words[2 + q] { null2(ap) } else { e[q] })), ..o }
}

/// The spec heap after the collection's weak processing: maps the
/// collector reset are reset maps, arrays it zapped are zapped arrays.
pub open spec fn fin_heap_w(ap: Program2, c: Ctx, sh: Seq<HeapObj>, h: H, hf: H) -> Seq<HeapObj> {
    Seq::new(sh.len(), |i: int|
        if is_map(ap, sh[i]) && obj(hf, i) != obj(h, i) && obj(hf, i) == killed(obj(h, i), c.nullid@, true) {
            reset_map(ap, sh[i])
        } else if sh[i].body is Array && obj(hf, i) != obj(h, i) {
            zap_spec(ap, sh[i], obj(h, i), obj(hf, i))
        } else {
            sh[i]
        })
}

pub open spec fn fin_state_w(ap: Program2, c: Ctx, s: State2, h: H, hf: H) -> State2 {
    State2 { heap: fin_heap_w(ap, c, s.heap, h, hf), ..s }
}

/// The class ids the collector compares are the program's builtins.
pub open spec fn cids_ok(ap: Program2, c: Ctx) -> bool {
    &&& c.list_cid as int == toit_spec::spec_common::builtin(toit_spec::v2::types::p1(ap), toit_spec::spec_common::LIST_CLASS)
    &&& c.tomb_cid as int == toit_spec::spec_common::builtin(toit_spec::v2::types::p1(ap), toit_spec::spec_common::TOMBSTONE_CLASS)
}

/// A header's class id as the collector reads it is the core's.
pub proof fn lemma_hcid(o: HeapObj, a: AObj, cb: Seq<u16>)
    requires obj_struct(o, a, cb),
    ensures hcid(hdr(a)) == o.class_id,
{
    toit_verified_core::view::lemma_class_id_shift(raw(a.words[0]));
}

/// The value of a reference word.
pub proof fn lemma_aval_ref(v: Value, y: int)
    requires aval(v) == AVal::Ref(y),
    ensures v == Value::Obj(y as usize), 0 <= y,
{
}

/// A zapped array is the spec's zapped array, represented by the collector's.
pub proof fn lemma_struct_zap(ap: Program2, cb: Seq<u16>, c: Ctx, h: H, s: State2, x: int, a2: AObj, addr: Seq<usize>)
    requires
        heap_ok(c, h), h.objs.len() == s.heap.len(), 0 <= x < s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] obj_struct(s.heap[i], h.objs[i], cb),
        heap_model_ok(s.heap, addr, cb), addr.len() == s.heap.len(),
        s.heap[x].body is Array,
        zapped_arr(c, h, obj(h, x), a2), obj_ok(a2), lay(a2) == lay(obj(h, x)),
        null2(ap) == Value::Obj(c.nullid@ as usize), cids_ok(ap, c),
    ensures ({
        let o2 = zap_spec(ap, s.heap[x], obj(h, x), a2);
        &&& obj_struct(o2, a2, cb)
        &&& obj_model_ok(o2, cb, addr)
        &&& toit_spec::v2::gc::zapped_elems(ap, s.heap, s.heap[x].body->Array_0, o2.body->Array_0)
    }),
{
    let o = s.heap[x];
    let a = obj(h, x);
    let e = o.body->Array_0;
    let o2 = zap_spec(ap, o, a, a2);
    let e2 = o2.body->Array_0;
    assert(obj_struct(o, a, cb));
    assert(obj_model_ok(o, cb, addr));
    assert(toit_verified_core::abs::addrs_ok(s.heap, addr));
    assert(c.nullid@ < h.objs.len());
    assert(a.words[1] == AVal::Raw(e.len() as usize));
    assert(obj_ok(a));
    assert(a.words.len() >= 2);
    assert(a2.words[0] == a.words[0] && a2.words[1] == a.words[1]);
    assert(aval(null2(ap)) == AVal::Ref(c.nullid@));
    assert forall|q: int| 0 <= q < e.len() implies #[trigger] a2.words[2 + q] == aval(e2[q]) by {
        assert(a.words[2 + q] == aval(e[q]));
    }
    assert(obj_struct(o2, a2, cb));
    assert forall|q: int| 0 <= q < e2.len() implies #[trigger] toit_verified_core::abs::encodable(addr, e2[q]) by {
        assert(toit_verified_core::abs::encodable(addr, e[q]));
    }
    assert(obj_model_ok(o2, cb, addr));
    assert forall|q: int| 0 <= q < e.len() implies {
        ||| #[trigger] e2[q] == e[q]
        ||| q % 2 == 1 && e2[q] == null2(ap) && match e[q] {
                Value::Obj(id) => (id as int) < s.heap.len()
                    && s.heap[id as int].class_id as int != toit_spec::spec_common::builtin(toit_spec::v2::types::p1(ap), toit_spec::spec_common::TOMBSTONE_CLASS),
                _ => false,
            }
    } by {
        if a2.words[2 + q] != a.words[2 + q] {
            let k = 2 + q;
            assert(a2.words[k] == a.words[k] || (2 <= k && (k - 2) % 2 == 1 && a2.words[k] == AVal::Ref(c.nullid@) && a.words[k] is Ref
                && 0 <= a.words[k]->Ref_0 < h.objs.len() && hcid(hdr(obj(h, a.words[k]->Ref_0))) != c.tomb_cid));
            let y = a.words[k]->Ref_0;
            assert(a.words[2 + q] == aval(e[q]));
            lemma_aval_ref(e[q], y);
            assert(obj_struct(s.heap[y], h.objs[y], cb));
            lemma_hcid(s.heap[y], h.objs[y], cb);
        }
    }
}

/// The map of a hidden node's backing list is a map of the spec whose
/// backing array is `x`.
pub proof fn lemma_backing(ap: Program2, cb: Seq<u16>, c: Ctx, h: H, hs: H, s: State2, nodes: Seq<Node>, nodes2: Seq<Node>,
                           ncb: int, m: int, x: int)
    requires
        heap_ok(c, h), h.objs.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] obj_struct(s.heap[i], h.objs[i], cb),
        heap_model_ok(s.heap, h.addr, cb),
        heap_ok(c, hs),
        hide_ok(c, h, hs, nodes, nodes2, ncb), 0 <= m < nodes.len(), nodes2[m].hid,
        0 <= ncb <= nodes.len(),
        backing(c, hs, nodes2[m].bk, x), 0 <= x < s.heap.len(), s.heap[x].body is Array,
        weak_keys_maps(ap, s, h, nodes, ncb), cids_ok(ap, c), c.map_cid != c.list_cid,
    ensures toit_spec::v2::gc::backing_array(ap, s.heap, nodes[m].key->Ref_0 as int, x),
{
    let mk = nodes[m].key->Ref_0;
    let l = nodes2[m].bk->Ref_0;
    let om = obj(h, mk);
    assert(nodes2[m] == (Node { ix: nodes2[m].ix, bk: nodes2[m].bk, hid: nodes2[m].hid, ..nodes[m] }));
    assert(from(h, mk) && weak_map(c, om) && nodes2[m].bk == om.words[4]);
    assert(is_map(ap, s.heap[mk]));
    let f = s.heap[mk].body->Instance_0;
    assert(obj_struct(s.heap[mk], om, cb));
    let q3: int = 3;
    assert(om.words[1 + q3] == aval(f[q3]));
    lemma_aval_ref(f[3], l);
    lemma_from_obj(c, hs, l);
    // The list is h's object (lists are no hidden maps).
    assert(obj(hs, l) == obj(h, l)) by {
        if obj(hs, l) != obj(h, l) {
            let m2 = choose|m2: int| 0 <= m2 < ncb && (#[trigger] nodes2[m2]).hid && nodes[m2].key == AVal::Ref(l);
            assert(nodes2[m2].hid && 0 <= m2 < nodes.len());
            assert(nodes[m2].key->Ref_0 == l);
            assert(weak_map(c, obj(h, l)) && obj(hs, l) == hidden(obj(h, l)));
            assert(hdr(obj(hs, l)) == hdr(obj(h, l)));
            assert(hidden(obj(h, l)).words[0] == obj(h, l).words[0]);
            assert(false);
        }
    }
    let ol = obj(h, l);
    lemma_from_obj(c, h, l);
    assert(obj_struct(s.heap[l], ol, cb));
    lemma_hcid(s.heap[l], ol, cb);
    assert(obj_model_ok(s.heap[l], cb, h.addr));
    lemma_htag(hdr(ol));
    assert(s.heap[l].body is Instance);
    let fl = s.heap[l].body->Instance_0;
    let cid = s.heap[l].class_id as int;
    assert(fl.len() == toit_verified_core::abs::ifc_bits(cb, cid));
    assert(isize_bits(ol.cbits) == toit_verified_core::abs::ifc_bits(cb, cid) + 1) by {
        let b = cb[cid];
        assert(((b >> 5u16) & 0x7ffu16) as int == ((b >> 5u16) & 0x7ffu16) as int);
    }
    assert(fl.len() >= 1);
    let q0: int = 0;
    assert(ol.words[1 + q0] == aval(fl[q0]));
    lemma_aval_ref(fl[0], x);
}

/// The spec heap after the collection (hiding, the weak pass, the
/// finalizer pass) is represented by the collector's, and its weak
/// processing is the spec's.
pub proof fn lemma_fin_rep_w(ap: Program2, cb: Seq<u16>, s: State2, c: Ctx, h: H, hs: H, hw: H, hf: H, st: St, rv: Seq<AVal>,
                             nodes: Seq<Node>, nodes2: Seq<Node>, nodesw: Seq<Node>, nm: Map<int, PointsTo<usize>>,
                             ncb: int, nn: int, main: Set<int>)
    requires
        heap_ok(c, h), heap_ok(c, hs), heap_ok(c, hw), heap_ok(c, hf),
        hide_ok(c, h, hs, nodes, nodes2, ncb), weak_ok(c, hs, hw, nodes2, nodesw, ncb),
        fin_done(c, hw, hf, st, rv, nodesw, nm, ncb, nn, main),
        nodesw.len() == nodes.len(),
        forall|m: int| 0 <= m < nodes.len() ==> (#[trigger] nodesw[m]).key == nodes[m].key && nodesw[m].kind == nodes[m].kind,
        keys_ok(h, nodes, ncb), c.map_cid != c.list_cid, 0 <= ncb <= nodes.len(),
        h.objs.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] obj_struct(s.heap[i], h.objs[i], cb),
        heap_model_ok(s.heap, h.addr, cb),
        null2(ap) == Value::Obj(c.nullid@ as usize),
        forall|i: int| 0 <= i < s.heap.len() && #[trigger] from(h, i) ==> !s.heap[i].ro,
        weak_keys_maps(ap, s, h, nodes, ncb), cids_ok(ap, c),
    ensures ({
        let s1 = fin_state_w(ap, c, s, h, hf);
        &&& zapped(ap, s, s1)
        &&& rep(s1.heap, hf, cb)
        &&& heap_model_ok(s1.heap, hf.addr, cb)
        &&& forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s1.heap[i]).ro == s.heap[i].ro
        &&& forall|i: int| 0 <= i < s.heap.len() && !is_map(ap, s.heap[i]) && !(s.heap[i].body is Array) ==> #[trigger] s1.heap[i] == s.heap[i]
    }),
{
    let s1 = fin_state_w(ap, c, s, h, hf);
    let sh = s.heap;
    let n = sh.len() as int;
    assert forall|i: int| 0 <= i < n implies #[trigger] obj_struct(s1.heap[i], hf.objs[i], cb) && obj_ok(hf.objs[i])
        && obj_model_ok(s1.heap[i], cb, hf.addr)
        && toit_spec::v2::gc::weak_change(ap, sh, i, s1.heap[i]) by {
        let o = obj(h, i);
        assert(obj_struct(sh[i], o, cb));
        assert(obj_model_ok(sh[i], cb, h.addr));
        assert(obj_ok(obj(hf, i)) && obj_ok(o));
        assert(toit_verified_core::abs::addrs_ok(sh, h.addr));
        assert(c.nullid@ < h.addr.len());
        assert(changed_ok(c, hw, hf, nodesw, ncb, main, i));
        assert(wchanged(c, hs, hw, nodes2, ncb, i));
        let hidm = exists|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes[m].key == AVal::Ref(i);
        if obj(hf, i) == o {
            assert(s1.heap[i] == sh[i]);
        } else if hidm {
            // A hidden weak map: restored (then unchanged) or reset.
            let m = choose|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes[m].key == AVal::Ref(i);
            assert(nodes2[m] == (Node { ix: nodes2[m].ix, bk: nodes2[m].bk, hid: nodes2[m].hid, ..nodes[m] }));
            assert(from(h, i) && weak_map(c, o) && obj(hs, i) == hidden(o) && nodes2[m].ix == o.words[3] && nodes2[m].bk == o.words[4]);
            assert(nodes2[m].key == AVal::Ref(i));
            assert(is_map(ap, sh[i]));
            lemma_from_obj(c, h, i);
            assert(unhide(hidden(o), nodes2[m].ix, nodes2[m].bk) == o) by { assert(unhide(hidden(o), nodes2[m].ix, nodes2[m].bk).words =~= o.words); }
            assert(lay(hidden(o)) == lay(o)) by { assert(hidden(o).words[0] == o.words[0] && hidden(o).words.len() == o.words.len()); }
            assert(killed(hidden(o), c.nullid@, true) == killed(o, c.nullid@, true)) by {
                if resettable(o) { assert(reset(hidden(o), c.nullid@).words =~= reset(o, c.nullid@).words); }
            }
            let ow = obj(hw, i);
            assert(ow == o || ow == killed(o, c.nullid@, true));
            lemma_struct_reset(ap, sh[i], o, cb, h.addr, c.nullid@);
            if ow == o {
                // Changed by the finalizer pass: killed as a key (its node's kind is a weak map's: reset).
                let m2 = choose|m2: int| 0 <= m2 < ncb && #[trigger] nodesw[m2].key == AVal::Ref(i) && nodesw[m2].kind <= KIND_WEAK_QUEUED
                    && obj(hf, i) == killed(obj(hw, i), c.nullid@, nodesw[m2].kind != KIND_TOIT);
                assert(nodes[m2].key == nodes[m].key);
                assert(m2 == m);
                assert(nodesw[m2].kind != KIND_TOIT);
                assert(obj(hf, i) == killed(o, c.nullid@, true));
            } else {
                lemma_clear_bit(hdr(o));
                assert(hdr(killed(o, c.nullid@, true)) == (hdr(o) - 32) as usize) by {
                    if resettable(o) { assert(hdr(reset(o, c.nullid@)) == hdr(o)); }
                }
                assert(!active(ow));
                assert(obj(hf, i) == ow);
            }
            assert(s1.heap[i] == reset_map(ap, sh[i]));
        } else if obj(hw, i) != obj(hs, i) {
            // A zapped array.
            assert(obj(hs, i) == o);
            let m = choose|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && backing(c, hs, nodes2[m].bk, i);
            assert(from(hs, i) && zapped_arr(c, hs, obj(hs, i), obj(hw, i)));
            assert(htag(hdr(o)) == ARRAY_TAG);
            assert(obj(hf, i) == obj(hw, i)) by {
                if obj(hf, i) != obj(hw, i) {
                    let m2 = choose|m2: int| 0 <= m2 < ncb && #[trigger] nodesw[m2].key == AVal::Ref(i) && nodesw[m2].kind <= KIND_WEAK_QUEUED
                        && obj(hf, i) == killed(obj(hw, i), c.nullid@, nodesw[m2].kind != KIND_TOIT);
                    assert(nodes[m2].key == AVal::Ref(i) && from(h, i));
                    assert(htag(hdr(obj(h, i))) == INSTANCE_TAG);
                    assert(false);
                }
            }
            lemma_htag(hdr(o));
            assert(sh[i].body is Array);
            assert(!is_map(ap, sh[i]));
            assert(s1.heap[i] == zap_spec(ap, sh[i], o, obj(hf, i)));
            assert(obj(hf, i).words[0] == o.words[0] && obj(hf, i).words[1] == o.words[1] && obj(hf, i).words.len() == o.words.len()) by {
                assert(o.words.len() >= 2);
            }
            assert(lay(obj(hf, i)) == lay(o));
            assert forall|y: int| 0 <= y < hs.objs.len() implies #[trigger] hcid(hdr(obj(hs, y))) == hcid(hdr(obj(h, y))) by {
                if obj(hs, y) != obj(h, y) {
                    let m3 = choose|m3: int| 0 <= m3 < ncb && (#[trigger] nodes2[m3]).hid && nodes[m3].key == AVal::Ref(y);
                    assert(obj(hs, y) == hidden(obj(h, y)));
                    assert(hidden(obj(h, y)).words[0] == obj(h, y).words[0]);
                }
            }
            assert(zapped_arr(c, h, o, obj(hf, i))) by {
                assert forall|k: int| 0 <= k < o.words.len() implies #[trigger] obj(hf, i).words[k] == o.words[k]
                    || (2 <= k && (k - 2) % 2 == 1 && obj(hf, i).words[k] == AVal::Ref(c.nullid@) && o.words[k] is Ref
                        && 0 <= o.words[k]->Ref_0 < h.objs.len() && hcid(hdr(obj(h, o.words[k]->Ref_0))) != c.tomb_cid) by {
                    if obj(hf, i).words[k] != o.words[k] {
                        let y = o.words[k]->Ref_0;
                        assert(hcid(hdr(obj(hs, y))) == hcid(hdr(obj(h, y))));
                    }
                }
            }
            lemma_struct_zap(ap, cb, c, h, s, i, obj(hf, i), h.addr);
            lemma_backing(ap, cb, c, h, hs, s, nodes, nodes2, ncb, m, i);
            assert(!sh[i].ro);
        } else {
            // Neither hidden nor zapped: a key killed by the finalizer pass.
            assert(obj(hw, i) == o) by {
                if obj(hs, i) != o {
                    let m3 = choose|m3: int| 0 <= m3 < ncb && (#[trigger] nodes2[m3]).hid && nodes[m3].key == AVal::Ref(i);
                    assert(false);
                }
            }
            let m = choose|m: int| 0 <= m < ncb && #[trigger] nodesw[m].key == AVal::Ref(i) && nodesw[m].kind <= KIND_WEAK_QUEUED
                && obj(hf, i) == killed(obj(hw, i), c.nullid@, nodesw[m].kind != KIND_TOIT);
            assert(active(o) && from(h, i));
            assert(nodes[m].key == AVal::Ref(i) && nodes[m].kind == nodesw[m].kind);
            lemma_htag(hdr(o));
            assert(htag(hdr(o)) == INSTANCE_TAG);
            assert(!(sh[i].body is Array));
            if is_map(ap, sh[i]) {
                lemma_struct_reset(ap, sh[i], o, cb, h.addr, c.nullid@);
                if obj(hf, i) == killed(o, c.nullid@, true) {
                    assert(s1.heap[i] == reset_map(ap, sh[i]));
                } else {
                    assert(nodes[m].kind == KIND_TOIT);
                    assert(s1.heap[i] == sh[i]);
                    lemma_struct_cleared(sh[i], o, cb);
                }
            } else {
                assert(s1.heap[i] == sh[i]);
                if nodes[m].kind != KIND_TOIT {
                    assert(nodes[m].key is Ref && nodes[m].key->Ref_0 == i);
                    assert(is_map(ap, sh[i]));
                }
                assert(obj(hf, i) == cleared(o));
                lemma_struct_cleared(sh[i], o, cb);
            }
        }
    }
    assert(toit_verified_core::abs::addrs_ok(sh, h.addr));
    assert(hf.addr == h.addr && s1.heap.len() == n);
    assert(toit_verified_core::abs::addrs_ok(s1.heap, hf.addr));
    assert forall|i: int| 0 <= i < s1.heap.len() implies #[trigger] obj_model_ok(s1.heap[i], cb, hf.addr) by {
        assert(obj_struct(s1.heap[i], hf.objs[i], cb));
    }
    assert(heap_model_ok(s1.heap, hf.addr, cb));
    lemma_rep_vm(s1.heap, hf, cb, hf.addr);
    assert(zapped(ap, s, s1)) by {
        assert(s1 == (State2 { heap: s1.heap, ..s }));
        assert forall|i: int| 0 <= i < n implies #[trigger] toit_spec::v2::gc::weak_change(ap, sh, i, s1.heap[i]) by {
            assert(obj_struct(s1.heap[i], hf.objs[i], cb));
        }
    }
}


/// THE BRIDGE (collections with hidden weak maps, the weak pass and the
/// finalizer pass; `statement::collect`'s result): for the core's state `s`
/// at a collection point, with the C++ roots starting with the running task
/// and the globals and the process heap in the VM's layout representing the
/// saved state, the collector's result renumbered is a collection of the
/// spec from the saved state; its weak processing (reset maps, zapped
/// arrays) is the spec's `zapped`.
pub proof fn lemma_spec_collection_core_w(ap: Program2, cb: Seq<u16>, s: State2, n0: int,
                                          c: Ctx, h: H, hs: H, hw: H, hf: H, st: St, rptr: *mut usize, rv: Seq<AVal>,
                                          nodes: Seq<Node>, nodes2: Seq<Node>, nodesw: Seq<Node>, nm: Map<int, PointsTo<usize>>,
                                          ncb: int, nn: int, main: Set<int>, ttab: *mut usize, tused: *mut usize, w: Window)
    requires
        heap_ok(c, h), heap_ok(c, hs), heap_ok(c, hw), heap_ok(c, hf),
        hide_ok(c, h, hs, nodes, nodes2, ncb), weak_ok(c, hs, hw, nodes2, nodesw, ncb),
        collected(c, hf, st, rptr, rv, fin_roots(rv, nodesw), ttab, tused, w),
        fin_done(c, hw, hf, st, rv, nodesw, nm, ncb, nn, main),
        nodesw.len() == nodes.len(),
        forall|m: int| 0 <= m < nodes.len() ==> (#[trigger] nodesw[m]).key == nodes[m].key && nodesw[m].kind == nodes[m].kind,
        keys_ok(h, nodes, ncb), c.map_cid != c.list_cid, 0 <= ncb <= nodes.len(),
        toit_spec::v2::sound::running_ok(ap, s),
        roots_core(s, rv),
        h.objs.len() == s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> #[trigger] obj_struct(saved(s).heap[i], h.objs[i], cb),
        heap_model_ok(s.heap, h.addr, cb),
        0 <= n0 <= s.heap.len(),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] s.heap[i].ro <==> i < n0),
        forall|i: int| 0 <= i < s.heap.len() ==> (#[trigger] from(h, i) <==> i >= n0),
        forall|i: int| 0 <= i < ap.roots.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.roots[i]),
        forall|i: int| 0 <= i < ap.literals.len() ==> gcbridge::ro_const(s.heap, #[trigger] ap.literals[i]),
        null2(ap) == Value::Obj(c.nullid@ as usize),
        weak_keys_maps(ap, saved(s), h, nodes, ncb), cids_ok(ap, c),
    ensures ({
        let s1 = fin_state_w(ap, c, saved(s), h, hf);
        let lv = live_seq(hf, st);
        let ren = gcbridge::ren_of(lv);
        let back = gcbridge::back_of(lv);
        let s2 = renamed(s1, ren, back);
        let a2 = Seq::new(back.len(), |k: int| st.addr2[back[k]]);
        &&& zapped(ap, saved(s), s1)
        &&& collection(ap, saved(s), s2)
        &&& heap_model_ok(s2.heap, a2, cb)
        &&& enc_seq(a2, s2.stack) == enc_seq(st.addr2, s.stack)
        &&& enc_seq(a2, s2.globals) == enc_seq(st.addr2, s.globals)
    }),
{
    let s0 = saved(s);
    let t = s.task as int;
    let sid = running_stack(s);
    lemma_saved_model(ap, s, h.addr, cb);
    assert forall|i: int| 0 <= i < s0.heap.len() && #[trigger] from(h, i) implies !s0.heap[i].ro by {
        assert(s0.heap[i].ro == s.heap[i].ro);
    }
    lemma_fin_rep_w(ap, cb, s0, c, h, hs, hw, hf, st, rv, nodes, nodes2, nodesw, nm, ncb, nn, main);
    let s1 = fin_state_w(ap, c, s0, h, hf);
    // The task and its stack object are neither maps nor arrays.
    assert(!is_map(ap, s0.heap[t]));
    assert(s0.heap[sid].body is Stack2);
    assert(!is_map(ap, s0.heap[sid]));
    assert(s1.heap[t] == s0.heap[t] && s1.heap[sid] == s0.heap[sid]);
    assert(obj_rep(s1.heap[t], hf.objs[t], cb, hf.objs.len() as int));
    assert(obj_rep(s1.heap[sid], hf.objs[sid], cb, hf.objs.len() as int));
    lemma_roots_core_live(ap, cb, s, c, hf, st, rptr, rv, fin_roots(rv, nodesw), w.pages as int);
    assert(state_live(s1, hf, st));
    assert forall|i: int| 0 <= i < s1.heap.len() implies (#[trigger] s1.heap[i].ro <==> i < n0) by {
        assert(s1.heap[i].ro == s0.heap[i].ro && s0.heap[i].ro == s.heap[i].ro);
    }
    assert forall|i: int| 0 <= i < s1.heap.len() implies (#[trigger] from(hf, i) <==> i >= n0) by {
        assert(from(h, i) == from(hf, i));
    }
    assert forall|i: int| 0 <= i < ap.roots.len() implies gcbridge::ro_const(s1.heap, #[trigger] ap.roots[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.roots[i]));
        if ap.roots[i] is Obj { assert(s1.heap[ap.roots[i]->Obj_0 as int].ro == s.heap[ap.roots[i]->Obj_0 as int].ro); }
    }
    assert forall|i: int| 0 <= i < ap.literals.len() implies gcbridge::ro_const(s1.heap, #[trigger] ap.literals[i]) by {
        assert(gcbridge::ro_const(s.heap, ap.literals[i]));
        if ap.literals[i] is Obj { assert(s1.heap[ap.literals[i]->Obj_0 as int].ro == s.heap[ap.literals[i]->Obj_0 as int].ro); }
    }
    lemma_bridge(ap, cb, s1, n0, c, hf, st, rptr, rv, fin_roots(rv, nodesw), ttab, tused, w);
    gcbridge::lemma_collected(ap, cb, s0, s1, live_seq(hf, st), st.addr2, n0);
}

} // verus!
