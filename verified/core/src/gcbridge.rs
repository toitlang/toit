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

//! Where the collector proof will meet the core (stage 0 of the plan,
//! OBLIGATIONS.md "The collector"). Proof only; nothing here is trusted.
//!
//! A collector that keeps object identities (it moves objects and frees
//! garbage, but has no notion of renumbering) delivers `collected`: the
//! contract the scavenge of the pilot proves (verified/gcpilot on branch
//! gc/proof-pilot, `scavenge::collected`), restated for the core's model
//! and for a whole collection. For the state `s1` after weak processing
//! (`toit_spec::v2::gc::zapped`, the abstract objects otherwise
//! unchanged) there is a live set that holds the roots and is closed under
//! references, holds the program heap (the first `n0` objects, which are
//! exactly the read-only ones), and new tagged, distinct addresses `addr2`
//! of the live objects, where each live object's words are its abstract
//! words in the core's encoding under `addr2` (`view::word_val`), and the
//! roots hold their unchanged abstract values encoded under `addr2`.
//!
//! `lemma_collected` numbers the live objects in order (`rank`) and shows
//! that this is a collection of the spec (`toit_spec::v2::gc::collection`,
//! what the GC leaf contracts promise) whose state the core's heap model
//! represents at the collector's addresses: the heap model is well formed
//! (`abs::heap_model_ok`), every word the collector left is the core's
//! word of the renumbered object (`view::word_val`), and the roots are the
//! encodings of the renumbered roots. What a collector proof must still
//! hand over at run time is the memory itself: the word permissions of the
//! live objects (`view::HeapMem`), the cards and the allocation window
//! (TRUSTED.md section 9).

use vstd::prelude::*;
#[cfg(verus_keep_ghost)]
use crate::abs::*;
#[cfg(verus_keep_ghost)]
use crate::view::word_val;
#[cfg(verus_keep_ghost)]
use toit_spec::types::{Value, HeapObj, Body};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{State2, Program2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::gc::*;

verus! {

/// The number of live ids below `i`.
pub open spec fn rank(live: Seq<bool>, i: int) -> int
    decreases i,
{
    if i <= 0 { 0 } else { rank(live, i - 1) + if live[i - 1] { 1int } else { 0int } }
}

/// The new id of each old one (`-1`: garbage) ...
pub open spec fn ren_of(live: Seq<bool>) -> Seq<int> {
    Seq::new(live.len(), |i: int| if live[i] { rank(live, i) } else { -1 })
}

/// ... and the old id of each new one.
pub open spec fn back_of(live: Seq<bool>) -> Seq<int> {
    Seq::new(rank(live, live.len() as int) as nat,
        |k: int| choose|i: int| 0 <= i < live.len() && live[i] && rank(live, i) == k)
}

pub open spec fn val_live_in(live: Seq<bool>, v: Value) -> bool {
    match v {
        Value::Obj(id) => (id as int) < live.len() && live[id as int],
        _ => true,
    }
}

/// A program-heap object (or a smi): a constant of the program.
pub open spec fn ro_const(h: Seq<HeapObj>, v: Value) -> bool {
    match v {
        Value::Obj(id) => (id as int) < h.len() && h[id as int].ro,
        _ => true,
    }
}

/// What a collector that keeps object identities delivers for the state
/// `s1` (after weak processing): the live set `live`, closed and holding
/// the roots and the program heap (the first `n0` objects); the new
/// addresses `addr2` of the live objects, tagged and distinct; each live
/// object well formed under them (`abs::obj_model_ok`: its words are the
/// core's words of it, `view::word_val`, by the heap model's definition).
pub open spec fn collected(ap: Program2, cb: Seq<u16>, s1: State2, live: Seq<bool>, addr2: Seq<usize>, n0: int) -> bool {
    let h = s1.heap;
    &&& live.len() == h.len()
    &&& addr2.len() == h.len()
    &&& h.len() < 0x4000_0000
    &&& 0 <= n0 <= h.len()
    &&& forall|i: int| 0 <= i < h.len() ==> (#[trigger] h[i].ro <==> i < n0)
    &&& forall|i: int| 0 <= i < n0 ==> #[trigger] live[i]
    &&& forall|i: int| 0 <= i < ap.roots.len() ==> ro_const(h, #[trigger] ap.roots[i])
    &&& forall|i: int| 0 <= i < ap.literals.len() ==> ro_const(h, #[trigger] ap.literals[i])
    &&& forall|j: int| 0 <= j < s1.stack.len() ==> val_live_in(live, #[trigger] s1.stack[j])
    &&& forall|j: int| 0 <= j < s1.globals.len() ==> val_live_in(live, #[trigger] s1.globals[j])
    &&& (s1.task as int) < live.len() && live[s1.task as int]
    &&& forall|i: int, j: int| 0 <= i < h.len() && live[i] && 0 <= j < obj_vals(h[i]).len()
            ==> val_live_in(live, #[trigger] obj_vals(h[i])[j])
    &&& forall|i: int| 0 <= i < h.len() && #[trigger] live[i] ==> addr2[i] & 3 == 1 && obj_model_ok(h[i], cb, addr2)
    &&& forall|i: int, j: int| 0 <= i < h.len() && 0 <= j < h.len() && live[i] && live[j] && i != j
            ==> #[trigger] addr2[i] != #[trigger] addr2[j]
}

// ---------------------------------------------------------------------------
// Ranks.

proof fn lemma_rank_bounds(live: Seq<bool>, i: int)
    requires 0 <= i <= live.len(),
    ensures 0 <= rank(live, i) <= i,
    decreases i,
{
    if i > 0 { lemma_rank_bounds(live, i - 1); }
}

proof fn lemma_rank_mono(live: Seq<bool>, i: int, j: int)
    requires 0 <= i <= j <= live.len(),
    ensures rank(live, i) <= rank(live, j),
    decreases j - i,
{
    if i < j { lemma_rank_mono(live, i, j - 1); }
}

/// A live id has a smaller rank than every later id.
proof fn lemma_rank_strict(live: Seq<bool>, i: int, j: int)
    requires 0 <= i < j <= live.len(), live[i],
    ensures rank(live, i) < rank(live, j),
{
    lemma_rank_mono(live, i + 1, j);
}

/// Every rank below the total is a live id's.
proof fn lemma_rank_onto(live: Seq<bool>, n: int, k: int)
    requires 0 <= n <= live.len(), 0 <= k < rank(live, n),
    ensures exists|i: int| 0 <= i < n && live[i] && rank(live, i) == k,
    decreases n,
{
    if k < rank(live, n - 1) {
        lemma_rank_onto(live, n - 1, k);
        let i = choose|i: int| 0 <= i < n - 1 && live[i] && rank(live, i) == k;
        assert(0 <= i < n && live[i] && rank(live, i) == k);
    } else {
        lemma_rank_bounds(live, n - 1);
        assert(live[n - 1] && rank(live, n - 1) == k);
    }
}

/// A live prefix keeps its ids.
proof fn lemma_rank_prefix(live: Seq<bool>, n0: int, i: int)
    requires 0 <= i <= n0 <= live.len(), forall|j: int| 0 <= j < n0 ==> #[trigger] live[j],
    ensures rank(live, i) == i,
    decreases i,
{
    if i > 0 { lemma_rank_prefix(live, n0, i - 1); assert(live[i - 1]); }
}

// ---------------------------------------------------------------------------
// The bridge.

/// The live ids and their renumbering form a compaction of the spec.
proof fn lemma_collected_ren(ap: Program2, cb: Seq<u16>, s1: State2, live: Seq<bool>, addr2: Seq<usize>, n0: int)
    requires collected(ap, cb, s1, live, addr2, n0),
    ensures
        ren_ok(ap, s1, ren_of(live), back_of(live)),
        forall|i: int| #[trigger] toit_spec::v2::gc::live(ren_of(live), i) <==> 0 <= i < live.len() && live[i],
        forall|k: int| 0 <= k < back_of(live).len() ==> 0 <= #[trigger] back_of(live)[k] < live.len(),
{
    let h = s1.heap;
    let n = h.len() as int;
    let ren = ren_of(live);
    let back = back_of(live);
    lemma_rank_bounds(live, n);
    assert forall|i: int| #[trigger] toit_spec::v2::gc::live(ren, i) <==> 0 <= i < live.len() && live[i] by {
        if 0 <= i < n && live[i] { lemma_rank_bounds(live, i); }
    }
    assert forall|k: int| 0 <= k < back.len() implies toit_spec::v2::gc::live(ren, #[trigger] back[k]) && ren[back[k]] == k
        && 0 <= back[k] < live.len() by {
        lemma_rank_onto(live, n, k);
    }
    assert forall|i: int| #[trigger] toit_spec::v2::gc::live(ren, i) implies ren[i] < back.len() && back[ren[i]] == i by {
        lemma_rank_strict(live, i, n);
        lemma_rank_bounds(live, i);
        let k = ren[i];
        lemma_rank_onto(live, n, k);
        let i2 = back[k];
        assert(0 <= i2 < n && live[i2] && rank(live, i2) == k);
        if i2 < i { lemma_rank_strict(live, i2, i); }
        if i < i2 { lemma_rank_strict(live, i, i2); }
    }
    assert forall|i: int| 0 <= i < h.len() && (#[trigger] h[i]).ro implies ren[i] == i by {
        lemma_rank_prefix(live, n0, i);
    }
    assert forall|i: int| 0 <= i < ap.roots.len() implies fixed(ren, #[trigger] ap.roots[i]) by {
        assert(ro_const(h, ap.roots[i]));
        match ap.roots[i] {
            Value::Obj(id) => { assert(h[id as int].ro); lemma_rank_prefix(live, n0, id as int); },
            _ => {},
        }
    }
    assert forall|i: int| 0 <= i < ap.literals.len() implies fixed(ren, #[trigger] ap.literals[i]) by {
        assert(ro_const(h, ap.literals[i]));
        match ap.literals[i] {
            Value::Obj(id) => { assert(h[id as int].ro); lemma_rank_prefix(live, n0, id as int); },
            _ => {},
        }
    }
    assert forall|j: int| 0 <= j < s1.stack.len() implies val_live(ren, #[trigger] s1.stack[j]) by {
        assert(val_live_in(live, s1.stack[j]));
    }
    assert forall|j: int| 0 <= j < s1.globals.len() implies val_live(ren, #[trigger] s1.globals[j]) by {
        assert(val_live_in(live, s1.globals[j]));
    }
    assert forall|i: int| #[trigger] toit_spec::v2::gc::live(ren, i) implies refs_live(ren, h, i) by {
        assert forall|j: int| 0 <= j < obj_vals(h[i]).len() implies val_live(ren, #[trigger] obj_vals(h[i])[j]) by {
            assert(val_live_in(live, obj_vals(h[i])[j]));
        }
    }
}

/// A renamed live value has the encoding under the compacted addresses
/// that the value has under the collector's addresses.
proof fn lemma_enc_ren(ren: Seq<int>, back: Seq<int>, addr2: Seq<usize>, a2: Seq<usize>, v: Value)
    requires
        val_live(ren, v),
        a2.len() == back.len(),
        ren.len() == addr2.len(),
        forall|k: int| 0 <= k < back.len() ==> #[trigger] a2[k] == addr2[back[k]],
        forall|i: int| #[trigger] toit_spec::v2::gc::live(ren, i) ==> ren[i] < back.len() && back[ren[i]] == i,
        back.len() < 0x4000_0000,
    ensures
        enc(a2, ren_val(ren, v)) == enc(addr2, v),
        encodable(addr2, v) ==> encodable(a2, ren_val(ren, v)),
{
    match v {
        Value::Obj(id) => {
            let i = id as int;
            assert(toit_spec::v2::gc::live(ren, i));
            assert(0 <= ren[i] < back.len());
            assert(ren[i] as usize as int == ren[i]);
            assert(a2[ren[i]] == addr2[back[ren[i]]]);
        },
        _ => {},
    }
}

/// The renumbered objects of what a collector delivers, at the collector's
/// addresses: a collection of the spec, represented by the core's heap
/// model.
pub proof fn lemma_collected(ap: Program2, cb: Seq<u16>, s: State2, s1: State2, live: Seq<bool>, addr2: Seq<usize>, n0: int)
    requires
        zapped(ap, s, s1),
        collected(ap, cb, s1, live, addr2, n0),
    ensures ({
        let ren = ren_of(live);
        let back = back_of(live);
        let s2 = renamed(s1, ren, back);
        let a2 = Seq::new(back.len(), |k: int| addr2[back[k]]);
        &&& collection(ap, s, s2)
        &&& heap_model_ok(s2.heap, a2, cb)
        &&& forall|k: int, j: int, w: usize| 0 <= k < s2.heap.len() && crate::view::is_word(s1.heap[back[k]], j) ==>
                (#[trigger] word_val(s2.heap[k], cb, a2, j, w) <==> word_val(s1.heap[back[k]], cb, addr2, j, w))
        &&& enc_seq(a2, s2.stack) == enc_seq(addr2, s1.stack)
        &&& enc_seq(a2, s2.globals) == enc_seq(addr2, s1.globals)
        &&& forall|i: int| 0 <= i < n0 ==> #[trigger] ren[i] == i
    }),
{
    let h = s1.heap;
    let n = h.len() as int;
    let ren = ren_of(live);
    let back = back_of(live);
    let s2 = renamed(s1, ren, back);
    let a2 = Seq::new(back.len(), |k: int| addr2[back[k]]);
    lemma_collected_ren(ap, cb, s1, live, addr2, n0);
    lemma_rank_bounds(live, n);
    assert(gc_by(ap, s, s1, ren, back, s2));
    // The heap model.
    assert forall|k: int| 0 <= k < back.len() implies #[trigger] a2[k] == addr2[back[k]] by {}
    assert forall|k: int| 0 <= k < a2.len() implies #[trigger] a2[k] & 3 == 1 by {
        assert(live[back[k]]);
    }
    assert forall|k1: int, k2: int| 0 <= k1 < a2.len() && 0 <= k2 < a2.len() && k1 != k2
        implies #[trigger] a2[k1] != #[trigger] a2[k2] by {
        assert(toit_spec::v2::gc::live(ren, back[k1]) && toit_spec::v2::gc::live(ren, back[k2]));
        assert(back[k1] != back[k2]);
    }
    assert(addrs_ok(s2.heap, a2));
    assert forall|k: int| 0 <= k < s2.heap.len() implies #[trigger] obj_model_ok(s2.heap[k], cb, a2) by {
        let i = back[k];
        assert(live[i]);
        assert(obj_model_ok(h[i], cb, addr2));
        assert(refs_live(ren, h, i));
        let o = h[i];
        match o.body {
            Body::Instance(f) => {
                assert forall|j: int| 0 <= j < f.len() implies #[trigger] encodable(a2, ren_vals(ren, f)[j]) by {
                    assert(val_live(ren, obj_vals(o)[j]));
                    lemma_enc_ren(ren, back, addr2, a2, f[j]);
                }
            },
            Body::Array(e) => {
                assert forall|j: int| 0 <= j < e.len() implies #[trigger] encodable(a2, ren_vals(ren, e)[j]) by {
                    assert(val_live(ren, obj_vals(o)[j]));
                    lemma_enc_ren(ren, back, addr2, a2, e[j]);
                    assert(encodable(addr2, e[j]));
                }
            },
            _ => {},
        }
    }
    assert(heap_model_ok(s2.heap, a2, cb));
    // The words.
    assert forall|k: int, j: int, w: usize| 0 <= k < s2.heap.len() && crate::view::is_word(h[back[k]], j) implies
        (#[trigger] word_val(s2.heap[k], cb, a2, j, w) <==> word_val(h[back[k]], cb, addr2, j, w)) by {
        let i = back[k];
        let o = h[i];
        assert(refs_live(ren, h, i));
        if j > 0 {
            match o.body {
                Body::Instance(f) => {
                    let x = j - crate::layout::INSTANCE_FIELDS_WORD;
                    if 0 <= x < f.len() {
                        assert(val_live(ren, obj_vals(o)[x]));
                        lemma_enc_ren(ren, back, addr2, a2, f[x]);
                    }
                },
                Body::Array(e) => {
                    let x = j - crate::layout::ARRAY_ELEMENTS_WORD;
                    if 0 <= x < e.len() {
                        assert(val_live(ren, obj_vals(o)[x]));
                        lemma_enc_ren(ren, back, addr2, a2, e[x]);
                    }
                },
                _ => {},
            }
        }
    }
    // The roots.
    assert(enc_seq(a2, s2.stack) =~= enc_seq(addr2, s1.stack)) by {
        assert forall|j: int| 0 <= j < s1.stack.len() implies enc(a2, s2.stack[j]) == enc(addr2, s1.stack[j]) by {
            assert(val_live(ren, s1.stack[j]));
            lemma_enc_ren(ren, back, addr2, a2, s1.stack[j]);
        }
    }
    assert(enc_seq(a2, s2.globals) =~= enc_seq(addr2, s1.globals)) by {
        assert forall|j: int| 0 <= j < s1.globals.len() implies enc(a2, s2.globals[j]) == enc(addr2, s1.globals[j]) by {
            assert(val_live(ren, s1.globals[j]));
            lemma_enc_ren(ren, back, addr2, a2, s1.globals[j]);
        }
    }
    assert forall|i: int| 0 <= i < n0 implies #[trigger] ren[i] == i by {
        lemma_rank_prefix(live, n0, i);
    }
}

} // verus!
