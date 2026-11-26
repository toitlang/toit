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

//! Stack shrinking after the copy (src/objects.cc,
//! `Stack::shrink_v2_for_gc`, as the C++ prototype does it with
//! `shrink_stacks()`): a copied stack whose free area is more than half of
//! it and larger than the room the core needs keeps its records in place,
//! moves its object stack down by `d` words, lowers its length and top by
//! `d`, and fills the `d` words it gave up with one-word fillers. The
//! copy's extent, the page tiling and the used words stay as they are.
//!
//! What the core sees of the stack is unchanged: the records (array words
//! `[0, record top)`), the header fields other than length and top, and
//! the object stack counted from the end (`len - top` slots). That is
//! `stack_copy_equiv`'s `same_abstraction` (verified/CONTRACTS.toml);
//! `lemma_same_abstraction` proves the Rust form of it for every shrunk
//! copy.

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::cheney::*;
use crate::tail::filler_word;
use crate::collect::tab_at;
#[cfg(verus_keep_ghost)]
use crate::copy::lemma_from_obj;

verus! {

/// The record top of a stack (the low 16 bits of word 4,
/// `Stack::v2_record_top`).
pub open spec fn rtop(o: AObj) -> int { (raw(o.words[STACK_RECORD_TOP_WORD as int]) % 0x1_0000) as int }

pub open spec fn slen(o: AObj) -> int { raw(o.words[STACK_LENGTH_WORD as int]) as int }

pub open spec fn stop(o: AObj) -> int { raw(o.words[STACK_TOP_WORD as int]) as int }

/// The words a collection takes from a stack (`shrink_v2_for_gc` with
/// `shrink_stacks()` and not aggressive): with `m` the record top plus the
/// room the core needs (`Ctx::smin`: twice the program's maximal height
/// plus the call, frame and core reserves), `top - m` if the top is above
/// `m` and above half the length and that is at least 8 words; else 0.
pub open spec fn red(c: Ctx, o: AObj) -> int {
    if htag(hdr(o)) == STACK_TAG && o.words.len() > STACK_RECORD_TOP_WORD {
        let m = rtop(o) + c.smin;
        if stop(o) > m && stop(o) > slen(o) / 2 && stop(o) - m >= 8 { stop(o) - m } else { 0 }
    } else {
        0
    }
}

/// The copy after shrinking: length and top lowered by `d`, the array up to
/// the new top as before, the object stack moved down by `d`, fillers in
/// the `d` words given up (the extent stays).
pub open spec fn cimg(c: Ctx, o: AObj) -> AObj {
    let d = red(c, o);
    if d == 0 {
        o
    } else {
        AObj {
            words: Seq::new(o.words.len(), |k: int|
                if k == STACK_LENGTH_WORD as int { AVal::Raw((slen(o) - d) as usize) }
                else if k == STACK_TOP_WORD as int { AVal::Raw((stop(o) - d) as usize) }
                else if k < o.sw + stop(o) - d { o.words[k] }
                else if k < o.sw + slen(o) - d { o.words[k + d] }
                else { AVal::Raw(filler_word()) }),
            ..o
        }
    }
}

/// `same_abstraction` (verified/cxx/annotated/ffi/interpreter_v2.render)
/// of a stack and its shrunk copy: the same record top, the same number of
/// object-stack slots, the records (array words `[0, rtop)`) equal, the
/// object stack equal counted from the end; the other header words equal.
pub open spec fn same_abstraction(o: AObj, o2: AObj) -> bool {
    &&& rtop(o2) == rtop(o)
    &&& slen(o2) - stop(o2) == slen(o) - stop(o)
    &&& forall|k: int| 0 <= k < rtop(o) ==> #[trigger] o2.words[o.sw + k] == o.words[o.sw + k]
    &&& forall|k: int| 0 <= k < slen(o) - stop(o) ==> #[trigger] o2.words[o.sw + stop(o2) + k] == o.words[o.sw + stop(o) + k]
    &&& forall|k: int| 0 <= k < o.sw && k != STACK_LENGTH_WORD && k != STACK_TOP_WORD ==> #[trigger] o2.words[k] == o.words[k]
    &&& o2.sw == o.sw && o2.cbits == o.cbits
}

/// A shrunk copy has the stack's abstraction.
pub proof fn lemma_same_abstraction(c: Ctx, o: AObj)
    requires obj_ok(o), htag(hdr(o)) == STACK_TAG, red(c, o) > 0,
    ensures same_abstraction(o, cimg(c, o)), stop(cimg(c, o)) == stop(o) - red(c, o), slen(cimg(c, o)) == slen(o) - red(c, o),
{
    let o2 = cimg(c, o);
    let d = red(c, o);
    assert(STACK_MIN_ARRAY_WORD <= o.sw);
    assert(o2.words[STACK_RECORD_TOP_WORD as int] == o.words[STACK_RECORD_TOP_WORD as int]);
    assert forall|k: int| 0 <= k < rtop(o) implies #[trigger] o2.words[o.sw + k] == o.words[o.sw + k] by {}
    assert forall|k: int| 0 <= k < slen(o) - stop(o) implies
        #[trigger] o2.words[o.sw + stop(o2) + k] == o.words[o.sw + stop(o) + k] by {}
}

/// Clearing the low half: `w & 0xffff` is `w % 0x10000`.
proof fn lemma_low16(w: usize)
    ensures w & 0xffffusize == w % 0x1_0000,
{
    assert(w & 0xffffusize == w % 0x1_0000) by (bit_vector);
}

/// Words `so .. so + n` of page `pg` hold `v` (with their permissions).
pub open spec fn holds(tp: Map<(int, int), PointsTo<usize>>, pg: int, so: int, page: *mut usize, n: int, v: spec_fn(int) -> usize) -> bool {
    n >= 0 && hs(tp, pg, so, page, Seq::new(n as nat, v))
}

pub open spec fn hs(tp: Map<(int, int), PointsTo<usize>>, pg: int, so: int, page: *mut usize, vs: Seq<usize>) -> bool {
    forall|q: int| 0 <= q < vs.len() ==> #[trigger] wperm_ok(tp, (pg, so + q), page, so + q) && tp[(pg, so + q)].is_init()
        && tp[(pg, so + q)].value() == vs[q]
}

/// One word of `holds`.
proof fn lemma_holds_at(tp: Map<(int, int), PointsTo<usize>>, pg: int, so: int, page: *mut usize, n: int, v: spec_fn(int) -> usize, q: int)
    requires holds(tp, pg, so, page, n, v), 0 <= q < n,
    ensures wperm_ok(tp, (pg, so + q), page, so + q), tp[(pg, so + q)].is_init(), tp[(pg, so + q)].value() == v(q),
{
    assert(Seq::new(n as nat, v)[q] == v(q));
}

/// `holds` for equal contents.
proof fn lemma_holds_ext(tp: Map<(int, int), PointsTo<usize>>, pg: int, so: int, page: *mut usize, n: int,
                        v1: spec_fn(int) -> usize, v2: spec_fn(int) -> usize)
    requires holds(tp, pg, so, page, n, v1), forall|q: int| 0 <= q < n ==> #[trigger] v1(q) == v2(q),
    ensures holds(tp, pg, so, page, n, v2),
{
    assert(Seq::new(n as nat, v1) =~= Seq::new(n as nat, v2));
}

/// One word written.
proof fn lemma_holds_write(tp1: Map<(int, int), PointsTo<usize>>, tp: Map<(int, int), PointsTo<usize>>, pg: int, so: int,
                           page: *mut usize, n: int, v1: spec_fn(int) -> usize, v2: spec_fn(int) -> usize, q0: int)
    requires
        holds(tp1, pg, so, page, n, v1), 0 <= q0 < n,
        tp.dom() == tp1.dom(), tp[(pg, so + q0)].ptr() == tp1[(pg, so + q0)].ptr(),
        tp[(pg, so + q0)].is_init(), tp[(pg, so + q0)].value() == v2(q0),
        forall|k: (int, int)| k != (pg, so + q0) ==> #[trigger] tp[k] == tp1[k],
        forall|q: int| 0 <= q < n && q != q0 ==> #[trigger] v2(q) == v1(q),
    ensures holds(tp, pg, so, page, n, v2),
{
    let vs1 = Seq::new(n as nat, v1);
    let vs2 = Seq::new(n as nat, v2);
    assert forall|q: int| 0 <= q < vs2.len() implies #[trigger] wperm_ok(tp, (pg, so + q), page, so + q) && tp[(pg, so + q)].is_init()
        && tp[(pg, so + q)].value() == vs2[q] by {
        lemma_holds_at(tp1, pg, so, page, n, v1, q);
        if q != q0 {
            assert(tp[(pg, so + q)] == tp1[(pg, so + q)]);
            assert(v2(q) == v1(q));
        }
    }
}

/// The words outside `so .. so + n` of page `pg` are those of `tp0`.
pub open spec fn frame(tp: Map<(int, int), PointsTo<usize>>, tp0: Map<(int, int), PointsTo<usize>>, pg: int, so: int, n: int) -> bool {
    &&& tp.dom() == tp0.dom()
    &&& forall|q: (int, int)| q.0 != pg || q.1 < so || q.1 >= so + n ==> #[trigger] tp[q] == tp0[q]
}

proof fn lemma_frame_write(tp1: Map<(int, int), PointsTo<usize>>, tp: Map<(int, int), PointsTo<usize>>,
                           tp0: Map<(int, int), PointsTo<usize>>, pg: int, so: int, n: int, q0: int)
    requires
        frame(tp1, tp0, pg, so, n), 0 <= q0 < n, tp.dom() == tp1.dom(),
        forall|k: (int, int)| k != (pg, so + q0) ==> #[trigger] tp[k] == tp1[k],
    ensures frame(tp, tp0, pg, so, n),
{
    assert forall|q: (int, int)| q.0 != pg || q.1 < so || q.1 >= so + n implies #[trigger] tp[q] == tp0[q] by {
        assert(q != (pg, so + q0));
        assert(tp[q] == tp1[q]);
        assert(tp1[q] == tp0[q]);
    }
}

/// Shrinks the stack copy at offset `so` of page `pg` in place (its words
/// are `o`'s under the address map `a`): afterwards they are `cimg(o)`'s.
pub fn shrink_one(c: &Ctx, page: *mut usize, so: usize, Ghost(pg): Ghost<int>, Ghost(o): Ghost<AObj>, Ghost(a): Ghost<Seq<usize>>,
                  Tracked(tp): Tracked<&mut Map<(int, int), PointsTo<usize>>>)
    requires
        ctx_ok(*c), obj_ok(o), o.sw == c.sw, htag(hdr(o)) == STACK_TAG,
        so + lay(o).size <= c.pw, page@.addr + c.pw * W <= usize::MAX,
        holds(*old(tp), pg, so as int, page, lay(o).size, |q: int| wval(o, a, q)),
    ensures
        frame(*final(tp), *old(tp), pg, so as int, lay(o).size),
        holds(*final(tp), pg, so as int, page, lay(o).size, |q: int| wval(cimg(*c, o), a, q)),
{
    let ghost sz = lay(o).size;
    let ghost tp0 = *tp;
    let ghost s = so as int;
    proof {
        lemma_w();
        assert(STACK_MIN_ARRAY_WORD <= o.sw);
        assert(sz == o.sw + slen(o) && o.words.len() == sz);
        assert(stop(o) <= slen(o));
        assert(o.words[2] is Raw && o.words[3] is Raw && o.words[4] is Raw);
        assert((so + 4) * W <= c.pw * W) by (nonlinear_arith) requires so + 4 <= c.pw, W >= 1;
        assert((so + 3) * W <= c.pw * W) by (nonlinear_arith) requires so + 3 <= c.pw, W >= 1;
        assert((so + 2) * W <= c.pw * W) by (nonlinear_arith) requires so + 2 <= c.pw, W >= 1;
        assert(sz >= 6);
        lemma_holds_at(*tp, pg, s, page, sz, |q: int| wval(o, a, q), 2);
        lemma_holds_at(*tp, pg, s, page, sz, |q: int| wval(o, a, q), 3);
        lemma_holds_at(*tp, pg, s, page, sz, |q: int| wval(o, a, q), 4);
        assert(wperm_ok(*tp, (pg, s + 2), page, s + 2) && tp[(pg, s + 2)].is_init());
        assert(wperm_ok(*tp, (pg, s + 3), page, s + 3) && tp[(pg, s + 3)].is_init());
        assert(wperm_ok(*tp, (pg, s + 4), page, s + 4) && tp[(pg, s + 4)].is_init());
        assert(frame(*tp, tp0, pg, s, sz));
    }
    let len = rd(page, so + 2, Ghost((pg, s + 2)), Tracked(&*tp));
    let top = rd(page, so + 3, Ghost((pg, s + 3)), Tracked(&*tp));
    let rw = rd(page, so + 4, Ghost((pg, s + 4)), Tracked(&*tp));
    let rt = rw & 0xffff;
    proof {
        assert(len == slen(o) && top == stop(o));
        lemma_low16(rw);
        assert(rt == rtop(o));
    }
    // The reduction, without overflow (`top - (rt + smin)`).
    if top <= rt {
        proof { assert(red(*c, o) == 0); assert(cimg(*c, o) == o); }
        return;
    }
    let m0 = top - rt;
    if m0 <= c.smin {
        proof { assert(red(*c, o) == 0); assert(cimg(*c, o) == o); }
        return;
    }
    let d = m0 - c.smin;
    if d < 8 || top <= len / 2 {
        proof { assert(red(*c, o) == 0); assert(cimg(*c, o) == o); }
        return;
    }
    proof { assert(red(*c, o) == d); }
    let sw = c.sw;
    let used = len - top;
    proof {
        let v0 = |q: int| wval(o, a, q);
        let vi = |q: int| if sw + top - d <= q < sw + top - d + 0 { wval(o, a, q + d) } else { wval(o, a, q) };
        assert forall|q: int| 0 <= q < sz implies #[trigger] v0(q) == vi(q) by {}
        lemma_holds_ext(*tp, pg, s, page, sz, v0, vi);
    }
    // Move the object stack down by d (ascending: every read is above the
    // words written so far).
    let mut i: usize = 0;
    while i < used
        invariant
            ctx_ok(*c), obj_ok(o), o.sw == c.sw, sw == c.sw, htag(hdr(o)) == STACK_TAG, red(*c, o) == d,
            sz == lay(o).size, sz == o.sw + slen(o), len == slen(o), top == stop(o), used == len - top, 8 <= d <= top,
            so + sz <= c.pw, page@.addr + c.pw * W <= usize::MAX, W >= 1, s == so,
            0 <= i <= used,
            frame(*tp, tp0, pg, s, sz),
            holds(*tp, pg, s, page, sz, |q: int| if sw + top - d <= q < sw + top - d + i { wval(o, a, q + d) } else { wval(o, a, q) }),
        decreases used - i,
    {
        let ghost src = (sw + top + i) as int;
        let ghost dst = (sw + top - d + i) as int;
        let ghost v1 = |q: int| if sw + top - d <= q < sw + top - d + i { wval(o, a, q + d) } else { wval(o, a, q) };
        let ghost v2 = |q: int| if sw + top - d <= q < sw + top - d + i + 1 { wval(o, a, q + d) } else { wval(o, a, q) };
        proof {
            assert(src < sz && dst < src);
            assert((so + src) * W <= c.pw * W) by (nonlinear_arith) requires so + src <= c.pw, W >= 1;
            assert(wperm_ok(*tp, (pg, s + src), page, s + src) && tp[(pg, s + src)].is_init());
            assert(tp[(pg, s + src)].value() == v1(src));
            assert(wperm_ok(*tp, (pg, s + dst), page, s + dst));
        }
        let v = rd(page, so + sw + top + i, Ghost((pg, s + src)), Tracked(&*tp));
        let ghost tp1 = *tp;
        wr(page, so + sw + top - d + i, v, Ghost((pg, s + dst)), Tracked(&mut *tp));
        proof {
            assert(v == wval(o, a, src));
            assert(v2(dst) == wval(o, a, dst + d));
            assert forall|q: int| 0 <= q < sz && q != dst implies #[trigger] v2(q) == v1(q) by {}
            lemma_holds_write(tp1, *tp, pg, s, page, sz, v1, v2, dst);
            lemma_frame_write(tp1, *tp, tp0, pg, s, sz, dst);
        }
        i += 1;
    }
    // The header: length and top.
    let ghost va = |q: int| if sw + top - d <= q < sw + len - d { wval(o, a, q + d) } else { wval(o, a, q) };
    let ghost vb = |q: int| if q == 2 { (len - d) as usize } else if sw + top - d <= q < sw + len - d { wval(o, a, q + d) } else { wval(o, a, q) };
    let ghost vc = |q: int| if q == 2 { (len - d) as usize } else if q == 3 { (top - d) as usize }
        else if sw + top - d <= q < sw + len - d { wval(o, a, q + d) } else { wval(o, a, q) };
    let ghost tp2 = *tp;
    proof { assert(holds(tp2, pg, s, page, sz, va)); assert(wperm_ok(tp2, (pg, s + 2), page, s + 2)); }
    wr(page, so + 2, len - d, Ghost((pg, s + 2)), Tracked(&mut *tp));
    proof {
        assert forall|q: int| 0 <= q < sz && q != 2 implies #[trigger] vb(q) == va(q) by {}
        lemma_holds_write(tp2, *tp, pg, s, page, sz, va, vb, 2);
        lemma_frame_write(tp2, *tp, tp0, pg, s, sz, 2);
        assert(wperm_ok(*tp, (pg, s + 3), page, s + 3));
    }
    let ghost tp3 = *tp;
    wr(page, so + 3, top - d, Ghost((pg, s + 3)), Tracked(&mut *tp));
    proof {
        assert forall|q: int| 0 <= q < sz && q != 3 implies #[trigger] vc(q) == vb(q) by {}
        lemma_holds_write(tp3, *tp, pg, s, page, sz, vb, vc, 3);
        lemma_frame_write(tp3, *tp, tp0, pg, s, sz, 3);
    }
    // The words given up: fillers.
    let fw: usize = usize::MAX - 107;
    let mut i: usize = 0;
    proof {
        let vi = |q: int| if q == 2 { (len - d) as usize } else if q == 3 { (top - d) as usize }
            else if sw + top - d <= q < sw + len - d { wval(o, a, q + d) }
            else if sw + len - d <= q < sw + len - d + 0 { fw } else { wval(o, a, q) };
        assert forall|q: int| 0 <= q < sz implies #[trigger] vc(q) == vi(q) by {}
        lemma_holds_ext(*tp, pg, s, page, sz, vc, vi);
    }
    while i < d
        invariant
            ctx_ok(*c), obj_ok(o), o.sw == c.sw, sw == c.sw, htag(hdr(o)) == STACK_TAG, red(*c, o) == d,
            sz == lay(o).size, sz == o.sw + slen(o), len == slen(o), top == stop(o), 8 <= d <= top, top <= len,
            so + sz <= c.pw, page@.addr + c.pw * W <= usize::MAX, W >= 1, fw == filler_word(), s == so,
            0 <= i <= d,
            frame(*tp, tp0, pg, s, sz),
            holds(*tp, pg, s, page, sz, |q: int| if q == 2 { (len - d) as usize } else if q == 3 { (top - d) as usize }
                else if sw + top - d <= q < sw + len - d { wval(o, a, q + d) }
                else if sw + len - d <= q < sw + len - d + i { fw } else { wval(o, a, q) }),
        decreases d - i,
    {
        let ghost dst = (sw + len - d + i) as int;
        let ghost v1 = |q: int| if q == 2 { (len - d) as usize } else if q == 3 { (top - d) as usize }
            else if sw + top - d <= q < sw + len - d { wval(o, a, q + d) }
            else if sw + len - d <= q < sw + len - d + i { fw } else { wval(o, a, q) };
        let ghost v2 = |q: int| if q == 2 { (len - d) as usize } else if q == 3 { (top - d) as usize }
            else if sw + top - d <= q < sw + len - d { wval(o, a, q + d) }
            else if sw + len - d <= q < sw + len - d + i + 1 { fw } else { wval(o, a, q) };
        proof {
            assert(dst < sz);
            assert((so + dst) * W <= c.pw * W) by (nonlinear_arith) requires so + dst <= c.pw, W >= 1;
            assert(wperm_ok(*tp, (pg, s + dst), page, s + dst));
        }
        let ghost tp1 = *tp;
        wr(page, so + sw + len - d + i, fw, Ghost((pg, s + dst)), Tracked(&mut *tp));
        proof {
            assert(v2(dst) == fw);
            assert forall|q: int| 0 <= q < sz && q != dst implies #[trigger] v2(q) == v1(q) by {}
            lemma_holds_write(tp1, *tp, pg, s, page, sz, v1, v2, dst);
            lemma_frame_write(tp1, *tp, tp0, pg, s, sz, dst);
        }
        i += 1;
    }
    proof {
        let o2 = cimg(*c, o);
        let vf = |q: int| if q == 2 { (len - d) as usize } else if q == 3 { (top - d) as usize }
            else if sw + top - d <= q < sw + len - d { wval(o, a, q + d) }
            else if sw + len - d <= q < sw + len - d + d { fw } else { wval(o, a, q) };
        assert(holds(*tp, pg, s, page, sz, vf));
        let vg = |q: int| wval(cimg(*c, o), a, q);
        assert forall|q: int| 0 <= q < sz implies #[trigger] vf(q) == vg(q) by {
            if q == 2 || q == 3 {
            } else if q < o.sw + stop(o) - d {
                assert(o2.words[q] == o.words[q]);
            } else if q < o.sw + slen(o) - d {
                assert(o2.words[q] == o.words[q + d]);
            } else {
                assert(o2.words[q] == AVal::Raw(filler_word()));
            }
        }
        lemma_holds_ext(*tp, pg, s, page, sz, vf, vg);
    }
}


/// The words of the copies: copy `kk`'s are `obj`'s (or, for `kk < ks`,
/// its shrunk image's) under the new address map.
pub open spec fn copies_words(c: Ctx, h: H, st: St, ks: int) -> bool {
    forall|kk: int, i: int| 0 <= kk < st.order.len() && 0 <= i < tsz(h, st, kk) ==>
        (#[trigger] st.tp[tkey(st, kk, i)]).is_init()
        && st.tp[tkey(st, kk, i)].value() == wval(if kk < ks { cimg(c, obj(h, st.order[kk])) } else { obj(h, st.order[kk]) }, st.addr2, i)
}


/// The walk's state: the copies `kk < ks` are shrunk, the rest as copied;
/// only copy words change.
pub open spec fn walk_ok(c: Ctx, h: H, s0: St, st: St, t: Tos, ks: int) -> bool {
    &&& st == (St { tp: st.tp, ..s0 })
    &&& st.tp.dom() == s0.tp.dom()
    &&& forall|p: int, k: int| 0 <= p < t.tn && 0 <= k < c.pw ==> #[trigger] wperm_ok(st.tp, (p, k), tptr(c, s0, p), k)
    &&& forall|q: (int, int)| 0 <= q.0 < t.tn && q.1 >= s0.tus[q.0] ==> #[trigger] st.tp[q] == s0.tp[q]
    &&& copies_words(c, h, st, ks)
}

/// Shrinks copy `ks` (at offset `so` of page `sp`) if it is a stack;
/// returns its size.
fn shrink_copy(c: &Ctx, t: &Tos, sstart: usize, sp: usize, so: usize, Ghost(h): Ghost<H>, Ghost(s0): Ghost<St>, Ghost(ks): Ghost<int>,
               Tracked(st): Tracked<&mut St>, Tracked(ctp): Tracked<&Map<int, PointsTo<u16>>>) -> (sz: usize)
    requires
        ctx_ok(*c), heap_ok(*c, h), ctab_ok(*c, *ctp), bk_ok(h, s0), tcopies_ok(*c, h, s0, *t), tpages_ok(*c, h, s0, *t),
        t.tn >= 1, 0 <= ks < s0.order.len(), 0 <= sp < t.tn, sstart == s0.tss[sp as int],
        s0.tloc[ks] == (sp as int, so as int),
        walk_ok(*c, h, s0, *old(st), *t, ks),
    ensures
        walk_ok(*c, h, s0, *final(st), *t, ks + 1),
        sz == tsz(h, s0, ks),
{
    proof { lemma_w(); }
    let ghost n = s0.order.len() as int;
    proof {
        assert(copies_words(*c, h, *st, ks));
        assert forall|p: int, k: int| 0 <= p < t.tn && 0 <= k < c.pw implies #[trigger] wperm_ok(st.tp, (p, k), tptr(*c, s0, p), k) by {}
    }
    let ghost j = s0.order[ks];
    let ghost o = obj(h, j);
    let ghost st1 = *st;
    let ghost pg = sp as int;
    proof {
        assert(s0.tloc[ks] == (sp as int, so as int));
        lemma_from_obj(*c, h, j);
        assert(cls_ok(*c, o));
        assert(tsz(h, s0, ks) == lay(o).size);
        assert(0 <= tpg(s0, ks) < t.tn && tend(h, s0, ks) <= s0.tus[tpg(s0, ks)]);
        assert(0 <= s0.tus[pg] <= c.pw - 1);
        assert(s0.tss[pg] % W == 0 && s0.tss[pg] + pbytes(*c) < usize::MAX);
        assert(tend(h, s0, ks) <= s0.tus[pg] && s0.tus[pg] <= c.pw - 1);
        assert(s0.tss[pg] + pbytes(*c) < usize::MAX);
    }
    let page = c.base.with_addr(sstart);
    proof {
        assert(page == tptr(*c, s0, pg));
        assert(page@.addr + c.pw * W <= usize::MAX);
        assert forall|q: int| 0 <= q < lay(o).size implies #[trigger] wperm_ok(st.tp, (pg, so + q), page, so + q)
            && st.tp[(pg, so + q)].is_init() && st.tp[(pg, so + q)].value() == wval(o, st.addr2, q) by {
            assert(tkey(s0, ks, q) == (pg, so + q));
            assert(st.tp[tkey(*st, ks, q)].is_init());
        }
        assert forall|q: int| 0 <= q < lay(o).size && #[trigger] o.words[q] is Raw implies
            wperm_ok(st.tp, (pg, so + q), page, so + q) && st.tp[(pg, so + q)].is_init()
            && st.tp[(pg, so + q)].value() == raw(o.words[q]) by {
            assert(wperm_ok(st.tp, (pg, so + q), page, so + q));
            assert(st.tp[(pg, so + q)].value() == wval(o, st.addr2, q));
        }
    }
    let (sz, _lo, _hi) = obj_layout(c, page, so, Ghost(pg), Tracked(&st.tp), Ghost(o), Ghost(c.pw as int), Tracked(ctp));
    proof {
        assert(wperm_ok(st.tp, (pg, so as int), page, so as int));
        assert(so * W <= c.pw * W) by (nonlinear_arith) requires so <= c.pw, W >= 1;
    }
    let hd = rd(page, so, Ghost((pg, so as int)), Tracked(&st.tp));
    proof {
        assert(o.words[0] is Raw);
        assert(hd == hdr(o));
    }
    if (hd >> 1) & 15 == STACK_TAG {
        proof {
            assert(o.sw == c.sw);
            assert(holds(st.tp, pg, so as int, page, lay(o).size, |q: int| wval(o, st.addr2, q))) by {
                let vs = Seq::new(lay(o).size as nat, |q: int| wval(o, st.addr2, q));
                assert forall|q: int| 0 <= q < vs.len() implies #[trigger] wperm_ok(st.tp, (pg, so + q), page, so + q)
                    && st.tp[(pg, so + q)].is_init() && st.tp[(pg, so + q)].value() == vs[q] by {}
            }
        }
        shrink_one(c, page, so, Ghost(pg), Ghost(o), Ghost(st.addr2), Tracked(&mut st.tp));
    } else {
        proof { assert(htag(hdr(o)) != STACK_TAG); assert(red(*c, o) == 0); assert(cimg(*c, o) == o); }
    }
    proof {
        let st2 = *st;
        let szo = lay(o).size;
        // The words of copy ks are its image's; the other copies' and
        // the words above the used words are untouched.
        assert(frame(st2.tp, st1.tp, pg, so as int, szo));
        assert forall|q: int| 0 <= q < szo implies #[trigger] wperm_ok(st2.tp, (pg, so + q), page, so + q)
            && st2.tp[(pg, so + q)].is_init() && st2.tp[(pg, so + q)].value() == wval(cimg(*c, o), st2.addr2, q) by {
            if htag(hdr(o)) == STACK_TAG {
                lemma_holds_at(st2.tp, pg, so as int, page, szo, |q: int| wval(cimg(*c, o), st.addr2, q), q);
            }
        }
        assert forall|p: int, k: int| 0 <= p < t.tn && 0 <= k < c.pw implies
            #[trigger] wperm_ok(st2.tp, (p, k), tptr(*c, s0, p), k) by {
            assert(wperm_ok(st1.tp, (p, k), tptr(*c, s0, p), k));
            if p == pg && so <= k < so + szo {
                assert(wperm_ok(st2.tp, (pg, so + (k - so)), page, so + (k - so)));
            } else {
                assert(st2.tp[(p, k)] == st1.tp[(p, k)]);
            }
        }
        assert forall|q: (int, int)| 0 <= q.0 < t.tn && q.1 >= s0.tus[q.0] implies #[trigger] st2.tp[q] == s0.tp[q] by {
            assert(st1.tp[q] == s0.tp[q]);
            if q.0 == pg { assert(q.1 >= so + szo); }
            assert(st2.tp[q] == st1.tp[q]);
        }
        assert forall|kk: int, i: int| 0 <= kk < st2.order.len() && 0 <= i < tsz(h, st2, kk) implies
            (#[trigger] st2.tp[tkey(st2, kk, i)]).is_init()
            && st2.tp[tkey(st2, kk, i)].value() == wval(if kk < ks + 1 { cimg(*c, obj(h, st2.order[kk])) } else { obj(h, st2.order[kk]) }, st2.addr2, i) by {
            if kk == ks {
                assert(tkey(st2, kk, i) == (pg, so + i));
                assert(wperm_ok(st2.tp, (pg, so + i), page, so + i));
            } else {
                assert(st1.tp[tkey(st1, kk, i)].is_init());
                if kk < ks { assert(before(h, s0, kk, ks)); } else { assert(before(h, s0, ks, kk)); }
                lemma_from_obj(*c, h, s0.order[kk]);
                assert(st2.tp[tkey(st2, kk, i)] == st1.tp[tkey(st1, kk, i)]);
            }
        }
        assert(st2.tp.dom() == s0.tp.dom());
        assert(tsz(h, s0, ks) == sz);
        assert(walk_ok(*c, h, s0, st2, *t, ks + 1));
    }
    sz
}
/// Shrinks every copied stack (`shrink_one`), walking the to-space pages
/// copy by copy as the scan does. Only the copies' words change.
pub fn shrink_stacks(c: &Ctx, t: &Tos, Ghost(h): Ghost<H>, Tracked(st): Tracked<&mut St>,
                     Tracked(ctp): Tracked<&Map<int, PointsTo<u16>>>)
    requires
        ctx_ok(*c), heap_ok(*c, h), ctab_ok(*c, *ctp), bk_ok(h, *old(st)),
        tcopies_ok(*c, h, *old(st), *t), tpages_ok(*c, h, *old(st), *t), t.tn >= 1,
        copies_words(*c, h, *old(st), 0),
    ensures
        *final(st) == (St { tp: final(st).tp, ..*old(st) }),
        final(st).tp.dom() == old(st).tp.dom(),
        forall|p: int, k: int| 0 <= p < t.tn && 0 <= k < c.pw ==> #[trigger] wperm_ok(final(st).tp, (p, k), tptr(*c, *old(st), p), k),
        forall|q: (int, int)| 0 <= q.0 < t.tn && q.1 >= old(st).tus[q.0] ==> #[trigger] final(st).tp[q] == old(st).tp[q],
        copies_words(*c, h, *final(st), old(st).order.len() as int),
{
    let ghost s0 = *st;
    let ghost n = s0.order.len() as int;
    proof { lemma_w(); }
    let mut sstart = tab_at(t.ttab, 0, Ghost(t.tcap as int), Tracked(&st.ttp));
    let mut sp: usize = 0;
    let mut so: usize = 0;
    let ghost mut ks: int = 0;
    proof {
        if n > 0 { assert(s0.tloc[0] == (0int, 0int)); }
        assert(0 <= s0.tus[0]);
        if n == 0 { assert(t.top == s0.tus[t.tn - 1]); }
    }
    while !(sp + 1 == t.tn && so == t.top)
        invariant
            ctx_ok(*c), heap_ok(*c, h), ctab_ok(*c, *ctp), bk_ok(h, s0), tcopies_ok(*c, h, s0, *t), tpages_ok(*c, h, s0, *t),
            t.tn >= 1, n == s0.order.len(),
            walk_ok(*c, h, s0, *st, *t, ks),
            0 <= sp < t.tn, sstart == s0.tss[sp as int],
            0 <= ks <= n, so <= s0.tus[sp as int],
            ks == n ==> sp + 1 == t.tn && so == t.top,
            ks < n ==> s0.tloc[ks] == (sp as int, so as int)
                || (so == s0.tus[sp as int] && sp + 1 < t.tn && s0.tloc[ks] == (sp + 1, 0int)),
        decreases n - ks, t.tn - sp,
    {
        proof {
            if ks == n { assert(false); }
            assert(s0.tus[t.tn - 1] == t.top);
        }
        let lim = if sp + 1 == t.tn {
            t.top
        } else {
            proof {
                assert((sp as int) < (t.tn as int) - 1);
                assert(wperm_ok(st.tup, sp as int, t.tused, sp as int));
                assert(tpages_ok(*c, h, s0, *t));
                assert(s0.tup[sp as int].is_init());
                assert(s0.tup[sp as int].value() == s0.tus[sp as int]);
                assert(st.tup == s0.tup);
            }
            tab_at(t.tused, sp, Ghost(t.tcap as int), Tracked(&st.tup))
        };
        if so == lim {
            proof {
                let j = s0.order[ks];
                lemma_from_obj(*c, h, j);
                assert(0 <= tpg(s0, ks) < t.tn && tend(h, s0, ks) <= s0.tus[tpg(s0, ks)]);
                assert(s0.tloc[ks] == (sp + 1, 0int));
                assert(wperm_ok(st.ttp, sp + 1, t.ttab, sp + 1));
                assert(s0.ttp[sp + 1].is_init() && s0.ttp[sp + 1].value() == s0.tss[sp + 1]);
                assert(0 <= s0.tus[sp + 1]);
            }
            sp = sp + 1;
            so = 0;
            sstart = tab_at(t.ttab, sp, Ghost(t.tcap as int), Tracked(&st.ttp));
        } else {
            proof { assert(s0.tloc[ks] == (sp as int, so as int)); }
            let sz = shrink_copy(c, t, sstart, sp, so, Ghost(h), Ghost(s0), Ghost(ks), Tracked(st), Tracked(ctp));
            proof {
                lemma_from_obj(*c, h, s0.order[ks]);
                assert(0 <= tpg(s0, ks) < t.tn && tend(h, s0, ks) <= s0.tus[tpg(s0, ks)]);
                assert(s0.tus[sp as int] <= c.pw - 1);
                if ks + 1 < n {
                    assert(s0.tloc[ks + 1] == succ(h, s0, ks, t.tn as int));
                }
                if ks + 1 == n {
                    assert(tpg(s0, n - 1) == t.tn - 1 && tend(h, s0, n - 1) == t.top);
                }
            }
            so = so + sz;
            proof { ks = ks + 1; }
        }
    }
    proof {
        if ks < n {
            assert(0 <= tpg(s0, ks) < t.tn && tend(h, s0, ks) <= s0.tus[tpg(s0, ks)]);
            lemma_from_obj(*c, h, s0.order[ks]);
            assert(s0.tus[t.tn - 1] == t.top);
            assert(false);
        }
    }
}

} // verus!
