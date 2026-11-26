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

//! The collection: to-space placement (`place`), the copy with its
//! forwarding header (`copy`), the slot visitor (`forward`), the root loop
//! (`do_roots`), the scan over the to-space pages (`scan`) and the driver
//! (`collect`, whose contract `collected` is the top-level statement).
//!
//! The ghost state (`St`) holds the permissions of from-space, to-space,
//! the roots and the to-space tables, and the bookkeeping: the copied ids
//! in copy order with their to-space locations, each copied id's position,
//! the new address map, the from-space words of the copies (the capacity
//! argument), a parent of each copy (the reachability argument), the
//! to-space page starts and their used words.

use vstd::prelude::*;
use vstd::raw_ptr::*;
use vstd::set_lib::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::space::*;

verus! {

/// The to-space as the code sees it: the page table and the used words of
/// each page (both caller-provided, `tcap` entries), the pages taken, the
/// used words of the last page and its start.
pub struct Tos {
    pub ttab: *mut usize,
    pub tused: *mut usize,
    pub tcap: usize,
    /// The pages reserved (`tail::reserve_pages`) and the size bound they
    /// rest on (no from-space object is larger than `mx` words).
    pub rs: usize,
    pub mx: Ghost<int>,
    pub tn: usize,
    pub top: usize,
    pub cur: usize,
}

pub tracked struct St {
    pub tracked fp: Map<(int, int), PointsTo<usize>>,
    pub tracked tp: Map<(int, int), PointsTo<usize>>,
    pub tracked rp: Map<int, PointsTo<usize>>,
    pub tracked ttp: Map<int, PointsTo<usize>>,
    pub tracked tup: Map<int, PointsTo<usize>>,
    /// Copied ids in copy order.
    pub ghost order: Seq<int>,
    /// The to-space location (page, word offset) of each copy.
    pub ghost tloc: Seq<(int, int)>,
    /// The copy index of each copied id.
    pub ghost pos: Map<int, int>,
    pub ghost addr2: Seq<usize>,
    /// The from-space words of the copies (page * pw + offset).
    pub ghost used: Set<int>,
    /// The words copied.
    pub ghost words: int,
    /// Why each copy was made: (-1 - i, 0) for root `i`, or (k, s) for
    /// slot `s` of copy `k`.
    pub ghost parent: Seq<(int, int)>,
    /// To-space page starts and the used words of each page.
    pub ghost tss: Seq<usize>,
    pub ghost tus: Seq<int>,
}

pub open spec fn copied(st: St, j: int) -> bool { st.pos.contains_key(j) }

pub open spec fn tsz(h: H, st: St, k: int) -> int { size(h, st.order[k]) }

pub open spec fn tpg(st: St, k: int) -> int { st.tloc[k].0 }

pub open spec fn toff(st: St, k: int) -> int { st.tloc[k].1 }

pub open spec fn tend(h: H, st: St, k: int) -> int { toff(st, k) + tsz(h, st, k) }

pub open spec fn tkey(st: St, k: int, i: int) -> (int, int) { (tpg(st, k), toff(st, k) + i) }

/// The tagged address of copy `k`.
pub open spec fn taddr(st: St, k: int) -> usize { (st.tss[tpg(st, k)] + toff(st, k) * W + 1) as usize }

/// The pointer of to-space page `p`.
pub open spec fn tptr(c: Ctx, st: St, p: int) -> *mut usize { ppage(c, st.tss[p] as int) }

/// Copy `k1` lies before copy `k2`.
pub open spec fn before(h: H, st: St, k1: int, k2: int) -> bool {
    tpg(st, k1) < tpg(st, k2) || (tpg(st, k1) == tpg(st, k2) && tend(h, st, k1) <= toff(st, k2))
}

/// Where the copy after copy `k` starts: right after it, or at the start
/// of the next page if `k` ends its page.
pub open spec fn succ(h: H, st: St, k: int, tn: int) -> (int, int) {
    if tend(h, st, k) == st.tus[tpg(st, k)] && tpg(st, k) + 1 < tn {
        (tpg(st, k) + 1, 0)
    } else {
        (tpg(st, k), tend(h, st, k))
    }
}

/// The from-space words of from-space object `j`.
pub open spec fn extent(c: Ctx, h: H, j: int) -> Set<int> {
    set_int_range(fpg(h, j) * c.pw + foff(h, j), fpg(h, j) * c.pw + foff(h, j) + size(h, j))
}

/// A processed reference does not refer to an uncopied from-space object.
pub open spec fn closed(h: H, st: St, v: AVal) -> bool {
    match v {
        AVal::Ref(j) => !from(h, j) || copied(st, j),
        _ => true,
    }
}

pub open spec fn is_ref(o: AObj, i: int) -> bool { lay(o).lo <= i < lay(o).hi }

/// Word `i` of copy `kk` is processed when the scan is at word `kc` of
/// copy `ks`.
pub open spec fn processed(kk: int, i: int, ks: int, kc: int) -> bool {
    kk < ks || (kk == ks && i < kc)
}

/// The address map word `i` of copy `kk` is encoded under.
pub open spec fn amap(h: H, st: St, kk: int, i: int, ks: int, kc: int) -> Seq<usize> {
    if processed(kk, i, ks, kc) { st.addr2 } else { h.addr }
}

// ---------------------------------------------------------------------------
// The invariant, in parts.

/// The bookkeeping: copy order and positions, the new address map.
pub open spec fn bk_ok(h: H, st: St) -> bool {
    let n = st.order.len() as int;
    &&& forall|k: int| 0 <= k < n ==> from(h, #[trigger] st.order[k]) && st.pos.contains_key(st.order[k]) && st.pos[st.order[k]] == k
    &&& forall|j: int| #[trigger] copied(st, j) ==> 0 <= st.pos[j] < n && st.order[st.pos[j]] == j
    &&& st.addr2.len() == h.objs.len()
    &&& forall|j: int| 0 <= j < h.objs.len() ==> #[trigger] st.addr2[j] ==
            (if copied(st, j) { taddr(st, st.pos[j]) } else { h.addr[j] })
}

/// From-space: an uncopied object is intact, a copied one has a forwarding
/// header (its new address).
pub open spec fn from_inv(c: Ctx, h: H, st: St) -> bool {
    &&& fshape(c, st.fp)
    &&& forall|j: int, k: int| from(h, j) && !copied(st, j) && 0 <= k < size(h, j) ==>
            (#[trigger] st.fp[fkey(h, j, k)]).is_init() && st.fp[fkey(h, j, k)].value() == wval(obj(h, j), h.addr, k)
    &&& forall|j: int| from(h, j) && #[trigger] copied(st, j) ==>
            st.fp[fkey(h, j, 0)].is_init() && st.fp[fkey(h, j, 0)].value() == st.addr2[j]
}

/// The copies in the to-space pages, in copy order, page by page.
pub open spec fn tcopies_ok(c: Ctx, h: H, st: St, t: Tos) -> bool {
    let n = st.order.len() as int;
    let tn = t.tn as int;
    &&& st.tloc.len() == n
    &&& tn == 0 ==> n == 0
    &&& tn > 0 ==> n > 0
    &&& n > 0 ==> st.tloc[0] == (0int, 0int)
    &&& forall|k: int| 0 <= k < n - 1 ==> #[trigger] st.tloc[k + 1] == succ(h, st, k, tn)
    &&& n > 0 ==> tpg(st, n - 1) == tn - 1 && tend(h, st, n - 1) == t.top
    &&& forall|k: int| 0 <= k < n ==> 0 <= #[trigger] tpg(st, k) < tn && 0 <= toff(st, k) && tend(h, st, k) <= st.tus[tpg(st, k)]
    &&& forall|k1: int, k2: int| 0 <= k1 < k2 < n ==> #[trigger] before(h, st, k1, k2)
}

/// The to-space pages: disjoint, not holding an object outside
/// from-space, their permissions, the sentinel word after the used words
/// of a closed page, the tables.
pub open spec fn tpages_ok(c: Ctx, h: H, st: St, t: Tos) -> bool {
    let tn = t.tn as int;
    &&& st.tss.len() == tn
    &&& st.tus.len() == tn
    &&& tn <= t.tcap
    &&& tn > 0 ==> st.tus[tn - 1] == t.top && t.cur == st.tss[tn - 1]
    &&& forall|p: int| 0 <= p < tn ==> 0 <= #[trigger] st.tus[p] <= c.pw - 1
    &&& forall|p: int| 0 <= p < tn ==> #[trigger] st.tss[p] % W == 0 && st.tss[p] + pbytes(c) < usize::MAX
    &&& forall|p: int, q: int| 0 <= p < q < tn ==> #[trigger] pages_apart(st.tss[p] as int, st.tss[q] as int, c.pw as int)
    &&& forall|p: int, j: int| 0 <= p < tn && 0 <= j < h.objs.len() && !from(h, j) ==>
            #[trigger] outside(st.tss[p] as int, #[trigger] h.addr[j] as int, c.pw as int)
    &&& forall|p: int, k: int| 0 <= p < tn && 0 <= k < c.pw ==> #[trigger] wperm_ok(st.tp, (p, k), tptr(c, st, p), k)
    &&& forall|q: (int, int)| #[trigger] st.tp.contains_key(q) ==> 0 <= q.0 < tn
    &&& forall|p: int| 0 <= p < tn - 1 ==> #[trigger] st.tp[(p, st.tus[p])].is_init() && st.tp[(p, st.tus[p])].value() == 0
    // The tables.
    &&& t.ttab@.addr + t.tcap * W <= usize::MAX
    &&& t.tused@.addr + t.tcap * W <= usize::MAX
    &&& forall|p: int| 0 <= p < t.tcap ==> #[trigger] wperm_ok(st.ttp, p, t.ttab, p)
    &&& forall|p: int| 0 <= p < t.tcap ==> #[trigger] wperm_ok(st.tup, p, t.tused, p)
    &&& forall|p: int| 0 <= p < tn ==> #[trigger] st.ttp[p].is_init() && st.ttp[p].value() == st.tss[p]
    &&& forall|p: int| 0 <= p < tn - 1 ==> #[trigger] st.tup[p].is_init() && st.tup[p].value() == st.tus[p]
}

/// The capacity argument: the from-space words of the copies, and the
/// pages: two consecutive pages hold more than a page's words.
pub open spec fn cap_ok(c: Ctx, h: H, st: St, t: Tos) -> bool {
    &&& st.used.len() == st.words
    &&& st.used.subset_of(set_int_range(0, c.nf * c.pw))
    &&& forall|j: int| #[trigger] from(h, j) && !copied(st, j) ==> st.used.disjoint(extent(c, h, j))
    &&& st.order.len() <= st.words
    &&& t.tn == 0 ==> st.words == 0
    &&& t.tn >= 1 ==> (t.tn - 1) * c.pw <= 2 * st.words - t.top
    &&& 1 <= t.mx@ <= c.pw - 1
    &&& forall|j: int| #[trigger] from(h, j) ==> size(h, j) <= t.mx@
    &&& 1 <= t.rs && (t.rs >= 2 * c.nf + 1 || t.rs * (c.pw - t.mx@) > c.nf * c.pw)
    &&& t.tn >= 1 ==> (t.tn - 1) * (c.pw - t.mx@) + t.top <= st.words
}

/// To-space contents: each copy holds its object's words, encoded under the
/// new address map where processed and the old one elsewhere; processed
/// reference slots are closed.
pub open spec fn to_inv(c: Ctx, h: H, st: St, ks: int, kc: int) -> bool {
    let n = st.order.len() as int;
    &&& forall|kk: int, i: int| 0 <= kk < n && 0 <= i < tsz(h, st, kk) ==>
            (#[trigger] st.tp[tkey(st, kk, i)]).is_init()
            && st.tp[tkey(st, kk, i)].value() == wval(obj(h, st.order[kk]), amap(h, st, kk, i, ks, kc), i)
    &&& forall|kk: int, i: int| 0 <= kk < n && 0 <= i < tsz(h, st, kk) && processed(kk, i, ks, kc)
            && is_ref(obj(h, st.order[kk]), i) ==> closed(h, st, #[trigger] obj(h, st.order[kk]).words[i])
}

/// Copy `k` was made for a root or for a reference slot of an earlier copy.
pub open spec fn parent_ok(h: H, st: St, rv: Seq<AVal>, k: int) -> bool {
    let p = st.parent[k].0;
    let s = st.parent[k].1;
    if p < 0 {
        0 <= -1 - p < rv.len() && rv[-1 - p] == AVal::Ref(st.order[k])
    } else {
        p < k && is_ref(obj(h, st.order[p]), s) && obj(h, st.order[p]).words[s] == AVal::Ref(st.order[k])
    }
}

pub open spec fn par_ok(h: H, st: St, rv: Seq<AVal>) -> bool {
    &&& st.parent.len() == st.order.len()
    &&& forall|k: int| 0 <= k < st.order.len() ==> #[trigger] parent_ok(h, st, rv, k)
}

/// The roots: an array of `rv.len()` words holding the root values; the
/// first `ri` are processed (encoded under the new address map, closed).
pub open spec fn roots_ok(c: Ctx, h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, ri: int) -> bool {
    &&& rptr@.addr + rv.len() * W <= usize::MAX
    &&& 0 <= ri <= rv.len()
    &&& forall|i: int| 0 <= i < rv.len() ==> #[trigger] slot_ok(c, h.objs.len() as int, rv[i])
    &&& forall|i: int| 0 <= i < rv.len() ==> #[trigger] wperm_ok(st.rp, i, rptr, i)
    &&& forall|i: int| 0 <= i < rv.len() ==> (#[trigger] st.rp[i]).is_init()
            && st.rp[i].value() == enc(if i < ri { st.addr2 } else { h.addr }, rv[i])
    &&& forall|i: int| 0 <= i < ri ==> closed(h, st, #[trigger] rv[i])
}

/// The Cheney invariant with the scan at word `kc` of copy `ks`.
pub open spec fn inv(c: Ctx, h: H, st: St, t: Tos, ks: int, kc: int, rv: Seq<AVal>) -> bool {
    &&& bk_ok(h, st)
    &&& from_inv(c, h, st)
    &&& tcopies_ok(c, h, st, t)
    &&& tpages_ok(c, h, st, t)
    &&& to_inv(c, h, st, ks, kc)
    &&& cap_ok(c, h, st, t)
    &&& par_ok(h, st, rv)
}

/// The page source's state during a collection.
pub open spec fn src_ok<S: PageSource>(c: Ctx, src: S, t: Tos) -> bool {
    &&& src.pw() == c.pw
    &&& src.prov() == c.base@.provenance
    &&& src.reserved() >= t.rs - t.tn
    &&& t.tcap >= t.rs
}

/// What a step of the collector keeps of the state before it.
pub open spec fn grows(h: H, s0: St, s1: St) -> bool {
    let n0 = s0.order.len() as int;
    &&& n0 <= s1.order.len()
    &&& forall|k: int| 0 <= k < n0 ==> #[trigger] s1.order[k] == s0.order[k]
    &&& forall|k: int| 0 <= k < n0 ==> #[trigger] s1.tloc[k] == s0.tloc[k]
    &&& forall|k: int| 0 <= k < n0 ==> #[trigger] s1.parent[k] == s0.parent[k]
    &&& forall|j: int| #[trigger] copied(s0, j) ==> copied(s1, j) && s1.pos[j] == s0.pos[j]
    &&& forall|j: int| 0 <= j < s0.addr2.len() && (copied(s0, j) || !from(h, j)) ==> #[trigger] s1.addr2[j] == s0.addr2[j]
    &&& s1.rp == s0.rp
    &&& s0.tss.len() <= s1.tss.len()
    &&& forall|p: int| 0 <= p < s0.tss.len() ==> #[trigger] s1.tss[p] == s0.tss[p]
}

/// `grows` composes.
pub proof fn lemma_grows_trans(h: H, s0: St, s1: St, s2: St)
    requires grows(h, s0, s1), grows(h, s1, s2), s1.addr2.len() == s0.addr2.len(),
    ensures grows(h, s0, s2),
{
    assert forall|j: int| 0 <= j < s0.addr2.len() && (copied(s0, j) || !from(h, j)) implies #[trigger] s2.addr2[j] == s0.addr2[j] by {
        assert(s1.addr2[j] == s0.addr2[j]);
        if copied(s0, j) { assert(copied(s1, j)); }
    }
    assert forall|k: int| 0 <= k < s0.order.len() implies #[trigger] s2.order[k] == s0.order[k] by {
        assert(s1.order[k] == s0.order[k]);
    }
    assert forall|k: int| 0 <= k < s0.order.len() implies #[trigger] s2.tloc[k] == s0.tloc[k] by {
        assert(s1.tloc[k] == s0.tloc[k]);
    }
    assert forall|k: int| 0 <= k < s0.order.len() implies #[trigger] s2.parent[k] == s0.parent[k] by {
        assert(s1.parent[k] == s0.parent[k]);
    }
    assert forall|j: int| #[trigger] copied(s0, j) implies copied(s2, j) && s2.pos[j] == s0.pos[j] by {
        assert(copied(s1, j));
    }
    assert forall|p: int| 0 <= p < s0.tss.len() implies #[trigger] s2.tss[p] == s0.tss[p] by {
        assert(s1.tss[p] == s0.tss[p]);
    }
}

/// A state grows into itself.
pub proof fn lemma_grows_refl(h: H, s0: St)
    ensures grows(h, s0, s0),
{
}

// ---------------------------------------------------------------------------
// Placement in to-space (next fit).

/// What `place` keeps of the ghost state.
pub open spec fn place_frame(s0: St, s1: St) -> bool {
    &&& s1.fp == s0.fp
    &&& s1.rp == s0.rp
    &&& s1.order == s0.order
    &&& s1.tloc == s0.tloc
    &&& s1.pos == s0.pos
    &&& s1.addr2 == s0.addr2
    &&& s1.used == s0.used
    &&& s1.words == s0.words
    &&& s1.parent == s0.parent
}

/// Room for `sz` words in to-space: in the last page if they fit below its
/// sentinel word, else in a new page from the page source (the old last
/// page gets its sentinel and its used words in the table). Returns the
/// offset in the (new) last page.
pub fn place<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, sz: usize, Ghost(h): Ghost<H>,
                        Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (off: usize)
    requires
        ctx_ok(*c), heap_ok(*c, h), others_ok(h, ro.others),
        tpages_ok(*c, h, *old(st), *old(t)),
        1 <= sz <= c.pw - 1,
        old(src).pw() == c.pw, old(src).prov() == c.base@.provenance,
        old(src).reserved() >= old(t).rs - old(t).tn,
        old(t).tcap >= old(t).rs,
        1 <= old(t).mx@ <= c.pw - 1, sz <= old(t).mx@,
        1 <= old(t).rs && (old(t).rs >= 2 * c.nf + 1 || old(t).rs * (c.pw - old(t).mx@) > c.nf * c.pw),
        old(t).tn >= 1 ==> (old(t).tn - 1) * (c.pw - old(t).mx@) + old(t).top <= old(st).words,
        old(st).words + sz <= c.nf * c.pw,
        old(t).tn == 0 ==> old(st).words == 0,
        old(t).tn >= 1 ==> (old(t).tn - 1) * c.pw <= 2 * old(st).words - old(t).top,
    ensures
        tpages_ok(*c, h, *final(st), *final(t)),
        place_frame(*old(st), *final(st)),
        final(t).ttab == old(t).ttab, final(t).tused == old(t).tused, final(t).tcap == old(t).tcap, final(t).rs == old(t).rs, final(t).mx == old(t).mx,
        final(t).tn >= 1, final(t).top == off + sz, off + sz <= c.pw - 1,
        (final(t).tn == old(t).tn && off == old(t).top && old(t).tn >= 1
            && final(st).tss == old(st).tss && final(st).tus == old(st).tus.update(old(t).tn - 1, off + sz))
        || (final(t).tn == old(t).tn + 1 && off == 0 && (old(t).tn == 0 || old(t).top + sz > c.pw - 1)
            && final(st).tss.subrange(0, old(t).tn as int) == old(st).tss && final(st).tus == old(st).tus.push(sz as int)),
        forall|q: (int, int)| old(st).tp.contains_key(q) && q != (old(t).tn - 1, old(t).top as int) ==> #[trigger] final(st).tp[q] == old(st).tp[q],
        final(t).tn == old(t).tn ==> final(st).tp == old(st).tp,
        final(src).pw() == c.pw, final(src).prov() == c.base@.provenance,
        final(src).reserved() >= final(t).rs - final(t).tn,
        (final(t).tn - 1) * c.pw <= 2 * (old(st).words + sz) - final(t).top,
        (final(t).tn - 1) * (c.pw - final(t).mx@) + final(t).top <= old(st).words + sz,
{
    let ghost s0 = *st;
    let ghost t0 = *t;
    proof { lemma_w(); }
    if t.tn == 0 || t.top + sz > c.pw - 1 {
        let ghost tn0 = t.tn as int;
        proof {
            // The reservation lasts: the copy will close no more than 2 nf pages.
            let w = s0.words;
            let pw = c.pw as int;
            if tn0 >= 1 {
                assert(tn0 * pw <= 2 * w + sz) by (nonlinear_arith)
                    requires (tn0 - 1) * pw <= 2 * w - t0.top, t0.top + sz >= pw;
            }
            assert(tn0 * pw <= 2 * w + sz);
            assert(tn0 < 2 * c.nf) by (nonlinear_arith)
                requires tn0 * pw <= 2 * w + sz, w + sz <= c.nf * pw, sz >= 1, pw >= 1;
            // And it lasts for the tail bound: every closed page holds at least pw - mx words.
            let mx = t0.mx@;
            let rs = t0.rs as int;
            if tn0 >= 1 {
                assert(tn0 * (pw - mx) <= w) by (nonlinear_arith)
                    requires (tn0 - 1) * (pw - mx) + t0.top <= w, t0.top + sz >= pw, sz <= mx;
            }
            assert(tn0 * (pw - mx) <= w) by (nonlinear_arith) requires tn0 == 0 || tn0 * (pw - mx) <= w, w >= 0;
            if rs < 2 * c.nf + 1 {
                assert(tn0 < rs) by (nonlinear_arith)
                    requires tn0 * (pw - mx) <= w, w + sz <= c.nf * pw, sz >= 1, rs * (pw - mx) > c.nf * pw, pw - mx >= 1;
            }
            assert(tn0 < rs);
        }
        if t.tn > 0 {
            // Close the last page: its sentinel word and its used words.
            let page = c.base.with_addr(t.cur);
            proof {
                assert(wperm_ok(st.tp, (tn0 - 1, t.top as int), tptr(*c, s0, tn0 - 1), t.top as int));
                assert(t.top * W <= pbytes(*c)) by (nonlinear_arith) requires t.top <= c.pw, W >= 1;
            }
            wr(page, t.top, 0, Ghost((tn0 - 1, t.top as int)), Tracked(&mut st.tp));
            proof {
                assert(wperm_ok(st.tup, tn0 - 1, t.tused, tn0 - 1));
                assert((t.tn - 1) * W <= t.tcap * W) by (nonlinear_arith) requires t.tn <= t.tcap, W >= 1;
            }
            wr(t.tused, t.tn - 1, t.top, Ghost(tn0 - 1), Tracked(&mut st.tup));
        }
        let ghost s1 = *st;
        let (s, perms) = src.take(Ghost(tn0));
        proof {
            let tracked mut np = perms.get();
            assert forall|k: int| 0 <= k < c.pw implies #[trigger] wperm_ok(np, (tn0, k), pptr(c.base@.provenance, s as int), k) by {}
            assert forall|p: int, k: int| 0 <= p < tn0 && 0 <= k < c.pw implies
                #[trigger] wperm_ok(s1.tp, (p, k), pptr(c.base@.provenance, s1.tss[p] as int), k) by {
                assert(wperm_ok(s0.tp, (p, k), tptr(*c, s0, p), k));
            }
            assert forall|p: int| 0 <= p < tn0 implies #[trigger] s1.tss[p] % W == 0 && s1.tss[p] + c.pw * W < usize::MAX by {
                assert(s0.tss[p] % W == 0 && s0.tss[p] + pbytes(*c) < usize::MAX);
            }
            lemma_page_apart_all(&mut np, tn0, s as int, &st.tp, s1.tss, tn0, c.pw as int, c.base@.provenance);
            lemma_page_apart_others(&mut np, tn0, s as int, &ro.others, h, h.objs.len() as int, c.pw as int, c.base@.provenance);
            st.tp.tracked_union_prefer_right(np);
        }
        proof {
            assert(wperm_ok(st.ttp, tn0, t.ttab, tn0));
            assert(t.tn * W <= t.tcap * W) by (nonlinear_arith) requires t.tn <= t.tcap, W >= 1;
        }
        wr(t.ttab, t.tn, s, Ghost(tn0), Tracked(&mut st.ttp));
        t.tn = t.tn + 1;
        t.top = sz;
        t.cur = s;
        proof {
            st.tss = s1.tss.push(s);
            st.tus = s1.tus.push(sz as int);
            let s2 = *st;
            assert(s2.tss.subrange(0, tn0) =~= s0.tss);
            assert forall|p: int| 0 <= p < t.tn implies #[trigger] s2.tss[p] % W == 0 && s2.tss[p] + pbytes(*c) < usize::MAX by {
                if p < tn0 { assert(s0.tss[p] % W == 0 && s0.tss[p] + pbytes(*c) < usize::MAX); }
            }
            assert forall|p: int| 0 <= p < t.tn implies 0 <= #[trigger] s2.tus[p] <= c.pw - 1 by {
                if p < tn0 { assert(0 <= s0.tus[p] <= c.pw - 1); }
            }
            assert forall|p: int, q: int| 0 <= p < q < t.tn implies
                #[trigger] pages_apart(s2.tss[p] as int, s2.tss[q] as int, c.pw as int) by {
                if q < tn0 {
                    assert(pages_apart(s0.tss[p] as int, s0.tss[q] as int, c.pw as int));
                } else {
                    assert(pages_apart(s as int, s1.tss[p] as int, c.pw as int));
                }
            }
            assert forall|p: int, j: int| 0 <= p < t.tn && 0 <= j < h.objs.len() && !from(h, j) implies
                #[trigger] outside(s2.tss[p] as int, #[trigger] h.addr[j] as int, c.pw as int) by {
                if p < tn0 {
                    assert(outside(s0.tss[p] as int, h.addr[j] as int, c.pw as int));
                } else {
                    assert(outside(s as int, h.addr[j] as int, c.pw as int));
                }
            }
            assert forall|p: int, k: int| 0 <= p < t.tn && 0 <= k < c.pw implies
                #[trigger] wperm_ok(s2.tp, (p, k), tptr(*c, s2, p), k) by {
                if p < tn0 {
                    assert(wperm_ok(s1.tp, (p, k), pptr(c.base@.provenance, s1.tss[p] as int), k));
                    assert(!perms@.contains_key((p, k)));
                } else {
                    assert(wperm_ok(perms@, (tn0, k), pptr(c.base@.provenance, s as int), k));
                }
            }
            assert forall|q: (int, int)| #[trigger] s2.tp.contains_key(q) implies 0 <= q.0 < t.tn by {
                if s1.tp.contains_key(q) { assert(s0.tp.contains_key(q)); }
            }
            if tn0 > 0 {
                let kk = (tn0 - 1, t0.top as int);
                assert(s1.tp[kk].is_init() && s1.tp[kk].value() == 0);
                assert(!perms@.contains_key(kk));
                assert(s2.tp[kk] == s1.tp[kk]);
                assert(s2.tus[tn0 - 1] == t0.top);
            }
            assert forall|p: int| 0 <= p < t.tn - 1 implies
                #[trigger] s2.tp[(p, s2.tus[p])].is_init() && s2.tp[(p, s2.tus[p])].value() == 0 by {
                assert(!perms@.contains_key((p, s2.tus[p])));
                assert(s2.tus[p] == s0.tus[p]);
                assert(0 <= s0.tus[p] <= c.pw - 1);
                assert(wperm_ok(s0.tp, (p, s0.tus[p]), tptr(*c, s0, p), s0.tus[p]));
                if p < tn0 - 1 {
                    assert(s0.tp[(p, s0.tus[p])].is_init() && s0.tp[(p, s0.tus[p])].value() == 0);
                    assert((p, s0.tus[p]) != (tn0 - 1, t0.top as int));
                    assert(s1.tp[(p, s0.tus[p])] == s0.tp[(p, s0.tus[p])]);
                    assert(s2.tp[(p, s0.tus[p])] == s1.tp[(p, s0.tus[p])]);
                } else {
                    assert(p == tn0 - 1);
                    assert(s0.tus[p] == t0.top);
                    assert(s1.tp[(tn0 - 1, t0.top as int)].is_init() && s1.tp[(tn0 - 1, t0.top as int)].value() == 0);
                }
            }
            assert forall|p: int| 0 <= p < t.tcap implies #[trigger] wperm_ok(s2.ttp, p, t.ttab, p) by {
                assert(wperm_ok(s0.ttp, p, t.ttab, p));
            }
            assert forall|p: int| 0 <= p < t.tcap implies #[trigger] wperm_ok(s2.tup, p, t.tused, p) by {
                assert(wperm_ok(s0.tup, p, t.tused, p));
            }
            assert forall|p: int| 0 <= p < t.tn implies #[trigger] s2.ttp[p].is_init() && s2.ttp[p].value() == s2.tss[p] by {
                if p < tn0 {
                    assert(s1.ttp == s0.ttp);
                    assert(s2.ttp[p] == s1.ttp[p]);
                    assert(tpages_ok(*c, h, s0, t0));
                    assert(0 <= p < t0.tn);
                    assert(s0.ttp[p].is_init());
                    assert(s0.ttp[p].value() == s0.tss[p]);
                }
            }
            assert forall|p: int| 0 <= p < t.tn - 1 implies #[trigger] s2.tup[p].is_init() && s2.tup[p].value() == s2.tus[p] by {
                if p < tn0 - 1 { assert(tpages_ok(*c, h, s0, t0)); assert(s0.tup[p].is_init()); assert(s0.tup[p].value() == s0.tus[p]); }
            }
            assert forall|q: (int, int)| s0.tp.contains_key(q) && q != (tn0 - 1, t0.top as int) implies
                #[trigger] s2.tp[q] == s0.tp[q] by {
                assert(!perms@.contains_key(q));
            }
        }
        0
    } else {
        let off = t.top;
        t.top = t.top + sz;
        proof {
            st.tus = s0.tus.update(t.tn - 1, t.top as int);
            let s2 = *st;
            assert forall|p: int| 0 <= p < t.tn implies 0 <= #[trigger] s2.tus[p] <= c.pw - 1 by {
                assert(0 <= s0.tus[p] <= c.pw - 1);
            }
            assert forall|p: int| 0 <= p < t.tn - 1 implies
                #[trigger] s2.tp[(p, s2.tus[p])].is_init() && s2.tp[(p, s2.tus[p])].value() == 0 by {
                assert(s0.tp[(p, s0.tus[p])].is_init());
            }
            assert forall|p: int| 0 <= p < t.tn - 1 implies #[trigger] s2.tup[p].is_init() && s2.tup[p].value() == s2.tus[p] by {
                assert(tpages_ok(*c, h, s0, t0));
                assert(s0.tup[p].is_init());
                assert(s0.tup[p].value() == s0.tus[p]);
            }
            assert forall|p: int, k: int| 0 <= p < t.tn && 0 <= k < c.pw implies
                #[trigger] wperm_ok(s2.tp, (p, k), tptr(*c, s2, p), k) by {
                assert(wperm_ok(s0.tp, (p, k), tptr(*c, s0, p), k));
            }
            let w = s0.words;
            let pw = c.pw as int;
            assert((t.tn - 1) * pw <= 2 * (w + sz) - t.top);
        }
        off
    }
}

} // verus!
