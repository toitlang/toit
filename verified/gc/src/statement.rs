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

//! The top-level statement (`collected`) and the driver (`collect`).

use vstd::prelude::*;
use vstd::raw_ptr::*;
use vstd::set_lib::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::space::*;
use crate::cheney::*;
use crate::copy::*;
use crate::collect::*;

verus! {

/// Why a collection did not start (nothing was changed).
pub enum GcError {
    /// The from-space table is not sorted, aligned or in the address space.
    BadFromTable,
    /// The to-space tables have fewer than `2 * nf + 1` entries.
    SmallTable,
    /// The page source could not reserve `2 * nf + 1` pages.
    NoReservation,
}

/// The heap after a collection: its pages (in the to-space tables) and
/// the used words of the last one (the allocation window is the rest of
/// that page below its sentinel word).
pub struct Window {
    pub pages: usize,
    pub top: usize,
}

// ---------------------------------------------------------------------------
// Reachability.

/// A reference slot of object `a` refers to object `b`.
pub open spec fn refers(h: H, a: int, b: int) -> bool {
    exists|s: int| is_ref(obj(h, a), s) && #[trigger] obj(h, a).words[s] == AVal::Ref(b)
}

/// `p` is a path from the roots to object `j`: its first object is a
/// root's referent, each next one is referred to by a reference slot of
/// the one before, the last is `j`.
pub open spec fn path(h: H, rv: Seq<AVal>, p: Seq<int>, j: int) -> bool {
    &&& p.len() >= 1
    &&& p[p.len() - 1] == j
    &&& exists|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(p[0])
    &&& forall|m: int| 0 <= m < p.len() - 1 ==> 0 <= #[trigger] p[m] < h.objs.len() && refers(h, p[m], p[m + 1])
}

/// Object `j` is reachable from the roots `rv`.
pub open spec fn reachable(h: H, rv: Seq<AVal>, j: int) -> bool {
    exists|p: Seq<int>| #[trigger] path(h, rv, p, j)
}

/// Every copy is reachable: through its parent chain.
pub proof fn lemma_copy_reach(c: Ctx, h: H, st: St, rv: Seq<AVal>, k: int)
    requires heap_ok(c, h), bk_ok(h, st), par_ok(h, st, rv), 0 <= k < st.order.len(),
    ensures reachable(h, rv, st.order[k]),
    decreases k,
{
    assert(parent_ok(h, st, rv, k));
    let p = st.parent[k].0;
    let s = st.parent[k].1;
    let j = st.order[k];
    if p < 0 {
        assert(rv[-1 - p] == AVal::Ref(j));
        let q = seq![j];
        assert(path(h, rv, q, j));
    } else {
        lemma_copy_reach(c, h, st, rv, p);
        let j2 = st.order[p];
        let q0 = choose|q0: Seq<int>| #[trigger] path(h, rv, q0, j2);
        assert(from(h, j2));
        lemma_from_obj(c, h, j2);
        assert(refers(h, j2, j));
        let q = q0.push(j);
        assert forall|m: int| 0 <= m < q.len() - 1 implies 0 <= #[trigger] q[m] < h.objs.len() && refers(h, q[m], q[m + 1]) by {
            if m < q0.len() - 1 {
                assert(q0[m] == q[m] && q0[m + 1] == q[m + 1]);
            } else {
                assert(q[m] == j2 && q[m + 1] == j);
            }
        }
        assert(q[0] == q0[0]);
        assert(path(h, rv, q, j));
    }
}

/// The objects of a path are live (outside from-space or copied): the
/// roots and the copies' reference slots are closed, and the program heap
/// does not refer to from-space.
pub proof fn lemma_path_live(c: Ctx, h: H, st: St, t: Tos, rptr: *mut usize, rv: Seq<AVal>, p: Seq<int>, j: int, m: int)
    requires
        heap_ok(c, h), bk_ok(h, st), to_inv(c, h, st, st.order.len() as int, 0),
        roots_ok(c, h, st, rptr, rv, rv.len() as int),
        path(h, rv, p, j), 0 <= m < p.len(),
    ensures !from(h, p[m]) || copied(st, p[m]),
    decreases m,
{
    if m == 0 {
        let i = choose|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(p[0]);
        assert(closed(h, st, rv[i]));
    } else {
        lemma_path_live(c, h, st, t, rptr, rv, p, j, m - 1);
        let a = p[m - 1];
        assert(0 <= a < h.objs.len() && refers(h, a, p[m]));
        let s = choose|s: int| is_ref(obj(h, a), s) && #[trigger] obj(h, a).words[s] == AVal::Ref(p[m]);
        if from(h, a) {
            let k = st.pos[a];
            assert(0 <= k < st.order.len() && st.order[k] == a);
            lemma_from_obj(c, h, a);
            assert(processed(k, s, st.order.len() as int, 0));
            assert(closed(h, st, obj(h, st.order[k]).words[s]));
        } else {
            assert(prog_ref_ok(h, obj(h, a).words[s]));
        }
    }
}

// ---------------------------------------------------------------------------
// The statement.

/// Object `j` survives: it is outside from-space (the program heap) or
/// copied.
pub open spec fn live(h: H, st: St, j: int) -> bool {
    !from(h, j) || copied(st, j)
}

/// A reference refers to a surviving object.
pub open spec fn val_live(h: H, st: St, v: AVal) -> bool {
    match v {
        AVal::Ref(i) => 0 <= i < h.objs.len() && live(h, st, i),
        _ => true,
    }
}

/// The to-space location of copied object `j` (page, word offset).
pub open spec fn cpg(st: St, j: int) -> int { st.tloc[st.pos[j]].0 }

pub open spec fn coff(st: St, j: int) -> int { st.tloc[st.pos[j]].1 }

/// THE STATEMENT. After a collection (`collect` returned `w`), for the heap
/// `h` it was given (object ids stable, contents unchanged):
/// - the copied objects are exactly the from-space objects reachable from
///   the roots;
/// - the objects outside from-space keep their addresses; every surviving
///   object (outside from-space or copied) has a tagged address, distinct
///   from every other surviving object's; the references of a surviving
///   object refer to surviving objects;
/// - each copy lies in a to-space page below that page's used words, the
///   copies do not overlap, and the words of copy `j` are `j`'s abstract
///   words with every reference encoded under the new address map `addr2`;
/// - every root holds its value encoded under `addr2`, and refers to a
///   surviving object;
/// - the heap now has `w.pages` pages, at least one and at most
///   `2 * nf + 1`: their starts in `ttab`, their used words in `tused`, a
///   zero sentinel word after the used words of each (the C++
///   chunk-end sentinel), the permissions of all their words (the copies'
///   and the allocation window's), pairwise disjoint and holding no object
///   outside from-space; the last page has `w.top` used words;
/// - the from-space permissions are handed back (to free the pages).
pub open spec fn collected(c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, ttab: *mut usize, tused: *mut usize,
                           w: Window) -> bool {
    &&& collected_objs(c, h, st, rptr, rv, w.pages as int)
    &&& collected_pages(c, h, st, ttab, tused, w)
}

/// The objects, the copies and the roots after the collection.
pub open spec fn collected_objs(c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, tn: int) -> bool {
    let n = h.objs.len() as int;
    // The objects.
    &&& st.addr2.len() == n
    &&& forall|j: int| 0 <= j < n ==> (#[trigger] copied(st, j) <==> from(h, j) && reachable(h, rv, j))
    &&& forall|j: int| 0 <= j < n && !from(h, j) ==> #[trigger] st.addr2[j] == h.addr[j]
    &&& forall|j: int| 0 <= j < n && live(h, st, j) ==> #[trigger] st.addr2[j] % 4 == 1
    &&& forall|j1: int, j2: int| 0 <= j1 < n && 0 <= j2 < n && live(h, st, j1) && live(h, st, j2) && j1 != j2
            ==> #[trigger] st.addr2[j1] != #[trigger] st.addr2[j2]
    &&& forall|j: int, k: int| 0 <= j < n && live(h, st, j) && is_ref(obj(h, j), k)
            ==> val_live(h, st, #[trigger] obj(h, j).words[k])
    // The copies.
    &&& forall|j: int| 0 <= j < n && #[trigger] copied(st, j) ==>
            0 <= cpg(st, j) < tn && 0 <= coff(st, j) && coff(st, j) + size(h, j) <= st.tus[cpg(st, j)]
            && st.addr2[j] == st.tss[cpg(st, j)] + coff(st, j) * W + 1
    &&& forall|j1: int, j2: int| 0 <= j1 < n && 0 <= j2 < n && copied(st, j1) && copied(st, j2) && j1 != j2
            && #[trigger] cpg(st, j1) == #[trigger] cpg(st, j2) ==>
            coff(st, j1) + size(h, j1) <= coff(st, j2) || coff(st, j2) + size(h, j2) <= coff(st, j1)
    &&& forall|j: int, k: int| 0 <= j < n && copied(st, j) && 0 <= k < size(h, j) ==>
            (#[trigger] st.tp[(cpg(st, j), coff(st, j) + k)]).is_init()
            && st.tp[(cpg(st, j), coff(st, j) + k)].value() == wval(obj(h, j), st.addr2, k)
    // The roots.
    &&& forall|i: int| 0 <= i < rv.len() ==> #[trigger] wperm_ok(st.rp, i, rptr, i) && st.rp[i].is_init()
            && st.rp[i].value() == enc(st.addr2, rv[i]) && val_live(h, st, rv[i])
}

/// The pages after the collection.
pub open spec fn collected_pages(c: Ctx, h: H, st: St, ttab: *mut usize, tused: *mut usize, w: Window) -> bool {
    let n = h.objs.len() as int;
    let tn = w.pages as int;
    &&& 1 <= tn <= 2 * c.nf + 1
    &&& st.tss.len() == tn && st.tus.len() == tn && st.tus[tn - 1] == w.top
    &&& forall|p: int| 0 <= p < tn ==> #[trigger] wperm_ok(st.ttp, p, ttab, p) && st.ttp[p].is_init() && st.ttp[p].value() == st.tss[p]
    &&& forall|p: int| 0 <= p < tn ==> #[trigger] wperm_ok(st.tup, p, tused, p) && st.tup[p].is_init() && st.tup[p].value() == st.tus[p]
    &&& forall|p: int| 0 <= p < tn ==> #[trigger] st.tss[p] % W == 0 && st.tss[p] + pbytes(c) < usize::MAX
            && 0 <= st.tus[p] <= c.pw - 1
    &&& forall|p: int, k: int| 0 <= p < tn && 0 <= k < c.pw ==> #[trigger] wperm_ok(st.tp, (p, k), ppage(c, st.tss[p] as int), k)
    &&& forall|p: int| 0 <= p < tn ==> #[trigger] st.tp[(p, st.tus[p])].is_init() && st.tp[(p, st.tus[p])].value() == 0
    &&& forall|p: int, q: int| 0 <= p < q < tn ==> #[trigger] pages_apart(st.tss[p] as int, st.tss[q] as int, c.pw as int)
    &&& forall|p: int, j: int| 0 <= p < tn && 0 <= j < n && !from(h, j) ==>
            #[trigger] outside(st.tss[p] as int, #[trigger] h.addr[j] as int, c.pw as int)
    // From-space, to be freed.
    &&& fshape(c, st.fp)
}

// ---------------------------------------------------------------------------
// From the invariant to the statement.

/// A copy's address: tagged, inside its page.
pub proof fn lemma_copy_addr(c: Ctx, h: H, st: St, t: Tos, k: int)
    requires heap_ok(c, h), bk_ok(h, st), tcopies_ok(c, h, st, t), tpages_ok(c, h, st, t), 0 <= k < st.order.len(),
    ensures
        taddr(st, k) % 4 == 1,
        st.tss[tpg(st, k)] < taddr(st, k) < st.tss[tpg(st, k)] + pbytes(c),
        taddr(st, k) == st.tss[tpg(st, k)] + toff(st, k) * W + 1,
{
    lemma_w();
    let p = tpg(st, k);
    let o = toff(st, k);
    let s = st.tss[p] as int;
    assert(0 <= p < t.tn && 0 <= o && tend(h, st, k) <= st.tus[p]);
    assert(st.tus[p] <= c.pw - 1);
    assert(s % (W as int) == 0 && s + pbytes(c) < usize::MAX);
    lemma_from_obj(c, h, st.order[k]);
    let w = W as int;
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(s, w);
    let q = s / w;
    assert(o * w + 1 < c.pw * w) by (nonlinear_arith) requires o + 2 <= c.pw, w >= 2;
    assert((s + o * w + 1) % 4 == 1) by (nonlinear_arith)
        requires s == w * q, w == 4 || w == 8, o >= 0, q >= 0;
}

/// The invariant at the end of the scan gives the statement's objects.
pub proof fn lemma_objs(c: Ctx, h: H, st: St, t: Tos, rptr: *mut usize, rv: Seq<AVal>)
    requires
        ctx_ok(c), fpages_ok(c), heap_ok(c, h),
        inv(c, h, st, t, st.order.len() as int, 0, rv), roots_ok(c, h, st, rptr, rv, rv.len() as int),
    ensures collected_objs(c, h, st, rptr, rv, t.tn as int),
{
    let n = h.objs.len() as int;
    let nc = st.order.len() as int;
    assert forall|j: int| 0 <= j < n implies (#[trigger] copied(st, j) <==> from(h, j) && reachable(h, rv, j)) by {
        if copied(st, j) {
            let k = st.pos[j];
            assert(0 <= k < nc && st.order[k] == j);
            lemma_copy_reach(c, h, st, rv, k);
        }
        if from(h, j) && reachable(h, rv, j) {
            let p = choose|p: Seq<int>| #[trigger] path(h, rv, p, j);
            lemma_path_live(c, h, st, t, rptr, rv, p, j, p.len() - 1);
        }
    }
    assert forall|j: int| 0 <= j < n && !from(h, j) implies #[trigger] st.addr2[j] == h.addr[j] by {
        if copied(st, j) { assert(from(h, st.order[st.pos[j]])); }
    }
    assert forall|j: int| 0 <= j < n && live(h, st, j) implies #[trigger] st.addr2[j] % 4 == 1 by {
        if copied(st, j) {
            lemma_copy_addr(c, h, st, t, st.pos[j]);
        } else {
            assert(!from(h, j));
        }
    }
    assert forall|j1: int, j2: int| 0 <= j1 < n && 0 <= j2 < n && live(h, st, j1) && live(h, st, j2) && j1 != j2
        implies #[trigger] st.addr2[j1] != #[trigger] st.addr2[j2] by {
        if copied(st, j1) && copied(st, j2) {
            let k1 = st.pos[j1];
            let k2 = st.pos[j2];
            assert(st.order[k1] == j1 && st.order[k2] == j2);
            lemma_copy_addr(c, h, st, t, k1);
            lemma_copy_addr(c, h, st, t, k2);
            assert(0 <= tpg(st, k1) < t.tn && 0 <= tpg(st, k2) < t.tn);
            if k1 < k2 { assert(before(h, st, k1, k2)); } else { assert(before(h, st, k2, k1)); }
            lemma_from_obj(c, h, j1);
            lemma_from_obj(c, h, j2);
            if tpg(st, k1) < tpg(st, k2) {
                assert(pages_apart(st.tss[tpg(st, k1)] as int, st.tss[tpg(st, k2)] as int, c.pw as int));
            } else if tpg(st, k2) < tpg(st, k1) {
                assert(pages_apart(st.tss[tpg(st, k2)] as int, st.tss[tpg(st, k1)] as int, c.pw as int));
            } else {
                assert(toff(st, k1) != toff(st, k2));
                lemma_w();
                assert(toff(st, k1) * W != toff(st, k2) * W) by (nonlinear_arith)
                    requires toff(st, k1) != toff(st, k2), W >= 1;
            }
        } else if copied(st, j1) {
            let k1 = st.pos[j1];
            lemma_copy_addr(c, h, st, t, k1);
            assert(!from(h, j2));
            assert(outside(st.tss[tpg(st, k1)] as int, h.addr[j2] as int, c.pw as int));
            assert(0 <= tpg(st, k1) < t.tn);
        } else if copied(st, j2) {
            let k2 = st.pos[j2];
            lemma_copy_addr(c, h, st, t, k2);
            assert(!from(h, j1));
            assert(outside(st.tss[tpg(st, k2)] as int, h.addr[j1] as int, c.pw as int));
            assert(0 <= tpg(st, k2) < t.tn);
        }
    }
    assert forall|j: int, k: int| 0 <= j < n && live(h, st, j) && is_ref(obj(h, j), k)
        implies val_live(h, st, #[trigger] obj(h, j).words[k]) by {
        assert(slots_ok(c, h, j));
        assert(slot_ok(c, n, obj(h, j).words[k]));
        assert(obj_ok(obj(h, j)));
        if copied(st, j) {
            let kk = st.pos[j];
            assert(st.order[kk] == j);
            assert(processed(kk, k, nc, 0));
            assert(closed(h, st, obj(h, st.order[kk]).words[k]));
        } else {
            assert(prog_ref_ok(h, obj(h, j).words[k]));
        }
    }
    assert forall|j: int| 0 <= j < n && #[trigger] copied(st, j) implies
        0 <= cpg(st, j) < t.tn && 0 <= coff(st, j) && coff(st, j) + size(h, j) <= st.tus[cpg(st, j)]
        && st.addr2[j] == st.tss[cpg(st, j)] + coff(st, j) * W + 1 by {
        let k = st.pos[j];
        assert(st.order[k] == j);
        assert(0 <= tpg(st, k) < t.tn && 0 <= toff(st, k) && tend(h, st, k) <= st.tus[tpg(st, k)]);
        lemma_copy_addr(c, h, st, t, k);
    }
    assert forall|j1: int, j2: int| 0 <= j1 < n && 0 <= j2 < n && copied(st, j1) && copied(st, j2) && j1 != j2
        && #[trigger] cpg(st, j1) == #[trigger] cpg(st, j2) implies
        coff(st, j1) + size(h, j1) <= coff(st, j2) || coff(st, j2) + size(h, j2) <= coff(st, j1) by {
        let k1 = st.pos[j1];
        let k2 = st.pos[j2];
        assert(st.order[k1] == j1 && st.order[k2] == j2);
        if k1 < k2 { assert(before(h, st, k1, k2)); } else { assert(before(h, st, k2, k1)); }
    }
    assert forall|j: int, k: int| 0 <= j < n && copied(st, j) && 0 <= k < size(h, j) implies
        (#[trigger] st.tp[(cpg(st, j), coff(st, j) + k)]).is_init()
        && st.tp[(cpg(st, j), coff(st, j) + k)].value() == wval(obj(h, j), st.addr2, k) by {
        let kk = st.pos[j];
        assert(st.order[kk] == j);
        assert(tkey(st, kk, k) == (cpg(st, j), coff(st, j) + k));
        assert(st.tp[tkey(st, kk, k)].is_init());
        assert(processed(kk, k, nc, 0));
    }
    assert forall|i: int| 0 <= i < rv.len() implies #[trigger] wperm_ok(st.rp, i, rptr, i) && st.rp[i].is_init()
        && st.rp[i].value() == enc(st.addr2, rv[i]) && val_live(h, st, rv[i]) by {
        assert(wperm_ok(st.rp, i, rptr, i));
        assert(st.rp[i].is_init());
        assert(closed(h, st, rv[i]));
        assert(slot_ok(c, n, rv[i]));
    }
    assert(bk_ok(h, st));
    assert(st.addr2.len() == n);
}

/// The statement's objects survive a change that keeps the bookkeeping, the
/// roots and the copies' words and pages.
pub proof fn lemma_objs_frame(c: Ctx, h: H, s0: St, s1: St, rptr: *mut usize, rv: Seq<AVal>, tn0: int, tn1: int)
    requires
        collected_objs(c, h, s0, rptr, rv, tn0), tn0 <= tn1,
        s1.addr2 == s0.addr2, s1.pos == s0.pos, s1.tloc == s0.tloc, s1.rp == s0.rp,
        forall|j: int| 0 <= j < h.objs.len() && #[trigger] copied(s0, j) ==>
            s1.tss[cpg(s0, j)] == s0.tss[cpg(s0, j)] && s1.tus[cpg(s0, j)] == s0.tus[cpg(s0, j)],
        forall|j: int, k: int| 0 <= j < h.objs.len() && copied(s0, j) && 0 <= k < size(h, j) ==>
            #[trigger] s1.tp[(cpg(s0, j), coff(s0, j) + k)] == s0.tp[(cpg(s0, j), coff(s0, j) + k)],
    ensures collected_objs(c, h, s1, rptr, rv, tn1),
{
    let n = h.objs.len() as int;
    assert forall|j: int| #[trigger] copied(s1, j) == copied(s0, j) by {}
    assert forall|j: int| #[trigger] live(h, s1, j) == live(h, s0, j) by {}
    assert forall|v: AVal| #[trigger] val_live(h, s1, v) == val_live(h, s0, v) by {}
    assert forall|j: int| 0 <= j < n implies (#[trigger] copied(s1, j) <==> from(h, j) && reachable(h, rv, j)) by {
        assert(copied(s0, j) <==> from(h, j) && reachable(h, rv, j));
    }
    assert forall|j: int| 0 <= j < n && live(h, s1, j) implies #[trigger] s1.addr2[j] % 4 == 1 by {
        assert(live(h, s0, j));
    }
    assert forall|j1: int, j2: int| 0 <= j1 < n && 0 <= j2 < n && live(h, s1, j1) && live(h, s1, j2) && j1 != j2
        implies #[trigger] s1.addr2[j1] != #[trigger] s1.addr2[j2] by {
        assert(live(h, s0, j1) && live(h, s0, j2));
    }
    assert forall|j: int, k: int| 0 <= j < n && live(h, s1, j) && is_ref(obj(h, j), k)
        implies val_live(h, s1, #[trigger] obj(h, j).words[k]) by {
        assert(live(h, s0, j));
        assert(val_live(h, s0, obj(h, j).words[k]));
    }
    assert forall|j: int| 0 <= j < n && #[trigger] copied(s1, j) implies
        0 <= cpg(s1, j) < tn1 && 0 <= coff(s1, j) && coff(s1, j) + size(h, j) <= s1.tus[cpg(s1, j)]
        && s1.addr2[j] == s1.tss[cpg(s1, j)] + coff(s1, j) * W + 1 by {
        assert(copied(s0, j));
    }
    assert forall|j1: int, j2: int| 0 <= j1 < n && 0 <= j2 < n && copied(s1, j1) && copied(s1, j2) && j1 != j2
        && #[trigger] cpg(s1, j1) == #[trigger] cpg(s1, j2) implies
        coff(s1, j1) + size(h, j1) <= coff(s1, j2) || coff(s1, j2) + size(h, j2) <= coff(s1, j1) by {
        assert(copied(s0, j1) && copied(s0, j2) && cpg(s0, j1) == cpg(s0, j2));
    }
    assert forall|j: int, k: int| 0 <= j < n && copied(s1, j) && 0 <= k < size(h, j) implies
        (#[trigger] s1.tp[(cpg(s1, j), coff(s1, j) + k)]).is_init()
        && s1.tp[(cpg(s1, j), coff(s1, j) + k)].value() == wval(obj(h, j), s1.addr2, k) by {
        assert(copied(s0, j));
        assert(s0.tp[(cpg(s0, j), coff(s0, j) + k)].is_init());
    }
    assert forall|i: int| 0 <= i < rv.len() implies #[trigger] wperm_ok(s1.rp, i, rptr, i) && s1.rp[i].is_init()
        && s1.rp[i].value() == enc(s1.addr2, rv[i]) && val_live(h, s1, rv[i]) by {
        assert(wperm_ok(s0.rp, i, rptr, i));
    }
}

/// The roots before a collection: `rv.len()` words at `rptr` holding the
/// root values under the old address map.
pub open spec fn roots_in(c: Ctx, h: H, rp: Map<int, PointsTo<usize>>, rptr: *mut usize, rv: Seq<AVal>) -> bool {
    &&& rptr@.addr + rv.len() * W <= usize::MAX
    &&& forall|i: int| 0 <= i < rv.len() ==> #[trigger] slot_ok(c, h.objs.len() as int, rv[i])
    &&& forall|i: int| 0 <= i < rv.len() ==> #[trigger] wperm_ok(rp, i, rptr, i) && rp[i].is_init()
            && rp[i].value() == enc(h.addr, rv[i])
}

/// A collection: checks the from-space table and the to-space tables,
/// reserves `2 * nf + 1` pages (the capacity bound), copies what the roots
/// reach, and closes the last page. Either it returns the new heap's pages
/// and `collected` holds, or it changed nothing (`GcError`).
///
/// The caller gives: the context and the from-space table (`ftp`), the
/// permissions of every from-space page word holding the heap `h`
/// (`from_ok`), the header permissions of the objects outside from-space
/// (`others`, read by no code), the root words, and the to-space tables
/// (`tcap` words each).
pub fn collect<S: PageSource>(c: &Ctx, src: &mut S, rptr: *mut usize, rlen: usize,
                              ttab: *mut usize, tused: *mut usize, tcap: usize,
                              Ghost(h): Ghost<H>, Ghost(rv): Ghost<Seq<AVal>>,
                              Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (r: Result<Window, GcError>)
    requires
        ctx_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        from_ok(*c, h, old(st).fp),
        rv.len() == rlen, roots_in(*c, h, old(st).rp, rptr, rv),
        ttab@.addr + tcap * W <= usize::MAX, tused@.addr + tcap * W <= usize::MAX,
        forall|p: int| 0 <= p < tcap ==> #[trigger] wperm_ok(old(st).ttp, p, ttab, p),
        forall|p: int| 0 <= p < tcap ==> #[trigger] wperm_ok(old(st).tup, p, tused, p),
        old(src).pw() == c.pw, old(src).prov() == c.base@.provenance,
    ensures
        match r {
            Ok(w) => collected(*c, h, *final(st), rptr, rv, ttab, tused, w),
            Err(_) => *final(st) == *old(st),
        },
        final(src).pw() == c.pw, final(src).prov() == c.base@.provenance,
{
    if !check_ftab(c, Tracked(&ro.ftp)) {
        return Err(GcError::BadFromTable);
    }
    if tcap < 2 * c.nf + 1 {
        return Err(GcError::SmallTable);
    }
    if !src.reserve(2 * c.nf + 1) {
        return Err(GcError::NoReservation);
    }
    proof {
        let tracked empty = Map::<(int, int), PointsTo<usize>>::tracked_empty();
        st.tp = empty;
        st.order = Seq::empty();
        st.tloc = Seq::empty();
        st.pos = Map::empty();
        st.addr2 = h.addr;
        st.used = Set::empty();
        st.words = 0;
        st.parent = Seq::empty();
        st.tss = Seq::empty();
        st.tus = Seq::empty();
    }
    let mut t = Tos { ttab, tused, tcap, tn: 0, top: 0, cur: 0 };
    proof {
        let s = *st;
        assert(bk_ok(h, s));
        assert(from_inv(*c, h, s));
        assert(tcopies_ok(*c, h, s, t));
        assert(tpages_ok(*c, h, s, t));
        assert(to_inv(*c, h, s, 0, 0));
        assert(set_int_range(0, c.nf * c.pw).len() >= 0);
        assert(cap_ok(*c, h, s, t));
        assert(par_ok(h, s, rv));
        assert(s.rp == old(st).rp);
        assert forall|i: int| 0 <= i < rv.len() implies (#[trigger] s.rp[i]).is_init()
            && s.rp[i].value() == enc(if i < 0 { s.addr2 } else { h.addr }, rv[i]) by {
            assert(wperm_ok(old(st).rp, i, rptr, i) && old(st).rp[i].is_init());
        }
        assert forall|i: int| 0 <= i < rv.len() implies #[trigger] wperm_ok(s.rp, i, rptr, i) by {
            assert(wperm_ok(old(st).rp, i, rptr, i));
        }
        assert(roots_ok(*c, h, s, rptr, rv, 0));
    }
    do_roots(c, src, &mut t, rptr, rlen, Ghost(h), Ghost(rv), Ghost(rv), Tracked(st), Tracked(ro));
    proof { if t.tn >= 1 { assert(scan_pos(h, *st, t, 0, 0, 0)); } }
    scan(c, src, &mut t, 0, 0, Ghost(0int), Ghost(h), Ghost(rptr), Ghost(rv), Ghost(rv), Tracked(st), Tracked(ro));
    let ghost s0 = *st;
    let ghost t0 = t;
    proof {
        lemma_objs(*c, h, s0, t0, rptr, rv);
        lemma_copies_bound(*c, h, s0, t0);
        lemma_w();
    }
    if t.tn == 0 {
        // Nothing survived: one page for the allocation window.
        let (s, perms) = src.take(Ghost(0int));
        proof {
            let tracked mut np = perms.get();
            lemma_page_apart_others(&mut np, 0, s as int, &ro.others, h, h.objs.len() as int, c.pw as int, c.base@.provenance);
            st.tp.tracked_union_prefer_right(np);
            assert(wperm_ok(st.ttp, 0, t.ttab, 0));
        }
        wr(t.ttab, 0, s, Ghost(0int), Tracked(&mut st.ttp));
        t.tn = 1;
        t.top = 0;
        t.cur = s;
        proof {
            st.tss = seq![s];
            st.tus = seq![0int];
            assert forall|k: int| 0 <= k < c.pw implies #[trigger] wperm_ok(st.tp, (0int, k), ppage(*c, s as int), k) by {
                assert(wperm_ok(perms@, (0int, k), pptr(c.base@.provenance, s as int), k));
            }
        }
    }
    let ghost s1 = *st;
    proof {
        assert(wperm_ok(st.tp, (t.tn - 1, t.top as int), ppage(*c, t.cur as int), t.top as int)) by {
            if t0.tn > 0 { assert(wperm_ok(s0.tp, (t.tn - 1, t.top as int), tptr(*c, s0, t.tn - 1), t.top as int)); }
        }
        assert(t.cur + pbytes(*c) < usize::MAX) by {
            if t0.tn > 0 { assert(s0.tss[t.tn - 1] + pbytes(*c) < usize::MAX); }
        }
        assert(t.top * W <= pbytes(*c)) by (nonlinear_arith) requires t.top <= c.pw, W >= 1;
        assert(wperm_ok(st.tup, t.tn - 1, t.tused, t.tn - 1));
        assert((t.tn - 1) * W <= t.tcap * W) by (nonlinear_arith) requires t.tn <= t.tcap, W >= 1;
    }
    let page = c.base.with_addr(t.cur);
    wr(page, t.top, 0, Ghost((t.tn - 1, t.top as int)), Tracked(&mut st.tp));
    wr(t.tused, t.tn - 1, t.top, Ghost(t.tn - 1), Tracked(&mut st.tup));
    src.release();
    let w = Window { pages: t.tn, top: t.top };
    proof {
        let s2 = *st;
        let tn = t.tn as int;
        let n = h.objs.len() as int;
        // The objects: the copies' words and pages are untouched.
        assert forall|j: int| 0 <= j < n && #[trigger] copied(s0, j) implies
            s2.tss[cpg(s0, j)] == s0.tss[cpg(s0, j)] && s2.tus[cpg(s0, j)] == s0.tus[cpg(s0, j)] by {
            assert(t0.tn > 0);
        }
        assert forall|j: int, k: int| 0 <= j < n && copied(s0, j) && 0 <= k < size(h, j) implies
            #[trigger] s2.tp[(cpg(s0, j), coff(s0, j) + k)] == s0.tp[(cpg(s0, j), coff(s0, j) + k)] by {
            assert(t0.tn > 0);
            assert(0 <= cpg(s0, j) < t0.tn && coff(s0, j) + size(h, j) <= s0.tus[cpg(s0, j)]);
            assert(s0.tus[t0.tn - 1] == t0.top);
            assert((cpg(s0, j), coff(s0, j) + k) != (tn - 1, t.top as int));
        }
        lemma_objs_frame(*c, h, s0, s2, rptr, rv, t0.tn as int, tn);
        // The pages.
        if t0.tn > 0 {
            assert(tn - 1 <= 2 * c.nf) by (nonlinear_arith)
                requires (tn - 1) * c.pw <= 2 * s0.words - t.top, s0.words <= c.nf * c.pw, c.pw >= 1, t.top >= 0;
        }
        assert forall|p: int| 0 <= p < tn implies #[trigger] wperm_ok(s2.ttp, p, ttab, p) && s2.ttp[p].is_init()
            && s2.ttp[p].value() == s2.tss[p] by {
            assert(wperm_ok(s0.ttp, p, ttab, p));
            if t0.tn > 0 { assert(s0.ttp[p].is_init() && s0.ttp[p].value() == s0.tss[p]); }
        }
        assert forall|p: int| 0 <= p < tn implies #[trigger] wperm_ok(s2.tup, p, tused, p) && s2.tup[p].is_init()
            && s2.tup[p].value() == s2.tus[p] by {
            assert(wperm_ok(s0.tup, p, tused, p));
            if p < tn - 1 {
                assert(s0.tup[p].is_init());
                assert(s0.tup[p].value() == s0.tus[p]);
            }
        }
        assert forall|p: int| 0 <= p < tn implies #[trigger] s2.tss[p] % W == 0 && s2.tss[p] + pbytes(*c) < usize::MAX
            && 0 <= s2.tus[p] <= c.pw - 1 by {
            if t0.tn > 0 { assert(s0.tss[p] % W == 0 && s0.tss[p] + pbytes(*c) < usize::MAX); assert(0 <= s0.tus[p] <= c.pw - 1); }
        }
        assert forall|p: int, k: int| 0 <= p < tn && 0 <= k < c.pw implies #[trigger] wperm_ok(s2.tp, (p, k), ppage(*c, s2.tss[p] as int), k) by {
            if t0.tn > 0 { assert(wperm_ok(s0.tp, (p, k), tptr(*c, s0, p), k)); }
            else { assert(wperm_ok(s1.tp, (p, k), ppage(*c, s1.tss[p] as int), k)); }
        }
        assert forall|p: int| 0 <= p < tn implies #[trigger] s2.tp[(p, s2.tus[p])].is_init() && s2.tp[(p, s2.tus[p])].value() == 0 by {
            if p < tn - 1 {
                assert(s0.tp[(p, s0.tus[p])].is_init());
                assert(s0.tp[(p, s0.tus[p])].value() == 0);
                assert(wperm_ok(s0.tp, (p, s0.tus[p]), tptr(*c, s0, p), s0.tus[p]));
            } else {
                assert(s2.tus[p] == t.top);
            }
        }
        assert forall|p: int, q: int| 0 <= p < q < tn implies #[trigger] pages_apart(s2.tss[p] as int, s2.tss[q] as int, c.pw as int) by {
            assert(pages_apart(s0.tss[p] as int, s0.tss[q] as int, c.pw as int));
        }
        assert forall|p: int, j: int| 0 <= p < tn && 0 <= j < n && !from(h, j) implies
            #[trigger] outside(s2.tss[p] as int, #[trigger] h.addr[j] as int, c.pw as int) by {
            if t0.tn > 0 { assert(outside(s0.tss[p] as int, h.addr[j] as int, c.pw as int)); }
        }
        assert(fshape(*c, s2.fp));
        assert(collected_pages(*c, h, s2, ttab, tused, w));
    }
    Ok(w)
}

} // verus!
