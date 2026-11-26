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
    &&& forall|x: int| 0 <= x < h.objs.len() ==> #[trigger] obj(hs, x) == obj(h, x)
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
            assert forall|x: int| 0 <= x < h.objs.len() implies #[trigger] obj(h2, x) == obj(h, x)
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

} // verus!
