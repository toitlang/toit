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
        rep(saved(s).heap, h, cb),
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
        assert(st.tp[(cpg(st, i), coff(st, i) + k)].value() == wval(obj(h, i), st.addr2, k));
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

} // verus!
