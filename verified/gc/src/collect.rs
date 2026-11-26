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

//! The slot visitor (`forward`, the C++ `scavenge_slot`), the root loop,
//! the scan over the to-space pages, and the driver `collect` with the
//! top-level statement `collected`.

use vstd::prelude::*;
use vstd::raw_ptr::*;
use vstd::set_lib::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::space::*;
use crate::cheney::*;
use crate::copy::*;

verus! {

/// A tagged address is odd.
pub proof fn lemma_tag_odd(s: int, k: int)
    requires s % (W as int) == 0, s >= 0, k >= 0,
    ensures (s + k * W + 1) % 2 == 1,
{
    lemma_w();
    let w = W as int;
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(s, w);
    let q = s / w;
    assert(s + k * w + 1 == 2 * (q * (w / 2) + k * (w / 2)) + 1) by (nonlinear_arith)
        requires s == w * q, w == 2 * (w / 2);
}

/// The word offset of a tagged address in its page.
pub proof fn lemma_offset(s: int, k: int)
    requires k >= 0,
    ensures (s + k * W + 1 - 1 - s) / (W as int) == k,
{
    lemma_w();
    assert(s + k * W + 1 - 1 - s == k * W);
    vstd::arithmetic::div_mod::lemma_div_by_multiple(k, W as int);
}

/// A tagged word lies in at most one from-space page.
pub proof fn lemma_one_page(c: Ctx, i1: int, i2: int, w: usize)
    requires fpages_ok(c), 0 <= i1 < c.nf, 0 <= i2 < c.nf, in_fpage(c, i1, w), in_fpage(c, i2, w),
    ensures i1 == i2,
{
    if i1 < i2 { assert(fs(c, i1) + pbytes(c) <= fs(c, i2)); }
    if i2 < i1 { assert(fs(c, i2) + pbytes(c) <= fs(c, i1)); }
}

/// The address of a from-space object is in its page.
pub proof fn lemma_from_addr(c: Ctx, h: H, j: int)
    requires ctx_ok(c), fpages_ok(c), heap_ok(c, h), from(h, j),
    ensures in_fpage(c, fpg(h, j), h.addr[j]), in_from(c, h.addr[j]), h.addr[j] % 2 == 1,
{
    lemma_from_obj(c, h, j);
    lemma_w();
    let p = fpg(h, j);
    assert(foff(h, j) * W + 1 < pbytes(c)) by (nonlinear_arith)
        requires foff(h, j) + 1 <= c.pw, W >= 2;
    assert(fs(c, p) % (W as int) == 0);
    lemma_tag_odd(fs(c, p), foff(h, j));
    assert(in_fpage(c, p, h.addr[j]));
}

/// Visits a reference slot holding `w` (the encoding of `v` under the old
/// address map): returns the slot's new word, the encoding of `v` under
/// the new address map, copying `v`'s object if it is in from-space and
/// not copied yet.
pub fn forward<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, w: usize,
                              Ghost(h): Ghost<H>, Ghost(v): Ghost<AVal>, Ghost(ks): Ghost<int>, Ghost(kc): Ghost<int>,
                              Ghost(par): Ghost<(int, int)>, Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>,
                              Ghost(ri): Ghost<int>,
                              Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (r: usize)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others),
        inv(*c, h, *old(st), *old(t), ks, kc, rv), roots_ok(*c, h, *old(st), rptr, rv, ri),
        src_ok(*c, *old(src), *old(t)),
        w == enc(h.addr, v), slot_ok(*c, h.objs.len() as int, v),
        0 <= ks <= old(st).order.len(), ks < old(st).order.len() || kc == 0,
        v matches AVal::Ref(j) ==> (from(h, j) && !copied(*old(st), j) ==> new_parent_ok(h, *old(st), rv, j, par)),
    ensures
        inv(*c, h, *final(st), *final(t), ks, kc, rv), roots_ok(*c, h, *final(st), rptr, rv, ri),
        src_ok(*c, *final(src), *final(t)),
        grows(h, *old(st), *final(st)),
        r == enc(final(st).addr2, v), closed(h, *final(st), v),
        final(t).ttab == old(t).ttab, final(t).tused == old(t).tused, final(t).tcap == old(t).tcap,
{
    let ghost s0 = *st;
    let ghost n = h.objs.len() as int;
    let ghost j = match v { AVal::Ref(j) => j, _ => -1 };
    proof {
        if j >= 0 && from(h, j) { lemma_from_addr(*c, h, j); }
        if j >= 0 && !from(h, j) {
            assert(0 <= j < n);
            assert(!in_from(*c, h.addr[j]) && h.addr[j] % 4 == 1);
        }
    }
    if w % 2 == 1 {
        let pi = find_page(c, w, Tracked(&ro.ftp));
        if pi < c.nf {
            proof {
                // Only a reference to a from-space object is in a from-space page.
                assert(in_from(*c, w));
                assert(v is Ref);
                assert(from(h, j));
                lemma_one_page(*c, pi as int, fpg(h, j), w);
                lemma_from_obj(*c, h, j);
            }
            let s = ftab_at(c, pi, Tracked(&ro.ftp));
            proof { lemma_offset(s as int, foff(h, j)); }
            let off = (w - 1 - s) / W;
            proof {
                assert(off == foff(h, j));
                assert(fkey(h, j, 0) == (pi as int, off as int));
                assert(wperm_ok(st.fp, (pi as int, off as int), fptr(*c, pi as int), off as int));
                assert(off * W <= pbytes(*c)) by (nonlinear_arith) requires off <= c.pw, W >= 1;
                if copied(s0, j) {
                    assert(s0.fp[fkey(h, j, 0)].is_init());
                    let k = s0.pos[j];
                    assert(0 <= k < s0.order.len());
                    assert(0 <= tpg(s0, k) < t.tn && 0 <= toff(s0, k));
                    assert(s0.tss[tpg(s0, k)] % W == 0);
                    lemma_tag_odd(s0.tss[tpg(s0, k)] as int, toff(s0, k));
                    assert(s0.addr2[j] == taddr(s0, k));
                } else {
                    assert(s0.fp[fkey(h, j, 0)].is_init());
                    assert(obj(h, j).words[0] is Raw);
                }
            }
            let fpage = c.base.with_addr(s);
            let hd = rd(fpage, off, Ghost((pi as int, off as int)), Tracked(&st.fp));
            if hd % 2 == 1 {
                proof { assert(copied(s0, j)); }
                hd
            } else {
                copy(c, src, t, s, off, Ghost(h), Ghost(j), Ghost(ks), Ghost(kc), Ghost(par), Ghost(rptr), Ghost(rv),
                     Ghost(ri), Tracked(st), Tracked(ro))
            }
        } else {
            proof {
                if j >= 0 && from(h, j) {
                    assert(in_fpage(*c, fpg(h, j), w));
                    assert(false);
                }
            }
            w
        }
    } else {
        proof {
            if j >= 0 && from(h, j) { assert(false); }
            if j >= 0 { assert(h.addr[j] % 2 == 1); }
        }
        w
    }
}

// ---------------------------------------------------------------------------
// The scan.

/// The scan moves over raw words of copy `ks` (`a..b`).
pub proof fn lemma_to_raw(c: Ctx, h: H, st: St, ks: int, a: int, b: int)
    requires
        heap_ok(c, h), bk_ok(h, st), to_inv(c, h, st, ks, a),
        0 <= ks < st.order.len(), 0 <= a <= b <= tsz(h, st, ks),
        forall|i: int| a <= i < b ==> !is_ref(obj(h, st.order[ks]), i),
    ensures to_inv(c, h, st, ks, b),
{
    let n = st.order.len() as int;
    let o = obj(h, st.order[ks]);
    lemma_from_obj(c, h, st.order[ks]);
    assert forall|kk: int, i: int| 0 <= kk < n && 0 <= i < tsz(h, st, kk) implies
        (#[trigger] st.tp[tkey(st, kk, i)]).is_init()
        && st.tp[tkey(st, kk, i)].value() == wval(obj(h, st.order[kk]), amap(h, st, kk, i, ks, b), i) by {
        assert(st.tp[tkey(st, kk, i)].is_init());
        if kk == ks && a <= i < b {
            assert(!is_ref(o, i));
            assert(o.words[i] is Raw);
        }
    }
    assert forall|kk: int, i: int| 0 <= kk < n && 0 <= i < tsz(h, st, kk) && processed(kk, i, ks, b)
        && is_ref(obj(h, st.order[kk]), i) implies closed(h, st, #[trigger] obj(h, st.order[kk]).words[i]) by {
        assert(processed(kk, i, ks, a));
    }
}

/// After the last word of copy `ks`, the scan is at copy `ks + 1`.
pub proof fn lemma_to_next(c: Ctx, h: H, st: St, ks: int)
    requires to_inv(c, h, st, ks, tsz(h, st, ks)), 0 <= ks < st.order.len(),
    ensures to_inv(c, h, st, ks + 1, 0),
{
    let n = st.order.len() as int;
    let e = tsz(h, st, ks);
    assert forall|kk: int, i: int| 0 <= kk < n && 0 <= i < tsz(h, st, kk) implies
        (#[trigger] st.tp[tkey(st, kk, i)]).is_init()
        && st.tp[tkey(st, kk, i)].value() == wval(obj(h, st.order[kk]), amap(h, st, kk, i, ks + 1, 0), i) by {
        assert(st.tp[tkey(st, kk, i)].is_init());
        assert(processed(kk, i, ks, e) == processed(kk, i, ks + 1, 0));
    }
    assert forall|kk: int, i: int| 0 <= kk < n && 0 <= i < tsz(h, st, kk) && processed(kk, i, ks + 1, 0)
        && is_ref(obj(h, st.order[kk]), i) implies closed(h, st, #[trigger] obj(h, st.order[kk]).words[i]) by {
        assert(processed(kk, i, ks, e));
    }
}

/// Distinct words of copies have distinct keys.
pub proof fn lemma_tkeys(c: Ctx, h: H, st: St, t: Tos, k1: int, i1: int, k2: int, i2: int)
    requires
        tcopies_ok(c, h, st, t),
        0 <= k1 < st.order.len(), 0 <= k2 < st.order.len(),
        0 <= i1 < tsz(h, st, k1), 0 <= i2 < tsz(h, st, k2),
        k1 != k2 || i1 != i2,
    ensures tkey(st, k1, i1) != tkey(st, k2, i2),
{
    if k1 < k2 { assert(before(h, st, k1, k2)); }
    if k2 < k1 { assert(before(h, st, k2, k1)); }
}

/// The parts of the invariant that do not read to-space hold for a state
/// that differs only in its to-space permissions (or root permissions).
pub proof fn lemma_frame_tp(c: Ctx, h: H, s2: St, s3: St, t: Tos, rv: Seq<AVal>)
    requires
        bk_ok(h, s2), from_inv(c, h, s2), tcopies_ok(c, h, s2, t), cap_ok(c, h, s2, t), par_ok(h, s2, rv),
        s3.fp == s2.fp, s3.ttp == s2.ttp, s3.tup == s2.tup, s3.order == s2.order, s3.tloc == s2.tloc,
        s3.pos == s2.pos, s3.addr2 == s2.addr2, s3.used == s2.used, s3.words == s2.words, s3.parent == s2.parent,
        s3.tss == s2.tss, s3.tus == s2.tus,
    ensures
        bk_ok(h, s3), from_inv(c, h, s3), tcopies_ok(c, h, s3, t), cap_ok(c, h, s3, t), par_ok(h, s3, rv),
        forall|j: int| #[trigger] copied(s3, j) == copied(s2, j),
{
    let n = s2.order.len() as int;
    assert forall|j: int| #[trigger] copied(s3, j) implies 0 <= s3.pos[j] < n && s3.order[s3.pos[j]] == j by {
        assert(copied(s2, j));
    }
    assert forall|j: int| 0 <= j < h.objs.len() implies #[trigger] s3.addr2[j] ==
        (if copied(s3, j) { taddr(s3, s3.pos[j]) } else { h.addr[j] }) by {
        assert(s2.addr2[j] == (if copied(s2, j) { taddr(s2, s2.pos[j]) } else { h.addr[j] }));
    }
    assert forall|j: int, k: int| from(h, j) && !copied(s3, j) && 0 <= k < size(h, j) implies
        (#[trigger] s3.fp[fkey(h, j, k)]).is_init() && s3.fp[fkey(h, j, k)].value() == wval(obj(h, j), h.addr, k) by {
        assert(!copied(s2, j));
    }
    assert forall|j: int| from(h, j) && #[trigger] copied(s3, j) implies
        s3.fp[fkey(h, j, 0)].is_init() && s3.fp[fkey(h, j, 0)].value() == s3.addr2[j] by {
        assert(copied(s2, j));
    }
    assert forall|k: int| 0 <= k < n - 1 implies #[trigger] s3.tloc[k + 1] == succ(h, s3, k, t.tn as int) by {
        assert(s2.tloc[k + 1] == succ(h, s2, k, t.tn as int));
    }
    assert forall|k: int| 0 <= k < n implies 0 <= #[trigger] tpg(s3, k) < t.tn && 0 <= toff(s3, k)
        && tend(h, s3, k) <= s3.tus[tpg(s3, k)] by {
        assert(0 <= tpg(s2, k) < t.tn && 0 <= toff(s2, k) && tend(h, s2, k) <= s2.tus[tpg(s2, k)]);
    }
    assert forall|k1: int, k2: int| 0 <= k1 < k2 < n implies #[trigger] before(h, s3, k1, k2) by {
        assert(before(h, s2, k1, k2));
    }
    assert forall|j: int| #[trigger] from(h, j) && !copied(s3, j) implies s3.used.disjoint(extent(c, h, j)) by {
        assert(!copied(s2, j));
    }
    assert forall|k: int| 0 <= k < n implies #[trigger] parent_ok(h, s3, rv, k) by {
        assert(parent_ok(h, s2, rv, k));
    }
}

/// The page part of the invariant depends only on the page fields.
pub proof fn lemma_tpages_frame(c: Ctx, h: H, s1: St, s2: St, t: Tos)
    requires
        tpages_ok(c, h, s1, t),
        s2.tp == s1.tp, s2.ttp == s1.ttp, s2.tup == s1.tup, s2.tss == s1.tss, s2.tus == s1.tus,
    ensures tpages_ok(c, h, s2, t),
{
    let tn = t.tn as int;
    assert forall|p: int| 0 <= p < tn implies 0 <= #[trigger] s2.tus[p] <= c.pw - 1 by {
        assert(0 <= s1.tus[p] <= c.pw - 1);
    }
    assert forall|p: int| 0 <= p < tn implies #[trigger] s2.tss[p] % W == 0 && s2.tss[p] + pbytes(c) < usize::MAX by {
        assert(s1.tss[p] % W == 0 && s1.tss[p] + pbytes(c) < usize::MAX);
    }
    assert forall|p: int, q: int| 0 <= p < q < tn implies #[trigger] pages_apart(s2.tss[p] as int, s2.tss[q] as int, c.pw as int) by {
        assert(pages_apart(s1.tss[p] as int, s1.tss[q] as int, c.pw as int));
    }
    assert forall|p: int, j: int| 0 <= p < tn && 0 <= j < h.objs.len() && !from(h, j) implies
        #[trigger] outside(s2.tss[p] as int, #[trigger] h.addr[j] as int, c.pw as int) by {
        assert(outside(s1.tss[p] as int, h.addr[j] as int, c.pw as int));
    }
    assert forall|p: int, k: int| 0 <= p < tn && 0 <= k < c.pw implies #[trigger] wperm_ok(s2.tp, (p, k), tptr(c, s2, p), k) by {
        assert(wperm_ok(s1.tp, (p, k), tptr(c, s1, p), k));
    }
    assert forall|q: (int, int)| #[trigger] s2.tp.contains_key(q) implies 0 <= q.0 < tn by {
        assert(s1.tp.contains_key(q));
    }
    assert forall|p: int| 0 <= p < tn - 1 implies #[trigger] s2.tp[(p, s2.tus[p])].is_init() && s2.tp[(p, s2.tus[p])].value() == 0 by {
        assert(s1.tp[(p, s1.tus[p])].is_init());
        assert(s1.tp[(p, s1.tus[p])].value() == 0);
    }
    assert forall|p: int| 0 <= p < t.tcap implies #[trigger] wperm_ok(s2.ttp, p, t.ttab, p) by {
        assert(wperm_ok(s1.ttp, p, t.ttab, p));
    }
    assert forall|p: int| 0 <= p < t.tcap implies #[trigger] wperm_ok(s2.tup, p, t.tused, p) by {
        assert(wperm_ok(s1.tup, p, t.tused, p));
    }
    assert forall|p: int| 0 <= p < tn implies #[trigger] s2.ttp[p].is_init() && s2.ttp[p].value() == s2.tss[p] by {
        assert(s1.ttp[p].is_init());
        assert(s1.ttp[p].value() == s1.tss[p]);
    }
    assert forall|p: int| 0 <= p < tn - 1 implies #[trigger] s2.tup[p].is_init() && s2.tup[p].value() == s2.tus[p] by {
        assert(s1.tup[p].is_init());
        assert(s1.tup[p].value() == s1.tus[p]);
    }
}

/// Writing the processed word of reference slot `i` of copy `ks` moves the
/// scan one word on.
pub proof fn lemma_scan_write(c: Ctx, h: H, s2: St, s3: St, t: Tos, ks: int, i: int, rv: Seq<AVal>, v: AVal)
    requires
        heap_ok(c, h), inv(c, h, s2, t, ks, i, rv),
        0 <= ks < s2.order.len(), 0 <= i < tsz(h, s2, ks), is_ref(obj(h, s2.order[ks]), i),
        v == obj(h, s2.order[ks]).words[i], closed(h, s2, v),
        s3.fp == s2.fp, s3.rp == s2.rp, s3.ttp == s2.ttp, s3.tup == s2.tup, s3.order == s2.order, s3.tloc == s2.tloc,
        s3.pos == s2.pos, s3.addr2 == s2.addr2, s3.used == s2.used, s3.words == s2.words, s3.parent == s2.parent,
        s3.tss == s2.tss, s3.tus == s2.tus,
        s3.tp.dom() == s2.tp.dom(),
        forall|q: (int, int)| q != tkey(s2, ks, i) ==> #[trigger] s3.tp[q] == s2.tp[q],
        s3.tp[tkey(s2, ks, i)].ptr() == s2.tp[tkey(s2, ks, i)].ptr(),
        s3.tp[tkey(s2, ks, i)].is_init(), s3.tp[tkey(s2, ks, i)].value() == enc(s2.addr2, v),
    ensures inv(c, h, s3, t, ks, i + 1, rv),
{
    let n = s2.order.len() as int;
    let key = tkey(s2, ks, i);
    lemma_from_obj(c, h, s2.order[ks]);
    lemma_frame_tp(c, h, s2, s3, t, rv);
    assert(0 <= tpg(s2, ks) < t.tn && tend(h, s2, ks) <= s2.tus[tpg(s2, ks)]);
    // The pages.
    assert forall|p: int, k: int| 0 <= p < t.tn && 0 <= k < c.pw implies #[trigger] wperm_ok(s3.tp, (p, k), tptr(c, s3, p), k) by {
        assert(wperm_ok(s2.tp, (p, k), tptr(c, s2, p), k));
    }
    assert forall|p: int| 0 <= p < t.tn - 1 implies #[trigger] s3.tp[(p, s3.tus[p])].is_init() && s3.tp[(p, s3.tus[p])].value() == 0 by {
        assert(s2.tp[(p, s2.tus[p])].is_init());
        if p == tpg(s2, ks) { assert((p, s2.tus[p]) != key); }
    }
    assert forall|q: (int, int)| #[trigger] s3.tp.contains_key(q) implies 0 <= q.0 < t.tn by {
        assert(s2.tp.contains_key(q));
    }
    assert(tpages_ok(c, h, s3, t));
    // The to-space words.
    assert forall|kk: int, i2: int| 0 <= kk < n && 0 <= i2 < tsz(h, s3, kk) implies
        (#[trigger] s3.tp[tkey(s3, kk, i2)]).is_init()
        && s3.tp[tkey(s3, kk, i2)].value() == wval(obj(h, s3.order[kk]), amap(h, s3, kk, i2, ks, i + 1), i2) by {
        if kk != ks || i2 != i {
            lemma_tkeys(c, h, s2, t, kk, i2, ks, i);
            assert(s2.tp[tkey(s2, kk, i2)].is_init());
        }
    }
    assert forall|kk: int, i2: int| 0 <= kk < n && 0 <= i2 < tsz(h, s3, kk) && processed(kk, i2, ks, i + 1)
        && is_ref(obj(h, s3.order[kk]), i2) implies closed(h, s3, #[trigger] obj(h, s3.order[kk]).words[i2]) by {
        if kk != ks || i2 != i { assert(processed(kk, i2, ks, i)); }
    }
}

/// Scans copy `ks` (at offset `so` of the to-space page starting at
/// `sstart`): visits its reference slots. Returns its size.
pub fn scan_object<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, sstart: usize, so: usize,
                              Ghost(h): Ghost<H>, Ghost(ks): Ghost<int>, Ghost(sp): Ghost<int>,
                              Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>,
                              Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (sz: usize)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others),
        inv(*c, h, *old(st), *old(t), ks, 0, rv), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        src_ok(*c, *old(src), *old(t)),
        0 <= ks < old(st).order.len(), old(st).tloc[ks] == (sp, so as int), sstart == old(st).tss[sp],
    ensures
        inv(*c, h, *final(st), *final(t), ks + 1, 0, rv), roots_ok(*c, h, *final(st), rptr, rv, rv.len() as int),
        src_ok(*c, *final(src), *final(t)),
        grows(h, *old(st), *final(st)),
        sz == tsz(h, *old(st), ks),
        final(t).ttab == old(t).ttab, final(t).tused == old(t).tused, final(t).tcap == old(t).tcap,
        old(t).tn <= final(t).tn,
{
    let ghost s0 = *st;
    let ghost jo = s0.order[ks];
    let ghost o = obj(h, jo);
    let ghost pw = c.pw as int;
    let ghost rl = rv.len() as int;
    proof {
        lemma_w();
        lemma_from_obj(*c, h, jo);
        assert(0 <= tpg(s0, ks) < t.tn && 0 <= toff(s0, ks) && tend(h, s0, ks) <= s0.tus[tpg(s0, ks)]);
        assert(s0.tus[sp] <= c.pw - 1);
        assert(s0.tss[sp] + pbytes(*c) < usize::MAX);
        assert forall|k: int| 0 <= k < lay(o).size && #[trigger] o.words[k] is Raw implies
            wperm_ok(s0.tp, (sp, so + k), ppage(*c, sstart as int), so + k) && s0.tp[(sp, so + k)].is_init()
            && s0.tp[(sp, so + k)].value() == raw(o.words[k]) by {
            assert(wperm_ok(s0.tp, (sp, so + k), tptr(*c, s0, sp), so + k));
            assert(tkey(s0, ks, k) == (sp, so + k));
            assert(s0.tp[tkey(s0, ks, k)].is_init());
        }
    }
    let tpage = c.base.with_addr(sstart);
    let (sz, lo, hi) = obj_layout(tpage, so, Ghost(sp), Tracked(&st.tp), Ghost(o), Ghost(pw));
    proof {
        assert forall|i: int| 0 <= i < lo implies !is_ref(o, i) by {}
        lemma_to_raw(*c, h, s0, ks, 0, lo as int);
    }
    let mut i = lo;
    while i < hi
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others),
            inv(*c, h, *st, *t, ks, i as int, rv), roots_ok(*c, h, *st, rptr, rv, rl),
            src_ok(*c, *src, *t),
            grows(h, s0, *st), s0.addr2.len() == h.objs.len(),
            0 <= ks < s0.order.len(), jo == s0.order[ks], o == obj(h, jo), rl == rv.len(),
            sz == lay(o).size, lo == lay(o).lo, hi == lay(o).hi, lo <= i <= hi, obj_ok(o), slots_ok(*c, h, jo),
            st.tloc[ks] == (sp, so as int), st.order[ks] == jo, st.tss[sp] == sstart, tpage == ppage(*c, sstart as int),
            sz == tsz(h, s0, ks), so + sz <= c.pw - 1, sstart + pbytes(*c) < usize::MAX,
            0 <= sp < t.tn,
            t.ttab == old(t).ttab, t.tused == old(t).tused, t.tcap == old(t).tcap, old(t).tn <= t.tn,
        decreases hi - i,
    {
        let ghost s1 = *st;
        proof {
            assert(st.order.len() >= s0.order.len());
            assert(tkey(s1, ks, i as int) == (sp, so + i));
            assert(wperm_ok(s1.tp, (sp, so + i), tptr(*c, s1, sp), so + i));
            assert(s1.tp[tkey(s1, ks, i as int)].is_init());
            assert(!processed(ks, i as int, ks, i as int));
            assert(slot_ok(*c, h.objs.len() as int, o.words[i as int]));
            assert((so + i) * W <= pbytes(*c)) by (nonlinear_arith) requires so + i <= c.pw, W >= 1;
            assert(tsz(h, s1, ks) == sz);
        }
        let w = rd(tpage, so + i, Ghost((sp, so + i)), Tracked(&st.tp));
        let r = forward(c, src, t, w, Ghost(h), Ghost(o.words[i as int]), Ghost(ks), Ghost(i as int), Ghost((ks, i as int)),
                        Ghost(rptr), Ghost(rv), Ghost(rl), Tracked(st), Tracked(ro));
        let ghost s2 = *st;
        proof {
            assert(bk_ok(h, s1));
            assert(s1.addr2.len() == s0.addr2.len());
            lemma_grows_trans(h, s0, s1, s2);
            assert(s2.tloc[ks] == s1.tloc[ks] && s2.order[ks] == jo);
            assert(s2.tss[sp] == sstart);
            assert(wperm_ok(s2.tp, (sp, so + i), tptr(*c, s2, sp), so + i));
            assert(tkey(s2, ks, i as int) == (sp, so + i));
        }
        wr(tpage, so + i, r, Ghost((sp, so + i)), Tracked(&mut st.tp));
        proof {
            lemma_scan_write(*c, h, s2, *st, *t, ks, i as int, rv, o.words[i as int]);
        }
        i += 1;
    }
    proof {
        let s3 = *st;
        assert(tsz(h, s3, ks) == sz);
        assert forall|i2: int| hi <= i2 < sz implies !is_ref(o, i2) by {}
        lemma_to_raw(*c, h, s3, ks, hi as int, sz as int);
        lemma_to_next(*c, h, s3, ks);
    }
    sz
}

/// The copies are at most `nf * pw` (each has a word of from-space).
pub proof fn lemma_copies_bound(c: Ctx, h: H, st: St, t: Tos)
    requires cap_ok(c, h, st, t), ctx_ok(c),
    ensures st.order.len() <= st.words <= c.nf * c.pw,
{
    assert(0 <= c.nf * c.pw) by (nonlinear_arith) requires c.nf >= 0, c.pw >= 0;
    lemma_int_range(0, c.nf * c.pw);
    lemma_len_subset(st.used, set_int_range(0, c.nf * c.pw));
}

/// Reads to-space table entry `p`.
#[inline(always)]
fn tab_at(tab: *mut usize, p: usize, Ghost(tcap): Ghost<int>, Tracked(perms): Tracked<&Map<int, PointsTo<usize>>>) -> (v: usize)
    requires
        0 <= p < tcap, tab@.addr + tcap * W <= usize::MAX,
        wperm_ok(*perms, p as int, tab, p as int), perms[p as int].is_init(),
    ensures v == perms[p as int].value(),
{
    proof {
        lemma_w();
        assert(p * W <= tcap * W) by (nonlinear_arith) requires p <= tcap, W >= 1;
    }
    rd(tab, p, Ghost(p as int), Tracked(perms))
}

/// The root loop (the C++ `iterate_roots` with `do_roots`): forwards every
/// root word in place.
pub fn do_roots<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, rptr: *mut usize, rlen: usize,
                           Ghost(h): Ghost<H>, Ghost(rv): Ghost<Seq<AVal>>,
                           Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others),
        inv(*c, h, *old(st), *old(t), 0, 0, rv), roots_ok(*c, h, *old(st), rptr, rv, 0),
        src_ok(*c, *old(src), *old(t)), rv.len() == rlen,
    ensures
        inv(*c, h, *final(st), *final(t), 0, 0, rv), roots_ok(*c, h, *final(st), rptr, rv, rlen as int),
        src_ok(*c, *final(src), *final(t)),
        final(t).ttab == old(t).ttab, final(t).tused == old(t).tused, final(t).tcap == old(t).tcap,
{
    let mut i: usize = 0;
    while i < rlen
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others),
            inv(*c, h, *st, *t, 0, 0, rv), roots_ok(*c, h, *st, rptr, rv, i as int),
            src_ok(*c, *src, *t), rv.len() == rlen, i <= rlen,
            t.ttab == old(t).ttab, t.tused == old(t).tused, t.tcap == old(t).tcap,
        decreases rlen - i,
    {
        proof {
            lemma_w();
            assert(wperm_ok(st.rp, i as int, rptr, i as int));
            assert(st.rp[i as int].is_init());
            assert(slot_ok(*c, h.objs.len() as int, rv[i as int]));
            assert(i * W <= rlen * W) by (nonlinear_arith) requires i <= rlen, W >= 1;
        }
        let w = rd(rptr, i, Ghost(i as int), Tracked(&st.rp));
        let r = forward(c, src, t, w, Ghost(h), Ghost(rv[i as int]), Ghost(0), Ghost(0), Ghost((-1 - i, 0int)),
                        Ghost(rptr), Ghost(rv), Ghost(i as int), Tracked(st), Tracked(ro));
        let ghost s1 = *st;
        proof { assert(wperm_ok(s1.rp, i as int, rptr, i as int)); }
        wr(rptr, i, r, Ghost(i as int), Tracked(&mut st.rp));
        proof {
            let s2 = *st;
            lemma_frame_tp(*c, h, s1, s2, *t, rv);
            assert(to_inv(*c, h, s2, 0, 0)) by {
                assert forall|kk: int, i2: int| 0 <= kk < s2.order.len() && 0 <= i2 < tsz(h, s2, kk) implies
                    (#[trigger] s2.tp[tkey(s2, kk, i2)]).is_init()
                    && s2.tp[tkey(s2, kk, i2)].value() == wval(obj(h, s2.order[kk]), amap(h, s2, kk, i2, 0, 0), i2) by {
                    assert(s1.tp[tkey(s1, kk, i2)].is_init());
                }
            }
            lemma_tpages_frame(*c, h, s1, s2, *t);
            assert forall|k: int| 0 <= k < rv.len() implies #[trigger] wperm_ok(s2.rp, k, rptr, k) by {
                assert(wperm_ok(s1.rp, k, rptr, k));
            }
            assert forall|k: int| 0 <= k < rv.len() implies (#[trigger] s2.rp[k]).is_init()
                && s2.rp[k].value() == enc(if k < i + 1 { s2.addr2 } else { h.addr }, rv[k]) by {
                if k != i { assert(s1.rp[k].is_init()); }
            }
            assert forall|k: int| 0 <= k < i + 1 implies closed(h, s2, #[trigger] rv[k]) by {
                if k != i { assert(closed(h, s1, rv[k])); }
            }
        }
        i += 1;
    }
}

/// The scan (the C++ `scan`): walks the copies in to-space page by page,
/// visiting their reference slots, until it reaches the copy pointer.
pub fn scan<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, Ghost(h): Ghost<H>, Ghost(rptr): Ghost<*mut usize>,
                       Ghost(rv): Ghost<Seq<AVal>>,
                       Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others),
        inv(*c, h, *old(st), *old(t), 0, 0, rv), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        src_ok(*c, *old(src), *old(t)),
    ensures
        inv(*c, h, *final(st), *final(t), final(st).order.len() as int, 0, rv),
        roots_ok(*c, h, *final(st), rptr, rv, rv.len() as int),
        src_ok(*c, *final(src), *final(t)),
        final(t).ttab == old(t).ttab, final(t).tused == old(t).tused, final(t).tcap == old(t).tcap,
{
    if t.tn == 0 {
        return;
    }
    let ghost rl = rv.len() as int;
    proof {
        assert(wperm_ok(st.ttp, 0, t.ttab, 0));
        assert(st.ttp[0].is_init());
    }
    let mut sstart = tab_at(t.ttab, 0, Ghost(t.tcap as int), Tracked(&st.ttp));
    let mut sp: usize = 0;
    let mut so: usize = 0;
    let ghost mut ks: int = 0;
    while !(sp + 1 == t.tn && so == t.top)
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others),
            inv(*c, h, *st, *t, ks, 0, rv), roots_ok(*c, h, *st, rptr, rv, rl), rl == rv.len(),
            src_ok(*c, *src, *t),
            t.ttab == old(t).ttab, t.tused == old(t).tused, t.tcap == old(t).tcap,
            t.tn >= 1, 0 <= sp < t.tn, sstart == st.tss[sp as int],
            0 <= ks <= st.order.len(), so <= st.tus[sp as int],
            ks == st.order.len() ==> sp + 1 == t.tn && so == t.top,
            ks < st.order.len() ==> st.tloc[ks] == (sp as int, so as int)
                || (so == st.tus[sp as int] && sp + 1 < t.tn && st.tloc[ks] == (sp + 1, 0int)),
        decreases c.nf * c.pw - ks, t.tn - sp,
    {
        let ghost s1 = *st;
        proof {
            lemma_copies_bound(*c, h, s1, *t);
            if ks == s1.order.len() { assert(false); }
            assert(s1.tus[t.tn - 1] == t.top);
        }
        let lim = if sp + 1 == t.tn {
            t.top
        } else {
            proof {
                assert(wperm_ok(st.ttp, sp as int, t.ttab, sp as int));
                assert(wperm_ok(st.tup, sp as int, t.tused, sp as int));
                assert((sp as int) < (t.tn as int) - 1);
                assert(tpages_ok(*c, h, s1, *t));
                assert(s1.tup[sp as int].is_init());
                assert(s1.tup[sp as int].value() == s1.tus[sp as int]);
            }
            tab_at(t.tused, sp, Ghost(t.tcap as int), Tracked(&st.tup))
        };
        if so == lim {
            proof {
                assert(sp + 1 < t.tn);
                // Copy ks does not start at the end of page sp.
                assert(0 <= tpg(s1, ks) < t.tn && tend(h, s1, ks) <= s1.tus[tpg(s1, ks)]);
                lemma_from_obj(*c, h, s1.order[ks]);
                assert(s1.tloc[ks] == (sp + 1, 0int));
                assert(wperm_ok(st.ttp, sp + 1, t.ttab, sp + 1));
                assert(st.ttp[sp + 1].is_init());
                assert(st.ttp[sp + 1].value() == st.tss[sp + 1]);
                assert(0 <= st.tus[sp + 1]);
            }
            sp = sp + 1;
            so = 0;
            sstart = tab_at(t.ttab, sp, Ghost(t.tcap as int), Tracked(&st.ttp));
        } else {
            proof {
                assert(s1.tloc[ks] == (sp as int, so as int));
            }
            let sz = scan_object(c, src, t, sstart, so, Ghost(h), Ghost(ks), Ghost(sp as int), Ghost(rptr), Ghost(rv),
                                 Tracked(st), Tracked(ro));
            proof {
                let s2 = *st;
                assert(s2.tloc[ks] == s1.tloc[ks] && s2.order[ks] == s1.order[ks]);
                assert(tsz(h, s2, ks) == sz);
                assert(0 <= tpg(s2, ks) < t.tn && tend(h, s2, ks) <= s2.tus[tpg(s2, ks)]);
                assert(s2.tus[sp as int] <= c.pw - 1);
                assert(s2.tss[sp as int] == s1.tss[sp as int]);
                if ks + 1 < s2.order.len() {
                    assert(s2.tloc[ks + 1] == succ(h, s2, ks, t.tn as int));
                }
            }
            so = so + sz;
            proof { ks = ks + 1; }
        }
    }
    proof {
        let s3 = *st;
        if ks < s3.order.len() {
            assert(0 <= tpg(s3, ks) < t.tn && tend(h, s3, ks) <= s3.tus[tpg(s3, ks)]);
            lemma_from_obj(*c, h, s3.order[ks]);
            assert(s3.tus[t.tn - 1] == t.top);
            assert(false);
        }
    }
}

} // verus!
