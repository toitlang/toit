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

//! Pages: the from-space table (checked at entry), the membership test (a
//! binary search over the sorted page starts, the C++ `in_from_space`),
//! the page source of to-space pages (the trusted boundary: `PageSource`),
//! and the disjointness of the pages the collector holds, derived from the
//! permissions it holds (`vstd::raw_ptr::PointsTo::is_disjoint`).

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::*;
use crate::model::*;

verus! {

/// The permissions of the from-space table: its `nf` words hold the page
/// starts.
pub open spec fn ftab_ok(c: Ctx, ftp: Map<int, PointsTo<usize>>) -> bool {
    &&& c.ftab@.addr + c.nf * W <= usize::MAX
    &&& forall|i: int| 0 <= i < c.nf ==> #[trigger] wperm_ok(ftp, i, c.ftab, i) && ftp[i].is_init()
            && ftp[i].value() == c.fss@[i]
}

/// The bytes of a page (`pw * W`; `pw` is at most 2^20).
#[inline(always)]
pub fn page_bytes(c: &Ctx) -> (r: usize)
    requires ctx_ok(*c),
    ensures r == pbytes(*c), r <= 0x80_0000,
{
    proof { lemma_w(); }
    c.pw * W
}

/// Reads entry `i` of the from-space table.
#[inline(always)]
pub fn ftab_at(c: &Ctx, i: usize, Tracked(ftp): Tracked<&Map<int, PointsTo<usize>>>) -> (s: usize)
    requires ctx_ok(*c), ftab_ok(*c, *ftp), i < c.nf,
    ensures s == fs(*c, i as int),
{
    proof {
        lemma_w();
        assert(wperm_ok(*ftp, i as int, c.ftab, i as int));
        assert(i * W <= c.nf * W) by (nonlinear_arith) requires i <= c.nf, W > 0;
    }
    rd(c.ftab, i, Ghost(i as int), Tracked(ftp))
}

/// Checks the from-space table: word-aligned starts, each page in the
/// address space with room above it, sorted and disjoint.
pub fn check_ftab(c: &Ctx, Tracked(ftp): Tracked<&Map<int, PointsTo<usize>>>) -> (r: bool)
    requires ctx_ok(*c), ftab_ok(*c, *ftp),
    ensures r ==> fpages_ok(*c),
{
    let pb = page_bytes(c);
    let mut i: usize = 0;
    let mut prev_end: usize = 0;
    while i < c.nf
        invariant
            ctx_ok(*c), ftab_ok(*c, *ftp), pb == pbytes(*c), i <= c.nf,
            forall|j: int| 0 <= j < i ==> #[trigger] fs(*c, j) % (W as int) == 0,
            forall|j: int| 0 <= j < i ==> #[trigger] fs(*c, j) + pb < usize::MAX,
            forall|j: int, k: int| 0 <= j < k < i ==> #[trigger] fs(*c, j) + pb <= #[trigger] fs(*c, k),
            forall|j: int| 0 <= j < i ==> #[trigger] fs(*c, j) + pb <= prev_end,
        decreases c.nf - i,
    {
        let s = ftab_at(c, i, Tracked(ftp));
        if s % W != 0 || s >= usize::MAX - pb || s < prev_end {
            return false;
        }
        prev_end = s + pb;
        i += 1;
    }
    true
}

/// The from-space page that holds the tagged word `w`, or `nf`.
pub fn find_page(c: &Ctx, w: usize, Tracked(ftp): Tracked<&Map<int, PointsTo<usize>>>) -> (r: usize)
    requires ctx_ok(*c), ftab_ok(*c, *ftp), fpages_ok(*c),
    ensures
        r <= c.nf,
        r < c.nf ==> in_fpage(*c, r as int, w),
        r == c.nf ==> forall|i: int| 0 <= i < c.nf ==> !#[trigger] in_fpage(*c, i, w),
{
    let pb = page_bytes(c);
    let mut lo: usize = 0;
    let mut hi: usize = c.nf;
    while lo < hi
        invariant
            ctx_ok(*c), ftab_ok(*c, *ftp), fpages_ok(*c), pb == pbytes(*c),
            lo <= hi <= c.nf,
            forall|i: int| 0 <= i < lo ==> #[trigger] fs(*c, i) + pb <= w,
            forall|i: int| hi <= i < c.nf ==> w <= #[trigger] fs(*c, i),
        decreases hi - lo,
    {
        let mid = lo + (hi - lo) / 2;
        let s = ftab_at(c, mid, Tracked(ftp));
        if w <= s {
            proof {
                assert forall|i: int| mid <= i < c.nf implies w <= #[trigger] fs(*c, i) by {
                    if i > mid { assert(fs(*c, mid as int) + pb <= fs(*c, i)); }
                }
            }
            hi = mid;
        } else if w - s >= pb {
            proof {
                assert forall|i: int| 0 <= i <= mid implies #[trigger] fs(*c, i) + pb <= w by {
                    if i < mid { assert(fs(*c, i) + pb <= fs(*c, mid as int)); }
                }
            }
            lo = mid + 1;
        } else {
            return mid;
        }
    }
    proof {
        assert forall|i: int| 0 <= i < c.nf implies !#[trigger] in_fpage(*c, i, w) by {
            if i < lo { assert(fs(*c, i) + pb <= w); } else { assert(w <= fs(*c, i)); }
        }
    }
    c.nf
}

// ---------------------------------------------------------------------------
// The page source.

/// The pointer to address `s` with provenance `prov`.
pub open spec fn pptr(prov: Provenance, s: int) -> *mut usize {
    ptr_mut_from_data::<usize>(PtrData::<usize> { addr: s as usize, provenance: prov, metadata: () })
}

/// `m` holds exactly the permissions of the `pw` words of the page at `s`
/// (keys `(key, k)`), which is word-aligned, not at 0, and in the address
/// space with room above it.
pub open spec fn page_ok(s: usize, m: Map<(int, int), PointsTo<usize>>, key: int, pw: int, prov: Provenance) -> bool {
    &&& s % W == 0
    &&& s + pw * W < usize::MAX
    &&& forall|k: int| 0 <= k < pw ==> #[trigger] wperm_ok(m, (key, k), pptr(prov, s as int), k)
    &&& forall|q: (int, int)| #[trigger] m.contains_key(q) ==> q.0 == key && 0 <= q.1 < pw
}

/// Where to-space pages come from (TRUSTED: the implementation is the
/// runtime's page allocator, at M5 ObjectMemory behind the FFI; see
/// TRUSTED.md). A collection first reserves the pages it may need
/// (`reserve`); while pages are reserved, `take` returns a fresh page:
/// the permissions of its words, with the heap's provenance (the pages'
/// addresses are exposed, as the core's heap is). `release` ends the
/// reservation.
pub trait PageSource {
    /// The provenance of the pages.
    spec fn prov(&self) -> Provenance;

    /// Words per page.
    spec fn pw(&self) -> int;

    /// Pages still reserved.
    spec fn reserved(&self) -> int;

    fn reserve(&mut self, n: usize) -> (r: bool)
        ensures
            final(self).prov() == old(self).prov(),
            final(self).pw() == old(self).pw(),
            r ==> final(self).reserved() >= n,
    ;

    fn take(&mut self, key: Ghost<int>) -> (r: (usize, Tracked<Map<(int, int), PointsTo<usize>>>))
        requires old(self).reserved() > 0,
        ensures
            final(self).prov() == old(self).prov(),
            final(self).pw() == old(self).pw(),
            final(self).reserved() == old(self).reserved() - 1,
            page_ok(r.0, r.1@, key@, old(self).pw(), old(self).prov()),
    ;

    fn release(&mut self)
        ensures
            final(self).prov() == old(self).prov(),
            final(self).pw() == old(self).pw(),
    ;
}

// ---------------------------------------------------------------------------
// Disjointness from the permissions.

/// The word ranges of two pages of `pw` words.
pub open spec fn pages_apart(s: int, t: int, pw: int) -> bool {
    s + pw * W <= t || t + pw * W <= s
}

/// The page whose permissions are `np` (keys `(key, k)`, at `s`) and the
/// one in `m` (keys `(q, k)`, at `t`) do not overlap.
pub proof fn lemma_pages_apart(tracked np: &mut Map<(int, int), PointsTo<usize>>, key: int, s: int,
                               tracked m: &Map<(int, int), PointsTo<usize>>, q: int, t: int, pw: int, prov: Provenance)
    requires
        1 <= pw,
        s % (W as int) == 0, t % (W as int) == 0, 0 <= s, 0 <= t,
        s + pw * W < usize::MAX, t + pw * W < usize::MAX,
        forall|k: int| 0 <= k < pw ==> #[trigger] wperm_ok(*old(np), (key, k), pptr(prov, s), k),
        forall|k: int| 0 <= k < pw ==> #[trigger] wperm_ok(*m, (q, k), pptr(prov, t), k),
    ensures
        *final(np) == *old(np),
        pages_apart(s, t, pw),
{
    lemma_w();
    let w = W as int;
    if t <= s && s < t + pw * w {
        let k = (s - t) / w;
        vstd::arithmetic::div_mod::lemma_fundamental_div_mod(s - t, w);
        assert((s - t) % w == 0) by {
            vstd::arithmetic::div_mod::lemma_sub_mod_noop(s, t, w);
        }
        assert(0 <= k < pw) by (nonlinear_arith) requires s - t == w * k, 0 <= s - t < pw * w, w > 0;
        assert(wperm_ok(*m, (q, k), pptr(prov, t), k));
        assert(wperm_ok(*old(np), (key, 0), pptr(prov, s), 0));
        np.tracked_borrow_mut((key, 0)).is_disjoint(m.tracked_borrow((q, k)));
        assert(false);
    } else if s < t && t < s + pw * w {
        let k = (t - s) / w;
        vstd::arithmetic::div_mod::lemma_fundamental_div_mod(t - s, w);
        assert((t - s) % w == 0) by {
            vstd::arithmetic::div_mod::lemma_sub_mod_noop(t, s, w);
        }
        assert(0 <= k < pw) by (nonlinear_arith) requires t - s == w * k, 0 < t - s < pw * w, w > 0;
        assert(wperm_ok(*m, (q, 0), pptr(prov, t), 0));
        assert(wperm_ok(*old(np), (key, k), pptr(prov, s), k));
        np.tracked_borrow_mut((key, k)).is_disjoint(m.tracked_borrow((q, 0)));
        assert(false);
    }
}

/// The page at `s` does not overlap the pages `0..n` of `tss`, whose
/// permissions are in `m` (keys `(p, k)`).
pub proof fn lemma_page_apart_all(tracked np: &mut Map<(int, int), PointsTo<usize>>, key: int, s: int,
                                  tracked m: &Map<(int, int), PointsTo<usize>>, tss: Seq<usize>, n: int, pw: int, prov: Provenance)
    requires
        1 <= pw, 0 <= n <= tss.len(),
        s % (W as int) == 0, 0 <= s, s + pw * W < usize::MAX,
        forall|k: int| 0 <= k < pw ==> #[trigger] wperm_ok(*old(np), (key, k), pptr(prov, s), k),
        forall|p: int| 0 <= p < n ==> #[trigger] tss[p] % W == 0 && tss[p] + pw * W < usize::MAX,
        forall|p: int, k: int| 0 <= p < n && 0 <= k < pw ==> #[trigger] wperm_ok(*m, (p, k), pptr(prov, tss[p] as int), k),
    ensures
        *final(np) == *old(np),
        forall|p: int| 0 <= p < n ==> #[trigger] pages_apart(s, tss[p] as int, pw),
    decreases n,
{
    if n > 0 {
        lemma_page_apart_all(np, key, s, m, tss, n - 1, pw, prov);
        assert(tss[n - 1] % W == 0 && tss[n - 1] + pw * W < usize::MAX);
        assert forall|k: int| 0 <= k < pw implies #[trigger] wperm_ok(*m, (n - 1, k), pptr(prov, tss[n - 1] as int), k) by {
            assert(wperm_ok(*m, (n - 1, k), pptr(prov, tss[n - 1] as int), k));
        }
        lemma_pages_apart(np, key, s, m, n - 1, tss[n - 1] as int, pw, prov);
    }
}

/// The tagged address `a` is not that of a word of the page at `s`.
pub open spec fn outside(s: int, a: int, pw: int) -> bool {
    !(s < a && a <= s + pw * W)
}

/// No object outside from-space among `0..n` has its header in the page at
/// `s` (their header permissions are in `others`).
pub proof fn lemma_page_apart_others(tracked np: &mut Map<(int, int), PointsTo<usize>>, key: int, s: int,
                                     tracked others: &Map<int, PointsTo<usize>>, h: H, n: int, pw: int, prov: Provenance)
    requires
        1 <= pw, 0 <= n <= h.objs.len(), h.addr.len() == h.objs.len(),
        s % (W as int) == 0, 0 <= s, s + pw * W < usize::MAX,
        forall|k: int| 0 <= k < pw ==> #[trigger] wperm_ok(*old(np), (key, k), pptr(prov, s), k),
        others_ok(h, *others),
    ensures
        *final(np) == *old(np),
        forall|j: int| 0 <= j < n && !from(h, j) ==> #[trigger] outside(s, h.addr[j] as int, pw),
    decreases n,
{
    if n > 0 {
        lemma_page_apart_others(np, key, s, others, h, n - 1, pw, prov);
        let j = n - 1;
        if !from(h, j) {
            assert(0 <= j < h.objs.len() && !from(h, j));
            assert((*others).contains_key(j));
            assert(others[j].ptr()@.addr == h.addr[j] - 1);
            let a = h.addr[j] - 1;
            if s <= a && a < s + pw * W {
                lemma_w();
                let w = W as int;
                let k = (a - s) / w;
                vstd::arithmetic::div_mod::lemma_fundamental_div_mod(a - s, w);
                assert(0 <= (a - s) % w < w);
                assert(0 <= k < pw && s + k * w <= a < s + k * w + w) by (nonlinear_arith)
                    requires a - s == w * k + (a - s) % w, 0 <= (a - s) % w < w, 0 <= a - s < pw * w, w > 0;
                assert(wperm_ok(*np, (key, k), pptr(prov, s), k));
                np.tracked_borrow_mut((key, k)).is_disjoint(others.tracked_borrow(j));
                assert(false);
            }
        }
    }
}

} // verus!
