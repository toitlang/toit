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

//! Weak maps (src/heap_roots.cc, `WeakMapFinalizerNode::weak_processing`
//! and `zap_dead_values`, as the C++ prototype runs them in a copying
//! collection): before the collection the index and backing fields of
//! every weak map with a node are moved into the node (`hide_maps`), so the
//! main scan does not trace them; after the main scan (`weak_pass`) each
//! surviving map's dead values (the odd entries of its backing list's
//! array that are from-space objects not copied, not tombstones) are
//! nulled, the hidden fields are forwarded and written back; each dead
//! map is reset. The proved Cheney core is unchanged.

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::space::*;
use crate::cheney::*;
use crate::copy::*;
use crate::collect::*;
use crate::fin::*;

verus! {

/// A weak map with its index and backing hidden (smi 0).
pub open spec fn hidden(o: AObj) -> AObj {
    AObj { words: o.words.update(3, AVal::Raw(0)).update(4, AVal::Raw(0)), ..o }
}

/// The hidden fields back.
pub open spec fn unhide(o: AObj, ix: AVal, bk: AVal) -> AObj {
    AObj { words: o.words.update(3, ix).update(4, bk), ..o }
}

/// An object the collector treats as a weak map: an instance of the map
/// class with its finalizer bit and at least the map's four fields.
pub open spec fn weak_map(c: Ctx, o: AObj) -> bool {
    &&& htag(hdr(o)) == INSTANCE_TAG && active(o) && hcid(hdr(o)) == c.map_cid
    &&& lay(o).lo == 1 && lay(o).hi >= 5
}

/// The callback nodes' keys in from-space: distinct, instances (the C++:
/// `add_finalizer` refuses a key with an active finalizer and takes only
/// instances; a queued Toit finalizer's key is null).
pub open spec fn keys_ok(h: H, nodes: Seq<Node>, ncb: int) -> bool {
    &&& forall|m1: int, m2: int| 0 <= m1 < ncb && 0 <= m2 < ncb && m1 != m2 && #[trigger] nodes[m1].key == #[trigger] nodes[m2].key
            ==> !(nodes[m1].key is Ref && from(h, nodes[m1].key->Ref_0))
    &&& forall|m: int| 0 <= m < ncb && (#[trigger] nodes[m]).key is Ref && from(h, nodes[m].key->Ref_0)
            ==> htag(hdr(obj(h, nodes[m].key->Ref_0))) == INSTANCE_TAG
}

/// The heap with the weak maps' fields hidden, and the nodes holding them.
pub open spec fn hide_ok(c: Ctx, h: H, hs: H, nodes: Seq<Node>, nodes2: Seq<Node>, ncb: int) -> bool {
    &&& hs.loc == h.loc && hs.addr == h.addr && hs.objs.len() == h.objs.len()
    &&& nodes2.len() == nodes.len()
    &&& forall|m: int| 0 <= m < nodes.len() ==> #[trigger] nodes2[m] == (Node { ix: nodes2[m].ix, bk: nodes2[m].bk, hid: nodes2[m].hid, ..nodes[m] })
    &&& forall|m: int| 0 <= m < nodes.len() && !(#[trigger] nodes2[m]).hid ==> nodes2[m].ix == nodes[m].ix && nodes2[m].bk == nodes[m].bk
    &&& forall|m: int| 0 <= m < nodes.len() && (#[trigger] nodes2[m]).hid ==> 0 <= m < ncb
            && (nodes[m].kind == KIND_WEAK || nodes[m].kind == KIND_WEAK_QUEUED)
            && nodes[m].key is Ref && from(h, nodes[m].key->Ref_0) && weak_map(c, obj(h, nodes[m].key->Ref_0))
            && nodes2[m].ix == obj(h, nodes[m].key->Ref_0).words[3] && nodes2[m].bk == obj(h, nodes[m].key->Ref_0).words[4]
            && obj(hs, nodes[m].key->Ref_0) == hidden(obj(h, nodes[m].key->Ref_0))
    &&& forall|x: int| #![trigger obj(hs, x)] 0 <= x < h.objs.len() ==> obj(hs, x) == obj(h, x)
            || exists|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes[m].key == AVal::Ref(x)
}

/// Word `k` of the uncopied from-space object `j` (at offset `off` of the
/// page starting at `s`).
pub fn fword(c: &Ctx, s: usize, off: usize, k: usize, Ghost(h): Ghost<H>, Ghost(j): Ghost<int>,
             Tracked(fp): Tracked<&Map<(int, int), PointsTo<usize>>>) -> (v: usize)
    requires
        ctx_ok(*c), fpages_ok(*c), heap_ok(*c, h), fshape(*c, *fp),
        from(h, j), s == fs(*c, fpg(h, j)), off == foff(h, j), 0 <= k < size(h, j),
        fp[fkey(h, j, k as int)].is_init(),
    ensures v == fp[fkey(h, j, k as int)].value(),
{
    proof {
        lemma_w();
        lemma_from_obj(*c, h, j);
        assert(fs(*c, fpg(h, j)) + pbytes(*c) < usize::MAX);
        assert(fkey(h, j, k as int) == (fpg(h, j), off + k));
        assert(wperm_ok(*fp, (fpg(h, j), off + k), fptr(*c, fpg(h, j)), off + k));
        assert((off + k) * W <= pbytes(*c)) by (nonlinear_arith) requires off + k <= c.pw, W >= 1;
    }
    let page = c.base.with_addr(s);
    rd(page, off + k, Ghost((fpg(h, j), (off + k) as int)), Tracked(fp))
}

/// `inv` with nothing copied does not depend on the parent roots.
pub proof fn lemma_inv_rvp(c: Ctx, h: H, st: St, t: Tos, rvp1: Seq<AVal>, rvp2: Seq<AVal>)
    requires inv(c, h, st, t, 0, 0, rvp1), st.order.len() == 0,
    ensures inv(c, h, st, t, 0, 0, rvp2),
{
}


/// Hides the index and backing of node `m`'s key if it is a weak map in
/// from-space (into node words 4 and 5) and marks the node.
pub fn hide_one(c: &Ctx, t: &Tos, nptr: *mut usize, m: usize, nn: usize, Ghost(h): Ghost<H>, Ghost(nd): Ghost<Node>,
                Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>,
                Tracked(np): Tracked<&mut Map<int, PointsTo<usize>>>) -> (r: (Ghost<H>, Ghost<Node>))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *t, 0, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, 0), old(st).order.len() == 0,
        m < nn, nodes_mem(*old(np), nptr, nn as int), node_in(*old(np), h, nd, m as int),
        slot_ok(*c, h.objs.len() as int, nd.key), nd.kind <= KIND_WEAK_QUEUED,
    ensures ({
        let h2 = r.0@;
        let nd2 = r.1@;
        &&& heap_ok(*c, h2) && others_ok(h2, ro.others)
        &&& inv(*c, h2, *final(st), *t, 0, 0, rvp) && roots_ok(*c, h2, *final(st), rptr, rv, 0)
        &&& *final(st) == (St { fp: final(st).fp, ..*old(st) })
        &&& nodes_mem(*final(np), nptr, nn as int)
        &&& forall|q: int| !(6 * m <= q < 6 * m + 6) ==> #[trigger] final(np)[q] == old(np)[q]
        &&& final(np)[6 * m] == old(np)[6 * m] && final(np)[6 * m + 1] == old(np)[6 * m + 1] && final(np)[6 * m + 2] == old(np)[6 * m + 2]
        &&& final(np)[6 * m + 3].is_init() && final(np)[6 * m + 3].value() == (if nd2.hid { HIDDEN } else { 0 })
        &&& nd2 == (Node { ix: nd2.ix, bk: nd2.bk, hid: nd2.hid, ..nd })
        &&& !nd2.hid ==> h2 == h && nd2.ix == nd.ix && nd2.bk == nd.bk
        &&& nd2.hid ==> (nd.kind == KIND_WEAK || nd.kind == KIND_WEAK_QUEUED) && nd.key is Ref && from(h, nd.key->Ref_0)
            && weak_map(*c, obj(h, nd.key->Ref_0))
            && nd2.ix == obj(h, nd.key->Ref_0).words[3] && nd2.bk == obj(h, nd.key->Ref_0).words[4]
            && h2 == with_obj(h, nd.key->Ref_0, hidden(obj(h, nd.key->Ref_0)))
            && final(np)[6 * m + 4].is_init() && final(np)[6 * m + 4].value() == enc(h.addr, nd2.ix)
            && final(np)[6 * m + 5].is_init() && final(np)[6 * m + 5].value() == enc(h.addr, nd2.bk)
    }),
{
    let ghost s0 = *st;
    let kind = nword(nptr, 6 * m, Ghost(nn as int), Tracked(&*np));
    let mut hid = false;
    let ghost mut h2 = h;
    let ghost mut nd2 = Node { hid: false, ..nd };
    if kind == KIND_WEAK || kind == KIND_WEAK_QUEUED {
        let kw = nword(nptr, 6 * m + 1, Ghost(nn as int), Tracked(&*np));
        let (dead, act, s, off, _cur) = key_status(c, kw, Ghost(h), Ghost(nd.key), Ghost(*t), Ghost(0int), Ghost(0int), Ghost(rvp),
                                                  Tracked(&*st), Tracked(ro));
        if dead && act {
            let ghost j = nd.key->Ref_0;
            let ghost o = obj(h, j);
            let ghost pg = fpg(h, j);
            proof {
                lemma_from_obj(*c, h, j);
                assert(!copied(*st, j));
                assert(st.fp[fkey(h, j, 0)].is_init());
                assert(o.words[0] is Raw);
            }
            let hd = fword(c, s, off, 0, Ghost(h), Ghost(j), Tracked(&st.fp));
            if (hd >> 1) & 15 == INSTANCE_TAG && (hd >> 6) == c.map_cid {
                proof {
                    lemma_w();
                    assert(fs(*c, pg) + pbytes(*c) < usize::MAX);
                    assert forall|k: int| 0 <= k < lay(o).size && #[trigger] o.words[k] is Raw implies
                        wperm_ok(st.fp, (pg, off + k), fptr(*c, pg), off + k) && st.fp[(pg, off + k)].is_init()
                        && st.fp[(pg, off + k)].value() == raw(o.words[k]) by {
                        assert(fkey(h, j, k) == (pg, off + k));
                        assert(st.fp[fkey(h, j, k)].is_init());
                    }
                }
                let fpage = c.base.with_addr(s);
                let (_sz, lo, hi) = obj_layout(c, fpage, off, Ghost(pg), Tracked(&st.fp), Ghost(o), Ghost(c.pw as int), Tracked(&ro.ctp));
                if lo == 1 && hi >= 5 {
                    proof {
                        assert(st.fp[fkey(h, j, 3)].is_init());
                        assert(st.fp[fkey(h, j, 4)].is_init());
                    }
                    let f2 = fword(c, s, off, 3, Ghost(h), Ghost(j), Tracked(&st.fp));
                    let f3 = fword(c, s, off, 4, Ghost(h), Ghost(j), Tracked(&st.fp));
                    set_nword(nptr, 6 * m + 4, f2, Ghost(nn as int), Tracked(np));
                    set_nword(nptr, 6 * m + 5, f3, Ghost(nn as int), Tracked(np));
                    proof {
                        assert(wperm_ok(st.fp, (pg, off + 3), fptr(*c, pg), off + 3));
                        assert((off + 4) * W <= pbytes(*c)) by (nonlinear_arith) requires off + 4 <= c.pw, W >= 1;
                        assert((off + 3) * W <= pbytes(*c)) by (nonlinear_arith) requires off + 3 <= c.pw, W >= 1;
                    }
                    wr(fpage, off + 3, 0, Ghost((pg, off + 3)), Tracked(&mut st.fp));
                    proof { assert(wperm_ok(s0.fp, (pg, off + 4), fptr(*c, pg), off + 4)); }
                    wr(fpage, off + 4, 0, Ghost((pg, off + 4)), Tracked(&mut st.fp));
                    proof {
                        let s2 = *st;
                        let o2 = hidden(o);
                        assert(o2.words.len() == o.words.len() && o2.words[0] == o.words[0] && hdr(o2) == hdr(o));
                        assert(obj_ok(o) && cls_ok(*c, o));
                        assert(lay(o2) == lay(o));
                        assert forall|k: int| lay(o2).lo <= k < lay(o2).hi implies #[trigger] slot_ok(*c, h.objs.len() as int, o2.words[k]) by {
                            assert(slots_ok(*c, h, j));
                            if k != 3 && k != 4 { assert(slot_ok(*c, h.objs.len() as int, o.words[k])); }
                        }
                        assert forall|k: int| 0 <= k < lay(o2).size && !(lay(o2).lo <= k < lay(o2).hi) implies #[trigger] o2.words[k] is Raw by {
                            assert(o.words[k] is Raw);
                        }
                        assert(same_shape(*c, h.objs.len() as int, o, o2));
                        assert forall|i: int, k: int| 0 <= i < c.nf && 0 <= k < c.pw implies #[trigger] wperm_ok(s2.fp, (i, k), fptr(*c, i), k) by {
                            assert(wperm_ok(s0.fp, (i, k), fptr(*c, i), k));
                        }
                        assert forall|q: (int, int)| !(q.0 == fpg(h, j) && foff(h, j) <= q.1 < foff(h, j) + size(h, j)) implies
                            #[trigger] s2.fp[q] == s0.fp[q] by {}
                        assert forall|k: int| 0 <= k < size(h, j) implies (#[trigger] s2.fp[fkey(h, j, k)]).is_init()
                            && s2.fp[fkey(h, j, k)].value() == wval(o2, h.addr, k) by {
                            assert(fkey(h, j, k) == (pg, off + k));
                            if k != 3 && k != 4 {
                                assert(s0.fp[fkey(h, j, k)].is_init());
                                assert(s2.fp[fkey(h, j, k)] == s0.fp[fkey(h, j, k)]);
                            }
                        }
                        lemma_modify(*c, h, s0, s2, *t, 0, 0, rv, rvp, rptr, 0, j, o2);
                        h2 = with_obj(h, j, o2);
                        nd2 = Node { ix: o.words[3], bk: o.words[4], hid: true, ..nd };
                        assert(f2 == wval(o, h.addr, 3) && f3 == wval(o, h.addr, 4));
                        assert(active(o));
                        assert(htag(hdr(o)) == INSTANCE_TAG && hcid(hdr(o)) == c.map_cid);
                        assert forall|x: int| 0 <= x < h2.objs.len() && !from(h2, x) implies #[trigger] ro.others.contains_key(x)
                            && ro.others[x].ptr()@.addr == h2.addr[x] - 1 by {
                            assert(ro.others.contains_key(x) && ro.others[x].ptr()@.addr == h.addr[x] - 1);
                        }
                    }
                    hid = true;
                }
            }
        }
    }
    proof { assert(nd2.hid == hid); }
    set_nword(nptr, 6 * m + 3, if hid { HIDDEN } else { 0 }, Ghost(nn as int), Tracked(np));
    (Ghost(h2), Ghost(nd2))
}


/// Hides the index and backing of every weak map that is a callback
/// node's key (`hide_one` for nodes `0..ncb`), before the collection.
pub fn hide_maps(c: &Ctx, t: &Tos, nptr: *mut usize, ncb: usize, nn: usize, Ghost(h): Ghost<H>, Ghost(nodes): Ghost<Seq<Node>>,
                 Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                 Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>,
                 Tracked(np): Tracked<&mut Map<int, PointsTo<usize>>>) -> (r: (Ghost<H>, Ghost<Seq<Node>>))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *t, 0, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, 0), old(st).order.len() == 0,
        ncb <= nn, nodes.len() == nn,
        forall|m: int| 0 <= m < ncb ==> (#[trigger] nodes[m]).kind <= KIND_WEAK_QUEUED,
        forall|m: int| 0 <= m < nn ==> slot_ok(*c, h.objs.len() as int, (#[trigger] nodes[m]).key) && !nodes[m].hid,
        nodes_mem(*old(np), nptr, nn as int),
        forall|m: int| 0 <= m < nn ==> #[trigger] node_in(*old(np), h, nodes[m], m),
        keys_ok(h, nodes, ncb as int),
    ensures ({
        let hs = r.0@;
        let nodes2 = r.1@;
        &&& heap_ok(*c, hs) && others_ok(hs, ro.others)
        &&& inv(*c, hs, *final(st), *t, 0, 0, rvp) && roots_ok(*c, hs, *final(st), rptr, rv, 0)
        &&& *final(st) == (St { fp: final(st).fp, ..*old(st) })
        &&& hide_ok(*c, h, hs, nodes, nodes2, ncb as int)
        &&& nodes_mem(*final(np), nptr, nn as int)
        &&& forall|m: int| #![trigger final(np)[6 * m]] 0 <= m < nn ==> final(np)[6 * m] == old(np)[6 * m] && final(np)[6 * m + 1] == old(np)[6 * m + 1]
                && final(np)[6 * m + 2] == old(np)[6 * m + 2]
        &&& forall|m: int| #![trigger final(np)[6 * m + 3]] ncb <= m < nn ==> final(np)[6 * m + 3] == old(np)[6 * m + 3]
        &&& forall|m: int| 0 <= m < ncb ==> (#[trigger] final(np)[6 * m + 3]).is_init()
                && final(np)[6 * m + 3].value() == (if nodes2[m].hid { HIDDEN } else { 0 })
        &&& forall|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid ==>
                final(np)[6 * m + 4].is_init() && final(np)[6 * m + 4].value() == enc(h.addr, nodes2[m].ix)
                && final(np)[6 * m + 5].is_init() && final(np)[6 * m + 5].value() == enc(h.addr, nodes2[m].bk)
    }),
{
    let ghost s0 = *st;
    let ghost np0 = *np;
    let ghost mut hc = h;
    let ghost mut nc = nodes;
    let mut i: usize = 0;
    while i < ncb
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), ctab_ok(*c, ro.ctp),
            heap_ok(*c, hc), others_ok(hc, ro.others),
            inv(*c, hc, *st, *t, 0, 0, rvp), roots_ok(*c, hc, *st, rptr, rv, 0), st.order.len() == 0,
            *st == (St { fp: st.fp, ..s0 }),
            i <= ncb, ncb <= nn, nodes.len() == nn, nc.len() == nn,
            forall|m: int| 0 <= m < ncb ==> (#[trigger] nodes[m]).kind <= KIND_WEAK_QUEUED,
            forall|m: int| 0 <= m < nn ==> slot_ok(*c, h.objs.len() as int, (#[trigger] nodes[m]).key) && !nodes[m].hid,
            forall|m: int| 0 <= m < nn ==> #[trigger] node_in(np0, h, nodes[m], m),
            keys_ok(h, nodes, ncb as int),
            forall|m: int| i <= m < nn ==> #[trigger] nc[m] == nodes[m],
            hide_ok(*c, h, hc, nodes, nc, ncb as int),
            nodes_mem(*np, nptr, nn as int),
            forall|m: int| #![trigger np[6 * m]] 0 <= m < nn ==> np[6 * m] == np0[6 * m] && np[6 * m + 1] == np0[6 * m + 1] && np[6 * m + 2] == np0[6 * m + 2],
            forall|m: int| #![trigger np[6 * m + 3]] i <= m < nn ==> np[6 * m + 3] == np0[6 * m + 3],
            forall|m: int| 0 <= m < i ==> (#[trigger] np[6 * m + 3]).is_init() && np[6 * m + 3].value() == (if nc[m].hid { HIDDEN } else { 0 }),
            forall|m: int| 0 <= m < i && (#[trigger] nc[m]).hid ==>
                np[6 * m + 4].is_init() && np[6 * m + 4].value() == enc(h.addr, nc[m].ix)
                && np[6 * m + 5].is_init() && np[6 * m + 5].value() == enc(h.addr, nc[m].bk),
        decreases ncb - i,
    {
        let ghost np1 = *np;
        let ghost h1 = hc;
        let ghost nd = nodes[i as int];
        proof {
            assert(node_in(np0, h, nd, i as int));
            assert(nc[i as int] == nd);
            let ii = i as int;
            assert(0 <= ii < nn);
            assert(np[6 * ii] == np0[6 * ii]);
            assert(np[6 * ii + 1] == np0[6 * ii + 1]);
            assert(np[6 * ii + 2] == np0[6 * ii + 2]);
            assert(np[6 * ii + 3] == np0[6 * ii + 3]);
            assert(node_in(*np, hc, nd, ii));
            assert(slot_ok(*c, hc.objs.len() as int, nd.key));
        }
        let r = hide_one(c, t, nptr, i, nn, Ghost(hc), Ghost(nd), Ghost(rptr), Ghost(rv), Ghost(rvp), Tracked(st), Tracked(ro), Tracked(np));
        proof {
            let h2 = r.0@;
            let nd2 = r.1@;
            let nc2 = nc.update(i as int, nd2);
            if nd2.hid {
                let j = nd.key->Ref_0;
                // The key was not hidden before (distinct keys): it is h's object.
                assert(obj(h1, j) == obj(h, j)) by {
                    if obj(h1, j) != obj(h, j) {
                        let m = choose|m: int| 0 <= m < ncb && (#[trigger] nc[m]).hid && nodes[m].key == AVal::Ref(j);
                        assert(m < i) by { if m >= i { assert(nc[m] == nodes[m]); } }
                        assert(nodes[m].key == nodes[i as int].key);
                    }
                }
            }
            assert forall|m: int| 0 <= m < nodes.len() implies #[trigger] nc2[m] == (Node { ix: nc2[m].ix, bk: nc2[m].bk, hid: nc2[m].hid, ..nodes[m] }) by {
                if m != i { assert(nc[m] == (Node { ix: nc[m].ix, bk: nc[m].bk, hid: nc[m].hid, ..nodes[m] })); }
            }
            assert forall|m: int| 0 <= m < nodes.len() && !(#[trigger] nc2[m]).hid implies nc2[m].ix == nodes[m].ix && nc2[m].bk == nodes[m].bk by {
                if m != i { assert(!nc[m].hid); }
            }
            assert forall|m: int| 0 <= m < nodes.len() && (#[trigger] nc2[m]).hid implies 0 <= m < ncb
                && (nodes[m].kind == KIND_WEAK || nodes[m].kind == KIND_WEAK_QUEUED)
                && nodes[m].key is Ref && from(h, nodes[m].key->Ref_0) && weak_map(*c, obj(h, nodes[m].key->Ref_0))
                && nc2[m].ix == obj(h, nodes[m].key->Ref_0).words[3] && nc2[m].bk == obj(h, nodes[m].key->Ref_0).words[4]
                && obj(h2, nodes[m].key->Ref_0) == hidden(obj(h, nodes[m].key->Ref_0)) by {
                if m != i {
                    assert(nc[m].hid);
                    if m >= i { assert(nc[m] == nodes[m]); }
                    let jm = nodes[m].key->Ref_0;
                    if nd2.hid {
                        assert(nodes[m].key != nodes[i as int].key);
                        assert(obj(h2, jm) == obj(h1, jm));
                    }
                }
            }
            assert forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() implies obj(h2, x) == obj(h, x)
                || exists|m: int| 0 <= m < ncb && (#[trigger] nc2[m]).hid && nodes[m].key == AVal::Ref(x) by {
                if obj(h2, x) != obj(h, x) {
                    if nd2.hid && nd.key == AVal::Ref(x) {
                        assert(nc2[i as int].hid);
                    } else {
                        assert(obj(h2, x) == obj(h1, x));
                        let m = choose|m: int| 0 <= m < ncb && (#[trigger] nc[m]).hid && nodes[m].key == AVal::Ref(x);
                        if m == i { assert(nc[m] == nodes[m]); }
                        assert(nc2[m].hid);
                    }
                }
            }
            assert(hide_ok(*c, h, h2, nodes, nc2, ncb as int));
            assert forall|m: int| #![trigger np[6 * m]] 0 <= m < nn implies np[6 * m] == np0[6 * m] && np[6 * m + 1] == np0[6 * m + 1]
                && np[6 * m + 2] == np0[6 * m + 2] by {
                assert(np1[6 * m] == np0[6 * m] && np1[6 * m + 1] == np0[6 * m + 1] && np1[6 * m + 2] == np0[6 * m + 2]);
                if m != i {
                    assert(np[6 * m] == np1[6 * m] && np[6 * m + 1] == np1[6 * m + 1] && np[6 * m + 2] == np1[6 * m + 2]);
                }
            }
            assert forall|m: int| #![trigger np[6 * m + 3]] i + 1 <= m < nn implies np[6 * m + 3] == np0[6 * m + 3] by {
                assert(np1[6 * m + 3] == np0[6 * m + 3]);
                assert(np[6 * m + 3] == np1[6 * m + 3]);
            }
            assert forall|m: int| 0 <= m < i + 1 implies (#[trigger] np[6 * m + 3]).is_init()
                && np[6 * m + 3].value() == (if nc2[m].hid { HIDDEN } else { 0 }) by {
                if m < i { assert(np[6 * m + 3] == np1[6 * m + 3]); }
            }
            assert forall|m: int| 0 <= m < i + 1 && (#[trigger] nc2[m]).hid implies
                np[6 * m + 4].is_init() && np[6 * m + 4].value() == enc(h.addr, nc2[m].ix)
                && np[6 * m + 5].is_init() && np[6 * m + 5].value() == enc(h.addr, nc2[m].bk) by {
                if m < i {
                    assert(nc[m].hid);
                    assert(np[6 * m + 4] == np1[6 * m + 4] && np[6 * m + 5] == np1[6 * m + 5]);
                }
            }
            assert forall|m: int| i + 1 <= m < nn implies #[trigger] nc2[m] == nodes[m] by {}
            hc = h2;
            nc = nc2;
        }
        i += 1;
    }
    (Ghost(hc), Ghost(nc))
}


/// `x` is the array of the list `bkv` (a weak map's backing): an instance
/// of the list class whose field 0 is `x`.
pub open spec fn backing(c: Ctx, h: H, bkv: AVal, x: int) -> bool {
    &&& bkv is Ref
    &&& from(h, bkv->Ref_0)
    &&& htag(hdr(obj(h, bkv->Ref_0))) == INSTANCE_TAG && hcid(hdr(obj(h, bkv->Ref_0))) == c.list_cid
    &&& lay(obj(h, bkv->Ref_0)).lo == 1 && lay(obj(h, bkv->Ref_0)).hi >= 2
    &&& obj(h, bkv->Ref_0).words[1] == AVal::Ref(x)
}

/// Array `o2` is `o` with some values nulled: element slots at odd indices
/// (`zap_dead_values`) that held an object other than a tombstone.
pub open spec fn zapped_arr(c: Ctx, h: H, o: AObj, o2: AObj) -> bool {
    &&& htag(hdr(o)) == ARRAY_TAG
    &&& o2.words.len() == o.words.len() && o2.cbits == o.cbits && o2.sw == o.sw
    &&& forall|k: int| 0 <= k < o.words.len() ==> #[trigger] o2.words[k] == o.words[k]
            || (2 <= k && (k - 2) % 2 == 1 && o2.words[k] == AVal::Ref(c.nullid@) && o.words[k] is Ref
                && 0 <= o.words[k]->Ref_0 < h.objs.len() && hcid(hdr(obj(h, o.words[k]->Ref_0))) != c.tomb_cid)
}

/// Nulls the dead values of the uncopied from-space array `a` (at offset
/// `off` of the page starting at `s`): the odd elements holding an
/// uncopied from-space object that is not a tombstone.
pub fn zap_array(c: &Ctx, t: &Tos, s: usize, off: usize, Ghost(h): Ghost<H>, Ghost(a): Ghost<int>, Ghost(ks): Ghost<int>,
                 Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                 Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (r: (bool, Ghost<H>))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *t, ks, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        0 <= ks <= old(st).order.len(),
        from(h, a), !copied(*old(st), a), s == fs(*c, fpg(h, a)), off == foff(h, a), htag(hdr(obj(h, a))) == ARRAY_TAG,
    ensures ({
        let h2 = r.1@;
        &&& heap_ok(*c, h2) && others_ok(h2, ro.others)
        &&& inv(*c, h2, *final(st), *t, ks, 0, rvp) && roots_ok(*c, h2, *final(st), rptr, rv, rv.len() as int)
        &&& *final(st) == (St { fp: final(st).fp, ..*old(st) })
        &&& h2.loc == h.loc && h2.addr == h.addr && h2.objs.len() == h.objs.len()
        &&& forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() && x != a ==> obj(h2, x) == obj(h, x)
        &&& zapped_arr(*c, h, obj(h, a), obj(h2, a))
    }),
{
    let ghost s0 = *st;
    let ghost o = obj(h, a);
    let ghost pg = fpg(h, a);
    proof {
        lemma_w();
        lemma_from_obj(*c, h, a);
        assert(lay(o).lo == 2);
        assert(o.words[1] is Raw);
        assert(s0.fp[fkey(h, a, 1)].is_init());
    }
    let len = fword(c, s, off, 1, Ghost(h), Ghost(a), Tracked(&st.fp));
    let ghost mut hc = h;
    let mut zapped = false;
    let mut i: usize = 1;
    proof {
        assert(len == raw(o.words[1]));
        assert(lay(o).size == 2 + len && lay(o).hi == 2 + len);
        assert forall|k: int| 0 <= k < o.words.len() implies #[trigger] obj(hc, a).words[k] == o.words[k] || false by {}
    }
    while i < len
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), ctab_ok(*c, ro.ctp),
            heap_ok(*c, hc), others_ok(hc, ro.others),
            inv(*c, hc, *st, *t, ks, 0, rvp), roots_ok(*c, hc, *st, rptr, rv, rv.len() as int),
            0 <= ks <= st.order.len(),
            *st == (St { fp: st.fp, ..s0 }),
            hc.loc == h.loc && hc.addr == h.addr && hc.objs.len() == h.objs.len(),
            forall|x: int| #![trigger obj(hc, x)] 0 <= x < h.objs.len() && x != a ==> obj(hc, x) == obj(h, x),
            from(h, a), !copied(*st, a), s == fs(*c, fpg(h, a)), off == foff(h, a), o == obj(h, a),
            pg == fpg(h, a),
            htag(hdr(o)) == ARRAY_TAG, lay(o).size == 2 + len, lay(o).lo == 2, lay(o).hi == 2 + len, len == raw(o.words[1]),
            1 <= i <= len + 1, i % 2 == 1, len < c.pw,
            lay(obj(hc, a)) == lay(o), hdr(obj(hc, a)) == hdr(o), obj(hc, a).words[1] == o.words[1],
            zapped_arr(*c, h, o, obj(hc, a)),
            forall|k: int| 2 + i <= k < o.words.len() ==> #[trigger] obj(hc, a).words[k] == o.words[k],
        decreases len + 1 - i,
    {
        let ghost oc = obj(hc, a);
        let ghost k = (2 + i) as int;
        proof {
            assert(hc.loc == h.loc);
            lemma_from_obj(*c, hc, a);
            assert(oc.words[k] == o.words[k]);
            assert(slots_ok(*c, hc, a));
            assert(lay(oc).lo <= k < lay(oc).hi);
            assert(slot_ok(*c, hc.objs.len() as int, oc.words[k]));
            assert(st.fp[fkey(hc, a, k)].is_init());
            assert(fkey(hc, a, k) == fkey(h, a, k));
        }
        let w = fword(c, s, off, 2 + i, Ghost(hc), Ghost(a), Tracked(&st.fp));
        let (dv, _av, sv, offv, _cv) = key_status(c, w, Ghost(hc), Ghost(oc.words[k]), Ghost(*t), Ghost(ks), Ghost(0int), Ghost(rvp),
                                                 Tracked(&*st), Tracked(ro));
        if dv {
            let ghost y = oc.words[k]->Ref_0;
            proof {
                lemma_from_obj(*c, hc, y);
                assert(obj(hc, y).words[0] is Raw);
                assert(st.fp[fkey(hc, y, 0)].is_init());
            }
            let hv = fword(c, sv, offv, 0, Ghost(hc), Ghost(y), Tracked(&st.fp));
            if (hv >> 6) != c.tomb_cid {
                let ghost s1 = *st;
                let ghost o2 = AObj { words: oc.words.update(k, AVal::Ref(c.nullid@)), ..oc };
                proof {
                    lemma_from_obj(*c, h, a);
                    assert(fpg(hc, a) == pg && foff(hc, a) == foff(h, a));
                    assert(fs(*c, pg) + pbytes(*c) < usize::MAX);
                    assert(fkey(hc, a, k) == (pg, off + k));
                    assert(wperm_ok(st.fp, (pg, off + k), fptr(*c, pg), off + k));
                    assert((off + k) * W <= pbytes(*c)) by (nonlinear_arith) requires off + k <= c.pw, W >= 1;
                }
                let fpage = c.base.with_addr(s);
                wr(fpage, off + 2 + i, c.null, Ghost((pg, off + k)), Tracked(&mut st.fp));
                proof {
                    let s2 = *st;
                    assert(o2.words.len() == oc.words.len() && o2.words[0] == oc.words[0] && o2.words[1] == oc.words[1]);
                    assert(hdr(o2) == hdr(oc));
                    assert(lay(o2) == lay(oc));
                    assert(obj_ok(oc) && cls_ok(*c, oc));
                    assert forall|q: int| lay(o2).lo <= q < lay(o2).hi implies #[trigger] slot_ok(*c, hc.objs.len() as int, o2.words[q]) by {
                        if q != k { assert(slot_ok(*c, hc.objs.len() as int, oc.words[q])); }
                    }
                    assert forall|q: int| 0 <= q < lay(o2).size && !(lay(o2).lo <= q < lay(o2).hi) implies #[trigger] o2.words[q] is Raw by {
                        assert(oc.words[q] is Raw);
                    }
                    assert(same_shape(*c, hc.objs.len() as int, oc, o2));
                    assert forall|pi: int, q: int| 0 <= pi < c.nf && 0 <= q < c.pw implies #[trigger] wperm_ok(s2.fp, (pi, q), fptr(*c, pi), q) by {
                        assert(wperm_ok(s1.fp, (pi, q), fptr(*c, pi), q));
                    }
                    assert forall|q: (int, int)| !(q.0 == fpg(hc, a) && foff(hc, a) <= q.1 < foff(hc, a) + size(hc, a)) implies
                        #[trigger] s2.fp[q] == s1.fp[q] by {}
                    assert forall|q: int| 0 <= q < size(hc, a) implies (#[trigger] s2.fp[fkey(hc, a, q)]).is_init()
                        && s2.fp[fkey(hc, a, q)].value() == wval(o2, hc.addr, q) by {
                        assert(fkey(hc, a, q) == (pg, off + q));
                        if q != k {
                            assert(s1.fp[fkey(hc, a, q)].is_init());
                            assert(s2.fp[fkey(hc, a, q)] == s1.fp[fkey(hc, a, q)]);
                        }
                    }
                    lemma_modify(*c, hc, s1, s2, *t, ks, 0, rv, rvp, rptr, rv.len() as int, a, o2);
                    let h2 = with_obj(hc, a, o2);
                    assert forall|x: int| 0 <= x < h2.objs.len() && !from(h2, x) implies #[trigger] ro.others.contains_key(x)
                        && ro.others[x].ptr()@.addr == h2.addr[x] - 1 by {
                        assert(ro.others.contains_key(x) && ro.others[x].ptr()@.addr == hc.addr[x] - 1);
                    }
                    assert(hdr(obj(h, y)) == hdr(obj(hc, y))) by {
                        if y == a { assert(hdr(obj(hc, a)) == hdr(o)); }
                    }
                    assert forall|q: int| 0 <= q < o.words.len() implies #[trigger] o2.words[q] == o.words[q]
                        || (2 <= q && (q - 2) % 2 == 1 && o2.words[q] == AVal::Ref(c.nullid@) && o.words[q] is Ref
                            && 0 <= o.words[q]->Ref_0 < h.objs.len() && hcid(hdr(obj(h, o.words[q]->Ref_0))) != c.tomb_cid) by {
                        if q != k { assert(oc.words[q] == o.words[q] || (2 <= q && (q - 2) % 2 == 1 && oc.words[q] == AVal::Ref(c.nullid@)
                            && o.words[q] is Ref && 0 <= o.words[q]->Ref_0 < h.objs.len() && hcid(hdr(obj(h, o.words[q]->Ref_0))) != c.tomb_cid)); }
                    }
                    assert forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() && x != a implies obj(h2, x) == obj(h, x) by {
                        assert(obj(hc, x) == obj(h, x));
                    }
                    assert forall|q: int| 2 + i + 2 <= q < o.words.len() implies #[trigger] obj(h2, a).words[q] == o.words[q] by {
                        assert(oc.words[q] == o.words[q]);
                    }
                    hc = h2;
                }
                zapped = true;
            }
        }
        i = i + 2;
    }
    (zapped, Ghost(hc))
}


/// The zapping of a live weak map whose backing (list) is `bkv`: if the
/// list and its array are uncopied from-space objects of the list class
/// and an array, the array's dead values are nulled (`zap_array`).
pub fn zap_backing(c: &Ctx, t: &Tos, bkw: usize, Ghost(h): Ghost<H>, Ghost(bkv): Ghost<AVal>, Ghost(ks): Ghost<int>,
                   Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                   Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (r: (bool, Ghost<H>))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *t, ks, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        0 <= ks <= old(st).order.len(),
        bkw == enc(h.addr, bkv), slot_ok(*c, h.objs.len() as int, bkv),
    ensures ({
        let h2 = r.1@;
        &&& heap_ok(*c, h2) && others_ok(h2, ro.others)
        &&& inv(*c, h2, *final(st), *t, ks, 0, rvp) && roots_ok(*c, h2, *final(st), rptr, rv, rv.len() as int)
        &&& *final(st) == (St { fp: final(st).fp, ..*old(st) })
        &&& h2.loc == h.loc && h2.addr == h.addr && h2.objs.len() == h.objs.len()
        &&& forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() ==> obj(h2, x) == obj(h, x)
                || (from(h, x) && !copied(*old(st), x) && backing(*c, h, bkv, x) && zapped_arr(*c, h, obj(h, x), obj(h2, x)))
    }),
{
    let (dl, _al, s, off, _cl) = key_status(c, bkw, Ghost(h), Ghost(bkv), Ghost(*t), Ghost(ks), Ghost(0int), Ghost(rvp),
                                           Tracked(&*st), Tracked(ro));
    if !dl {
        return (false, Ghost(h));
    }
    let ghost l = bkv->Ref_0;
    let ghost ol = obj(h, l);
    let ghost pg = fpg(h, l);
    proof {
        lemma_w();
        lemma_from_obj(*c, h, l);
        assert(ol.words[0] is Raw);
        assert(st.fp[fkey(h, l, 0)].is_init());
    }
    let hd = fword(c, s, off, 0, Ghost(h), Ghost(l), Tracked(&st.fp));
    if (hd >> 1) & 15 != INSTANCE_TAG || (hd >> 6) != c.list_cid {
        return (false, Ghost(h));
    }
    proof {
        assert(fs(*c, pg) + pbytes(*c) < usize::MAX);
        assert forall|k: int| 0 <= k < lay(ol).size && #[trigger] ol.words[k] is Raw implies
            wperm_ok(st.fp, (pg, off + k), fptr(*c, pg), off + k) && st.fp[(pg, off + k)].is_init()
            && st.fp[(pg, off + k)].value() == raw(ol.words[k]) by {
            assert(fkey(h, l, k) == (pg, off + k));
            assert(st.fp[fkey(h, l, k)].is_init());
        }
    }
    let lpage = c.base.with_addr(s);
    let (_sz, lo, hi) = obj_layout(c, lpage, off, Ghost(pg), Tracked(&st.fp), Ghost(ol), Ghost(c.pw as int), Tracked(&ro.ctp));
    if !(lo == 1 && hi >= 2) {
        return (false, Ghost(h));
    }
    proof {
        assert(st.fp[fkey(h, l, 1)].is_init());
        assert(slots_ok(*c, h, l));
        assert(slot_ok(*c, h.objs.len() as int, ol.words[1]));
    }
    let aw = fword(c, s, off, 1, Ghost(h), Ghost(l), Tracked(&st.fp));
    let (da, _aa, sa, offa, _ca) = key_status(c, aw, Ghost(h), Ghost(ol.words[1]), Ghost(*t), Ghost(ks), Ghost(0int), Ghost(rvp),
                                             Tracked(&*st), Tracked(ro));
    if !da {
        return (false, Ghost(h));
    }
    let ghost a = ol.words[1]->Ref_0;
    proof {
        lemma_from_obj(*c, h, a);
        assert(obj(h, a).words[0] is Raw);
        assert(st.fp[fkey(h, a, 0)].is_init());
    }
    let ha = fword(c, sa, offa, 0, Ghost(h), Ghost(a), Tracked(&st.fp));
    if (ha >> 1) & 15 != ARRAY_TAG {
        return (false, Ghost(h));
    }
    proof {
        assert(backing(*c, h, bkv, a));
    }
    zap_array(c, t, sa, offa, Ghost(h), Ghost(a), Ghost(ks), Ghost(rptr), Ghost(rv), Ghost(rvp), Tracked(st), Tracked(ro))
}


/// Whether the copy at address `a` (copy `pos[j]`) was made before the
/// main scan ended (copy index below `n0`): its page and offset come before
/// the main scan's end `(tn0 - 1, top0)` (a search over the to-space table).
pub fn copy_scanned(c: &Ctx, t: &Tos, a: usize, tn0: usize, top0: usize, Ghost(h): Ghost<H>, Ghost(j): Ghost<int>,
                    Ghost(n0): Ghost<int>, Tracked(st): Tracked<&St>) -> (r: bool)
    requires
        ctx_ok(*c), heap_ok(*c, h), bk_ok(h, *st), tcopies_ok(*c, h, *st, *t), tpages_ok(*c, h, *st, *t),
        copied(*st, j), a == st.addr2[j], 0 <= n0 <= st.order.len(), tn0 <= t.tn,
        n0 == 0 ==> tn0 == 0,
        n0 >= 1 ==> tn0 >= 1 && tpg(*st, n0 - 1) == tn0 - 1 && tend(h, *st, n0 - 1) == top0,
    ensures r == (st.pos[j] < n0),
{
    let ghost k = st.pos[j];
    proof {
        lemma_w();
        assert(0 <= k < st.order.len() && st.order[k] == j);
        lemma_from_obj(*c, h, j);
        assert(0 <= tpg(*st, k) < t.tn && 0 <= toff(*st, k) && tend(h, *st, k) <= st.tus[tpg(*st, k)]);
        assert(st.tus[tpg(*st, k)] <= c.pw - 1);
        assert(a == taddr(*st, k));
    }
    if tn0 == 0 {
        return false;
    }
    let pb = page_bytes(c);
    let mut p: usize = 0;
    while p < t.tn
        invariant
            ctx_ok(*c), heap_ok(*c, h), bk_ok(h, *st), tcopies_ok(*c, h, *st, *t), tpages_ok(*c, h, *st, *t),
            copied(*st, j), a == st.addr2[j], k == st.pos[j], 0 <= k < st.order.len(), st.order[k] == j,
            0 <= tpg(*st, k) < t.tn, 0 <= toff(*st, k), tend(h, *st, k) <= st.tus[tpg(*st, k)], st.tus[tpg(*st, k)] <= c.pw - 1,
            a == taddr(*st, k), size(h, j) >= 1, pb == pbytes(*c),
            0 <= n0 <= st.order.len(), 1 <= tn0 <= t.tn, n0 >= 1, tpg(*st, n0 - 1) == tn0 - 1, tend(h, *st, n0 - 1) == top0,
            p <= t.tn,
            forall|q: int| 0 <= q < p ==> !(st.tss[q] < a && a < st.tss[q] + pbytes(*c)),
        decreases t.tn - p,
    {
        proof {
            assert(wperm_ok(st.ttp, p as int, t.ttab, p as int));
            assert(st.ttp[p as int].is_init() && st.ttp[p as int].value() == st.tss[p as int]);
            assert(st.tss[p as int] + pbytes(*c) < usize::MAX);
        }
        let s = tab_at(t.ttab, p, Ghost(t.tcap as int), Tracked(&st.ttp));
        if s < a && a - s < pb {
            let off = (a - 1 - s) / W;
            proof {
                let q = tpg(*st, k);
                let s2 = st.tss[q];
                assert(toff(*st, k) < c.pw);
                assert(toff(*st, k) * W < pbytes(*c)) by (nonlinear_arith) requires toff(*st, k) < c.pw, W >= 1;
                if p as int != q {
                    if (p as int) < q { assert(pages_apart(st.tss[p as int] as int, st.tss[q] as int, c.pw as int)); }
                    else { assert(pages_apart(st.tss[q] as int, st.tss[p as int] as int, c.pw as int)); }
                    assert(false);
                }
                lemma_offset(s as int, toff(*st, k));
                assert(off == toff(*st, k));
                let kk = n0 - 1;
                lemma_from_obj(*c, h, st.order[kk]);
                assert(tsz(h, *st, kk) >= 1 && tsz(h, *st, k) >= 1);
                if k < n0 {
                    if k < kk { assert(before(h, *st, k, kk)); }
                } else {
                    assert(before(h, *st, kk, k));
                }
            }
            return p + 1 < tn0 || (p + 1 == tn0 && off < top0);
        }
        p += 1;
    }
    proof {
        let q = tpg(*st, k);
        assert(toff(*st, k) * W < pbytes(*c)) by (nonlinear_arith) requires toff(*st, k) < c.pw, W >= 1;
        assert(!(st.tss[q] < a && a < st.tss[q] + pbytes(*c)));
        assert(false);
    }
    false
}


/// The invariant after a copied weak map gets its hidden fields back: the
/// heap's object `j` (copy `k`) becomes `o2` (words 3 and 4 replaced; they
/// were raw words, so no copy has them as its parent) and the copy's words
/// 3 and 4 hold `o2`'s under the address map their position needs (closed
/// if processed).
pub proof fn lemma_restore(c: Ctx, h: H, st: St, st2: St, t: Tos, ks: int, kc: int, rv: Seq<AVal>, rvp: Seq<AVal>,
                           rptr: *mut usize, ri: int, j: int, o2: AObj)
    requires
        ctx_ok(c), heap_ok(c, h), inv(c, h, st, t, ks, kc, rvp), roots_ok(c, h, st, rptr, rv, ri),
        0 <= ks <= st.order.len(), ks < st.order.len() || kc == 0,
        from(h, j), copied(st, j),
        same_shape(c, h.objs.len() as int, obj(h, j), o2), o2.words.len() == obj(h, j).words.len(),
        lay(obj(h, j)).lo <= 3, 5 <= lay(obj(h, j)).hi,
        obj(h, j).words[3] is Raw, obj(h, j).words[4] is Raw,
        forall|i: int| 0 <= i < o2.words.len() && i != 3 && i != 4 ==> #[trigger] o2.words[i] == obj(h, j).words[i],
        processed(st.pos[j], 3, ks, kc) ==> closed(h, st, o2.words[3]),
        processed(st.pos[j], 4, ks, kc) ==> closed(h, st, o2.words[4]),
        st2 == (St { tp: st2.tp, ..st }), st2.tp.dom() == st.tp.dom(),
        forall|q: (int, int)| q != tkey(st, st.pos[j], 3) && q != tkey(st, st.pos[j], 4) ==> #[trigger] st2.tp[q] == st.tp[q],
        st2.tp[tkey(st, st.pos[j], 3)].ptr() == st.tp[tkey(st, st.pos[j], 3)].ptr(),
        st2.tp[tkey(st, st.pos[j], 4)].ptr() == st.tp[tkey(st, st.pos[j], 4)].ptr(),
        st2.tp[tkey(st, st.pos[j], 3)].is_init(), st2.tp[tkey(st, st.pos[j], 4)].is_init(),
        st2.tp[tkey(st, st.pos[j], 3)].value() == wval(o2, amap(h, st, st.pos[j], 3, ks, kc), 3),
        st2.tp[tkey(st, st.pos[j], 4)].value() == wval(o2, amap(h, st, st.pos[j], 4, ks, kc), 4),
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
    let nc = st.order.len() as int;
    let k = st.pos[j];
    let o = obj(h, j);
    lemma_from_obj(c, h, j);
    assert(0 <= k < nc && st.order[k] == j);
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
    assert forall|x: int, q: int| 0 <= x < n && !from(h2, x) && lay(obj(h2, x)).lo <= q < lay(obj(h2, x)).hi implies
        #[trigger] prog_ref_ok(h2, obj(h2, x).words[q]) by {
        assert(x != j);
        assert(prog_ref_ok(h, obj(h, x).words[q]));
    }
    assert(heap_ok(c, h2));
    // The parts that do not read to-space words, for st2 under h.
    lemma_frame_tp(c, h, st, st2, t, rvp);
    // Then under h2.
    assert forall|q: int| 0 <= q < nc implies from(h2, #[trigger] st2.order[q]) && st2.pos.contains_key(st2.order[q])
        && st2.pos[st2.order[q]] == q by {
        assert(from(h, st.order[q]));
    }
    assert forall|x: int| 0 <= x < h2.objs.len() implies #[trigger] st2.addr2[x] ==
        (if copied(st2, x) { taddr(st2, st2.pos[x]) } else { h2.addr[x] }) by {
        assert(st.addr2[x] == (if copied(st, x) { taddr(st, st.pos[x]) } else { h.addr[x] }));
    }
    assert(bk_ok(h2, st2));
    assert forall|x: int, q: int| from(h2, x) && !copied(st2, x) && 0 <= q < size(h2, x) implies
        (#[trigger] st2.fp[fkey(h2, x, q)]).is_init() && st2.fp[fkey(h2, x, q)].value() == wval(obj(h2, x), h2.addr, q) by {
        assert(x != j);
        assert(st.fp[fkey(h, x, q)].is_init());
    }
    assert forall|x: int| from(h2, x) && #[trigger] copied(st2, x) implies
        st2.fp[fkey(h2, x, 0)].is_init() && st2.fp[fkey(h2, x, 0)].value() == st2.addr2[x] by {
        assert(copied(st, x));
        assert(st.fp[fkey(h, x, 0)].is_init());
    }
    assert(from_inv(c, h2, st2));
    assert forall|q: int| 0 <= q < nc implies #[trigger] tsz(h2, st2, q) == tsz(h, st, q) by {}
    assert forall|q: int| 0 <= q < nc - 1 implies #[trigger] st2.tloc[q + 1] == succ(h2, st2, q, t.tn as int) by {
        assert(st.tloc[q + 1] == succ(h, st, q, t.tn as int));
        assert(tsz(h2, st2, q) == tsz(h, st, q));
    }
    assert forall|q: int| 0 <= q < nc implies 0 <= #[trigger] tpg(st2, q) < t.tn && 0 <= toff(st2, q)
        && tend(h2, st2, q) <= st2.tus[tpg(st2, q)] by {
        assert(0 <= tpg(st, q) < t.tn && 0 <= toff(st, q) && tend(h, st, q) <= st.tus[tpg(st, q)]);
    }
    assert forall|k1: int, k2: int| 0 <= k1 < k2 < nc implies #[trigger] before(h2, st2, k1, k2) by {
        assert(before(h, st, k1, k2));
        assert(tsz(h2, st2, k1) == tsz(h, st, k1));
    }
    if nc > 0 { assert(tsz(h2, st2, nc - 1) == tsz(h, st, nc - 1)); }
    assert(tcopies_ok(c, h2, st2, t));
    // The to-space pages: the changed words are inside copy k, below its
    // page's used words.
    assert(0 <= tpg(st, k) < t.tn && 0 <= toff(st, k) && tend(h, st, k) <= st.tus[tpg(st, k)]);
    let key3 = tkey(st, k, 3);
    let key4 = tkey(st, k, 4);
    assert(size(h, j) >= 5);
    assert forall|p: int, q: int| 0 <= p < t.tn && 0 <= q < c.pw implies #[trigger] wperm_ok(st2.tp, (p, q), tptr(c, st2, p), q) by {
        assert(wperm_ok(st.tp, (p, q), tptr(c, st, p), q));
    }
    assert forall|q: (int, int)| #[trigger] st2.tp.contains_key(q) implies 0 <= q.0 < t.tn by {
        assert(st.tp.contains_key(q));
    }
    assert forall|p: int| 0 <= p < t.tn - 1 implies #[trigger] st2.tp[(p, st2.tus[p])].is_init() && st2.tp[(p, st2.tus[p])].value() == 0 by {
        assert(st.tp[(p, st.tus[p])].is_init() && st.tp[(p, st.tus[p])].value() == 0);
        assert((p, st.tus[p]) != key3 && (p, st.tus[p]) != key4);
    }
    assert forall|p: int, x: int| 0 <= p < t.tn && 0 <= x < h2.objs.len() && !from(h2, x) implies
        #[trigger] outside(st2.tss[p] as int, #[trigger] h2.addr[x] as int, c.pw as int) by {
        assert(outside(st.tss[p] as int, h.addr[x] as int, c.pw as int));
    }
    assert forall|p: int| 0 <= p < t.tcap implies #[trigger] wperm_ok(st2.ttp, p, t.ttab, p) by {
        assert(wperm_ok(st.ttp, p, t.ttab, p));
    }
    assert forall|p: int| 0 <= p < t.tcap implies #[trigger] wperm_ok(st2.tup, p, t.tused, p) by {
        assert(wperm_ok(st.tup, p, t.tused, p));
    }
    assert forall|p: int| 0 <= p < t.tn implies #[trigger] st2.ttp[p].is_init() && st2.ttp[p].value() == st2.tss[p] by {
        assert(st.ttp[p].is_init() && st.ttp[p].value() == st.tss[p]);
    }
    assert forall|p: int| 0 <= p < t.tn - 1 implies #[trigger] st2.tup[p].is_init() && st2.tup[p].value() == st2.tus[p] by {
        assert(st.tup[p].is_init() && st.tup[p].value() == st.tus[p]);
    }
    assert forall|p: int| 0 <= p < t.tn implies 0 <= #[trigger] st2.tus[p] <= c.pw - 1 by { assert(0 <= st.tus[p] <= c.pw - 1); }
    assert forall|p: int| 0 <= p < t.tn implies #[trigger] st2.tss[p] % W == 0 && st2.tss[p] + pbytes(c) < usize::MAX by {
        assert(st.tss[p] % W == 0 && st.tss[p] + pbytes(c) < usize::MAX);
    }
    assert forall|p: int, q: int| 0 <= p < q < t.tn implies #[trigger] pages_apart(st2.tss[p] as int, st2.tss[q] as int, c.pw as int) by {
        assert(pages_apart(st.tss[p] as int, st.tss[q] as int, c.pw as int));
    }
    assert(tpages_ok(c, h, st, t));
    assert(st2.tss.len() == t.tn && st2.tus.len() == t.tn && t.tn <= t.tcap);
    assert(t.tn > 0 ==> st2.tus[t.tn - 1] == t.top && t.cur == st2.tss[t.tn - 1]);
    assert(tpages_ok(c, h2, st2, t));
    // The copies' words.
    assert forall|kk: int, i: int| 0 <= kk < nc && 0 <= i < tsz(h2, st2, kk) implies
        (#[trigger] st2.tp[tkey(st2, kk, i)]).is_init()
        && st2.tp[tkey(st2, kk, i)].value() == wval(obj(h2, st2.order[kk]), amap(h2, st2, kk, i, ks, kc), i) by {
        assert(st.tp[tkey(st, kk, i)].is_init());
        if kk != k {
            lemma_tkeys(c, h, st, t, kk, i, k, 3);
            lemma_tkeys(c, h, st, t, kk, i, k, 4);
            assert(st.order[kk] != j);
            assert(obj(h2, st.order[kk]) == obj(h, st.order[kk]));
        } else if i != 3 && i != 4 {
            lemma_tkeys(c, h, st, t, kk, i, k, 3);
            lemma_tkeys(c, h, st, t, kk, i, k, 4);
            assert(o2.words[i] == o.words[i]);
        }
    }
    assert forall|kk: int, i: int| 0 <= kk < nc && 0 <= i < tsz(h2, st2, kk) && processed(kk, i, ks, kc)
        && is_ref(obj(h2, st2.order[kk]), i) implies closed(h2, st2, #[trigger] obj(h2, st2.order[kk]).words[i]) by {
        if kk != k {
            assert(st.order[kk] != j);
            assert(obj(h2, st.order[kk]) == obj(h, st.order[kk]));
            assert(closed(h, st, obj(h, st.order[kk]).words[i]));
        } else if i != 3 && i != 4 {
            assert(o2.words[i] == o.words[i]);
            assert(closed(h, st, o.words[i]));
        }
    }
    assert(to_inv(c, h2, st2, ks, kc));
    assert forall|x: int| #[trigger] from(h2, x) && !copied(st2, x) implies st2.used.disjoint(extent(c, h2, x)) by {
        assert(st.used.disjoint(extent(c, h, x)));
        assert(extent(c, h2, x) == extent(c, h, x));
    }
    assert forall|x: int| #[trigger] from(h2, x) implies size(h2, x) <= t.mx@ by {
        assert(size(h, x) <= t.mx@);
    }
    assert(cap_ok(c, h2, st2, t));
    assert forall|q: int| 0 <= q < nc implies #[trigger] parent_ok(h2, st2, rvp, q) by {
        assert(parent_ok(h, st, rvp, q));
        let p = st.parent[q].0;
        let s = st.parent[q].1;
        if p >= 0 {
            if st.order[p] == j {
                assert(o.words[s] == AVal::Ref(st.order[q]));
                assert(s != 3 && s != 4);
                assert(o2.words[s] == o.words[s]);
            } else {
                assert(obj(h2, st.order[p]) == obj(h, st.order[p]));
            }
        }
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


/// One hidden weak map's node (`nodes`'s `i`, key `j`, the map before
/// hiding `oj`): if the map survived, its dead values are nulled
/// (`zap_backing`), its hidden fields forwarded and written back into its
/// copy (encoded for the copy's place before or after the main scan's
/// end); if it died, it is reset (`kill_key`). Marks the node: zapped or 0.

/// Writes a surviving weak map's fields back into its copy (`cur`) and
/// re-establishes the invariant for the heap with the map's object `o2`.
pub fn restore_copy(c: &Ctx, t: &Tos, cur: usize, w3: usize, w4: usize, Ghost(h): Ghost<H>, Ghost(j): Ghost<int>,
                    Ghost(o2): Ghost<AObj>, Ghost(n0): Ghost<int>,
                    Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                    Tracked(st): Tracked<&mut St>)
    requires
        ctx_ok(*c), heap_ok(*c, h), inv(*c, h, *old(st), *t, n0, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        0 <= n0 <= old(st).order.len(),
        from(h, j), copied(*old(st), j), cur == old(st).addr2[j],
        same_shape(*c, h.objs.len() as int, obj(h, j), o2), o2.words.len() == obj(h, j).words.len(),
        lay(obj(h, j)).lo <= 3, 5 <= lay(obj(h, j)).hi,
        obj(h, j).words[3] is Raw, obj(h, j).words[4] is Raw,
        forall|q: int| 0 <= q < o2.words.len() && q != 3 && q != 4 ==> #[trigger] o2.words[q] == obj(h, j).words[q],
        w3 == enc(if old(st).pos[j] < n0 { old(st).addr2 } else { h.addr }, o2.words[3]),
        w4 == enc(if old(st).pos[j] < n0 { old(st).addr2 } else { h.addr }, o2.words[4]),
        old(st).pos[j] < n0 ==> closed(h, *old(st), o2.words[3]) && closed(h, *old(st), o2.words[4]),
    ensures
        heap_ok(*c, with_obj(h, j, o2)),
        inv(*c, with_obj(h, j, o2), *final(st), *t, n0, 0, rvp),
        roots_ok(*c, with_obj(h, j, o2), *final(st), rptr, rv, rv.len() as int),
        *final(st) == (St { tp: final(st).tp, ..*old(st) }),
{
    let ghost s3 = *st;
    let ghost k = s3.pos[j];
    let ghost pg = tpg(s3, k);
    let ghost of = toff(s3, k);
    proof {
        lemma_w();
        lemma_from_obj(*c, h, j);
        assert(0 <= k < s3.order.len() && s3.order[k] == j);
        assert(0 <= pg < t.tn && 0 <= of && tend(h, s3, k) <= s3.tus[pg]);
        assert(s3.tus[pg] <= c.pw - 1);
        assert(s3.tss[pg] + pbytes(*c) < usize::MAX);
        assert(s3.tss[pg] % W == 0);
        assert(cur == taddr(s3, k));
        assert(tsz(h, s3, k) == size(h, j) && size(h, j) >= 5);
        assert(wperm_ok(s3.tp, (pg, of + 3), tptr(*c, s3, pg), of + 3));
        assert(wperm_ok(s3.tp, (pg, of + 4), tptr(*c, s3, pg), of + 4));
        assert(at(ppage(*c, (cur - 1) as int), 3) == at(tptr(*c, s3, pg), of + 3));
        assert(at(ppage(*c, (cur - 1) as int), 4) == at(tptr(*c, s3, pg), of + 4));
        assert((cur - 1) as int + 4 * W <= usize::MAX) by (nonlinear_arith)
            requires (cur - 1) as int == s3.tss[pg] + of * W, of + 4 < c.pw, s3.tss[pg] + c.pw * W < usize::MAX, W >= 1;
    }
    let copy = c.base.with_addr(cur - 1);
    wr(copy, 3, w3, Ghost((pg, of + 3)), Tracked(&mut st.tp));
    proof { assert(wperm_ok(st.tp, (pg, of + 4), copy, 4)); }
    wr(copy, 4, w4, Ghost((pg, of + 4)), Tracked(&mut st.tp));
    proof {
        let s4 = *st;
        assert(tkey(s3, k, 3) == (pg, of + 3) && tkey(s3, k, 4) == (pg, of + 4));
        assert(processed(k, 3, n0, 0) == (k < n0) && processed(k, 4, n0, 0) == (k < n0));
        assert(amap(h, s3, k, 3, n0, 0) == (if k < n0 { s3.addr2 } else { h.addr }));
        assert(amap(h, s3, k, 4, n0, 0) == (if k < n0 { s3.addr2 } else { h.addr }));
        assert forall|q: (int, int)| q != tkey(s3, k, 3) && q != tkey(s3, k, 4) implies #[trigger] s4.tp[q] == s3.tp[q] by {}
        assert(s4 == (St { tp: s4.tp, ..s3 }));
        lemma_restore(*c, h, s3, s4, *t, n0, 0, rv, rvp, rptr, rv.len() as int, j, o2);
    }
}


/// One hidden weak map's node (`nodes`'s `i`, key `j`, the map before
/// hiding `oj`): if the map survived, its dead values are nulled
/// (`zap_backing`), its hidden fields forwarded and written back into its
/// copy (encoded for the copy's place before or after the main scan's
/// end); if it died, it is reset (`kill_key`). Marks the node: zapped or 0.

/// One hidden weak map's node (`nodes`'s `i`, key `j`, the map before
/// hiding `oj`): if the map survived, its dead values are nulled
/// (`zap_backing`), its hidden fields forwarded and written back into its
/// copy (encoded for the copy's place before or after the main scan's

/// Forwards a hidden index and backing (parents: the node's roots).
pub fn fwd_two<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, ixw: usize, bkw: usize, Ghost(h): Ghost<H>,
                              Ghost(ix): Ghost<AVal>, Ghost(bk): Ghost<AVal>, Ghost(ks): Ghost<int>, Ghost(ri2): Ghost<int>,
                              Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                              Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>) -> (r: (usize, usize))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *old(t), ks, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        src_ok(*c, *old(src), *old(t)), 0 <= ks <= old(st).order.len(),
        ixw == enc(h.addr, ix), bkw == enc(h.addr, bk),
        slot_ok(*c, h.objs.len() as int, ix), slot_ok(*c, h.objs.len() as int, bk),
        0 <= ri2 && ri2 + 1 < rvp.len(), rvp[ri2] == ix, rvp[ri2 + 1] == bk,
    ensures
        inv(*c, h, *final(st), *final(t), ks, 0, rvp), roots_ok(*c, h, *final(st), rptr, rv, rv.len() as int),
        src_ok(*c, *final(src), *final(t)),
        grows(h, *old(st), *final(st)), final(st).addr2.len() == old(st).addr2.len(),
        r.0 == enc(final(st).addr2, ix), r.1 == enc(final(st).addr2, bk),
        closed(h, *final(st), ix), closed(h, *final(st), bk),
        final(t).ttab == old(t).ttab, final(t).tused == old(t).tused, final(t).tcap == old(t).tcap,
        final(t).rs == old(t).rs, final(t).mx == old(t).mx, old(t).tn <= final(t).tn,
{
    let ghost s1 = *st;
    let a = forward(c, src, t, ixw, Ghost(h), Ghost(ix), Ghost(ks), Ghost(0int), Ghost((-1 - ri2, 0int)), Ghost(rptr),
                    Ghost(rv), Ghost(rvp), Ghost(rv.len() as int), Tracked(st), Tracked(ro));
    let ghost s2 = *st;
    let b = forward(c, src, t, bkw, Ghost(h), Ghost(bk), Ghost(ks), Ghost(0int), Ghost((-1 - (ri2 + 1), 0int)), Ghost(rptr),
                    Ghost(rv), Ghost(rvp), Ghost(rv.len() as int), Tracked(st), Tracked(ro));
    let ghost s3 = *st;
    proof {
        assert(bk_ok(h, s1) && bk_ok(h, s2));
        lemma_grows_trans(h, s1, s2, s3);
        if ix is Ref {
            if copied(s2, ix->Ref_0) { assert(copied(s3, ix->Ref_0)); }
            assert(s3.addr2[ix->Ref_0] == s2.addr2[ix->Ref_0]);
        }
    }
    (a, b)
}

/// end); if it died, it is reset (`kill_key`). Marks the node: zapped or 0.
pub fn weak_live<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, nptr: *mut usize, i: usize, nn: usize,
                               tn0: usize, top0: usize, cur: usize,
                               Ghost(h): Ghost<H>, Ghost(nd): Ghost<Node>, Ghost(oj): Ghost<AObj>, Ghost(n0): Ghost<int>,
                               Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                               Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>,
                               Tracked(np): Tracked<&mut Map<int, PointsTo<usize>>>) -> (r: (Ghost<H>, Ghost<bool>))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *old(t), n0, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        src_ok(*c, *old(src), *old(t)),
        0 <= n0 <= old(st).order.len(), tn0 <= old(t).tn,
        n0 == 0 ==> tn0 == 0,
        n0 >= 1 ==> tn0 >= 1 && tpg(*old(st), n0 - 1) == tn0 - 1 && tend(h, *old(st), n0 - 1) == top0,
        nd.key is Ref, from(h, nd.key->Ref_0), weak_map(*c, oj), obj(h, nd.key->Ref_0) == hidden(oj),
        oj.words[3] == nd.ix, oj.words[4] == nd.bk,
        slot_ok(*c, h.objs.len() as int, nd.key), slot_ok(*c, h.objs.len() as int, nd.ix), slot_ok(*c, h.objs.len() as int, nd.bk),
        i < nn, nodes_mem(*old(np), nptr, nn as int),
        old(np)[6 * i + 1].is_init() && old(np)[6 * i + 1].value() == enc(h.addr, nd.key),
        old(np)[6 * i + 4].is_init() && old(np)[6 * i + 4].value() == enc(h.addr, nd.ix),
        old(np)[6 * i + 5].is_init() && old(np)[6 * i + 5].value() == enc(h.addr, nd.bk),
        rvp.len() > rv.len() + 4 * i + 3, rvp[rv.len() + 4 * i + 2] == nd.ix, rvp[rv.len() + 4 * i + 3] == nd.bk,
        copied(*old(st), nd.key->Ref_0), cur == old(st).addr2[nd.key->Ref_0],
    ensures ({
        let h2 = r.0@;
        let z = r.1@;
        let j = nd.key->Ref_0;
        &&& heap_ok(*c, h2) && others_ok(h2, ro.others)
        &&& inv(*c, h2, *final(st), *final(t), n0, 0, rvp) && roots_ok(*c, h2, *final(st), rptr, rv, rv.len() as int)
        &&& src_ok(*c, *final(src), *final(t))
        &&& grows(h, *old(st), *final(st)) && final(st).addr2.len() == old(st).addr2.len()
        &&& final(t).ttab == old(t).ttab && final(t).tused == old(t).tused && final(t).tcap == old(t).tcap
            && final(t).rs == old(t).rs && final(t).mx == old(t).mx && old(t).tn <= final(t).tn
        &&& nodes_mem(*final(np), nptr, nn as int)
        &&& forall|q: int| q != 6 * i + 3 ==> #[trigger] final(np)[q] == old(np)[q]
        &&& final(np)[6 * i + 3].is_init() && final(np)[6 * i + 3].value() == (if z { ZAPPED } else { 0 })
        &&& h2.loc == h.loc && h2.addr == h.addr && h2.objs.len() == h.objs.len()
        &&& obj(h2, j) == unhide(obj(h, j), nd.ix, nd.bk) || obj(h2, j) == killed(obj(h, j), c.nullid@, true)
        &&& forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() && x != j ==> obj(h2, x) == obj(h, x)
                || (from(h, x) && backing(*c, h, nd.bk, x) && zapped_arr(*c, h, obj(h, x), obj(h2, x)))
    }),
{
    let ghost s0 = *st;
    let ghost j = nd.key->Ref_0;
    let ghost ki = rv.len() + 4 * i;
    proof { lemma_from_obj(*c, h, j); }
    let bkw = nword(nptr, 6 * i + 5, Ghost(nn as int), Tracked(&*np));
    let ixw = nword(nptr, 6 * i + 4, Ghost(nn as int), Tracked(&*np));
    let (zapped, hzr) = zap_backing(c, &*t, bkw, Ghost(h), Ghost(nd.bk), Ghost(n0), Ghost(rptr), Ghost(rv), Ghost(rvp),
                                    Tracked(st), Tracked(ro));
    let ghost hz = hzr@;
    let ghost s1 = *st;
    proof {
        assert(copied(s0, j));
        assert(obj(hz, j) == obj(h, j));
        assert(slot_ok(*c, hz.objs.len() as int, nd.ix) && slot_ok(*c, hz.objs.len() as int, nd.bk));
        assert(ixw == enc(hz.addr, nd.ix) && bkw == enc(hz.addr, nd.bk));
        assert(rvp[ki + 2] == nd.ix && rvp[ki + 3] == nd.bk);
        assert(n0 <= st.order.len());
    }
    let (a, b) = fwd_two(c, src, t, ixw, bkw, Ghost(hz), Ghost(nd.ix), Ghost(nd.bk), Ghost(n0), Ghost(ki + 2), Ghost(rptr),
                         Ghost(rv), Ghost(rvp), Tracked(st), Tracked(ro));
    let ghost s3 = *st;
    let ghost k = s0.pos[j];
    proof {
        assert(copied(s1, j));
        assert(copied(s3, j) && s3.pos[j] == k);
        assert(s3.addr2[j] == s0.addr2[j]);
        assert(cur == s3.addr2[j]);
        assert(t.tn == s3.tss.len() && s1.tss.len() <= s3.tss.len());
        assert(s3.tloc[k] == s0.tloc[k]);
        // The main scan's end is still where it was.
        if n0 >= 1 {
            assert(s3.tloc[n0 - 1] == s0.tloc[n0 - 1] && s3.order[n0 - 1] == s0.order[n0 - 1]);
            assert(tsz(hz, s3, n0 - 1) == tsz(h, s0, n0 - 1));
        }
    }
    let sc = copy_scanned(c, &*t, cur, tn0, top0, Ghost(hz), Ghost(j), Ghost(n0), Tracked(&*st));
    let w3 = if sc { a } else { ixw };
    let w4 = if sc { b } else { bkw };
    let ghost o2 = unhide(obj(hz, j), nd.ix, nd.bk);
    proof {
        let oo = obj(hz, j);
        lemma_from_obj(*c, hz, j);
        assert(oo == hidden(oj));
        assert(oo.words[3] is Raw && oo.words[4] is Raw);
        assert(o2.words[3] == nd.ix && o2.words[4] == nd.bk);
        assert(lay(o2) == lay(oo)) by { assert(o2.words[0] == oo.words[0] && o2.words.len() == oo.words.len()); }
        assert(obj_ok(oo) && cls_ok(*c, oo));
        assert forall|q: int| 0 <= q < lay(o2).size && !(lay(o2).lo <= q < lay(o2).hi) implies #[trigger] o2.words[q] is Raw by {
            assert(oo.words[q] is Raw);
        }
        assert forall|q: int| lay(o2).lo <= q < lay(o2).hi implies #[trigger] slot_ok(*c, hz.objs.len() as int, o2.words[q]) by {
            assert(slots_ok(*c, hz, j));
            if q != 3 && q != 4 { assert(slot_ok(*c, hz.objs.len() as int, oo.words[q])); }
        }
        assert(same_shape(*c, hz.objs.len() as int, oo, o2));
        assert(lay(oo).lo == 1 && lay(oo).hi >= 5) by { assert(lay(oj) == lay(oo)) by { assert(oj.words[0] == oo.words[0] && oj.words.len() == oo.words.len()); } }
        assert(sc == (k < n0));
    }
    restore_copy(c, &*t, cur, w3, w4, Ghost(hz), Ghost(j), Ghost(o2), Ghost(n0), Ghost(rptr), Ghost(rv), Ghost(rvp), Tracked(st));
    proof {
        let s4 = *st;
        let h2 = with_obj(hz, j, o2);
        assert forall|x: int| 0 <= x < h2.objs.len() && !from(h2, x) implies #[trigger] ro.others.contains_key(x)
            && ro.others[x].ptr()@.addr == h2.addr[x] - 1 by {
            assert(!from(hz, x) && 0 <= x < hz.objs.len());
            assert(ro.others.contains_key(x));
            assert(ro.others[x].ptr()@.addr == hz.addr[x] - 1);
        }
        assert forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() && x != j implies obj(h2, x) == obj(h, x)
            || (from(h, x) && backing(*c, h, nd.bk, x) && zapped_arr(*c, h, obj(h, x), obj(h2, x))) by {
            assert(obj(h2, x) == obj(hz, x));
        }
        assert(bk_ok(h, s0));
        lemma_grows_refl(h, s0);
        lemma_grows_trans(h, s0, s1, s3);
        assert(grows(h, s0, s4)) by {
            assert forall|jj: int| 0 <= jj < s0.addr2.len() && (copied(s0, jj) || !from(h, jj)) implies #[trigger] s4.addr2[jj] == s0.addr2[jj] by {
                assert(s3.addr2[jj] == s0.addr2[jj]);
            }
        }
        assert(obj(h2, j) == unhide(obj(h, j), nd.ix, nd.bk));
    }
    set_nword(nptr, 6 * i + 3, if zapped { ZAPPED } else { 0 }, Ghost(nn as int), Tracked(np));
    (Ghost(with_obj(hz, j, o2)), Ghost(zapped))
}

/// One hidden weak map's node (`nodes`'s `i`, key `j`, the map before
/// hiding `oj`): if the map survived, its dead values are nulled
/// (`zap_backing`), its hidden fields forwarded and written back into its
/// copy (encoded for the copy's place before or after the main scan's
/// end); if it died, it is reset (`kill_key`). Marks the node: zapped or 0.
pub fn weak_one<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, nptr: *mut usize, i: usize, nn: usize,
                               tn0: usize, top0: usize,
                               Ghost(h): Ghost<H>, Ghost(nd): Ghost<Node>, Ghost(oj): Ghost<AObj>, Ghost(n0): Ghost<int>,
                               Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                               Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>,
                               Tracked(np): Tracked<&mut Map<int, PointsTo<usize>>>) -> (r: (Ghost<H>, Ghost<bool>))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), others_ok(h, ro.others), ctab_ok(*c, ro.ctp),
        inv(*c, h, *old(st), *old(t), n0, 0, rvp), roots_ok(*c, h, *old(st), rptr, rv, rv.len() as int),
        src_ok(*c, *old(src), *old(t)),
        0 <= n0 <= old(st).order.len(), tn0 <= old(t).tn,
        n0 == 0 ==> tn0 == 0,
        n0 >= 1 ==> tn0 >= 1 && tpg(*old(st), n0 - 1) == tn0 - 1 && tend(h, *old(st), n0 - 1) == top0,
        nd.key is Ref, from(h, nd.key->Ref_0), weak_map(*c, oj), obj(h, nd.key->Ref_0) == hidden(oj),
        oj.words[3] == nd.ix, oj.words[4] == nd.bk,
        slot_ok(*c, h.objs.len() as int, nd.key), slot_ok(*c, h.objs.len() as int, nd.ix), slot_ok(*c, h.objs.len() as int, nd.bk),
        i < nn, nodes_mem(*old(np), nptr, nn as int),
        old(np)[6 * i + 1].is_init() && old(np)[6 * i + 1].value() == enc(h.addr, nd.key),
        old(np)[6 * i + 4].is_init() && old(np)[6 * i + 4].value() == enc(h.addr, nd.ix),
        old(np)[6 * i + 5].is_init() && old(np)[6 * i + 5].value() == enc(h.addr, nd.bk),
        rvp.len() > rv.len() + 4 * i + 3, rvp[rv.len() + 4 * i + 2] == nd.ix, rvp[rv.len() + 4 * i + 3] == nd.bk,
    ensures ({
        let h2 = r.0@;
        let z = r.1@;
        let j = nd.key->Ref_0;
        &&& heap_ok(*c, h2) && others_ok(h2, ro.others)
        &&& inv(*c, h2, *final(st), *final(t), n0, 0, rvp) && roots_ok(*c, h2, *final(st), rptr, rv, rv.len() as int)
        &&& src_ok(*c, *final(src), *final(t))
        &&& grows(h, *old(st), *final(st)) && final(st).addr2.len() == old(st).addr2.len()
        &&& final(t).ttab == old(t).ttab && final(t).tused == old(t).tused && final(t).tcap == old(t).tcap
            && final(t).rs == old(t).rs && final(t).mx == old(t).mx && old(t).tn <= final(t).tn
        &&& nodes_mem(*final(np), nptr, nn as int)
        &&& forall|q: int| q != 6 * i + 3 ==> #[trigger] final(np)[q] == old(np)[q]
        &&& final(np)[6 * i + 3].is_init() && final(np)[6 * i + 3].value() == (if z { ZAPPED } else { 0 })
        &&& h2.loc == h.loc && h2.addr == h.addr && h2.objs.len() == h.objs.len()
        &&& obj(h2, j) == unhide(obj(h, j), nd.ix, nd.bk) || obj(h2, j) == killed(obj(h, j), c.nullid@, true)
        &&& forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() && x != j ==> obj(h2, x) == obj(h, x)
                || (from(h, x) && backing(*c, h, nd.bk, x) && zapped_arr(*c, h, obj(h, x), obj(h2, x)))
    }),
{
    let ghost s0 = *st;
    let ghost j = nd.key->Ref_0;
    let ghost ki = rv.len() + 4 * i;
    proof {
        lemma_from_obj(*c, h, j);
        assert(hdr(obj(h, j)) == hdr(oj));
        assert(active(obj(h, j)));
    }
    let kw = nword(nptr, 6 * i + 1, Ghost(nn as int), Tracked(&*np));
    let (dead, _act, s, off, cur) = key_status(c, kw, Ghost(h), Ghost(nd.key), Ghost(*t), Ghost(n0), Ghost(0int), Ghost(rvp),
                                              Tracked(&*st), Tracked(ro));
    if dead {
        kill_key(c, s, off, true, Ghost(h), Ghost(j), Ghost(*t), Ghost(n0), Ghost(0int), Ghost(rv), Ghost(rvp), Ghost(rptr),
                 Ghost(rv.len() as int), Tracked(st), Tracked(ro));
        let ghost h2 = with_obj(h, j, killed(obj(h, j), c.nullid@, true));
        proof {
            lemma_grows_refl(h, s0);
            assert(bk_ok(h, s0));
            assert forall|x: int| 0 <= x < h2.objs.len() && !from(h2, x) implies #[trigger] ro.others.contains_key(x)
                && ro.others[x].ptr()@.addr == h2.addr[x] - 1 by {
                assert(ro.others.contains_key(x) && ro.others[x].ptr()@.addr == h.addr[x] - 1);
            }
            assert(grows(h, s0, *st)) by {
                assert forall|jj: int| #[trigger] copied(s0, jj) implies copied(*st, jj) && st.pos[jj] == s0.pos[jj] by {}
            }
        }
        set_nword(nptr, 6 * i + 3, 0, Ghost(nn as int), Tracked(np));
        proof {
            assert forall|x: int| #![trigger obj(h2, x)] 0 <= x < h.objs.len() && x != j implies obj(h2, x) == obj(h, x) by {}
            assert(obj(h2, j) == killed(obj(h, j), c.nullid@, true));
            assert(h2.loc == h.loc && h2.addr == h.addr && h2.objs.len() == h.objs.len());
        }
        return (Ghost(h2), Ghost(false));
    }
    proof { assert(copied(*st, j)); }
    weak_live(c, src, t, nptr, i, nn, tn0, top0, cur, Ghost(h), Ghost(nd), Ghost(oj), Ghost(n0), Ghost(rptr), Ghost(rv), Ghost(rvp),
              Tracked(st), Tracked(ro), Tracked(np))
}


/// Word `q` of the node array is a callback node's mark (verdict) word.
pub open spec fn mark_word(q: int, ncb: int) -> bool { 0 <= q && q % 6 == 3 && q / 6 < ncb }

/// How the weak pass may have changed object `x` (relative to the hidden
/// heap `hs`): not at all; a hidden map got its fields back or was reset;
/// an array of a hidden map's backing list had values nulled.
pub open spec fn wchanged(c: Ctx, hs: H, hw: H, nodes2: Seq<Node>, ncb: int, x: int) -> bool {
    ||| obj(hw, x) == obj(hs, x)
    ||| exists|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes2[m].key == AVal::Ref(x)
            && (obj(hw, x) == unhide(obj(hs, x), nodes2[m].ix, nodes2[m].bk) || obj(hw, x) == killed(obj(hs, x), c.nullid@, true))
    ||| from(hs, x) && zapped_arr(c, hs, obj(hs, x), obj(hw, x))
            && exists|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && backing(c, hs, nodes2[m].bk, x)
}

/// The weak pass's result: every hidden map restored or reset, arrays
/// zapped, the nodes marked.
pub open spec fn weak_ok(c: Ctx, hs: H, hw: H, nodes2: Seq<Node>, nodesw: Seq<Node>, ncb: int) -> bool {
    &&& hw.loc == hs.loc && hw.addr == hs.addr && hw.objs.len() == hs.objs.len()
    &&& nodesw.len() == nodes2.len()
    &&& forall|m: int| 0 <= m < nodes2.len() ==> #[trigger] nodesw[m] == (Node { zap: nodesw[m].zap, ..nodes2[m] })
    &&& forall|m: int| 0 <= m < nodes2.len() && (#[trigger] nodesw[m]).zap ==> nodes2[m].hid && m < ncb
    &&& forall|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid ==>
            obj(hw, nodes2[m].key->Ref_0) == unhide(obj(hs, nodes2[m].key->Ref_0), nodes2[m].ix, nodes2[m].bk)
            || obj(hw, nodes2[m].key->Ref_0) == killed(obj(hs, nodes2[m].key->Ref_0), c.nullid@, true)
    &&& forall|x: int| 0 <= x < hs.objs.len() ==> #[trigger] wchanged(c, hs, hw, nodes2, ncb, x)
}

/// Zapping twice is zapping (headers unchanged in between).
pub proof fn lemma_zap_trans(c: Ctx, hs: H, hc: H, os: AObj, oc: AObj, o2: AObj)
    requires
        zapped_arr(c, hs, os, oc), zapped_arr(c, hc, oc, o2), hc.objs.len() == hs.objs.len(),
        forall|y: int| #![trigger obj(hc, y)] 0 <= y < hs.objs.len() ==> hcid(hdr(obj(hc, y))) == hcid(hdr(obj(hs, y))),
        !(c.nullid@ < hs.objs.len() && 0 <= c.nullid@) || true,
        hdr(oc) == hdr(os),
    ensures zapped_arr(c, hs, os, o2),
{
    assert forall|k: int| 0 <= k < os.words.len() implies #[trigger] o2.words[k] == os.words[k]
        || (2 <= k && (k - 2) % 2 == 1 && o2.words[k] == AVal::Ref(c.nullid@) && os.words[k] is Ref
            && 0 <= os.words[k]->Ref_0 < hs.objs.len() && hcid(hdr(obj(hs, os.words[k]->Ref_0))) != c.tomb_cid) by {
        assert(oc.words[k] == os.words[k] || (2 <= k && (k - 2) % 2 == 1 && oc.words[k] == AVal::Ref(c.nullid@) && os.words[k] is Ref
            && 0 <= os.words[k]->Ref_0 < hs.objs.len() && hcid(hdr(obj(hs, os.words[k]->Ref_0))) != c.tomb_cid));
        assert(o2.words[k] == oc.words[k] || (2 <= k && (k - 2) % 2 == 1 && o2.words[k] == AVal::Ref(c.nullid@) && oc.words[k] is Ref
            && 0 <= oc.words[k]->Ref_0 < hc.objs.len() && hcid(hdr(obj(hc, oc.words[k]->Ref_0))) != c.tomb_cid));
        if o2.words[k] != oc.words[k] && oc.words[k] == os.words[k] {
            let y = os.words[k]->Ref_0;
            assert(hcid(hdr(obj(hc, y))) == hcid(hdr(obj(hs, y))));
        }
    }
}

/// The weak pass (after the main scan, before the finalizer pass): each
/// hidden weak map's node in order (`weak_one`).
pub fn weak_pass<S: PageSource>(c: &Ctx, src: &mut S, t: &mut Tos, nptr: *mut usize, ncb: usize, nn: usize,
                                tn0: usize, top0: usize,
                                Ghost(h): Ghost<H>, Ghost(hs): Ghost<H>, Ghost(nodes): Ghost<Seq<Node>>, Ghost(nodes2): Ghost<Seq<Node>>,
                                Ghost(n0): Ghost<int>,
                                Ghost(rptr): Ghost<*mut usize>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(rvp): Ghost<Seq<AVal>>,
                                Tracked(st): Tracked<&mut St>, Tracked(ro): Tracked<&Ro>,
                                Tracked(np): Tracked<&mut Map<int, PointsTo<usize>>>) -> (r: (Ghost<H>, Ghost<Seq<Node>>))
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, hs), others_ok(hs, ro.others), ctab_ok(*c, ro.ctp),
        heap_ok(*c, h),
        inv(*c, hs, *old(st), *old(t), n0, 0, rvp), roots_ok(*c, hs, *old(st), rptr, rv, rv.len() as int),
        src_ok(*c, *old(src), *old(t)),
        0 <= n0 <= old(st).order.len(), tn0 <= old(t).tn,
        n0 == 0 ==> tn0 == 0,
        n0 >= 1 ==> tn0 >= 1 && tpg(*old(st), n0 - 1) == tn0 - 1 && tend(hs, *old(st), n0 - 1) == top0,
        c.map_cid != c.list_cid,
        ncb <= nn, nodes.len() == nn,
        hide_ok(*c, h, hs, nodes, nodes2, ncb as int),
        rvp == fin_roots(rv, nodes2),
        keys_ok(h, nodes, ncb as int),
        forall|m: int| 0 <= m < nn ==> slot_ok(*c, h.objs.len() as int, (#[trigger] nodes[m]).key),
        nodes_mem(*old(np), nptr, nn as int),
        forall|m: int| 0 <= m < ncb ==> (#[trigger] old(np)[6 * m + 1]).is_init() && old(np)[6 * m + 1].value() == enc(h.addr, nodes[m].key),
        forall|m: int| 0 <= m < ncb ==> (#[trigger] old(np)[6 * m + 3]).is_init()
            && old(np)[6 * m + 3].value() == (if nodes2[m].hid { HIDDEN } else { 0 }),
        forall|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid ==>
            old(np)[6 * m + 4].is_init() && old(np)[6 * m + 4].value() == enc(h.addr, nodes2[m].ix)
            && old(np)[6 * m + 5].is_init() && old(np)[6 * m + 5].value() == enc(h.addr, nodes2[m].bk),
    ensures ({
        let hw = r.0@;
        let nodesw = r.1@;
        &&& heap_ok(*c, hw) && others_ok(hw, ro.others)
        &&& inv(*c, hw, *final(st), *final(t), n0, 0, rvp) && roots_ok(*c, hw, *final(st), rptr, rv, rv.len() as int)
        &&& src_ok(*c, *final(src), *final(t))
        &&& grows(hs, *old(st), *final(st)) && final(st).addr2.len() == old(st).addr2.len()
        &&& final(t).ttab == old(t).ttab && final(t).tused == old(t).tused && final(t).tcap == old(t).tcap
            && final(t).rs == old(t).rs && final(t).mx == old(t).mx && old(t).tn <= final(t).tn
        &&& weak_ok(*c, hs, hw, nodes2, nodesw, ncb as int)
        &&& nodes_mem(*final(np), nptr, nn as int)
        &&& forall|q: int| !mark_word(q, ncb as int) ==> #[trigger] final(np)[q] == old(np)[q]
        &&& forall|m: int| 0 <= m < ncb ==> (#[trigger] final(np)[6 * m + 3]).is_init()
                && (final(np)[6 * m + 3].value() == ZAPPED) == nodesw[m].zap
    }),
{
    let ghost s0 = *st;
    let ghost t0 = *t;
    let ghost np0 = *np;
    let ghost mut hc = hs;
    let ghost mut nc = nodes2.map_values(|nd: Node| Node { zap: false, ..nd });
    let mut i: usize = 0;
    proof {
        lemma_grows_refl(hs, s0);
        assert forall|x: int| 0 <= x < hs.objs.len() implies #[trigger] wchanged(*c, hs, hc, nodes2, ncb as int, x) by {}
    }
    while i < ncb
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, hs), ctab_ok(*c, ro.ctp), heap_ok(*c, h),
            heap_ok(*c, hc), others_ok(hc, ro.others),
            inv(*c, hc, *st, *t, n0, 0, rvp), roots_ok(*c, hc, *st, rptr, rv, rv.len() as int),
            src_ok(*c, *src, *t),
            0 <= n0 <= s0.order.len(), tn0 <= t0.tn, t0.tn <= t.tn,
            n0 == 0 ==> tn0 == 0,
            n0 >= 1 ==> tn0 >= 1 && tpg(s0, n0 - 1) == tn0 - 1 && tend(hs, s0, n0 - 1) == top0,
            grows(hs, s0, *st), st.addr2.len() == s0.addr2.len(), s0.addr2.len() == hs.objs.len(),
            t.ttab == t0.ttab, t.tused == t0.tused, t.tcap == t0.tcap, t.rs == t0.rs, t.mx == t0.mx,
            c.map_cid != c.list_cid,
            i <= ncb, ncb <= nn, nodes.len() == nn, nc.len() == nn,
            hide_ok(*c, h, hs, nodes, nodes2, ncb as int),
            rvp == fin_roots(rv, nodes2),
            keys_ok(h, nodes, ncb as int),
            forall|y: int| #![trigger size(hc, y)] 0 <= y < hs.objs.len() ==> size(hc, y) == size(hs, y),
            forall|m: int| 0 <= m < nn ==> slot_ok(*c, h.objs.len() as int, (#[trigger] nodes[m]).key),
            hc.loc == hs.loc, hc.addr == hs.addr, hc.objs.len() == hs.objs.len(),
            forall|y: int| #![trigger obj(hc, y)] 0 <= y < hs.objs.len() ==> hcid(hdr(obj(hc, y))) == hcid(hdr(obj(hs, y)))
                && htag(hdr(obj(hc, y))) == htag(hdr(obj(hs, y))),
            forall|m: int| 0 <= m < nn ==> #[trigger] nc[m] == (Node { zap: nc[m].zap, ..nodes2[m] }),
            forall|m: int| 0 <= m < nn && (#[trigger] nc[m]).zap ==> nodes2[m].hid && m < i,
            forall|m: int| i <= m < ncb && (#[trigger] nodes2[m]).hid ==> obj(hc, nodes2[m].key->Ref_0) == obj(hs, nodes2[m].key->Ref_0),
            forall|m: int| 0 <= m < i && (#[trigger] nodes2[m]).hid ==>
                obj(hc, nodes2[m].key->Ref_0) == unhide(obj(hs, nodes2[m].key->Ref_0), nodes2[m].ix, nodes2[m].bk)
                || obj(hc, nodes2[m].key->Ref_0) == killed(obj(hs, nodes2[m].key->Ref_0), c.nullid@, true),
            forall|x: int| 0 <= x < hs.objs.len() ==> #[trigger] wchanged(*c, hs, hc, nodes2, ncb as int, x),
            nodes_mem(*np, nptr, nn as int),
            forall|q: int| !mark_word(q, ncb as int) ==> #[trigger] np[q] == np0[q],
            forall|m: int| i <= m < ncb ==> #[trigger] np[6 * m + 3] == np0[6 * m + 3],
            forall|m: int| 0 <= m < i ==> (#[trigger] np[6 * m + 3]).is_init() && (np[6 * m + 3].value() == ZAPPED) == nc[m].zap,
            forall|m: int| 0 <= m < ncb ==> (#[trigger] np0[6 * m + 1]).is_init() && np0[6 * m + 1].value() == enc(h.addr, nodes[m].key),
            forall|m: int| 0 <= m < ncb ==> (#[trigger] np0[6 * m + 3]).is_init()
                && np0[6 * m + 3].value() == (if nodes2[m].hid { HIDDEN } else { 0 }),
            forall|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid ==>
                np0[6 * m + 4].is_init() && np0[6 * m + 4].value() == enc(h.addr, nodes2[m].ix)
                && np0[6 * m + 5].is_init() && np0[6 * m + 5].value() == enc(h.addr, nodes2[m].bk),
        decreases ncb - i,
    {
        let ghost ii = i as int;
        proof {
            assert(np[6 * ii + 3] == np0[6 * ii + 3]);
            assert(np0[6 * ii + 3].is_init());
        }
        let mk = nword(nptr, 6 * i + 3, Ghost(nn as int), Tracked(&*np));
        if mk == HIDDEN {
            let ghost nd = nodes2[ii];
            let ghost j = nd.key->Ref_0;
            let ghost oj = obj(h, j);
            let ghost h1 = hc;
            let ghost s1 = *st;
            let ghost np1 = *np;
            proof {
                assert(nd.hid);
                assert(nodes2[ii] == (Node { ix: nd.ix, bk: nd.bk, hid: nd.hid, ..nodes[ii] }));
                assert(obj(hc, j) == obj(hs, j));
                assert(obj(hs, j) == hidden(oj));
                lemma_from_obj(*c, h, j);
                assert(slots_ok(*c, h, j));
                assert(lay(oj).lo == 1 && lay(oj).hi >= 5);
                assert(slot_ok(*c, h.objs.len() as int, oj.words[3]) && slot_ok(*c, h.objs.len() as int, oj.words[4]));
                assert(from(hc, j));
                assert(!mark_word(6 * ii + 1, ncb as int));
                assert(np[6 * ii + 1] == np0[6 * ii + 1]);
                assert(!mark_word(6 * ii + 4, ncb as int));
                assert(np[6 * ii + 4] == np0[6 * ii + 4]);
                assert(!mark_word(6 * ii + 5, ncb as int));
                assert(np[6 * ii + 5] == np0[6 * ii + 5]);
                assert(nd.key == nodes[ii].key);
                let ki = rv.len() + 4 * ii;
                assert(rvp.len() == rv.len() + 4 * nodes2.len());
                assert(rvp[ki + 2] == nodes2[(4 * ii + 2) / 4].ix);
                assert((4 * ii + 2) / 4 == ii && (4 * ii + 2) % 4 == 2) by (nonlinear_arith) requires ii >= 0;
                assert((4 * ii + 3) / 4 == ii && (4 * ii + 3) % 4 == 3) by (nonlinear_arith) requires ii >= 0;
                assert(rvp[ki + 2] == nd.ix && rvp[ki + 3] == nd.bk);
                if n0 >= 1 {
                    assert(s1.tloc[n0 - 1] == s0.tloc[n0 - 1] && s1.order[n0 - 1] == s0.order[n0 - 1]);
                    assert(size(hc, s0.order[n0 - 1]) == size(hs, s0.order[n0 - 1]));
                }
            }
            let r = weak_one(c, src, t, nptr, i, nn, tn0, top0, Ghost(hc), Ghost(nd), Ghost(oj), Ghost(n0), Ghost(rptr), Ghost(rv), Ghost(rvp),
                             Tracked(st), Tracked(ro), Tracked(np));
            proof {
                let h2 = r.0@;
                let z = r.1@;
                let s2 = *st;
                assert(bk_ok(hc, s1));
                lemma_grows_trans(hs, s0, s1, s2);
                let nc2 = nc.update(ii, Node { zap: z, ..nd });
                lemma_wstep(*c, h, hs, h1, h2, nodes, nodes2, ncb as int, ii, oj);
                assert forall|m: int| 0 <= m < nn implies #[trigger] nc2[m] == (Node { zap: nc2[m].zap, ..nodes2[m] }) by {
                    if m != ii { assert(nc[m] == (Node { zap: nc[m].zap, ..nodes2[m] })); }
                }
                assert forall|m: int| 0 <= m < nn && (#[trigger] nc2[m]).zap implies nodes2[m].hid && m < i + 1 by {
                    if m != ii { assert(nc[m].zap); }
                }
                assert forall|q: int| !mark_word(q, ncb as int) implies #[trigger] np[q] == np0[q] by {
                    assert(np1[q] == np0[q]);
                    assert(q != 6 * ii + 3) by { if q == 6 * ii + 3 { assert(mark_word(q, ncb as int)); } }
                }
                assert forall|m: int| i + 1 <= m < ncb implies #[trigger] np[6 * m + 3] == np0[6 * m + 3] by {
                    assert(np1[6 * m + 3] == np0[6 * m + 3]);
                }
                assert forall|m: int| 0 <= m < i + 1 implies (#[trigger] np[6 * m + 3]).is_init() && (np[6 * m + 3].value() == ZAPPED) == nc2[m].zap by {
                    if m < i { assert(np[6 * m + 3] == np1[6 * m + 3]); }
                }
                assert forall|m: int| i + 1 <= m < ncb && (#[trigger] nodes2[m]).hid implies obj(h2, nodes2[m].key->Ref_0) == obj(hs, nodes2[m].key->Ref_0) by {}
                hc = h2;
                nc = nc2;
            }
        } else {
            proof {
                assert(!nodes2[ii].hid);
                assert(!nc[ii].zap);
                assert(np[6 * ii + 3].value() == 0);
            }
        }
        i += 1;
    }
    proof {
        assert forall|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid implies
            obj(hc, nodes2[m].key->Ref_0) == unhide(obj(hs, nodes2[m].key->Ref_0), nodes2[m].ix, nodes2[m].bk)
            || obj(hc, nodes2[m].key->Ref_0) == killed(obj(hs, nodes2[m].key->Ref_0), c.nullid@, true) by {}
        assert(weak_ok(*c, hs, hc, nodes2, nc, ncb as int));
    }
    (Ghost(hc), Ghost(nc))
}


/// One step of the weak pass on the heap facts (`weak_one`'s result).
pub proof fn lemma_wstep(c: Ctx, h: H, hs: H, h1: H, h2: H, nodes: Seq<Node>, nodes2: Seq<Node>, ncb: int, i: int, oj: AObj)
    requires
        ctx_ok(c), heap_ok(c, h), heap_ok(c, h1), hide_ok(c, h, hs, nodes, nodes2, ncb), keys_ok(h, nodes, ncb), c.map_cid != c.list_cid,
        0 <= i < ncb, ncb <= nodes.len(), nodes2[i].hid, oj == obj(h, nodes2[i].key->Ref_0), heap_ok(c, hs),
        h1.loc == hs.loc, h1.addr == hs.addr, h1.objs.len() == hs.objs.len(),
        forall|y: int| #![trigger size(h1, y)] 0 <= y < hs.objs.len() ==> size(h1, y) == size(hs, y),
        forall|y: int| #![trigger obj(h1, y)] 0 <= y < hs.objs.len() ==> hcid(hdr(obj(h1, y))) == hcid(hdr(obj(hs, y)))
            && htag(hdr(obj(h1, y))) == htag(hdr(obj(hs, y))),
        forall|m: int| i <= m < ncb && (#[trigger] nodes2[m]).hid ==> obj(h1, nodes2[m].key->Ref_0) == obj(hs, nodes2[m].key->Ref_0),
        forall|m: int| 0 <= m < i && (#[trigger] nodes2[m]).hid ==>
            obj(h1, nodes2[m].key->Ref_0) == unhide(obj(hs, nodes2[m].key->Ref_0), nodes2[m].ix, nodes2[m].bk)
            || obj(h1, nodes2[m].key->Ref_0) == killed(obj(hs, nodes2[m].key->Ref_0), c.nullid@, true),
        forall|x: int| 0 <= x < hs.objs.len() ==> #[trigger] wchanged(c, hs, h1, nodes2, ncb, x),
        h2.loc == h1.loc && h2.addr == h1.addr && h2.objs.len() == h1.objs.len(),
        obj(h2, nodes2[i].key->Ref_0) == unhide(obj(h1, nodes2[i].key->Ref_0), nodes2[i].ix, nodes2[i].bk)
            || obj(h2, nodes2[i].key->Ref_0) == killed(obj(h1, nodes2[i].key->Ref_0), c.nullid@, true),
        forall|x: int| #![trigger obj(h2, x)] 0 <= x < h1.objs.len() && x != nodes2[i].key->Ref_0 ==> obj(h2, x) == obj(h1, x)
            || (from(h1, x) && backing(c, h1, nodes2[i].bk, x) && zapped_arr(c, h1, obj(h1, x), obj(h2, x))),
    ensures
        forall|y: int| #![trigger size(h2, y)] 0 <= y < hs.objs.len() ==> size(h2, y) == size(hs, y),
        forall|y: int| #![trigger obj(h2, y)] 0 <= y < hs.objs.len() ==> hcid(hdr(obj(h2, y))) == hcid(hdr(obj(hs, y)))
            && htag(hdr(obj(h2, y))) == htag(hdr(obj(hs, y))),
        forall|m: int| i + 1 <= m < ncb && (#[trigger] nodes2[m]).hid ==> obj(h2, nodes2[m].key->Ref_0) == obj(hs, nodes2[m].key->Ref_0),
        forall|m: int| 0 <= m < i + 1 && (#[trigger] nodes2[m]).hid ==>
            obj(h2, nodes2[m].key->Ref_0) == unhide(obj(hs, nodes2[m].key->Ref_0), nodes2[m].ix, nodes2[m].bk)
            || obj(h2, nodes2[m].key->Ref_0) == killed(obj(hs, nodes2[m].key->Ref_0), c.nullid@, true),
        forall|x: int| 0 <= x < hs.objs.len() ==> #[trigger] wchanged(c, hs, h2, nodes2, ncb, x),
{
    let ii = i;
    let nd = nodes2[i];
    let j = nd.key->Ref_0;
    assert(nodes2[ii] == (Node { ix: nd.ix, bk: nd.bk, hid: nd.hid, ..nodes[ii] }));
    assert(from(h, j) && weak_map(c, oj) && obj(hs, j) == hidden(oj));
    assert(obj(h1, j) == obj(hs, j));
    lemma_from_obj(c, h, j);
        assert forall|y: int| #![trigger size(h2, y)] 0 <= y < hs.objs.len() implies size(h2, y) == size(hs, y) by {
            assert(size(h1, y) == size(hs, y));
            if 0 <= y < hs.objs.len() && obj(h2, y) != obj(h1, y) {
                if y == j {
                    lemma_from_obj(c, h1, j);
                    if obj(h2, j) == killed(obj(h1, j), c.nullid@, true) {
                        assert(obj(h1, j) == hidden(oj) && hdr(obj(h1, j)) == hdr(oj) && active(obj(h1, j)));
                        assert(from(h1, j));
                        lemma_killed_shape(c, h1, j, true);
                        assert(lay(obj(h2, j)) == lay(obj(h1, j)));
                    } else {
                        assert(obj(h1, j) == hidden(oj) && htag(hdr(oj)) == INSTANCE_TAG);
                        assert(obj(h2, j).words[0] == obj(h1, j).words[0] && obj(h2, j).words[1] == obj(h1, j).words[1]);
                        assert(obj(h2, j).words.len() == obj(h1, j).words.len() && obj(h2, j).cbits == obj(h1, j).cbits);
                        assert(lay(obj(h2, j)) == lay(obj(h1, j)));
                    }
                } else {
                    assert(zapped_arr(c, h1, obj(h1, y), obj(h2, y)));
                    assert(obj_ok(obj(h1, y)));
                    assert(obj(h1, y).words.len() >= 2);
                    assert(obj(h2, y).words[0] == obj(h1, y).words[0]);
                    assert(obj(h2, y).words[1] == obj(h1, y).words[1]);
                    assert(htag(hdr(obj(h1, y))) == ARRAY_TAG);
                    assert(lay(obj(h2, y)) == lay(obj(h1, y)));
                }
            }
        }
        // Headers keep their class ids and tags.
        assert forall|y: int| #![trigger obj(h2, y)] 0 <= y < hs.objs.len() implies hcid(hdr(obj(h2, y))) == hcid(hdr(obj(hs, y)))
            && htag(hdr(obj(h2, y))) == htag(hdr(obj(hs, y))) by {
            assert(hcid(hdr(obj(h1, y))) == hcid(hdr(obj(hs, y))) && htag(hdr(obj(h1, y))) == htag(hdr(obj(hs, y))));
            if y == j {
                if obj(h2, j) == killed(obj(h1, j), c.nullid@, true) {
                    lemma_clear_bit(hdr(obj(h1, j)));
                    assert(hdr(obj(h1, j)) == hdr(oj));
                    if resettable(obj(h1, j)) { assert(hdr(reset(obj(h1, j), c.nullid@)) == hdr(obj(h1, j))); }
                } else {
                    assert(hdr(obj(h2, j)) == hdr(obj(h1, j)));
                }
            } else if obj(h2, y) != obj(h1, y) {
                assert(zapped_arr(c, h1, obj(h1, y), obj(h2, y)));
                assert(obj_ok(obj(h1, y)));
                assert(obj(h2, y).words[0] == obj(h1, y).words[0]);
            }
        }
        assert forall|x: int| 0 <= x < hs.objs.len() implies #[trigger] wchanged(c, hs, h2, nodes2, ncb as int, x) by {
            assert(wchanged(c, hs, h1, nodes2, ncb as int, x));
            if x == j {
                assert(obj(h1, j) == obj(hs, j));
                assert(0 <= ii < ncb && nodes2[ii].hid && nodes2[ii].key == AVal::Ref(x));
            } else if obj(h2, x) != obj(h1, x) {
                // A zapped array of this map's backing list.
                let l = nd.bk->Ref_0;
                assert(backing(c, h1, nd.bk, x));
                assert(obj(h1, l) == obj(hs, l)) by {
                    if obj(h1, l) != obj(hs, l) {
                        assert(wchanged(c, hs, h1, nodes2, ncb as int, l));
                        assert(hcid(hdr(obj(h1, l))) == hcid(hdr(obj(hs, l))) && htag(hdr(obj(h1, l))) == htag(hdr(obj(hs, l))));
                        if exists|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes2[m].key == AVal::Ref(l) {
                            let m = choose|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes2[m].key == AVal::Ref(l);
                            assert(weak_map(c, obj(h, l)));
                            assert(obj(hs, l) == hidden(obj(h, l)));
                            assert(hdr(obj(hs, l)) == hdr(obj(h, l)));
                            assert(false);
                        } else {
                            assert(zapped_arr(c, hs, obj(hs, l), obj(h1, l)));
                            assert(false);
                        }
                    }
                }
                assert(backing(c, hs, nd.bk, x));
                assert(hdr(obj(h1, x)) == hdr(obj(hs, x))) by {
                    if obj(h1, x) != obj(hs, x) {
                        assert(zapped_arr(c, h1, obj(h1, x), obj(h2, x)));
                        assert(htag(hdr(obj(h1, x))) == htag(hdr(obj(hs, x))));
                        assert(obj_ok(obj(hs, x)) && obj_ok(obj(h1, x)));
                        if exists|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes2[m].key == AVal::Ref(x) {
                            let m = choose|m: int| 0 <= m < ncb && (#[trigger] nodes2[m]).hid && nodes2[m].key == AVal::Ref(x);
                            assert(htag(hdr(obj(h1, x))) == htag(hdr(obj(hs, x))));
                            assert(weak_map(c, obj(h, x)) && obj(hs, x) == hidden(obj(h, x)));
                            assert(zapped_arr(c, h1, obj(h1, x), obj(h2, x)));
                            assert(false);
                        } else {
                            assert(zapped_arr(c, hs, obj(hs, x), obj(h1, x)));
                        }
                    }
                }
                if obj(h1, x) == obj(hs, x) {
                    assert(zapped_arr(c, hs, obj(hs, x), obj(h2, x))) by {
                        assert forall|y: int| #![trigger obj(h1, y)] 0 <= y < hs.objs.len() implies hcid(hdr(obj(h1, y))) == hcid(hdr(obj(hs, y))) by {}
                        assert forall|k: int| 0 <= k < obj(hs, x).words.len() implies #[trigger] obj(h2, x).words[k] == obj(hs, x).words[k]
                            || (2 <= k && (k - 2) % 2 == 1 && obj(h2, x).words[k] == AVal::Ref(c.nullid@) && obj(hs, x).words[k] is Ref
                                && 0 <= obj(hs, x).words[k]->Ref_0 < hs.objs.len()
                                && hcid(hdr(obj(hs, obj(hs, x).words[k]->Ref_0))) != c.tomb_cid) by {
                            if obj(h2, x).words[k] != obj(hs, x).words[k] {
                                let y = obj(hs, x).words[k]->Ref_0;
                                assert(hcid(hdr(obj(h1, y))) == hcid(hdr(obj(hs, y))));
                            }
                        }
                    }
                } else {
                    assert(zapped_arr(c, hs, obj(hs, x), obj(h1, x)));
                    lemma_zap_trans(c, hs, h1, obj(hs, x), obj(h1, x), obj(h2, x));
                }
                assert(0 <= ii < ncb && nodes2[ii].hid);
            }
        }
        assert forall|m: int| i + 1 <= m < ncb && (#[trigger] nodes2[m]).hid implies
            obj(h2, nodes2[m].key->Ref_0) == obj(hs, nodes2[m].key->Ref_0) by {
            let jm = nodes2[m].key->Ref_0;
            assert(nodes2[m].key == nodes[m].key && nodes2[ii].key == nodes[ii].key);
            assert(nodes[m].key != nodes[ii].key);
            assert(obj(h1, jm) == obj(hs, jm));
            if obj(h2, jm) != obj(h1, jm) {
                assert(zapped_arr(c, h1, obj(h1, jm), obj(h2, jm)));
                assert(weak_map(c, obj(h, jm)) && obj(hs, jm) == hidden(obj(h, jm)));
                assert(hdr(obj(hs, jm)) == hdr(obj(h, jm)));
                assert(false);
            }
        }
        assert forall|m: int| 0 <= m < i + 1 && (#[trigger] nodes2[m]).hid implies
            obj(h2, nodes2[m].key->Ref_0) == unhide(obj(hs, nodes2[m].key->Ref_0), nodes2[m].ix, nodes2[m].bk)
            || obj(h2, nodes2[m].key->Ref_0) == killed(obj(hs, nodes2[m].key->Ref_0), c.nullid@, true) by {
            let jm = nodes2[m].key->Ref_0;
            if m < i {
                assert(nodes[m].key != nodes[ii].key);
                if obj(h2, jm) != obj(h1, jm) {
                    assert(zapped_arr(c, h1, obj(h1, jm), obj(h2, jm)));
                    assert(htag(hdr(obj(h1, jm))) == htag(hdr(obj(hs, jm))));
                    assert(weak_map(c, obj(h, jm)) && obj(hs, jm) == hidden(obj(h, jm)));
                    assert(hdr(obj(hs, jm)) == hdr(obj(h, jm)));
                    assert(false);
                }
            }
        }
}

} // verus!
