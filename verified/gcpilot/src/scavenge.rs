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

//! The scavenge itself: the copy with its forwarding header
//! (`ScavengeVisitor::clone_into_space`), the slot visitor
//! (`ScavengeVisitor::scavenge_root`), the root loop (`do_roots`), the scan
//! loop (`scan_copied_chunk`) and the driver (`TwoSpaceHeap::do_scavenge`
//! without finalizers, promotion and the remembered set).

use vstd::prelude::*;
use vstd::raw_ptr::*;
use vstd::set_lib::*;
use crate::*;

verus! {

/// The capacity argument: the from-space words of the copied objects and
/// of uncopied young object `j` fit in the used part of from-space, so the
/// copy fits in to-space.
proof fn lemma_capacity(c: Ctx, h: H, s0: St, f0: int, p: int, j: int)
    requires heap_ok(c, h), inv(c, h, s0, f0, p), young(h, j), !copied(s0, j),
    ensures
        f0 + words(obj(h, j)) <= h.fused,
        s0.used.union(extent(h, j)).len() == f0 + words(obj(h, j)),
        s0.used.union(extent(h, j)).subset_of(set_int_range(0, h.fused)),
{
    lemma_young_obj(c, h, j);
    let used1 = s0.used.union(extent(h, j));
    lemma_int_range(h.fidx[j], h.fidx[j] + words(obj(h, j)));
    assert(s0.used.disjoint(extent(h, j)));
    lemma_set_disjoint_lens(s0.used, extent(h, j));
    assert(used1.subset_of(set_int_range(0, h.fused)));
    lemma_int_range(0, h.fused);
    lemma_len_subset(used1, set_int_range(0, h.fused));
}

/// The state after copying `j` to `f0` (the ghost updates of `copy_obj`).
pub open spec fn copy_step(c: Ctx, h: H, s0: St, s1: St, f0: int, j: int) -> bool {
    let sz = words(obj(h, j));
    &&& s1.order == s0.order.push(j)
    &&& s1.starts == s0.starts.push(f0 + sz)
    &&& s1.pos == s0.pos.insert(j, s0.order.len() as int)
    &&& s1.addr2 == s0.addr2.update(j, taddr(c, f0) as usize)
    &&& s1.used == s0.used.union(extent(h, j))
    &&& s1.rp == s0.rp
    &&& shape(s1.fp, c.fptr, c.flen as int)
    &&& forall|i: int| i != h.fidx[j] ==> #[trigger] s1.fp[i] == s0.fp[i]
    &&& s1.fp[h.fidx[j]].is_init() && s1.fp[h.fidx[j]].value() == taddr(c, f0) as usize
    &&& shape(s1.tp, c.tptr, c.tlen as int)
    &&& forall|t: int| !(f0 <= t < f0 + sz) ==> #[trigger] s1.tp[t] == s0.tp[t]
    &&& forall|t: int| f0 <= t < f0 + sz ==> (#[trigger] s1.tp[t]).is_init() && s1.tp[t].value() == wval(obj(h, j), h.addr, t - f0)
}

/// A copy keeps the bookkeeping part of the invariant.
proof fn lemma_copy_order(c: Ctx, h: H, s0: St, s1: St, f0: int, p: int, j: int)
    requires
        ctx_ok(c), heap_ok(c, h), inv(c, h, s0, f0, p), young(h, j), !copied(s0, j),
        copy_step(c, h, s0, s1, f0, j), f0 + words(obj(h, j)) <= h.fused,
    ensures
        forall|k: int| 0 <= k < s1.order.len() ==> #[trigger] send(h, s1, k) == s1.starts[k + 1],
        forall|k: int| 0 <= k < s1.order.len() ==> 0 <= #[trigger] s1.starts[k] && send(h, s1, k) <= f0 + words(obj(h, j)),
        forall|k1: int, k2: int| #![trigger send(h, s1, k1), s1.starts[k2]] 0 <= k1 < k2 < s1.order.len() ==> send(h, s1, k1) <= s1.starts[k2],
        forall|k: int| 0 <= k < s1.order.len() ==> young(h, #[trigger] s1.order[k]) && s1.pos.contains_key(s1.order[k]) && s1.pos[s1.order[k]] == k,
        forall|jj: int| #[trigger] copied(s1, jj) ==> 0 <= s1.pos[jj] < s1.order.len() && s1.order[s1.pos[jj]] == jj,
        forall|jj: int| 0 <= jj < h.objs.len() ==> #[trigger] s1.addr2[jj] ==
            (if copied(s1, jj) { taddr(c, s1.starts[s1.pos[jj]]) as usize } else { h.addr[jj] }),
        grows(h, s0, s1),
{
    let n = s0.order.len() as int;
    let f1 = f0 + words(obj(h, j));
    assert forall|kk: int| 0 <= kk < n + 1 implies #[trigger] send(h, s1, kk) == s1.starts[kk + 1] by {
        if kk < n { assert(send(h, s0, kk) == s0.starts[kk + 1]); }
    }
    assert forall|kk: int| 0 <= kk < n + 1 implies 0 <= #[trigger] s1.starts[kk] && send(h, s1, kk) <= f1 by {
        if kk < n { assert(0 <= s0.starts[kk] && send(h, s0, kk) <= f0); }
    }
    assert forall|k1: int, k2: int| #![trigger send(h, s1, k1), s1.starts[k2]] 0 <= k1 < k2 < n + 1
        implies send(h, s1, k1) <= s1.starts[k2] by {
        assert(0 <= s0.starts[k1] && send(h, s0, k1) <= f0);
        if k2 < n { assert(send(h, s0, k1) <= s0.starts[k2]); }
    }
    assert forall|kk: int| 0 <= kk < n + 1 implies young(h, #[trigger] s1.order[kk])
        && s1.pos.contains_key(s1.order[kk]) && s1.pos[s1.order[kk]] == kk by {
        if kk < n {
            assert(young(h, s0.order[kk]) && s0.pos.contains_key(s0.order[kk]) && s0.pos[s0.order[kk]] == kk);
            assert(copied(s0, s0.order[kk]));
        }
    }
    assert forall|jj: int| #[trigger] copied(s1, jj) implies 0 <= s1.pos[jj] < n + 1 && s1.order[s1.pos[jj]] == jj by {
        if jj != j { assert(copied(s0, jj)); }
    }
    assert forall|jj: int| 0 <= jj < h.objs.len() implies #[trigger] s1.addr2[jj] ==
        (if copied(s1, jj) { taddr(c, s1.starts[s1.pos[jj]]) as usize } else { h.addr[jj] }) by {
        if jj != j {
            assert(s0.addr2[jj] == (if copied(s0, jj) { taddr(c, s0.starts[s0.pos[jj]]) as usize } else { h.addr[jj] }));
            if copied(s0, jj) { assert(0 <= s0.pos[jj] < n); }
        }
    }
    assert forall|jj: int| 0 <= jj < s0.addr2.len() && (copied(s0, jj) || !young(h, jj)) implies #[trigger] s1.addr2[jj] == s0.addr2[jj] by {
    }
    assert forall|jj: int| 0 <= jj < s0.addr2.len() && !young(h, jj) implies !copied(s1, jj) by {
        if copied(s0, jj) { assert(young(h, s0.order[s0.pos[jj]])); }
    }
    assert forall|k: int| 0 <= k <= n implies #[trigger] s1.starts[k] == s0.starts[k] by {}
    assert forall|k: int| 0 <= k < n implies #[trigger] s1.order[k] == s0.order[k] by {}
}

/// A copy keeps the from-space part of the invariant.
proof fn lemma_copy_from(c: Ctx, h: H, s0: St, s1: St, f0: int, p: int, j: int)
    requires
        ctx_ok(c), heap_ok(c, h), inv(c, h, s0, f0, p), young(h, j), !copied(s0, j),
        copy_step(c, h, s0, s1, f0, j), f0 + words(obj(h, j)) <= h.fused,
    ensures
        forall|jj: int, off: int| young(h, jj) && !copied(s1, jj) && 0 <= off < words(obj(h, jj)) ==>
            (#[trigger] fval(s1.fp, h, jj, off)).is_init() && fval(s1.fp, h, jj, off).value() == wval(obj(h, jj), h.addr, off),
        forall|jj: int| young(h, jj) && #[trigger] copied(s1, jj) ==>
            fval(s1.fp, h, jj, 0).is_init() && fval(s1.fp, h, jj, 0).value() == s1.addr2[jj],
{
    lemma_young_obj(c, h, j);
    assert forall|jj: int, off: int| young(h, jj) && !copied(s1, jj) && 0 <= off < words(obj(h, jj)) implies
        (#[trigger] fval(s1.fp, h, jj, off)).is_init() && fval(s1.fp, h, jj, off).value() == wval(obj(h, jj), h.addr, off) by {
        assert(jj != j);
        assert(disjoint(h, j, jj));
        assert(fval(s0.fp, h, jj, off).is_init());
    }
    assert forall|jj: int| young(h, jj) && #[trigger] copied(s1, jj) implies
        fval(s1.fp, h, jj, 0).is_init() && fval(s1.fp, h, jj, 0).value() == s1.addr2[jj] by {
        if jj != j {
            assert(copied(s0, jj));
            assert(disjoint(h, j, jj));
            assert(fval(s0.fp, h, jj, 0).is_init());
            lemma_young_obj(c, h, jj);
        }
    }
}

/// A copy keeps the to-space part of the invariant (the new copy lies at or
/// above the scan pointer, so it is unprocessed), the capacity part, and the
/// roots.
proof fn lemma_copy_to(c: Ctx, h: H, s0: St, s1: St, f0: int, p: int, j: int,
                       rptr: *mut usize, rv: Seq<AVal>, ri: int)
    requires
        ctx_ok(c), heap_ok(c, h), inv(c, h, s0, f0, p), young(h, j), !copied(s0, j),
        roots_ok(h, s0, rptr, rv, ri),
        copy_step(c, h, s0, s1, f0, j), f0 + words(obj(h, j)) <= h.fused,
    ensures
        forall|k: int, off: int| 0 <= k < s1.order.len() && 0 <= off < words(obj(h, s1.order[k])) ==>
            (#[trigger] tval(s1, k, off)).is_init()
            && tval(s1, k, off).value() == wval(obj(h, s1.order[k]), amap(h, s1, s1.starts[k] + off, p), off),
        forall|k: int, off: int| 0 <= k < s1.order.len() && 0 <= off < words(obj(h, s1.order[k])) && s1.starts[k] + off < p
            && is_ref_slot(obj(h, s1.order[k]), off) ==> closed(h, s1, #[trigger] slot(h, s1, k, off)),
        forall|jj: int| #[trigger] young(h, jj) && !copied(s1, jj) ==> s1.used.disjoint(extent(h, jj)),
        roots_ok(h, s1, rptr, rv, ri),
{
    let n = s0.order.len() as int;
    let nobj = h.objs.len() as int;
    assert forall|kk: int, off: int| 0 <= kk < n + 1 && 0 <= off < words(obj(h, s1.order[kk])) implies
        (#[trigger] tval(s1, kk, off)).is_init()
        && tval(s1, kk, off).value() == wval(obj(h, s1.order[kk]), amap(h, s1, s1.starts[kk] + off, p), off) by {
        if kk < n {
            let jk = s0.order[kk];
            assert(young(h, jk));
            lemma_young_obj(c, h, jk);
            assert(tval(s0, kk, off).is_init());
            assert(0 <= s0.starts[kk] && send(h, s0, kk) <= f0);
            assert(tval(s1, kk, off) == tval(s0, kk, off));
            if s0.starts[kk] + off < p && off > 0 {
                let ok = obj(h, jk);
                lemma_slot(ok, nobj, off);
                if is_ref_slot(ok, off) {
                    assert(closed(h, s0, slot(h, s0, kk, off)));
                }
                lemma_enc_same(s0.addr2, s1.addr2, ok.slots[off - 1]);
            }
        } else {
            assert(s1.order[kk] == j);
            assert(s1.tp[f0 + off].is_init());
        }
    }
    assert forall|kk: int, off: int| 0 <= kk < n + 1 && 0 <= off < words(obj(h, s1.order[kk])) && s1.starts[kk] + off < p
        && is_ref_slot(obj(h, s1.order[kk]), off) implies closed(h, s1, #[trigger] slot(h, s1, kk, off)) by {
        if kk < n {
            assert(closed(h, s0, slot(h, s0, kk, off)));
        }
    }
    assert forall|jj: int| #[trigger] young(h, jj) && !copied(s1, jj) implies s1.used.disjoint(extent(h, jj)) by {
        assert(jj != j);
        assert(disjoint(h, j, jj));
        assert(s0.used.disjoint(extent(h, jj)));
    }
    assert forall|i: int| 0 <= i < rv.len() implies (#[trigger] s1.rp[i]).is_init()
        && s1.rp[i].value() == enc(if i < ri { s1.addr2 } else { h.addr }, rv[i]) by {
        assert(s0.rp[i].is_init());
        if i < ri {
            assert(closed(h, s0, rv[i]));
            assert(val_ok(rv[i], nobj, true));
            lemma_enc_same(s0.addr2, s1.addr2, rv[i]);
        }
    }
    assert forall|i: int| 0 <= i < ri implies closed(h, s1, #[trigger] rv[i]) by {
        assert(closed(h, s0, rv[i]));
    }
}

/// Copies young object `j` (not yet copied, at from-space index `fi`) to
/// to-space at `free` and installs the forwarding header.
fn copy_obj(c: &Ctx, fi: usize, free: &mut usize, Ghost(h): Ghost<H>, Ghost(j): Ghost<int>, Ghost(p): Ghost<int>,
            Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(ri): Ghost<int>,
            Tracked(st): Tracked<&mut St>) -> (r: usize)
    requires
        ctx_ok(*c), heap_ok(*c, h), inv(*c, h, *old(st), *old(free) as int, p),
        roots_ok(h, *old(st), rptr, rv, ri),
        young(h, j), !copied(*old(st), j), fi == h.fidx[j],
    ensures
        inv(*c, h, *final(st), *final(free) as int, p),
        roots_ok(h, *final(st), rptr, rv, ri),
        grows(h, *old(st), *final(st)),
        copied(*final(st), j), r == final(st).addr2[j],
        forall|t: int| 0 <= t < *old(free) ==> #[trigger] final(st).tp[t] == old(st).tp[t],
{
    let ghost s0 = *st;
    let ghost f0 = *free as int;
    let ghost o = obj(h, j);
    proof {
        lemma_young_obj(*c, h, j);
        lemma_capacity(*c, h, s0, f0, p, j);
        assert(fval(s0.fp, h, j, 0).is_init());
        assert(slot_ok(s0.fp, c.fptr, fi as int));
    }
    let hd = rd(c.fptr, fi, Tracked(&st.fp));
    proof { assert(hd == o.hdr); }
    let second = if (hd / 2) % 4 != 0 {
        proof {
            assert(fval(s0.fp, h, j, 1).is_init());
            assert(slot_ok(s0.fp, c.fptr, fi + 1));
        }
        rd(c.fptr, fi + 1, Tracked(&st.fp))
    } else {
        0
    };
    proof {
        if kind(hd) != 0 {
            assert(fval(s0.fp, h, j, 1).value() == wval(o, h.addr, 1));
            assert(second == (o.slots.len() - 1) as usize);
        }
    }
    let (_lo, size) = layout(hd, second);
    let ti = *free;
    let mut k: usize = 0;
    while k < size
        invariant
            ctx_ok(*c), heap_ok(*c, h),
            o == obj(h, j), k <= size, size == words(o), ti == f0, f0 + size <= h.fused, h.fused <= c.flen, c.flen <= c.tlen,
            fi == h.fidx[j], fi + size <= h.fused,
            st.fp == s0.fp, st.rp == s0.rp, st.order == s0.order, st.starts == s0.starts, st.pos == s0.pos,
            st.addr2 == s0.addr2, st.used == s0.used,
            shape(st.tp, c.tptr, c.tlen as int),
            st.tp.dom() == s0.tp.dom(),
            forall|t: int| !(ti <= t < ti + k) ==> #[trigger] st.tp[t] == s0.tp[t],
            forall|t: int| ti <= t < ti + k ==> (#[trigger] st.tp[t]).is_init() && st.tp[t].value() == wval(o, h.addr, t - ti),
            inv(*c, h, s0, f0, p),
            young(h, j), !copied(s0, j),
        decreases size - k,
    {
        proof {
            assert(fval(s0.fp, h, j, k as int).is_init());
            assert(slot_ok(st.fp, c.fptr, fi + k));
            assert(slot_ok(st.tp, c.tptr, ti + k));
        }
        let v = rd(c.fptr, fi + k, Tracked(&st.fp));
        proof { assert(v == wval(o, h.addr, k as int)); }
        let ghost tp0 = st.tp;
        wr(c.tptr, ti + k, v, Tracked(&mut st.tp));
        proof {
            assert forall|i: int| 0 <= i < c.tlen implies #[trigger] slot_ok(st.tp, c.tptr, i) by {
                assert(slot_ok(tp0, c.tptr, i));
            }
        }
        k += 1;
    }
    proof {
        lemma_w();
        lemma_mul_le(ti as int, c.tlen as int);
    }
    let na = c.tstart + ti * W + 1;
    proof { assert(slot_ok(st.fp, c.fptr, fi as int)); }
    let ghost fp0 = st.fp;
    wr(c.fptr, fi, na, Tracked(&mut st.fp));
    *free = ti + size;
    proof {
        st.order = s0.order.push(j);
        st.starts = s0.starts.push(f0 + size);
        st.pos = s0.pos.insert(j, s0.order.len() as int);
        st.addr2 = s0.addr2.update(j, na);
        st.used = s0.used.union(extent(h, j));
        let s1 = *st;
        assert(na == taddr(*c, f0) as usize);
        assert forall|i: int| 0 <= i < c.flen implies #[trigger] slot_ok(s1.fp, c.fptr, i) by {
            assert(slot_ok(fp0, c.fptr, i));
        }
        assert(copy_step(*c, h, s0, s1, f0, j));
        lemma_copy_order(*c, h, s0, s1, f0, p, j);
        lemma_copy_from(*c, h, s0, s1, f0, p, j);
        lemma_copy_to(*c, h, s0, s1, f0, p, j, rptr, rv, ri);
        assert(inv(*c, h, s1, f0 + size, p));
    }
    na
}

/// Visits one reference slot (`ScavengeVisitor::scavenge_root` without
/// promotion and remembered set): returns the slot's new word.
fn scav_word(c: &Ctx, w: usize, free: &mut usize, Ghost(h): Ghost<H>, Ghost(v): Ghost<AVal>, Ghost(p): Ghost<int>,
             Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(ri): Ghost<int>,
             Tracked(st): Tracked<&mut St>) -> (r: usize)
    requires
        ctx_ok(*c), heap_ok(*c, h), inv(*c, h, *old(st), *old(free) as int, p),
        roots_ok(h, *old(st), rptr, rv, ri),
        w == enc(h.addr, v), val_ok(v, h.objs.len() as int, true),
    ensures
        inv(*c, h, *final(st), *final(free) as int, p),
        roots_ok(h, *final(st), rptr, rv, ri),
        grows(h, *old(st), *final(st)),
        forall|t: int| 0 <= t < *old(free) ==> #[trigger] final(st).tp[t] == old(st).tp[t],
        r == enc(final(st).addr2, v), closed(h, *final(st), v),
{
    let ghost s0 = *st;
    let ghost j = match v { AVal::Ref(j) => j, _ => -1 };
    proof {
        lemma_w();
        if j >= 0 && young(h, j) {
            lemma_tag(c.fstart as int, h.fidx[j]);
            lemma_mul_lt(h.fidx[j], c.flen as int);
            lemma_index(c.fstart as int, h.fidx[j]);
        }
        if j >= 0 && copied(s0, j) {
            assert(young(h, s0.order[s0.pos[j]]));
        }
    }
    if w % 2 == 1 && w > c.fstart && w - c.fstart < c.flen * W {
        proof {
            if !(v is Ref) {
            } else if !young(h, j) {
                assert(!in_from(*c, h.addr[j]));
            }
            assert(v is Ref && young(h, j));
            assert(w - c.fstart == h.fidx[j] * W + 1);
        }
        let fi = (w - c.fstart) / W;
        proof {
            assert(fi == h.fidx[j]);
            assert(slot_ok(s0.fp, c.fptr, fi as int));
            if copied(s0, j) {
                assert(fval(s0.fp, h, j, 0).is_init());
                assert(0 <= s0.pos[j] < s0.order.len());
                assert(0 <= s0.starts[s0.pos[j]]);
                lemma_tag(c.tstart as int, s0.starts[s0.pos[j]]);
            } else {
                assert(fval(s0.fp, h, j, 0).is_init());
                assert(obj_ok(obj(h, j), h.objs.len() as int));
            }
        }
        let hd = rd(c.fptr, fi, Tracked(&st.fp));
        if hd % 2 == 1 {
            proof { assert(copied(s0, j)); }
            hd
        } else {
            copy_obj(c, fi, free, Ghost(h), Ghost(j), Ghost(p), Ghost(rptr), Ghost(rv), Ghost(ri), Tracked(st))
        }
    } else {
        proof {
            if v is Ref {
                if young(h, j) {
                    assert(w == faddr(*c, h.fidx[j]));
                    assert(false);
                }
                assert(!copied(s0, j));
            }
        }
        w
    }
}

/// The invariant depends on the state only through its fields: a state with
/// the same bookkeeping and from-space, whose to-space satisfies the
/// to-space clauses for the scan pointer `p2`, satisfies it.
proof fn lemma_inv_frame(c: Ctx, h: H, s1: St, s2: St, free: int, p1: int, p2: int)
    requires
        inv(c, h, s1, free, p1),
        s2.fp == s1.fp, s2.order == s1.order, s2.starts == s1.starts, s2.pos == s1.pos,
        s2.addr2 == s1.addr2, s2.used == s1.used,
        shape(s2.tp, c.tptr, c.tlen as int),
        0 <= p2 <= free,
        forall|k: int, off: int| 0 <= k < s2.order.len() && 0 <= off < words(obj(h, s2.order[k])) ==>
            (#[trigger] tval(s2, k, off)).is_init()
            && tval(s2, k, off).value() == wval(obj(h, s2.order[k]), amap(h, s2, s2.starts[k] + off, p2), off),
        forall|k: int, off: int| 0 <= k < s2.order.len() && 0 <= off < words(obj(h, s2.order[k])) && s2.starts[k] + off < p2
            && is_ref_slot(obj(h, s2.order[k]), off) ==> closed(h, s2, #[trigger] slot(h, s2, k, off)),
    ensures inv(c, h, s2, free, p2),
{
    let n = s1.order.len() as int;
    assert forall|k: int| 0 <= k < n implies #[trigger] send(h, s2, k) == s2.starts[k + 1] by {
        assert(send(h, s1, k) == s1.starts[k + 1]);
    }
    assert forall|k: int| 0 <= k < n implies 0 <= #[trigger] s2.starts[k] && send(h, s2, k) <= free by {
        assert(0 <= s1.starts[k] && send(h, s1, k) <= free);
    }
    assert forall|k1: int, k2: int| #![trigger send(h, s2, k1), s2.starts[k2]] 0 <= k1 < k2 < n implies send(h, s2, k1) <= s2.starts[k2] by {
        assert(send(h, s1, k1) <= s1.starts[k2]);
    }
    assert forall|j: int| #[trigger] copied(s2, j) implies 0 <= s2.pos[j] < n && s2.order[s2.pos[j]] == j by {
        assert(copied(s1, j));
    }
    assert forall|j: int| 0 <= j < h.objs.len() implies #[trigger] s2.addr2[j] ==
        (if copied(s2, j) { taddr(c, s2.starts[s2.pos[j]]) as usize } else { h.addr[j] }) by {
        assert(s1.addr2[j] == (if copied(s1, j) { taddr(c, s1.starts[s1.pos[j]]) as usize } else { h.addr[j] }));
    }
    assert forall|j: int, off: int| young(h, j) && !copied(s2, j) && 0 <= off < words(obj(h, j)) implies
        (#[trigger] fval(s2.fp, h, j, off)).is_init() && fval(s2.fp, h, j, off).value() == wval(obj(h, j), h.addr, off) by {
        assert(!copied(s1, j));
    }
    assert forall|j: int| young(h, j) && #[trigger] copied(s2, j) implies
        fval(s2.fp, h, j, 0).is_init() && fval(s2.fp, h, j, 0).value() == s2.addr2[j] by {
        assert(copied(s1, j));
    }
    assert forall|j: int| #[trigger] young(h, j) && !copied(s2, j) implies s2.used.disjoint(extent(h, j)) by {
        assert(!copied(s1, j));
    }
}

/// The same to-space satisfies the to-space clauses of a state with the
/// same bookkeeping.
proof fn lemma_tp_same(c: Ctx, h: H, s1: St, s2: St, free: int, p: int)
    requires
        inv(c, h, s1, free, p),
        s2.fp == s1.fp, s2.tp == s1.tp, s2.order == s1.order, s2.starts == s1.starts, s2.pos == s1.pos,
        s2.addr2 == s1.addr2, s2.used == s1.used,
    ensures inv(c, h, s2, free, p),
{
    let n = s1.order.len() as int;
    assert forall|k: int, off: int| 0 <= k < n && 0 <= off < words(obj(h, s2.order[k])) implies
        (#[trigger] tval(s2, k, off)).is_init()
        && tval(s2, k, off).value() == wval(obj(h, s2.order[k]), amap(h, s2, s2.starts[k] + off, p), off) by {
        assert(tval(s1, k, off).is_init());
    }
    assert forall|k: int, off: int| 0 <= k < n && 0 <= off < words(obj(h, s2.order[k])) && s2.starts[k] + off < p
        && is_ref_slot(obj(h, s2.order[k]), off) implies closed(h, s2, #[trigger] slot(h, s2, k, off)) by {
        assert(closed(h, s1, slot(h, s1, k, off)));
        let v = slot(h, s1, k, off);
        if v is Ref {
            let jv = match v { AVal::Ref(jv) => jv, _ => 0 };
            assert(copied(s1, jv) == copied(s2, jv));
        }
    }
    lemma_inv_frame(c, h, s1, s2, free, p, p);
}

/// Writing the processed word of reference slot `s` of the copy being
/// scanned advances the scan pointer by one word.
proof fn lemma_scan_write(c: Ctx, h: H, s2: St, s3: St, free: int, s: int, ks: int, v: AVal)
    requires
        ctx_ok(c), heap_ok(c, h), inv(c, h, s2, free, s),
        0 <= ks < s2.order.len(), s2.starts[ks] <= s < send(h, s2, ks),
        is_ref_slot(obj(h, s2.order[ks]), s - s2.starts[ks]),
        v == obj(h, s2.order[ks]).slots[s - s2.starts[ks] - 1],
        closed(h, s2, v),
        s3.fp == s2.fp, s3.order == s2.order, s3.starts == s2.starts, s3.pos == s2.pos,
        s3.addr2 == s2.addr2, s3.used == s2.used,
        shape(s3.tp, c.tptr, c.tlen as int),
        forall|t: int| t != s ==> #[trigger] s3.tp[t] == s2.tp[t],
        s3.tp[s].is_init(), s3.tp[s].value() == enc(s2.addr2, v),
    ensures inv(c, h, s3, free, s + 1),
{
    let n = s2.order.len() as int;
    let off = s - s2.starts[ks];
    assert forall|kk: int, off2: int| 0 <= kk < n && 0 <= off2 < words(obj(h, s3.order[kk])) implies
        (#[trigger] tval(s3, kk, off2)).is_init()
        && tval(s3, kk, off2).value() == wval(obj(h, s3.order[kk]), amap(h, s3, s3.starts[kk] + off2, s + 1), off2) by {
        assert(tval(s2, kk, off2).is_init());
        if kk != ks {
            if kk < ks { assert(send(h, s2, kk) <= s2.starts[ks]); }
            else { assert(send(h, s2, ks) <= s2.starts[kk]); }
        }
    }
    assert forall|kk: int, off2: int| 0 <= kk < n && 0 <= off2 < words(obj(h, s3.order[kk]))
        && s3.starts[kk] + off2 < s + 1 && is_ref_slot(obj(h, s3.order[kk]), off2)
        implies closed(h, s3, #[trigger] slot(h, s3, kk, off2)) by {
        if kk != ks {
            if kk < ks { assert(send(h, s2, kk) <= s2.starts[ks]); }
            else { assert(send(h, s2, ks) <= s2.starts[kk]); }
            assert(closed(h, s2, slot(h, s2, kk, off2)));
        } else if off2 != off {
            assert(closed(h, s2, slot(h, s2, kk, off2)));
        }
        let w = slot(h, s2, kk, off2);
        if w is Ref {
            let jw = match w { AVal::Ref(jw) => jw, _ => 0 };
            assert(copied(s2, jw) == copied(s3, jw));
        }
    }
    lemma_inv_frame(c, h, s2, s3, free, s, s + 1);
}

/// The words of the copy being scanned before its first reference slot (its
/// header and length) read the same under both address maps: the scan
/// pointer moves over them.
proof fn lemma_scan_skip(c: Ctx, h: H, s0: St, free: int, sc: int, ks: int, lo: int)
    requires
        ctx_ok(c), heap_ok(c, h), inv(c, h, s0, free, sc),
        0 <= ks < s0.order.len(), sc == s0.starts[ks], lo == ref_lo(obj(h, s0.order[ks])),
        1 <= lo <= words(obj(h, s0.order[ks])),
    ensures inv(c, h, s0, free, sc + lo),
{
    let n = s0.order.len() as int;
    let nobj = h.objs.len() as int;
    let o = obj(h, s0.order[ks]);
    lemma_young_obj(c, h, s0.order[ks]);
    assert(0 <= s0.starts[ks] && send(h, s0, ks) <= free);
    assert forall|kk: int, off: int| 0 <= kk < n && 0 <= off < words(obj(h, s0.order[kk])) implies
        (#[trigger] tval(s0, kk, off)).is_init()
        && tval(s0, kk, off).value() == wval(obj(h, s0.order[kk]), amap(h, s0, s0.starts[kk] + off, sc + lo), off) by {
        assert(tval(s0, kk, off).is_init());
        if kk != ks {
            if kk < ks { assert(send(h, s0, kk) <= s0.starts[ks]); }
            else { assert(send(h, s0, ks) <= s0.starts[kk]); }
        } else if 0 < off < lo {
            lemma_slot(o, nobj, off);
        }
    }
    assert forall|kk: int, off: int| 0 <= kk < n && 0 <= off < words(obj(h, s0.order[kk]))
        && s0.starts[kk] + off < sc + lo && is_ref_slot(obj(h, s0.order[kk]), off)
        implies closed(h, s0, #[trigger] slot(h, s0, kk, off)) by {
        if kk != ks {
            if kk < ks { assert(send(h, s0, kk) <= s0.starts[ks]); }
            else { assert(send(h, s0, ks) <= s0.starts[kk]); }
        }
    }
    lemma_inv_frame(c, h, s0, s0, free, sc, sc + lo);
}

/// The root loop (`ScavengeVisitor::do_roots`).
fn scavenge_roots(c: &Ctx, rptr: *mut usize, rlen: usize, free: &mut usize, Ghost(h): Ghost<H>, Ghost(rv): Ghost<Seq<AVal>>,
                  Tracked(st): Tracked<&mut St>)
    requires
        ctx_ok(*c), heap_ok(*c, h), inv(*c, h, *old(st), *old(free) as int, 0),
        roots_ok(h, *old(st), rptr, rv, 0), rv.len() == rlen,
    ensures
        inv(*c, h, *final(st), *final(free) as int, 0),
        roots_ok(h, *final(st), rptr, rv, rlen as int),
{
    let mut i: usize = 0;
    while i < rlen
        invariant
            ctx_ok(*c), heap_ok(*c, h), rv.len() == rlen, i <= rlen,
            inv(*c, h, *st, *free as int, 0),
            roots_ok(h, *st, rptr, rv, i as int),
        decreases rlen - i,
    {
        proof {
            assert(slot_ok(st.rp, rptr, i as int));
            assert(st.rp[i as int].is_init());
            assert(val_ok(rv[i as int], h.objs.len() as int, true));
        }
        let w = rd(rptr, i, Tracked(&st.rp));
        let r = scav_word(c, w, free, Ghost(h), Ghost(rv[i as int]), Ghost(0), Ghost(rptr), Ghost(rv), Ghost(i as int), Tracked(st));
        let ghost s1 = *st;
        proof { assert(slot_ok(st.rp, rptr, i as int)); }
        wr(rptr, i, r, Tracked(&mut st.rp));
        proof {
            let s2 = *st;
            lemma_tp_same(*c, h, s1, s2, *free as int, 0);
            assert forall|k: int| 0 <= k < rlen implies #[trigger] slot_ok(s2.rp, rptr, k) by {
                assert(slot_ok(s1.rp, rptr, k));
            }
            assert forall|k: int| 0 <= k < rv.len() implies (#[trigger] s2.rp[k]).is_init()
                && s2.rp[k].value() == enc(if k < i + 1 { s2.addr2 } else { h.addr }, rv[k]) by {
                assert(slot_ok(s1.rp, rptr, k));
                if k != i { assert(s1.rp[k].is_init()); }
            }
            assert forall|k: int| 0 <= k < i + 1 implies closed(h, s2, #[trigger] rv[k]) by {
                if k != i { assert(closed(h, s1, rv[k])); }
                let v = rv[k];
                if v is Ref {
                    let jv = match v { AVal::Ref(jv) => jv, _ => 0 };
                    assert(copied(s1, jv) == copied(s2, jv));
                }
            }
        }
        i += 1;
    }
}

/// The scan loop (`scan_copied_chunk` over one to-space chunk, with the
/// copy pointer instead of a sentinel).
fn scan(c: &Ctx, free: &mut usize, Ghost(h): Ghost<H>, Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>,
        Tracked(st): Tracked<&mut St>)
    requires
        ctx_ok(*c), heap_ok(*c, h), inv(*c, h, *old(st), *old(free) as int, 0),
        roots_ok(h, *old(st), rptr, rv, rv.len() as int),
    ensures
        inv(*c, h, *final(st), *final(free) as int, *final(free) as int),
        roots_ok(h, *final(st), rptr, rv, rv.len() as int),
{
    let ghost nobj = h.objs.len() as int;
    let ghost rl = rv.len() as int;
    let mut sc: usize = 0;
    let ghost mut ks: int = 0;
    while sc < *free
        invariant
            ctx_ok(*c), heap_ok(*c, h),
            inv(*c, h, *st, *free as int, sc as int),
            roots_ok(h, *st, rptr, rv, rl),
            0 <= ks <= st.order.len(), sc == st.starts[ks],
            nobj == h.objs.len() as int, rl == rv.len() as int,
        decreases h.fused - sc,
    {
        let ghost s0 = *st;
        proof {
            assert(ks < s0.order.len());
            assert(young(h, s0.order[ks]));
            lemma_young_obj(*c, h, s0.order[ks]);
            assert(0 <= s0.starts[ks] && send(h, s0, ks) <= *free);
            assert(tval(s0, ks, 0).is_init());
            assert(slot_ok(s0.tp, c.tptr, sc as int));
        }
        let ghost jo = s0.order[ks];
        let ghost o = obj(h, jo);
        let hd = rd(c.tptr, sc, Tracked(&st.tp));
        proof { assert(hd == o.hdr); }
        let second = if (hd / 2) % 4 != 0 {
            proof {
                assert(tval(s0, ks, 1).is_init());
                assert(slot_ok(s0.tp, c.tptr, sc + 1));
            }
            rd(c.tptr, sc + 1, Tracked(&st.tp))
        } else {
            0
        };
        proof {
            if kind(hd) != 0 {
                assert(tval(s0, ks, 1).value() == wval(o, amap(h, s0, sc + 1, sc as int), 1));
                assert(second == (o.slots.len() - 1) as usize);
            }
        }
        let (lo, size) = layout(hd, second);
        let end = sc + size;
        proof {
            assert(size == words(o));
            assert(lo == ref_lo(o));
            assert(end == send(h, s0, ks));
            lemma_scan_skip(*c, h, s0, *free as int, sc as int, ks, lo as int);
        }
        let mut s = sc + lo;
        while s < end
            invariant
                ctx_ok(*c), heap_ok(*c, h),
                inv(*c, h, *st, *free as int, s as int),
                roots_ok(h, *st, rptr, rv, rl),
                0 <= ks < st.order.len(), st.order[ks] == jo, nobj == h.objs.len() as int, rl == rv.len() as int,
                st.starts[ks] == sc, o == obj(h, jo),
                sc + lo <= s <= end, end == sc + words(o), lo == ref_lo(o), obj_ok(o, nobj),
            decreases end - s,
        {
            let ghost s1 = *st;
            let ghost off = s - sc;
            proof {
                assert(0 <= s1.starts[ks] && send(h, s1, ks) <= *free);
                assert(tval(s1, ks, off).is_init());
                assert(slot_ok(s1.tp, c.tptr, s as int));
                lemma_slot(o, nobj, off);
            }
            let w = rd(c.tptr, s, Tracked(&st.tp));
            proof { assert(w == enc(h.addr, o.slots[off - 1])); }
            let r = scav_word(c, w, free, Ghost(h), Ghost(o.slots[off - 1]), Ghost(s as int), Ghost(rptr), Ghost(rv), Ghost(rl), Tracked(st));
            let ghost s2 = *st;
            proof {
                assert(slot_ok(s2.tp, c.tptr, s as int));
                assert(0 <= s2.starts[ks] && send(h, s2, ks) <= *free);
            }
            wr(c.tptr, s, r, Tracked(&mut st.tp));
            proof {
                let s3 = *st;
                assert forall|i: int| 0 <= i < c.tlen implies #[trigger] slot_ok(s3.tp, c.tptr, i) by {
                    assert(slot_ok(s2.tp, c.tptr, i));
                }
                lemma_scan_write(*c, h, s2, s3, *free as int, s as int, ks, o.slots[off - 1]);
                assert(roots_ok(h, s3, rptr, rv, rl));
            }
            s += 1;
        }
        proof {
            assert(send(h, *st, ks) == st.starts[ks + 1]);
        }
        sc = end;
        proof { ks = ks + 1; }
    }
}

/// A scavenge (`TwoSpaceHeap::do_scavenge` without finalizers, promotion
/// and the remembered set): the roots, then the scan. Returns the copy
/// pointer (the to-space words in use).
pub fn scavenge(c: &Ctx, rptr: *mut usize, rlen: usize, Ghost(h): Ghost<H>, Ghost(rv): Ghost<Seq<AVal>>,
                Tracked(st): Tracked<&mut St>) -> (free: usize)
    requires
        ctx_ok(*c), heap_ok(*c, h), from_ok(*c, h, old(st).fp), shape(old(st).tp, c.tptr, c.tlen as int),
        old(st).order == Seq::<int>::empty(), old(st).starts == seq![0int], old(st).pos == Map::<int, int>::empty(),
        old(st).addr2 == h.addr, old(st).used == Set::<int>::empty(),
        roots_ok(h, *old(st), rptr, rv, 0), rv.len() == rlen,
    ensures
        collected(*c, h, *final(st), free as int, rptr, rv),
{
    let mut free: usize = 0;
    proof {
        let s0 = *st;
        assert forall|j: int| 0 <= j < h.objs.len() implies #[trigger] s0.addr2[j] ==
            (if copied(s0, j) { taddr(*c, s0.starts[s0.pos[j]]) as usize } else { h.addr[j] }) by {}
        assert forall|j: int, off: int| young(h, j) && !copied(s0, j) && 0 <= off < words(obj(h, j)) implies
            (#[trigger] fval(s0.fp, h, j, off)).is_init() && fval(s0.fp, h, j, off).value() == wval(obj(h, j), h.addr, off) by {}
        assert(s0.used.subset_of(set_int_range(0, h.fused)));
        assert(inv(*c, h, s0, 0, 0));
    }
    scavenge_roots(c, rptr, rlen, &mut free, Ghost(h), Ghost(rv), Tracked(st));
    scan(c, &mut free, Ghost(h), Ghost(rptr), Ghost(rv), Tracked(st));
    proof { lemma_collected(*c, h, *st, free as int, rptr, rv); }
    free
}

/// The contract of a scavenge, in the core's terms (README, "The
/// property"): the abstract heap `h.objs` is not changed (ids are stable);
/// `live` (the copied ids) are young; each is at a distinct to-space
/// address below the copy pointer, where its words are its abstract words
/// encoded under the new address map `addr2`; the reference slots of the
/// copies and the roots refer to live or non-young objects; a non-young
/// object keeps its address.
pub open spec fn collected(c: Ctx, h: H, st: St, free: int, rptr: *mut usize, rv: Seq<AVal>) -> bool {
    &&& 0 <= free <= h.fused
    &&& st.addr2.len() == h.objs.len()
    &&& forall|j: int| 0 <= j < h.objs.len() && !young(h, j) ==> #[trigger] st.addr2[j] == h.addr[j] && !copied(st, j)
    &&& forall|j: int| #[trigger] copied(st, j) ==> young(h, j) && 0 <= st.starts[st.pos[j]]
            && st.starts[st.pos[j]] + words(obj(h, j)) <= free
            && st.addr2[j] == taddr(c, st.starts[st.pos[j]])
    &&& forall|j1: int, j2: int| #![trigger copied(st, j1), copied(st, j2)] copied(st, j1) && copied(st, j2) && j1 != j2 ==>
            st.starts[st.pos[j1]] + words(obj(h, j1)) <= st.starts[st.pos[j2]]
            || st.starts[st.pos[j2]] + words(obj(h, j2)) <= st.starts[st.pos[j1]]
    &&& forall|j: int, off: int| copied(st, j) && 0 <= off < words(obj(h, j)) ==>
            (#[trigger] st.tp[st.starts[st.pos[j]] + off]).is_init()
            && st.tp[st.starts[st.pos[j]] + off].value() == wval(obj(h, j), st.addr2, off)
            && (is_ref_slot(obj(h, j), off) ==> closed(h, st, obj(h, j).slots[off - 1]))
    &&& shape(st.rp, rptr, rv.len() as int)
    &&& forall|i: int| 0 <= i < rv.len() ==> (#[trigger] st.rp[i]).is_init()
            && st.rp[i].value() == enc(st.addr2, rv[i]) && closed(h, st, rv[i])
}

proof fn lemma_collected(c: Ctx, h: H, st: St, free: int, rptr: *mut usize, rv: Seq<AVal>)
    requires ctx_ok(c), heap_ok(c, h), inv(c, h, st, free, free), roots_ok(h, st, rptr, rv, rv.len() as int),
    ensures collected(c, h, st, free, rptr, rv),
{
    let n = st.order.len() as int;
    assert forall|j: int| 0 <= j < h.objs.len() && !young(h, j) implies #[trigger] st.addr2[j] == h.addr[j] && !copied(st, j) by {
        if copied(st, j) { assert(young(h, st.order[st.pos[j]])); }
    }
    assert forall|j: int| #[trigger] copied(st, j) implies young(h, j) && 0 <= st.starts[st.pos[j]]
        && st.starts[st.pos[j]] + words(obj(h, j)) <= free
        && st.addr2[j] == taddr(c, st.starts[st.pos[j]]) by {
        let k = st.pos[j];
        assert(young(h, st.order[k]));
        assert(0 <= st.starts[k] && send(h, st, k) <= free);
        lemma_w();
        lemma_mul_le(st.starts[k], c.tlen as int);
    }
    assert forall|j1: int, j2: int| #![trigger copied(st, j1), copied(st, j2)] copied(st, j1) && copied(st, j2) && j1 != j2 implies
        st.starts[st.pos[j1]] + words(obj(h, j1)) <= st.starts[st.pos[j2]]
        || st.starts[st.pos[j2]] + words(obj(h, j2)) <= st.starts[st.pos[j1]] by {
        let k1 = st.pos[j1];
        let k2 = st.pos[j2];
        if k1 < k2 { assert(send(h, st, k1) <= st.starts[k2]); }
        else { assert(send(h, st, k2) <= st.starts[k1]); }
    }
    assert forall|j: int, off: int| copied(st, j) && 0 <= off < words(obj(h, j)) implies
        (#[trigger] st.tp[st.starts[st.pos[j]] + off]).is_init()
        && st.tp[st.starts[st.pos[j]] + off].value() == wval(obj(h, j), st.addr2, off)
        && (is_ref_slot(obj(h, j), off) ==> closed(h, st, obj(h, j).slots[off - 1])) by {
        let k = st.pos[j];
        assert(tval(st, k, off).is_init());
        assert(0 <= st.starts[k] && send(h, st, k) <= free);
        if is_ref_slot(obj(h, j), off) { assert(closed(h, st, slot(h, st, k, off))); }
    }
}

} // verus!
