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

//! The copy of one from-space object to to-space with its forwarding
//! header (the C++ `SandboxCopyingCollector::copy`), and that it keeps the
//! invariant: one lemma per part of it.

use vstd::prelude::*;
use vstd::raw_ptr::*;
use vstd::set_lib::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::space::*;
use crate::cheney::*;

verus! {

/// The parent recorded for a new copy of `j` is valid.
pub open spec fn new_parent_ok(h: H, st: St, rv: Seq<AVal>, j: int, par: (int, int)) -> bool {
    if par.0 < 0 {
        0 <= -1 - par.0 < rv.len() && rv[-1 - par.0] == AVal::Ref(j)
    } else {
        par.0 < st.order.len() && is_ref(obj(h, st.order[par.0]), par.1) && obj(h, st.order[par.0]).words[par.1] == AVal::Ref(j)
    }
}

/// The effect of copying from-space object `j` (the state before `s0`,
/// `t0`; after `s1`, `t1`).
pub open spec fn copy_step(c: Ctx, h: H, s0: St, s1: St, t0: Tos, t1: Tos, j: int, par: (int, int)) -> bool {
    let n = s0.order.len() as int;
    let sz = size(h, j);
    let off = t1.top - sz;
    &&& s1.order == s0.order.push(j)
    &&& s1.tloc == s0.tloc.push((t1.tn - 1, off))
    &&& s1.pos == s0.pos.insert(j, n)
    &&& s1.addr2 == s0.addr2.update(j, taddr(s1, n))
    &&& s1.used == s0.used.union(extent(c, h, j))
    &&& s1.words == s0.words + sz
    &&& s1.parent == s0.parent.push(par)
    &&& s1.rp == s0.rp
    &&& t1.ttab == t0.ttab && t1.tused == t0.tused && t1.tcap == t0.tcap
    &&& t1.tn >= 1 && 0 <= off && t1.top <= c.pw - 1
    &&& (t1.tn == t0.tn && off == t0.top && t0.tn >= 1 && s1.tss == s0.tss && s1.tus == s0.tus.update(t0.tn - 1, t1.top as int))
        || (t1.tn == t0.tn + 1 && off == 0 && (t0.tn == 0 || t0.top + sz > c.pw - 1)
            && s1.tss.subrange(0, t0.tn as int) == s0.tss && s1.tus == s0.tus.push(sz))
    &&& tpages_ok(c, h, s1, t1)
    &&& fshape(c, s1.fp)
    &&& forall|q: (int, int)| q != fkey(h, j, 0) ==> #[trigger] s1.fp[q] == s0.fp[q]
    &&& s1.fp[fkey(h, j, 0)].is_init() && s1.fp[fkey(h, j, 0)].value() == s1.addr2[j]
    &&& forall|i: int| 0 <= i < sz ==> (#[trigger] s1.tp[(t1.tn - 1, off + i)]).is_init()
            && s1.tp[(t1.tn - 1, off + i)].value() == wval(obj(h, j), h.addr, i)
    &&& forall|q: (int, int)| s0.tp.contains_key(q) && q != (t0.tn - 1, t0.top as int)
            && !(q.0 == t1.tn - 1 && off <= q.1 < off + sz) ==> #[trigger] s1.tp[q] == s0.tp[q]
    &&& (t1.tn - 1) * c.pw <= 2 * s1.words - t1.top
}

// ---------------------------------------------------------------------------
// Facts about from-space.

/// A from-space object is well formed and in its page.
pub proof fn lemma_from_obj(c: Ctx, h: H, j: int)
    requires heap_ok(c, h), from(h, j),
    ensures
        0 <= j < h.objs.len(), obj_ok(obj(h, j)), fobj_ok(c, h, j), slots_ok(c, h, j),
        1 <= size(h, j) <= c.pw - 1,
{
    assert(0 <= j < h.objs.len() && fobj_ok(c, h, j));
    assert(obj_ok(obj(h, j)));
    assert(slots_ok(c, h, j));
}

/// The from-space words of two from-space objects are apart.
pub proof fn lemma_extents_apart(c: Ctx, h: H, j1: int, j2: int)
    requires ctx_ok(c), heap_ok(c, h), from(h, j1), from(h, j2), j1 != j2,
    ensures
        extent(c, h, j1).disjoint(extent(c, h, j2)),
        forall|k1: int, k2: int| 0 <= k1 < size(h, j1) && 0 <= k2 < size(h, j2) ==> fkey(h, j1, k1) != fkey(h, j2, k2),
{
    lemma_from_obj(c, h, j1);
    lemma_from_obj(c, h, j2);
    assert(fdisjoint(h, j1, j2));
    let pw = c.pw as int;
    let p1 = fpg(h, j1);
    let p2 = fpg(h, j2);
    let a1 = p1 * pw + foff(h, j1);
    let a2 = p2 * pw + foff(h, j2);
    if p1 < p2 {
        assert(p1 * pw + pw <= p2 * pw) by (nonlinear_arith) requires p1 < p2, pw >= 0;
    } else if p2 < p1 {
        assert(p2 * pw + pw <= p1 * pw) by (nonlinear_arith) requires p2 < p1, pw >= 0;
    }
    assert(a1 + size(h, j1) <= a2 || a2 + size(h, j2) <= a1);
    assert(extent(c, h, j1).disjoint(extent(c, h, j2)));
}

/// The from-space words of a from-space object lie in from-space.
pub proof fn lemma_extent_in(c: Ctx, h: H, j: int)
    requires ctx_ok(c), heap_ok(c, h), from(h, j),
    ensures
        extent(c, h, j).subset_of(set_int_range(0, c.nf * c.pw)),
        extent(c, h, j).len() == size(h, j),
{
    lemma_from_obj(c, h, j);
    let pw = c.pw as int;
    let p = fpg(h, j);
    assert(p * pw + pw <= c.nf * pw) by (nonlinear_arith) requires p < c.nf, pw >= 0;
    assert(0 <= p * pw) by (nonlinear_arith) requires p >= 0, pw >= 0;
    lemma_int_range(p * pw + foff(h, j), p * pw + foff(h, j) + size(h, j));
}

/// The copies fit in from-space: with object `j` (not copied) they are at
/// most `nf * pw` words.
pub proof fn lemma_capacity(c: Ctx, h: H, st: St, t: Tos, j: int)
    requires ctx_ok(c), heap_ok(c, h), cap_ok(c, h, st, t), from(h, j), !copied(st, j),
    ensures
        st.words + size(h, j) <= c.nf * c.pw,
        st.used.union(extent(c, h, j)).len() == st.words + size(h, j),
        st.used.union(extent(c, h, j)).subset_of(set_int_range(0, c.nf * c.pw)),
{
    lemma_extent_in(c, h, j);
    let u = st.used.union(extent(c, h, j));
    assert(st.used.disjoint(extent(c, h, j)));
    lemma_set_disjoint_lens(st.used, extent(c, h, j));
    lemma_int_range(0, c.nf * c.pw);
    lemma_len_subset(u, set_int_range(0, c.nf * c.pw));
}

// ---------------------------------------------------------------------------
// The copy keeps the invariant.

/// An old to-space page keeps its start.
pub proof fn lemma_old_page(s0: St, s1: St, t0: Tos, t1: Tos, p: int)
    requires
        s0.tss.len() == t0.tn, 0 <= p < t0.tn,
        s1.tss == s0.tss || s1.tss.subrange(0, t0.tn as int) == s0.tss,
        s1.tss.len() >= t0.tn,
    ensures s1.tss[p] == s0.tss[p],
{
    if s1.tss != s0.tss {
        assert(s1.tss.subrange(0, t0.tn as int)[p] == s1.tss[p]);
    }
}

pub proof fn lemma_copy_bk(c: Ctx, h: H, s0: St, s1: St, t0: Tos, t1: Tos, j: int, par: (int, int))
    requires
        heap_ok(c, h), bk_ok(h, s0), from(h, j), !copied(s0, j),
        s0.parent.len() == s0.order.len(),
        tcopies_ok(c, h, s0, t0), tpages_ok(c, h, s0, t0),
        copy_step(c, h, s0, s1, t0, t1, j, par),
    ensures bk_ok(h, s1), grows(h, s0, s1),
{
    let n = s0.order.len() as int;
    assert forall|k: int| 0 <= k < n + 1 implies from(h, #[trigger] s1.order[k]) && s1.pos.contains_key(s1.order[k])
        && s1.pos[s1.order[k]] == k by {
        if k < n {
            assert(from(h, s0.order[k]) && s0.pos.contains_key(s0.order[k]) && s0.pos[s0.order[k]] == k);
            assert(s0.order[k] != j);
        }
    }
    assert forall|jj: int| #[trigger] copied(s1, jj) implies 0 <= s1.pos[jj] < n + 1 && s1.order[s1.pos[jj]] == jj by {
        if jj != j { assert(copied(s0, jj)); }
    }
    assert forall|jj: int| 0 <= jj < h.objs.len() implies #[trigger] s1.addr2[jj] ==
        (if copied(s1, jj) { taddr(s1, s1.pos[jj]) } else { h.addr[jj] }) by {
        if jj != j {
            assert(s0.addr2[jj] == (if copied(s0, jj) { taddr(s0, s0.pos[jj]) } else { h.addr[jj] }));
            if copied(s0, jj) {
                let k = s0.pos[jj];
                assert(0 <= k < n);
                assert(s1.tloc[k] == s0.tloc[k]);
                assert(0 <= tpg(s0, k) < t0.tn);
                lemma_old_page(s0, s1, t0, t1, tpg(s0, k));
            }
        }
    }
    assert forall|k: int| 0 <= k < n implies #[trigger] s1.order[k] == s0.order[k] by {}
    assert forall|k: int| 0 <= k < n implies #[trigger] s1.tloc[k] == s0.tloc[k] by {}
    assert forall|k: int| 0 <= k < n implies #[trigger] s1.parent[k] == s0.parent[k] by {}
    assert forall|jj: int| #[trigger] copied(s0, jj) implies copied(s1, jj) && s1.pos[jj] == s0.pos[jj] by {
        assert(jj != j);
    }
    assert forall|jj: int| 0 <= jj < s0.addr2.len() && (copied(s0, jj) || !from(h, jj)) implies
        #[trigger] s1.addr2[jj] == s0.addr2[jj] by {
        assert(jj != j);
    }
    assert forall|p: int| 0 <= p < s0.tss.len() implies #[trigger] s1.tss[p] == s0.tss[p] by {
        lemma_old_page(s0, s1, t0, t1, p);
    }
}

pub proof fn lemma_copy_from(c: Ctx, h: H, s0: St, s1: St, t0: Tos, t1: Tos, j: int, par: (int, int))
    requires
        ctx_ok(c), heap_ok(c, h), bk_ok(h, s0), from_inv(c, h, s0), from(h, j), !copied(s0, j),
        bk_ok(h, s1), grows(h, s0, s1),
        copy_step(c, h, s0, s1, t0, t1, j, par),
    ensures from_inv(c, h, s1),
{
    assert forall|jj: int, k: int| from(h, jj) && !copied(s1, jj) && 0 <= k < size(h, jj) implies
        (#[trigger] s1.fp[fkey(h, jj, k)]).is_init() && s1.fp[fkey(h, jj, k)].value() == wval(obj(h, jj), h.addr, k) by {
        assert(jj != j);
        assert(!copied(s0, jj));
        lemma_extents_apart(c, h, jj, j);
        lemma_from_obj(c, h, j);
        assert(fkey(h, jj, k) != fkey(h, j, 0));
        assert(s0.fp[fkey(h, jj, k)].is_init());
    }
    assert forall|jj: int| from(h, jj) && #[trigger] copied(s1, jj) implies
        s1.fp[fkey(h, jj, 0)].is_init() && s1.fp[fkey(h, jj, 0)].value() == s1.addr2[jj] by {
        if jj != j {
            assert(copied(s0, jj));
            lemma_extents_apart(c, h, jj, j);
            lemma_from_obj(c, h, j);
            lemma_from_obj(c, h, jj);
            assert(fkey(h, jj, 0) != fkey(h, j, 0));
            assert(s0.fp[fkey(h, jj, 0)].is_init());
            assert(0 <= jj < s0.addr2.len());
        }
    }
}

/// The last copy of a page ends at or before every later copy of it.
pub proof fn lemma_last_on_page(c: Ctx, h: H, s0: St, t0: Tos, k: int)
    requires tcopies_ok(c, h, s0, t0), tpages_ok(c, h, s0, t0), 0 <= k < s0.order.len(),
    ensures
        tpg(s0, k) < t0.tn - 1 || (tpg(s0, k) == t0.tn - 1 && tend(h, s0, k) <= t0.top),
{
    assert(0 <= tpg(s0, k) < t0.tn && tend(h, s0, k) <= s0.tus[tpg(s0, k)]);
}

pub proof fn lemma_copy_tcopies(c: Ctx, h: H, s0: St, s1: St, t0: Tos, t1: Tos, j: int, par: (int, int))
    requires
        ctx_ok(c), heap_ok(c, h), bk_ok(h, s0), from(h, j), !copied(s0, j),
        tcopies_ok(c, h, s0, t0), tpages_ok(c, h, s0, t0),
        copy_step(c, h, s0, s1, t0, t1, j, par),
    ensures tcopies_ok(c, h, s1, t1),
{
    let n = s0.order.len() as int;
    let sz = size(h, j);
    let off = t1.top - sz;
    let same = t1.tn == t0.tn;
    lemma_from_obj(c, h, j);
    assert(tsz(h, s1, n) == sz);
    assert forall|k: int| 0 <= k < n implies #[trigger] tsz(h, s1, k) == tsz(h, s0, k) && tpg(s1, k) == tpg(s0, k)
        && toff(s1, k) == toff(s0, k) by {}
    // The used words of old pages, except the last one if the copy went there.
    assert forall|p: int| 0 <= p < t0.tn && (p < t0.tn - 1 || !same) implies #[trigger] s1.tus[p] == s0.tus[p] by {}
    if n > 0 {
        assert(s1.tloc[0] == s0.tloc[0]);
    }
    assert forall|k: int| 0 <= k < n + 1 - 1 implies #[trigger] s1.tloc[k + 1] == succ(h, s1, k, t1.tn as int) by {
        let p = tpg(s0, k);
        assert(0 <= p < t0.tn);
        if k < n - 1 {
            assert(s0.tloc[k + 1] == succ(h, s0, k, t0.tn as int));
            assert(before(h, s0, k, n - 1));
            if p == t0.tn - 1 {
                // Not the last copy of the last page: it ends below the top.
                assert(tpg(s0, n - 1) == t0.tn - 1);
                assert(tend(h, s0, k) <= toff(s0, n - 1));
                assert(tsz(h, s0, n - 1) >= 1) by { lemma_from_obj(c, h, s0.order[n - 1]); }
                assert(tend(h, s0, k) < t0.top);
                assert(s0.tus[p] == t0.top);
                if same { assert(s1.tus[p] == t1.top); }
            } else {
                assert(s1.tus[p] == s0.tus[p]);
            }
        } else {
            // The last old copy: the new one follows it.
            assert(k == n - 1);
            assert(p == t0.tn - 1 && tend(h, s0, k) == t0.top);
            assert(s0.tus[p] == t0.top);
            if same {
                assert(s1.tus[p] == t1.top);
                assert(t1.top > t0.top);
            } else {
                assert(s1.tus[p] == t0.top);
            }
        }
    }
    assert forall|k: int| 0 <= k < n + 1 implies 0 <= #[trigger] tpg(s1, k) < t1.tn && 0 <= toff(s1, k)
        && tend(h, s1, k) <= s1.tus[tpg(s1, k)] by {
        if k < n {
            lemma_last_on_page(c, h, s0, t0, k);
            assert(0 <= tpg(s0, k) < t0.tn && 0 <= toff(s0, k) && tend(h, s0, k) <= s0.tus[tpg(s0, k)]);
            if same && tpg(s0, k) == t0.tn - 1 {
                assert(s1.tus[tpg(s0, k)] == t1.top);
            } else {
                assert(s1.tus[tpg(s0, k)] == s0.tus[tpg(s0, k)]);
            }
        } else {
            assert(s1.tus[t1.tn - 1] == t1.top);
        }
    }
    assert forall|k1: int, k2: int| 0 <= k1 < k2 < n + 1 implies #[trigger] before(h, s1, k1, k2) by {
        if k2 < n {
            assert(before(h, s0, k1, k2));
        } else {
            lemma_last_on_page(c, h, s0, t0, k1);
        }
    }
}

pub proof fn lemma_copy_to(c: Ctx, h: H, s0: St, s1: St, t0: Tos, t1: Tos, j: int, par: (int, int), ks: int, kc: int)
    requires
        ctx_ok(c), heap_ok(c, h), bk_ok(h, s0), from(h, j), !copied(s0, j),
        tcopies_ok(c, h, s0, t0), tpages_ok(c, h, s0, t0), to_inv(c, h, s0, ks, kc),
        bk_ok(h, s1), grows(h, s0, s1),
        copy_step(c, h, s0, s1, t0, t1, j, par),
        0 <= ks <= s0.order.len(), ks < s0.order.len() || kc == 0,
    ensures to_inv(c, h, s1, ks, kc),
{
    let n = s0.order.len() as int;
    let sz = size(h, j);
    let off = t1.top - sz;
    let nobj = h.objs.len() as int;
    assert forall|kk: int, i: int| 0 <= kk < n + 1 && 0 <= i < tsz(h, s1, kk) implies
        (#[trigger] s1.tp[tkey(s1, kk, i)]).is_init()
        && s1.tp[tkey(s1, kk, i)].value() == wval(obj(h, s1.order[kk]), amap(h, s1, kk, i, ks, kc), i) by {
        if kk < n {
            let jk = s0.order[kk];
            assert(s1.order[kk] == jk && s1.tloc[kk] == s0.tloc[kk]);
            assert(from(h, jk));
            lemma_from_obj(c, h, jk);
            lemma_last_on_page(c, h, s0, t0, kk);
            assert(0 <= tpg(s0, kk) < t0.tn && 0 <= toff(s0, kk) && tend(h, s0, kk) <= s0.tus[tpg(s0, kk)]);
            assert(s0.tus[tpg(s0, kk)] <= c.pw - 1);
            let key = tkey(s0, kk, i);
            assert(wperm_ok(s0.tp, key, tptr(c, s0, tpg(s0, kk)), toff(s0, kk) + i));
            assert(key != (t0.tn - 1, t0.top as int));
            assert(!(key.0 == t1.tn - 1 && off <= key.1 < off + sz));
            assert(s1.tp[key] == s0.tp[key]);
            assert(s0.tp[key].is_init());
            let o = obj(h, jk);
            if processed(kk, i, ks, kc) {
                if is_ref(o, i) {
                    assert(closed(h, s0, o.words[i]));
                    assert(slots_ok(c, h, jk));
                    assert(slot_ok(c, nobj, o.words[i]));
                    lemma_enc_same(s0.addr2, s1.addr2, o.words[i]);
                } else {
                    assert(o.words[i] is Raw);
                }
            }
        } else {
            assert(s1.order[kk] == j);
            assert(tkey(s1, kk, i) == (t1.tn - 1, off + i));
        }
    }
    assert forall|kk: int, i: int| 0 <= kk < n + 1 && 0 <= i < tsz(h, s1, kk) && processed(kk, i, ks, kc)
        && is_ref(obj(h, s1.order[kk]), i) implies closed(h, s1, #[trigger] obj(h, s1.order[kk]).words[i]) by {
        assert(kk < n);
        assert(s1.order[kk] == s0.order[kk]);
        assert(closed(h, s0, obj(h, s0.order[kk]).words[i]));
    }
}

pub proof fn lemma_copy_cap(c: Ctx, h: H, s0: St, s1: St, t0: Tos, t1: Tos, j: int, par: (int, int))
    requires
        ctx_ok(c), heap_ok(c, h), bk_ok(h, s0), cap_ok(c, h, s0, t0), from(h, j), !copied(s0, j),
        bk_ok(h, s1),
        copy_step(c, h, s0, s1, t0, t1, j, par),
    ensures cap_ok(c, h, s1, t1),
{
    lemma_capacity(c, h, s0, t0, j);
    lemma_from_obj(c, h, j);
    assert forall|jj: int| #[trigger] from(h, jj) && !copied(s1, jj) implies s1.used.disjoint(extent(c, h, jj)) by {
        assert(jj != j);
        assert(!copied(s0, jj));
        assert(s0.used.disjoint(extent(c, h, jj)));
        lemma_extents_apart(c, h, j, jj);
    }
}

pub proof fn lemma_copy_par(c: Ctx, h: H, s0: St, s1: St, t0: Tos, t1: Tos, j: int, par: (int, int), rv: Seq<AVal>)
    requires
        par_ok(h, s0, rv), new_parent_ok(h, s0, rv, j, par),
        copy_step(c, h, s0, s1, t0, t1, j, par),
    ensures par_ok(h, s1, rv),
{
    let n = s0.order.len() as int;
    assert forall|k: int| 0 <= k < n + 1 implies #[trigger] parent_ok(h, s1, rv, k) by {
        if k < n {
            assert(parent_ok(h, s0, rv, k));
            assert(s1.parent[k] == s0.parent[k]);
            assert(s1.order[k] == s0.order[k]);
            let p = s0.parent[k].0;
            if p >= 0 { assert(s1.order[p] == s0.order[p]); }
        } else {
            assert(s1.parent[k] == par);
            assert(s1.order[k] == j);
            if par.0 >= 0 { assert(s1.order[par.0] == s0.order[par.0]); }
        }
    }
}

/// Copies from-space object `j` (at offset `off` of the from-space page
/// starting at `fstart`) to to-space and installs its forwarding header.
/// Returns its new address.
pub fn copy<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, fstart: usize, off: usize,
                           Ghost(h): Ghost<H>, Ghost(j): Ghost<int>, Ghost(ks): Ghost<int>, Ghost(kc): Ghost<int>,
                           Ghost(par): Ghost<(int, int)>, Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                           Ghost(ri): Ghost<int>,
                           Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (r: usize)
    requires
        ctx_ok(*c), fpages_ok(*c), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *old(t), ks, kc, rvp), roots_ok(*c, h, *old(st), rptr, rv, ri),
        src_ok(*c, *old(src), *old(t)),
        from(h, j), !copied(*old(st), j), fstart == fs(*c, fpg(h, j)), off == foff(h, j),
        0 <= ks <= old(st).order.len(), ks < old(st).order.len() || kc == 0,
        new_parent_ok(h, *old(st), rvp, j, par),
    ensures
        inv(*c, h, *final(st), *final(t), ks, kc, rvp), roots_ok(*c, h, *final(st), rptr, rv, ri),
        src_ok(*c, *final(src), *final(t)),
        grows(h, *old(st), *final(st)),
        copied(*final(st), j), r == final(st).addr2[j],
        final(t).ttab == old(t).ttab, final(t).tused == old(t).tused, final(t).tcap == old(t).tcap,
{
    let ghost s0 = *st;
    let ghost t0 = *t;
    let ghost o = obj(h, j);
    let ghost pg = fpg(h, j);
    let ghost pw = c.pw as int;
    proof {
        lemma_w();
        lemma_from_obj(*c, h, j);
        assert(fs(*c, pg) + pbytes(*c) < usize::MAX);
        assert forall|k: int| 0 <= k < lay(o).size && #[trigger] o.words[k] is Raw implies
            wperm_ok(s0.fp, (pg, off + k), fptr(*c, pg), off + k) && s0.fp[(pg, off + k)].is_init()
            && s0.fp[(pg, off + k)].value() == raw(o.words[k]) by {
            assert(wperm_ok(s0.fp, (pg, off + k), fptr(*c, pg), off + k));
            assert(fkey(h, j, k) == (pg, off + k));
            assert(s0.fp[fkey(h, j, k)].is_init());
        }
    }
    let fpage = c.base.with_addr(fstart);
    let (sz, _lo, _hi) = obj_layout(c, fpage, off, Ghost(pg), Tracked(&st.fp), Ghost(o), Ghost(pw), Tracked(&ro.ctp));
    proof {
        lemma_capacity(*c, h, s0, t0, j);
    }
    let toff = place(c, src, t, sz, Ghost(h), Tracked(st), Tracked(ro));
    let ghost sp = *st;
    let ghost tn1 = t.tn as int;
    let tpage = c.base.with_addr(t.cur);
    proof {
        assert(t.cur == sp.tss[tn1 - 1]);
        assert(sp.tss[tn1 - 1] + pbytes(*c) < usize::MAX);
    }
    let mut k: usize = 0;
    while k < sz
        invariant
            ctx_ok(*c), fpages_ok(*c), heap_ok(*c, h),
            k <= sz, sz == size(h, j), o == obj(h, j), pg == fpg(h, j), off == foff(h, j),
            from(h, j), !copied(s0, j), from_inv(*c, h, s0), fpage == fptr(*c, pg),
            toff + sz <= c.pw - 1, tn1 == t.tn, tn1 >= 1, tpage == tptr(*c, sp, tn1 - 1),
            tpages_ok(*c, h, sp, *t),
            sp.tss[tn1 - 1] + pbytes(*c) < usize::MAX,
            fs(*c, pg) + pbytes(*c) < usize::MAX,
            st.fp == s0.fp, st.rp == sp.rp, st.ttp == sp.ttp, st.tup == sp.tup,
            st.order == sp.order, st.tloc == sp.tloc, st.pos == sp.pos, st.addr2 == sp.addr2,
            st.used == sp.used, st.words == sp.words, st.parent == sp.parent, st.tss == sp.tss, st.tus == sp.tus,
            st.tp.dom() == sp.tp.dom(),
            forall|q: (int, int)| !(q.0 == tn1 - 1 && toff <= q.1 < toff + k) ==> #[trigger] st.tp[q] == sp.tp[q],
            forall|q: (int, int)| sp.tp.contains_key(q) ==> #[trigger] st.tp[q].ptr() == sp.tp[q].ptr(),
            forall|i: int| 0 <= i < k ==> (#[trigger] st.tp[(tn1 - 1, toff + i)]).is_init()
                && st.tp[(tn1 - 1, toff + i)].value() == wval(o, h.addr, i),
        decreases sz - k,
    {
        proof {
            assert(fkey(h, j, k as int) == (pg, off + k));
            assert(s0.fp[fkey(h, j, k as int)].is_init());
            assert(wperm_ok(st.fp, (pg, off + k), fptr(*c, pg), off + k));
            assert(wperm_ok(sp.tp, (tn1 - 1, toff + k), tptr(*c, sp, tn1 - 1), toff + k));
            assert((off + k) * W <= pbytes(*c)) by (nonlinear_arith) requires off + k <= c.pw, W >= 1;
            assert((toff + k) * W <= pbytes(*c)) by (nonlinear_arith) requires toff + k <= c.pw, W >= 1;
        }
        let v = rd(fpage, off + k, Ghost((pg, off + k)), Tracked(&st.fp));
        wr(tpage, toff + k, v, Ghost((tn1 - 1, toff + k)), Tracked(&mut st.tp));
        k += 1;
    }
    proof {
        assert((toff * W) <= pbytes(*c)) by (nonlinear_arith) requires toff <= c.pw, W >= 1;
        assert(wperm_ok(st.fp, (pg, off as int), fptr(*c, pg), off as int));
        assert(off * W <= pbytes(*c)) by (nonlinear_arith) requires off <= c.pw, W >= 1;
    }
    let na = t.cur + toff * W + 1;
    let ghost sq = *st;
    wr(fpage, off, na, Ghost((pg, off as int)), Tracked(&mut st.fp));
    proof {
        let n = s0.order.len() as int;
        st.order = s0.order.push(j);
        st.tloc = s0.tloc.push((tn1 - 1, toff as int));
        st.pos = s0.pos.insert(j, n);
        st.addr2 = s0.addr2.update(j, na);
        st.used = s0.used.union(extent(*c, h, j));
        st.words = s0.words + sz;
        st.parent = s0.parent.push(par);
        let s1 = *st;
        assert(taddr(s1, n) == na);
        // The pages: the copy wrote words of the last page only.
        assert forall|p: int, kk: int| 0 <= p < tn1 && 0 <= kk < c.pw implies
            #[trigger] wperm_ok(s1.tp, (p, kk), tptr(*c, s1, p), kk) by {
            assert(wperm_ok(sp.tp, (p, kk), tptr(*c, sp, p), kk));
            assert(sq.tp[(p, kk)].ptr() == sp.tp[(p, kk)].ptr());
        }
        assert forall|p: int| 0 <= p < tn1 - 1 implies
            #[trigger] s1.tp[(p, s1.tus[p])].is_init() && s1.tp[(p, s1.tus[p])].value() == 0 by {
            assert(s1.tus[p] == sp.tus[p]);
            assert(sq.tp[(p, sp.tus[p])] == sp.tp[(p, sp.tus[p])]);
            assert(sp.tp[(p, sp.tus[p])].is_init() && sp.tp[(p, sp.tus[p])].value() == 0);
        }
        assert forall|q: (int, int)| #[trigger] s1.tp.contains_key(q) implies 0 <= q.0 < tn1 by {
            assert(sp.tp.contains_key(q));
        }
        assert(tpages_ok(*c, h, s1, *t));
        assert forall|i: int, kk: int| 0 <= i < c.nf && 0 <= kk < c.pw implies #[trigger] wperm_ok(s1.fp, (i, kk), fptr(*c, i), kk) by {
            assert(wperm_ok(s0.fp, (i, kk), fptr(*c, i), kk));
        }
        assert(fkey(h, j, 0) == (pg, off as int));
        assert forall|q: (int, int)| q != fkey(h, j, 0) implies #[trigger] s1.fp[q] == s0.fp[q] by {}
        assert forall|i: int| 0 <= i < sz implies (#[trigger] s1.tp[(tn1 - 1, toff + i)]).is_init()
            && s1.tp[(tn1 - 1, toff + i)].value() == wval(obj(h, j), h.addr, i) by {
            assert(sq.tp[(tn1 - 1, toff + i)].is_init());
        }
        assert forall|q: (int, int)| s0.tp.contains_key(q) && q != (t0.tn - 1, t0.top as int)
            && !(q.0 == tn1 - 1 && toff <= q.1 < toff + sz) implies #[trigger] s1.tp[q] == s0.tp[q] by {
            assert(sq.tp[q] == sp.tp[q]);
        }
        assert(copy_step(*c, h, s0, s1, t0, *t, j, par));
        lemma_copy_bk(*c, h, s0, s1, t0, *t, j, par);
        lemma_copy_from(*c, h, s0, s1, t0, *t, j, par);
        lemma_copy_tcopies(*c, h, s0, s1, t0, *t, j, par);
        lemma_copy_to(*c, h, s0, s1, t0, *t, j, par, ks, kc);
        lemma_copy_cap(*c, h, s0, s1, t0, *t, j, par);
        lemma_copy_par(*c, h, s0, s1, t0, *t, j, par, rvp);
        lemma_copy_roots(*c, h, s0, s1, rptr, rv, ri);
        assert(s1.addr2[j] == na);
    }
    na
}

pub proof fn lemma_copy_roots(c: Ctx, h: H, s0: St, s1: St, rptr: *mut usize, rv: Seq<AVal>, ri: int)
    requires
        heap_ok(c, h), bk_ok(h, s0), roots_ok(c, h, s0, rptr, rv, ri), grows(h, s0, s1),
        s1.addr2.len() == s0.addr2.len(),
    ensures roots_ok(c, h, s1, rptr, rv, ri),
{
    assert forall|i: int| 0 <= i < rv.len() implies (#[trigger] s1.rp[i]).is_init()
        && s1.rp[i].value() == enc(if i < ri { s1.addr2 } else { h.addr }, rv[i]) by {
        assert(s0.rp[i].is_init());
        if i < ri {
            assert(closed(h, s0, rv[i]));
            assert(slot_ok(c, h.objs.len() as int, rv[i]));
            lemma_enc_same(s0.addr2, s1.addr2, rv[i]);
        }
    }
    assert forall|i: int| 0 <= i < ri implies closed(h, s1, #[trigger] rv[i]) by {
        assert(closed(h, s0, rv[i]));
    }
}

} // verus!
