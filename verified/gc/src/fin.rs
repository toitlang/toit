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

//! Finalizers (milestone M4): the finalizer pass of a collection, as
//! src/heap_roots.cc's `weak_processing` does it after the first scan.
//!
//! The C++ gives the finalizer nodes as arrays (`Nodes`): the registered
//! callback finalizers (Toit finalizers, kind 0, and weak maps, kind 1),
//! the queue of runnable finalizers, and the VM finalizers (external
//! memory). The collector decides each node's fate (`KEEP`, `QUEUE`,
//! `DELETE`, `FREE`) and forwards its slots; the C++ list surgery (unlink,
//! move to the queue, delete, free the external memory) follows the
//! verdicts.
//!
//! Changes to from-space objects (a dead key's finalizer bit cleared, a
//! dead weak map reset) change the abstract heap: `lemma_modify` shows that
//! the invariant holds for the modified heap.

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
use crate::statement::{val_live, live};

verus! {

/// The finalizer bit of a header word (bit 4 of the smi value).
pub open spec fn fbit(h: usize) -> bool { (h / 32) % 2 == 1 }

pub open spec fn active(o: AObj) -> bool { fbit(hdr(o)) }

/// The heap with object `j` replaced by `o2`.
/// The number of copies.
pub open spec fn nc0(st: St) -> int { st.order.len() as int }

pub open spec fn with_obj(h: H, j: int, o2: AObj) -> H {
    H { objs: h.objs.update(j, o2), ..h }
}

/// `o2` may replace from-space object `o`: the same layout, well formed,
/// valid reference slots.
pub open spec fn same_shape(c: Ctx, n: int, o: AObj, o2: AObj) -> bool {
    &&& lay(o2) == lay(o)
    &&& obj_ok(o2)
    &&& cls_ok(c, o2)
    &&& forall|k: int| lay(o2).lo <= k < lay(o2).hi ==> #[trigger] slot_ok(c, n, o2.words[k])
}

/// The invariant holds for the heap with an uncopied from-space object
/// replaced by one of the same shape whose words are in from-space.
pub proof fn lemma_modify(c: Ctx, h: H, st: St, st2: St, t: Tos, ks: int, kc: int, rv: Seq<AVal>, rvp: Seq<AVal>,
                          rptr: *mut usize, ri: int, j: int, o2: AObj)
    requires
        ctx_ok(c), heap_ok(c, h), inv(c, h, st, t, ks, kc, rvp), roots_ok(c, h, st, rptr, rv, ri),
        from(h, j), !copied(st, j),
        same_shape(c, h.objs.len() as int, obj(h, j), o2),
        st2.tp == st.tp, st2.rp == st.rp, st2.ttp == st.ttp, st2.tup == st.tup, st2.order == st.order,
        st2.tloc == st.tloc, st2.pos == st.pos, st2.addr2 == st.addr2, st2.used == st.used,
        st2.words == st.words, st2.parent == st.parent, st2.tss == st.tss, st2.tus == st.tus,
        fshape(c, st2.fp),
        forall|q: (int, int)| !(q.0 == fpg(h, j) && foff(h, j) <= q.1 < foff(h, j) + size(h, j)) ==> #[trigger] st2.fp[q] == st.fp[q],
        forall|k: int| 0 <= k < size(h, j) ==> (#[trigger] st2.fp[fkey(h, j, k)]).is_init()
            && st2.fp[fkey(h, j, k)].value() == wval(o2, h.addr, k),
    ensures ({
        let h2 = with_obj(h, j, o2);
        &&& heap_ok(c, h2)
        &&& inv(c, h2, st2, t, ks, kc, rvp)
        &&& roots_ok(c, h2, st2, rptr, rv, ri)
        &&& forall|x: int| #[trigger] size(h2, x) == size(h, x)
    }),
{
    let h2 = with_obj(h, j, o2);
    let n = h.objs.len() as int;
    lemma_from_obj(c, h, j);
    assert forall|x: int| #[trigger] size(h2, x) == size(h, x) by {
        if x == j { assert(obj(h2, x) == o2); }
    }
    assert forall|x: int| #[trigger] from(h2, x) == from(h, x) by {}
    // The heap.
    assert forall|x: int| 0 <= x < n implies #[trigger] obj_ok(obj(h2, x)) by {
        if x != j { assert(obj_ok(obj(h, x))); }
    }
    assert forall|x: int| 0 <= x < n implies #[trigger] cls_ok(c, obj(h2, x)) by {
        if x != j { assert(cls_ok(c, obj(h, x))); }
    }
    assert forall|x: int| 0 <= x < n implies #[trigger] slots_ok(c, h2, x) by {
        if x != j { assert(slots_ok(c, h, x)); assert(obj(h2, x) == obj(h, x)); }
    }
    assert forall|x: int| #[trigger] from(h2, x) implies 0 <= x < n && fobj_ok(c, h2, x) by {
        assert(fobj_ok(c, h, x));
        assert(size(h2, x) == size(h, x));
    }
    assert forall|x1: int, x2: int| from(h2, x1) && from(h2, x2) && x1 != x2 implies #[trigger] fdisjoint(h2, x1, x2) by {
        assert(fdisjoint(h, x1, x2));
        assert(size(h2, x1) == size(h, x1) && size(h2, x2) == size(h, x2));
    }
    assert forall|x: int, k: int| 0 <= x < n && !from(h2, x) && lay(obj(h2, x)).lo <= k < lay(obj(h2, x)).hi implies
        #[trigger] prog_ref_ok(h2, obj(h2, x).words[k]) by {
        assert(x != j);
        assert(prog_ref_ok(h, obj(h, x).words[k]));
    }
    assert(heap_ok(c, h2));
    // The bookkeeping and the to-space do not see object j.
    assert forall|k: int| 0 <= k < st.order.len() implies from(h2, #[trigger] st2.order[k]) && st2.pos.contains_key(st2.order[k])
        && st2.pos[st2.order[k]] == k by {
        assert(from(h, st.order[k]));
    }
    assert forall|x: int| #[trigger] copied(st2, x) implies 0 <= st2.pos[x] < nc0(st) && st2.order[st2.pos[x]] == x by {
        assert(copied(st, x));
    }
    assert forall|x: int| 0 <= x < h2.objs.len() implies #[trigger] st2.addr2[x] ==
        (if copied(st2, x) { taddr(st2, st2.pos[x]) } else { h2.addr[x] }) by {
        assert(st.addr2[x] == (if copied(st, x) { taddr(st, st.pos[x]) } else { h.addr[x] }));
    }
    assert(bk_ok(h2, st2));
    assert forall|x: int, k: int| from(h2, x) && !copied(st2, x) && 0 <= k < size(h2, x) implies
        (#[trigger] st2.fp[fkey(h2, x, k)]).is_init() && st2.fp[fkey(h2, x, k)].value() == wval(obj(h2, x), h2.addr, k) by {
        assert(fkey(h2, x, k) == fkey(h, x, k));
        if x != j {
            lemma_extents_apart(c, h, x, j);
            assert(st.fp[fkey(h, x, k)].is_init());
            let q = fkey(h, x, k);
            assert(!(q.0 == fpg(h, j) && foff(h, j) <= q.1 < foff(h, j) + size(h, j))) by {
                if q.0 == fpg(h, j) && foff(h, j) <= q.1 < foff(h, j) + size(h, j) {
                    assert(q == fkey(h, j, q.1 - foff(h, j)));
                }
            }
        }
    }
    assert forall|x: int| from(h2, x) && #[trigger] copied(st2, x) implies
        st2.fp[fkey(h2, x, 0)].is_init() && st2.fp[fkey(h2, x, 0)].value() == st2.addr2[x] by {
        assert(x != j);
        assert(st.fp[fkey(h, x, 0)].is_init());
        lemma_extents_apart(c, h, x, j);
        lemma_from_obj(c, h, x);
        let q = fkey(h, x, 0);
        assert(!(q.0 == fpg(h, j) && foff(h, j) <= q.1 < foff(h, j) + size(h, j))) by {
            if q.0 == fpg(h, j) && foff(h, j) <= q.1 < foff(h, j) + size(h, j) {
                assert(q == fkey(h, j, q.1 - foff(h, j)));
            }
        }
    }
    assert(from_inv(c, h2, st2));
    let nc = st.order.len() as int;
    assert forall|k: int| 0 <= k < nc implies #[trigger] st.order[k] != j by {
        assert(copied(st, st.order[k]));
    }
    assert forall|k: int| 0 <= k < nc implies #[trigger] tsz(h2, st2, k) == tsz(h, st, k) by {}
    assert forall|k: int| 0 <= k < nc - 1 implies #[trigger] st2.tloc[k + 1] == succ(h2, st2, k, t.tn as int) by {
        assert(st.tloc[k + 1] == succ(h, st, k, t.tn as int));
        assert(tsz(h2, st2, k) == tsz(h, st, k));
    }
    assert forall|k: int| 0 <= k < nc implies 0 <= #[trigger] tpg(st2, k) < t.tn && 0 <= toff(st2, k)
        && tend(h2, st2, k) <= st2.tus[tpg(st2, k)] by {
        assert(0 <= tpg(st, k) < t.tn && 0 <= toff(st, k) && tend(h, st, k) <= st.tus[tpg(st, k)]);
    }
    assert forall|k1: int, k2: int| 0 <= k1 < k2 < nc implies #[trigger] before(h2, st2, k1, k2) by {
        assert(before(h, st, k1, k2));
        assert(tsz(h2, st2, k1) == tsz(h, st, k1));
    }
    if nc > 0 { assert(tsz(h2, st2, nc - 1) == tsz(h, st, nc - 1)); }
    assert(tcopies_ok(c, h2, st2, t));
    assert forall|p: int, x: int| 0 <= p < t.tn && 0 <= x < n && !from(h2, x) implies
        #[trigger] outside(st2.tss[p] as int, #[trigger] h2.addr[x] as int, c.pw as int) by {
        assert(outside(st.tss[p] as int, h.addr[x] as int, c.pw as int));
    }
    lemma_tpages_frame(c, h, st, st2, t);
    assert(tpages_ok(c, h2, st2, t)) by {
        assert forall|p: int, x: int| 0 <= p < t.tn && 0 <= x < h2.objs.len() && !from(h2, x) implies
            #[trigger] outside(st2.tss[p] as int, #[trigger] h2.addr[x] as int, c.pw as int) by {}
    }
    assert forall|kk: int, i: int| 0 <= kk < nc && 0 <= i < tsz(h2, st2, kk) implies
        (#[trigger] st2.tp[tkey(st2, kk, i)]).is_init()
        && st2.tp[tkey(st2, kk, i)].value() == wval(obj(h2, st2.order[kk]), amap(h2, st2, kk, i, ks, kc), i) by {
        assert(st.tp[tkey(st, kk, i)].is_init());
        assert(obj(h2, st.order[kk]) == obj(h, st.order[kk]));
    }
    assert forall|kk: int, i: int| 0 <= kk < nc && 0 <= i < tsz(h2, st2, kk) && processed(kk, i, ks, kc)
        && is_ref(obj(h2, st2.order[kk]), i) implies closed(h2, st2, #[trigger] obj(h2, st2.order[kk]).words[i]) by {
        assert(obj(h2, st.order[kk]) == obj(h, st.order[kk]));
        assert(closed(h, st, obj(h, st.order[kk]).words[i]));
    }
    assert(to_inv(c, h2, st2, ks, kc));
    assert forall|x: int| #[trigger] from(h2, x) && !copied(st2, x) implies st2.used.disjoint(extent(c, h2, x)) by {
        assert(st.used.disjoint(extent(c, h, x)));
        assert(extent(c, h2, x) == extent(c, h, x));
    }
    assert(cap_ok(c, h2, st2, t));
    assert forall|k: int| 0 <= k < nc implies #[trigger] parent_ok(h2, st2, rvp, k) by {
        assert(parent_ok(h, st, rvp, k));
        let p = st.parent[k].0;
        if p >= 0 { assert(obj(h2, st.order[p]) == obj(h, st.order[p])); }
    }
    assert(par_ok(h2, st2, rvp));
    assert forall|i: int| 0 <= i < rv.len() implies #[trigger] slot_ok(c, h2.objs.len() as int, rv[i]) by {
        assert(slot_ok(c, n, rv[i]));
    }
    assert forall|i: int| 0 <= i < rv.len() implies (#[trigger] st2.rp[i]).is_init()
        && st2.rp[i].value() == enc(if i < ri { st2.addr2 } else { h2.addr }, rv[i]) by {
        assert(st.rp[i].is_init());
    }
    assert forall|i: int| 0 <= i < ri implies closed(h2, st2, #[trigger] rv[i]) by {
        assert(closed(h, st, rv[i]));
    }
    assert forall|i: int| 0 <= i < rv.len() implies #[trigger] wperm_ok(st2.rp, i, rptr, i) by {
        assert(wperm_ok(st.rp, i, rptr, i));
    }
}

// ---------------------------------------------------------------------------
// A key's status, and the modifications of dead keys.

/// Object `j` with its finalizer bit cleared.
pub open spec fn cleared(o: AObj) -> AObj {
    AObj { words: o.words.update(0, AVal::Raw((hdr(o) - 32) as usize)), ..o }
}

/// A weak map with its contents dropped (`WeakMapFinalizerNode::
/// weak_processing` for an unreachable map: size and spaces left 0, index
/// and backing null).
pub open spec fn reset(o: AObj, nullid: int) -> AObj {
    AObj { words: o.words.update(1, AVal::Raw(0)).update(2, AVal::Raw(0)).update(3, AVal::Ref(nullid)).update(4, AVal::Ref(nullid)), ..o }
}

/// Clearing the finalizer bit changes neither the class tag nor the class
/// id of a header.
pub proof fn lemma_clear_bit(h: usize)
    requires fbit(h),
    ensures
        htag((h - 32) as usize) == htag(h), hcid((h - 32) as usize) == hcid(h),
        ((h - 32) as usize) % 2 == h % 2, !fbit((h - 32) as usize), h >= 32,
        h & 32 == 32,
{
    assert((h / 32) % 2 == 1 ==> h & 32usize == 32usize) by (bit_vector);
    assert(h & 32usize == 32usize ==> ((((h - 32) as usize) >> 1usize) & 15usize == (h >> 1usize) & 15usize
        && ((h - 32) as usize) >> 6usize == h >> 6usize && h >= 32)) by (bit_vector);
    assert(h & 32usize == 32usize ==> (((h - 32) as usize) / 32) % 2 == 0) by (bit_vector);
    assert(h & 32usize == 32usize ==> ((h - 32) as usize) % 2 == h % 2) by (bit_vector);
}

/// What a key is: a from-space object not copied (dead), its finalizer bit.
pub open spec fn key_dead(h: H, st: St, v: AVal) -> bool {
    match v {
        AVal::Ref(j) => from(h, j) && !copied(st, j),
        _ => false,
    }
}

pub open spec fn key_active(h: H, v: AVal) -> bool {
    match v {
        AVal::Ref(j) => from(h, j) && active(obj(h, j)),
        _ => false,
    }
}

/// The status of the key holding `w` (the encoding of `v` under the old
/// address map): dead (an uncopied from-space object; then its page start
/// and offset), active (a from-space object with its finalizer bit: read
/// from the copy if it is copied, as `HeapObject::has_active_finalizer`
/// follows the forwarding header). Objects outside from-space have no
/// finalizers (no object of a program image has the bit: LAYOUT.toml).
pub fn key_status(c: &Ctx, w: usize, Ghost(h): Ghost<H>, Ghost(v): Ghost<AVal>, Ghost(t): Ghost<Tos>,
                  Ghost(ks): Ghost<int>, Ghost(kc): Ghost<int>, Ghost(rv): Ghost<Seq<AVal>>,
                  Tracked(st): Tracked<&St>, Tracked(ro): Tracked<&Ro>) -> (r: (bool, bool, usize, usize, usize))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h),
        inv(*c, h, *st, t, ks, kc, rv),
        w == enc(h.addr, v), slot_ok(*c, h.objs.len() as int, v),
    ensures
        r.0 == key_dead(h, *st, v),
        r.1 == key_active(h, v),
        r.0 ==> v is Ref && r.2 == fs(*c, fpg(h, v->Ref_0)) && r.3 == foff(h, v->Ref_0),
        !r.0 ==> r.4 == enc(st.addr2, v),
{
    let ghost j = match v { AVal::Ref(j) => j, _ => -1 };
    proof {
        if j >= 0 && from(h, j) { crate::collect::lemma_from_addr(*c, h, j); }
        if j >= 0 && !from(h, j) {
            assert(0 <= j < h.objs.len());
            assert(!in_from(*c, h.addr[j]));
        }
    }
    if w % 2 == 1 {
        let pi = find_page(c, w, Tracked(&ro.ftp));
        if pi < c.nf {
            proof {
                assert(in_from(*c, w));
                assert(v is Ref);
                assert(from(h, j));
                crate::collect::lemma_one_page(*c, pi as int, fpg(h, j), w);
                lemma_from_obj(*c, h, j);
            }
            let s = ftab_at(c, pi, Tracked(&ro.ftp));
            proof { crate::collect::lemma_offset(s as int, foff(h, j)); }
            let off = (w - 1 - s) / W;
            proof {
                lemma_w();
                assert(off == foff(h, j));
                assert(fkey(h, j, 0) == (pi as int, off as int));
                assert(wperm_ok(st.fp, (pi as int, off as int), fptr(*c, pi as int), off as int));
                assert(off * W <= pbytes(*c)) by (nonlinear_arith) requires off <= c.pw, W >= 1;
                assert(st.fp[fkey(h, j, 0)].is_init());
                if copied(*st, j) {
                    let k = st.pos[j];
                    assert(0 <= k < st.order.len() && st.order[k] == j);
                    assert(0 <= tpg(*st, k) < t.tn && 0 <= toff(*st, k));
                    assert(st.tss[tpg(*st, k)] % W == 0);
                    crate::collect::lemma_tag_odd(st.tss[tpg(*st, k)] as int, toff(*st, k));
                } else {
                    assert(obj(h, j).words[0] is Raw);
                }
            }
            let fpage = c.base.with_addr(s);
            let hd = rd(fpage, off, Ghost((pi as int, off as int)), Tracked(&st.fp));
            if hd % 2 == 1 {
                // Copied: the header is the copy's.
                let ghost k = st.pos[j];
                proof {
                    assert(st.addr2[j] == taddr(*st, k));
                    assert(0 <= tpg(*st, k) < t.tn && 0 <= toff(*st, k) && tend(h, *st, k) <= st.tus[tpg(*st, k)]);
                    assert(st.tus[tpg(*st, k)] <= c.pw - 1);
                    assert(st.tss[tpg(*st, k)] + pbytes(*c) < usize::MAX);
                    assert(toff(*st, k) * W < pbytes(*c)) by (nonlinear_arith) requires toff(*st, k) < c.pw, W >= 1;
                    assert(wperm_ok(st.tp, (tpg(*st, k), toff(*st, k)), tptr(*c, *st, tpg(*st, k)), toff(*st, k)));
                    assert(tkey(*st, k, 0) == (tpg(*st, k), toff(*st, k)));
                    assert(st.tp[tkey(*st, k, 0)].is_init());
                    assert(obj(h, j).words[0] is Raw);
                    assert(at(ppage(*c, (hd - 1) as int), 0) == at(tptr(*c, *st, tpg(*st, k)), toff(*st, k)));
                }
                let copy = c.base.with_addr(hd - 1);
                let ch = rd(copy, 0, Ghost((tpg(*st, k), toff(*st, k))), Tracked(&st.tp));
                (false, (ch / 32) % 2 == 1, s, off, hd)
            } else {
                (true, (hd / 32) % 2 == 1, s, off, w)
            }
        } else {
            proof {
                if j >= 0 && from(h, j) { assert(in_fpage(*c, fpg(h, j), w)); assert(false); }
            }
            proof { if j >= 0 { assert(st.addr2[j] == h.addr[j]); } }
            (false, false, 0, 0, w)
        }
    } else {
        proof {
            if j >= 0 && from(h, j) { assert(false); }
            if j >= 0 { assert(st.addr2[j] == h.addr[j]); }
        }
        (false, false, 0, 0, w)
    }
}

/// An object the weak-map reset can write: an instance (or task) with at
/// least the map's four fields.
pub open spec fn resettable(o: AObj) -> bool { lay(o).lo == 1 && lay(o).hi >= 5 }

/// A dead key after the finalizer pass: its finalizer bit cleared, a weak
/// map's contents dropped first.
pub open spec fn killed(o: AObj, nullid: int, rst: bool) -> AObj {
    if rst && resettable(o) { cleared(reset(o, nullid)) } else { cleared(o) }
}

/// The killed key has the key's shape.
pub proof fn lemma_killed_shape(c: Ctx, h: H, j: int, rst: bool)
    requires ctx_ok(c), heap_ok(c, h), from(h, j), active(obj(h, j)),
    ensures same_shape(c, h.objs.len() as int, obj(h, j), killed(obj(h, j), c.nullid@, rst)),
{
    let o = obj(h, j);
    let o2 = killed(o, c.nullid@, rst);
    lemma_from_obj(c, h, j);
    assert(o.words[0] is Raw);
    lemma_clear_bit(hdr(o));
    let n = h.objs.len() as int;
    assert(slots_ok(c, h, j));
    assert(cls_ok(c, o));
    assert(o2.cbits == o.cbits && o2.sw == o.sw && o2.words.len() == o.words.len());
    if rst && resettable(o) {
        let r = reset(o, c.nullid@);
        assert(hdr(r) == hdr(o));
        assert(htag(hdr(o)) == INSTANCE_TAG || htag(hdr(o)) == TASK_TAG) by {
            if !(htag(hdr(o)) == INSTANCE_TAG || htag(hdr(o)) == TASK_TAG) {
                assert(lay(o).lo != 1 || lay(o).hi < 5);
            }
        }
        assert(lay(r) == lay(o));
        assert(hdr(o2) == (hdr(o) - 32) as usize);
        assert(lay(o2) == lay(o));
        assert forall|k: int| lay(o2).lo <= k < lay(o2).hi implies #[trigger] slot_ok(c, n, o2.words[k]) by {
            if k > 4 { assert(o2.words[k] == o.words[k]); assert(slot_ok(c, n, o.words[k])); }
        }
        assert forall|k: int| 0 <= k < lay(o2).size && !(lay(o2).lo <= k < lay(o2).hi) implies #[trigger] o2.words[k] is Raw by {
            if k != 0 { assert(o2.words[k] == o.words[k]); }
        }
    } else {
        assert(hdr(o2) == (hdr(o) - 32) as usize);
        assert(lay(o2) == lay(o)) by {
            assert(o2.words[1] == o.words[1]);
            assert(o2.words[2] == o.words[2]);
            assert(o2.words[3] == o.words[3]);
        }
        assert forall|k: int| lay(o2).lo <= k < lay(o2).hi implies #[trigger] slot_ok(c, n, o2.words[k]) by {
            assert(o2.words[k] == o.words[k]);
            assert(slot_ok(c, n, o.words[k]));
        }
        assert forall|k: int| 0 <= k < lay(o2).size && !(lay(o2).lo <= k < lay(o2).hi) implies #[trigger] o2.words[k] is Raw by {
            if k != 0 { assert(o2.words[k] == o.words[k]); }
        }
    }
    assert(lay(o2) == lay(o));
    assert(obj_ok(o2));
    assert(cls_ok(c, o2));
}

/// Kills the dead key `j` (an uncopied from-space object with its finalizer
/// bit, at offset `off` of the page at `s`): `killed`, in from-space.
pub fn kill_key(c: &Ctx, s: usize, off: usize, rst: bool, Ghost(h): Ghost<H>, Ghost(j): Ghost<int>, Ghost(t): Ghost<Tos>,
                Ghost(ks): Ghost<int>, Ghost(kc): Ghost<int>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                Ghost(rptr): Ghost<*mut usize>, Ghost(ri): Ghost<int>, Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>)
    requires
        ctx_ok(*c), fpages_ok(*c), heap_ok(*c, h), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), t, ks, kc, rvp), roots_ok(*c, h, *old(st), rptr, rv, ri),
        from(h, j), !copied(*old(st), j), active(obj(h, j)), s == fs(*c, fpg(h, j)), off == foff(h, j),
    ensures ({
        let h2 = with_obj(h, j, killed(obj(h, j), c.nullid@, rst));
        &&& heap_ok(*c, h2)
        &&& inv(*c, h2, *final(st), t, ks, kc, rvp)
        &&& roots_ok(*c, h2, *final(st), rptr, rv, ri)
        &&& forall|x: int| #[trigger] size(h2, x) == size(h, x)
        &&& final(st).tp == old(st).tp && final(st).rp == old(st).rp && final(st).ttp == old(st).ttp
        &&& final(st).tup == old(st).tup && final(st).order == old(st).order && final(st).tloc == old(st).tloc
        &&& final(st).pos == old(st).pos && final(st).addr2 == old(st).addr2 && final(st).used == old(st).used
        &&& final(st).words == old(st).words && final(st).parent == old(st).parent
        &&& final(st).tss == old(st).tss && final(st).tus == old(st).tus
    }),
{
    let ghost s0 = *st;
    let ghost o = obj(h, j);
    let ghost pg = fpg(h, j);
    let ghost o2 = killed(o, c.nullid@, rst);
    proof {
        lemma_w();
        lemma_from_obj(*c, h, j);
        lemma_killed_shape(*c, h, j, rst);
        lemma_clear_bit(hdr(o));
        assert(fs(*c, pg) + pbytes(*c) < usize::MAX);
        assert(o.words[0] is Raw);
        assert(fkey(h, j, 0) == (pg, off as int));
        assert(s0.fp[fkey(h, j, 0)].is_init());
        assert(wperm_ok(s0.fp, (pg, off as int), fptr(*c, pg), off as int));
        assert(off * W <= pbytes(*c)) by (nonlinear_arith) requires off <= c.pw, W >= 1;
        assert forall|k: int| 0 <= k < lay(o).size && #[trigger] o.words[k] is Raw implies
            wperm_ok(s0.fp, (pg, off + k), fptr(*c, pg), off + k) && s0.fp[(pg, off + k)].is_init()
            && s0.fp[(pg, off + k)].value() == raw(o.words[k]) by {
            assert(wperm_ok(s0.fp, (pg, off + k), fptr(*c, pg), off + k));
            assert(fkey(h, j, k) == (pg, off + k));
            assert(s0.fp[fkey(h, j, k)].is_init());
        }
    }
    let fpage = c.base.with_addr(s);
    let hd = rd(fpage, off, Ghost((pg, off as int)), Tracked(&st.fp));
    let mut did_reset = false;
    if rst {
        let (_sz, lo, hi) = obj_layout(c, fpage, off, Ghost(pg), Tracked(&st.fp), Ghost(o), Ghost(c.pw as int), Tracked(&ro.ctp));
        if lo == 1 && hi >= 5 {
            proof {
                assert forall|k: int| 1 <= k <= 4 implies #[trigger] wperm_ok(st.fp, (pg, off + k), fptr(*c, pg), off + k) by {}
                assert((off + 4) * W <= pbytes(*c)) by (nonlinear_arith) requires off + 4 <= c.pw, W >= 1;
                assert((off + 1) * W <= pbytes(*c)) by (nonlinear_arith) requires off + 1 <= c.pw, W >= 1;
                assert((off + 2) * W <= pbytes(*c)) by (nonlinear_arith) requires off + 2 <= c.pw, W >= 1;
                assert((off + 3) * W <= pbytes(*c)) by (nonlinear_arith) requires off + 3 <= c.pw, W >= 1;
            }
            wr(fpage, off + 1, 0, Ghost((pg, off + 1)), Tracked(&mut st.fp));
            proof { assert(wperm_ok(s0.fp, (pg, off + 2), fptr(*c, pg), off + 2)); }
            wr(fpage, off + 2, 0, Ghost((pg, off + 2)), Tracked(&mut st.fp));
            proof { assert(wperm_ok(s0.fp, (pg, off + 3), fptr(*c, pg), off + 3)); }
            wr(fpage, off + 3, c.null, Ghost((pg, off + 3)), Tracked(&mut st.fp));
            proof { assert(wperm_ok(s0.fp, (pg, off + 4), fptr(*c, pg), off + 4)); }
            wr(fpage, off + 4, c.null, Ghost((pg, off + 4)), Tracked(&mut st.fp));
            did_reset = true;
        }
    }
    proof { assert(wperm_ok(st.fp, (pg, off as int), fptr(*c, pg), off as int)); }
    wr(fpage, off, hd - 32, Ghost((pg, off as int)), Tracked(&mut st.fp));
    proof {
        let s2 = *st;
        assert(did_reset == (rst && resettable(o)));
        assert forall|i: int, k: int| 0 <= i < c.nf && 0 <= k < c.pw implies #[trigger] wperm_ok(s2.fp, (i, k), fptr(*c, i), k) by {
            assert(wperm_ok(s0.fp, (i, k), fptr(*c, i), k));
        }
        assert forall|q: (int, int)| !(q.0 == fpg(h, j) && foff(h, j) <= q.1 < foff(h, j) + size(h, j)) implies
            #[trigger] s2.fp[q] == s0.fp[q] by {
            assert(size(h, j) >= 5 || !did_reset);
        }
        assert forall|k: int| 0 <= k < size(h, j) implies (#[trigger] s2.fp[fkey(h, j, k)]).is_init()
            && s2.fp[fkey(h, j, k)].value() == wval(o2, h.addr, k) by {
            assert(fkey(h, j, k) == (pg, off + k));
            if !(k == 0 || (did_reset && 1 <= k <= 4)) {
                assert(s0.fp[fkey(h, j, k)].is_init());
                assert(o2.words[k] == o.words[k]);
            }
        }
        lemma_modify(*c, h, s0, s2, t, ks, kc, rv, rvp, rptr, ri, j, o2);
    }
}

// ---------------------------------------------------------------------------
// The finalizer nodes.

/// Node kinds: a registered Toit finalizer, a registered weak map, the same
/// two in the queue of runnable finalizers, a VM finalizer.
pub const KIND_TOIT: usize = 0;
pub const KIND_WEAK: usize = 1;
pub const KIND_TOIT_QUEUED: usize = 2;
pub const KIND_WEAK_QUEUED: usize = 3;
pub const KIND_VM: usize = 4;

/// Verdicts: keep the node (its key and lambda forwarded), move it to the
/// queue (a Toit finalizer whose key died: its lambda runs), delete it,
/// free the key's external memory and delete it (a VM finalizer whose key
/// died).
pub const KEEP: usize = 0;
pub const QUEUE: usize = 1;
pub const DELETE: usize = 2;
pub const FREE: usize = 3;

/// A node: its kind, the values of its key and lambda (`Raw(0)` for a VM
/// finalizer's lambda).
pub struct Node {
    pub kind: usize,
    pub key: AVal,
    pub lam: AVal,
}

/// The node array: four words per node (kind, key, lambda, verdict).
pub open spec fn nodes_mem(np: Map<int, PointsTo<usize>>, nptr: *mut usize, nn: int) -> bool {
    &&& nptr@.addr + 4 * nn * W <= usize::MAX
    &&& forall|m: int| 0 <= m < 4 * nn ==> #[trigger] wperm_ok(np, m, nptr, m)
}

/// Node `i`'s words as the C++ wrote them.
pub open spec fn node_in(np: Map<int, PointsTo<usize>>, h: H, nd: Node, i: int) -> bool {
    &&& np[4 * i].is_init() && np[4 * i].value() == nd.kind
    &&& np[4 * i + 1].is_init() && np[4 * i + 1].value() == enc(h.addr, nd.key)
    &&& np[4 * i + 2].is_init() && np[4 * i + 2].value() == enc(h.addr, nd.lam)
}

/// A key that was dead after the first scan: a from-space object no strong
/// root reaches (`main`: the objects copied by then).
pub open spec fn dead_main(h: H, v: AVal, main: Set<int>) -> bool {
    match v {
        AVal::Ref(j) => from(h, j) && !main.contains(j),
        _ => false,
    }
}

/// The fate of a node (heap `h0` before the finalizer pass, `h` and `st`
/// after): verdict `d`, key word `kw`, lambda word `lw`.
pub open spec fn fate(c: Ctx, h0: H, h: H, st: St, main: Set<int>, nd: Node, d: usize, kw: usize, lw: usize) -> bool {
    let kv = nd.key;
    let lv = nd.lam;
    if nd.kind == KIND_TOIT_QUEUED {
        d == KEEP && val_live(h, st, kv) && kw == enc(st.addr2, kv) && val_live(h, st, lv) && lw == enc(st.addr2, lv)
    } else if nd.kind == KIND_VM {
        ||| (d == KEEP && key_active(h, kv) && val_live(h, st, kv) && kw == enc(st.addr2, kv))
        ||| (d == DELETE && !key_active(h, kv))
        ||| (d == FREE && key_active(h, kv) && key_dead(h, st, kv))
    } else {
        ||| (d == KEEP && key_active(h, kv) && val_live(h, st, kv) && kw == enc(st.addr2, kv)
                && val_live(h, st, lv) && lw == enc(st.addr2, lv))
        ||| (d == DELETE && !key_active(h, kv))
        ||| (d == QUEUE && nd.kind == KIND_TOIT && dead_main(h0, kv, main) && key_active(h0, kv)
                && obj(h, kv->Ref_0) == killed(obj(h0, kv->Ref_0), c.nullid@, false)
                && kw == c.null && val_live(h, st, lv) && lw == enc(st.addr2, lv))
        ||| (d == DELETE && nd.kind != KIND_TOIT && dead_main(h0, kv, main) && key_active(h0, kv)
                && obj(h, kv->Ref_0) == killed(obj(h0, kv->Ref_0), c.nullid@, true))
    }
}

pub open spec fn node_out(c: Ctx, h0: H, h: H, st: St, main: Set<int>, np: Map<int, PointsTo<usize>>, nd: Node, i: int) -> bool {
    &&& np[4 * i].is_init() && np[4 * i].value() == nd.kind
    &&& np[4 * i + 1].is_init() && np[4 * i + 2].is_init() && np[4 * i + 3].is_init()
    &&& fate(c, h0, h, st, main, nd, np[4 * i + 3].value(), np[4 * i + 1].value(), np[4 * i + 2].value())
}

/// The heap during the finalizer pass: the objects of `h0`, some killed
/// (and then without their finalizer bit).
pub open spec fn heap_from(c: Ctx, h0: H, h: H) -> bool {
    &&& h.loc == h0.loc && h.addr == h0.addr && h.objs.len() == h0.objs.len()
    &&& forall|x: int| 0 <= x < h.objs.len() ==> #[trigger] obj(h, x) == obj(h0, x) || !active(obj(h, x))
}

/// A fate stays true when the state grows and a dead active key is killed.
pub proof fn lemma_fate_frame(c: Ctx, h0: H, h: H, st: St, h2: H, st2: St, main: Set<int>, nd: Node, d: usize, kw: usize, lw: usize)
    requires
        fate(c, h0, h, st, main, nd, d, kw, lw), nd.kind != KIND_VM,
        grows(h, st, st2), st.addr2.len() == h.objs.len(),
        st2.addr2.len() == st.addr2.len(),
        h2.loc == h.loc, h2.addr == h.addr, h2.objs.len() == h.objs.len(),
        forall|x: int| 0 <= x < h.objs.len() && #[trigger] obj(h2, x) != obj(h, x) ==> active(obj(h, x)) && from(h, x) && !copied(st, x),
        forall|x: int| 0 <= x < h0.objs.len() ==> (#[trigger] obj(h0, x)).words.len() >= 1,
        h0.objs.len() == h.objs.len(),
        nd.key matches AVal::Ref(j) ==> 0 <= j < h.objs.len(),
        nd.lam matches AVal::Ref(j) ==> 0 <= j < h.objs.len(),
    ensures fate(c, h0, h2, st2, main, nd, d, kw, lw),
{
    assert forall|v: AVal| #[trigger] val_live(h, st, v) implies val_live(h2, st2, v) && enc(st2.addr2, v) == enc(st.addr2, v) by {
        if v is Ref {
            let j = v->Ref_0;
            if copied(st, j) { assert(copied(st2, j)); }
            assert(st2.addr2[j] == st.addr2[j]);
        }
    }
    if nd.key is Ref {
        let j = nd.key->Ref_0;
        if key_active(h, nd.key) && val_live(h, st, nd.key) {
            assert(obj(h2, j) == obj(h, j));
        }
        if !key_active(h, nd.key) && from(h, j) {
            assert(obj(h2, j) == obj(h, j));
        }
        if d == QUEUE && nd.kind == KIND_TOIT && dead_main(h0, nd.key, main) && key_active(h0, nd.key) {
            lemma_clear_bit(hdr(obj(h0, j)));
            assert(obj(h0, j).words.len() >= 1);
            assert(hdr(obj(h, j)) == (hdr(obj(h0, j)) - 32) as usize);
            assert(!active(obj(h, j)));
            assert(obj(h2, j) == obj(h, j));
        }
    }
}

} // verus!
