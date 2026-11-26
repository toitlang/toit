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

//! The tail bound of the reservation: a pass over the from-space pages (the
//! objects tile each page up to its used words) finds the largest object
//! `mx`; next-fit placement closes a page only when the next object does
//! not fit below its sentinel word, so every closed page holds at least
//! `pw - mx` words and a collection takes at most
//! `floor(nf * pw / (pw - mx)) + 1` pages (`reserve_pages`), never more than
//! the general `2 * nf + 1`.

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::*;
use crate::model::*;
use crate::layout::*;
use crate::space::*;
#[cfg(verus_keep_ghost)]
use crate::copy::lemma_from_obj;

verus! {

/// The used words of the from-space pages (`Ctx::fused`, `nf` words: the
/// C++ chunks' used words).
pub open spec fn fused_ok(c: Ctx, fup: Map<int, PointsTo<usize>>) -> bool {
    &&& c.fused@.addr + c.nf * W <= usize::MAX
    &&& forall|p: int| 0 <= p < c.nf ==> #[trigger] wperm_ok(fup, p, c.fused, p) && fup[p].is_init()
            && fup[p].value() <= c.pw - 1
}

pub open spec fn fend(fup: Map<int, PointsTo<usize>>, p: int) -> int { fup[p].value() as int }

/// A from-space object starts at offset `o` of page `p`.
pub open spec fn obj_at(h: H, p: int, o: int) -> bool {
    exists|j: int| #[trigger] from(h, j) && fpg(h, j) == p && foff(h, j) == o
}

/// The C++ one-word filler (`FreeListRegion::single_free_word_header()`:
/// class id -2, tag `SINGLE_FREE_WORD_TAG` 10, as a smi): what the C++
/// writes over the words a stack shrunk in place gave up.
pub open spec fn filler_word() -> usize { (usize::MAX - 107) as usize }

/// Word `o` of from-space page `p` is a one-word filler.
pub open spec fn filler(fp: Map<(int, int), PointsTo<usize>>, p: int, o: int) -> bool {
    fp[(p, o)].is_init() && fp[(p, o)].value() == filler_word()
}

/// Offset `o` of page `p` is strictly inside a from-space object.
pub open spec fn inside(h: H, p: int, o: int) -> bool {
    exists|j: int| #[trigger] from(h, j) && fpg(h, j) == p && foff(h, j) < o < foff(h, j) + size(h, j)
}

/// An object or a filler starts at offset `o` of page `p`.
pub open spec fn start_ok(h: H, fp: Map<(int, int), PointsTo<usize>>, p: int, o: int) -> bool {
    obj_at(h, p, o) || filler(fp, p, o)
}

/// The from-space objects and one-word fillers tile each page from offset
/// 0 up to its used words: objects end at or below the used words, a
/// non-empty page starts with an object or a filler, and every object and
/// every filler outside objects is followed by an object, a filler, or
/// the used words. (The C++ semi-space allocates by bumping a chunk's top;
/// fillers come only from stacks shrunk in place. Part of the entry
/// derivation, M5.)
pub open spec fn tiled(c: Ctx, h: H, fp: Map<(int, int), PointsTo<usize>>, fup: Map<int, PointsTo<usize>>) -> bool {
    &&& forall|j: int| #[trigger] from(h, j) ==> foff(h, j) + size(h, j) <= fend(fup, fpg(h, j))
    &&& forall|p: int| 0 <= p < c.nf && fend(fup, p) > 0 ==> #[trigger] start_ok(h, fp, p, 0)
    &&& forall|j: int| #[trigger] from(h, j) ==>
            foff(h, j) + size(h, j) == fend(fup, fpg(h, j)) || start_ok(h, fp, fpg(h, j), foff(h, j) + size(h, j))
    &&& forall|p: int, o: int| 0 <= p < c.nf && 0 <= o < fend(fup, p) && #[trigger] filler(fp, p, o)
            && !obj_at(h, p, o) && !inside(h, p, o) ==> o + 1 == fend(fup, p) || start_ok(h, fp, p, o + 1)
}

/// What the collection needs of the tail bound (`Ctx::tail`).
pub open spec fn tail_ok(c: Ctx, h: H, fp: Map<(int, int), PointsTo<usize>>, fup: Map<int, PointsTo<usize>>) -> bool {
    c.tail ==> fused_ok(c, fup) && tiled(c, h, fp, fup)
}

/// The filler word is no object header (its tag, 10, has no layout).
pub proof fn lemma_filler_tag()
    ensures htag(filler_word()) == 10,
{
    assert(((usize::MAX - 107) as usize >> 1usize) & 15usize == 10usize) by (bit_vector);
}

/// The largest from-space object (in words; at least 1): walks every
/// from-space page from offset 0 to its used words, object by object,
/// stepping over fillers.
pub fn max_size(c: &Ctx, Ghost(h): Ghost<H>, Tracked(fp): Tracked<&Map<(int, int), PointsTo<usize>>>,
                Tracked(fup): Tracked<&Map<int, PointsTo<usize>>>, Tracked(ftp): Tracked<&Map<int, PointsTo<usize>>>,
                Tracked(ctp): Tracked<&Map<int, PointsTo<u16>>>) -> (m: usize)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, *ftp), heap_ok(*c, h), ctab_ok(*c, *ctp), from_ok(*c, h, *fp),
        fused_ok(*c, *fup), tiled(*c, h, *fp, *fup),
    ensures
        1 <= m <= c.pw - 1,
        forall|j: int| #[trigger] from(h, j) ==> size(h, j) <= m,
{
    proof { lemma_w(); lemma_filler_tag(); }
    let fw: usize = usize::MAX - 107;
    let mut m: usize = 1;
    let mut p: usize = 0;
    while p < c.nf
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, *ftp), heap_ok(*c, h), ctab_ok(*c, *ctp), from_ok(*c, h, *fp),
            fused_ok(*c, *fup), tiled(*c, h, *fp, *fup), fw == filler_word(), htag(filler_word()) == 10,
            0 <= p <= c.nf, 1 <= m <= c.pw - 1,
            forall|j: int| #[trigger] from(h, j) && fpg(h, j) < p ==> size(h, j) <= m,
        decreases c.nf - p,
    {
        proof {
            assert(wperm_ok(*ftp, p as int, c.ftab, p as int));
            assert(wperm_ok(*fup, p as int, c.fused, p as int));
        }
        let fstart = rd(c.ftab, p, Ghost(p as int), Tracked(ftp));
        let e = rd(c.fused, p, Ghost(p as int), Tracked(fup));
        let fpage = c.base.with_addr(fstart);
        let ghost pg = p as int;
        proof {
            assert(fstart == fs(*c, pg));
            assert(fs(*c, pg) + pbytes(*c) < usize::MAX);
            assert(e == fend(*fup, pg) && e <= c.pw - 1);
            if e > 0 { assert(start_ok(h, *fp, pg, 0)); }
        }
        let mut o: usize = 0;
        while o < e
            invariant
                ctx_ok(*c), fpages_ok(*c), heap_ok(*c, h), ctab_ok(*c, *ctp), from_ok(*c, h, *fp),
                fused_ok(*c, *fup), tiled(*c, h, *fp, *fup), fw == filler_word(), htag(filler_word()) == 10,
                0 <= pg < c.nf, pg == p, e == fend(*fup, pg), e <= c.pw - 1,
                fstart == fs(*c, pg), fpage == fptr(*c, pg), fs(*c, pg) + pbytes(*c) < usize::MAX,
                o <= e, o < e ==> start_ok(h, *fp, pg, o as int),
                1 <= m <= c.pw - 1,
                forall|j: int| #[trigger] from(h, j) && fpg(h, j) < pg ==> size(h, j) <= m,
                forall|j: int| #[trigger] from(h, j) && fpg(h, j) == pg && foff(h, j) < o ==>
                    size(h, j) <= m && foff(h, j) + size(h, j) <= o,
            decreases e - o,
        {
            let ghost o0 = o as int;
            proof {
                assert(fpage@.addr + c.pw * W <= usize::MAX);
                assert(c.base.with_addr(fstart) == fptr(*c, pg));
                assert(wperm_ok(*fp, (pg, o0), fpage, o0));
                if obj_at(h, pg, o0) {
                    let j = choose|j: int| #[trigger] from(h, j) && fpg(h, j) == pg && foff(h, j) == o0;
                    lemma_from_obj(*c, h, j);
                    assert(fkey(h, j, 0) == (pg, o0));
                    assert(fp[fkey(h, j, 0)].is_init());
                }
                assert(o * W <= c.pw * W) by (nonlinear_arith) requires o <= c.pw, W >= 1;
            }
            let hd = rd(fpage, o, Ghost((pg, o0)), Tracked(fp));
            if hd == fw {
                // A filler word: no object starts here (its tag has no layout)
                // or covers it.
                proof {
                    if obj_at(h, pg, o0) {
                        let j = choose|j: int| #[trigger] from(h, j) && fpg(h, j) == pg && foff(h, j) == o0;
                        lemma_from_obj(*c, h, j);
                        assert(fkey(h, j, 0) == (pg, o0));
                        assert(obj(h, j).words[0] is Raw);
                        assert(hd == raw(obj(h, j).words[0]));
                        assert(htag(hdr(obj(h, j))) == 10);
                        assert(false);
                    }
                    if inside(h, pg, o0) {
                        let k = choose|k: int| #[trigger] from(h, k) && fpg(h, k) == pg && foff(h, k) < o0 < foff(h, k) + size(h, k);
                        assert(false);
                    }
                    assert(filler(*fp, pg, o0));
                }
                o = o + 1;
                proof {
                    assert forall|k: int| #[trigger] from(h, k) && fpg(h, k) == pg && foff(h, k) < o implies
                        size(h, k) <= m && foff(h, k) + size(h, k) <= o by {
                        if foff(h, k) == o0 { assert(obj_at(h, pg, o0)); }
                    }
                }
            } else {
                proof { assert(!filler(*fp, pg, o0)); assert(obj_at(h, pg, o0)); }
                let ghost j = choose|j: int| #[trigger] from(h, j) && fpg(h, j) == pg && foff(h, j) == o0;
                let ghost ob = obj(h, j);
                proof {
                    lemma_from_obj(*c, h, j);
                    assert forall|k: int| 0 <= k < lay(ob).size && #[trigger] ob.words[k] is Raw implies
                        wperm_ok(*fp, (pg, o + k), fpage, o + k) && fp[(pg, o + k)].is_init()
                        && fp[(pg, o + k)].value() == raw(ob.words[k]) by {
                        assert(fkey(h, j, k) == (pg, o + k));
                        assert(fp[fkey(h, j, k)].is_init());
                    }
                }
                let (sz, _lo, _hi) = obj_layout(c, fpage, o, Ghost(pg), Tracked(fp), Ghost(ob), Ghost(c.pw as int), Tracked(ctp));
                if sz > m {
                    m = sz;
                }
                o = o + sz;
                proof {
                    assert(sz == size(h, j) && 1 <= sz <= c.pw - 1);
                    assert(foff(h, j) + size(h, j) <= fend(*fup, pg));
                    assert forall|k: int| #[trigger] from(h, k) && fpg(h, k) == pg && foff(h, k) < o implies
                        size(h, k) <= m && foff(h, k) + size(h, k) <= o by {
                        if foff(h, k) >= o0 && k != j {
                            assert(fdisjoint(h, j, k));
                            lemma_from_obj(*c, h, k);
                        }
                    }
                    if o < e {
                        assert(from(h, j));
                        assert(foff(h, j) + size(h, j) == fend(*fup, fpg(h, j))
                            || start_ok(h, *fp, fpg(h, j), foff(h, j) + size(h, j)));
                    }
                }
            }
        }
        proof {
            assert forall|j: int| #[trigger] from(h, j) && fpg(h, j) < p + 1 implies size(h, j) <= m by {
                if fpg(h, j) == pg {
                    lemma_from_obj(*c, h, j);
                    assert(foff(h, j) + size(h, j) <= fend(*fup, fpg(h, j)));
                }
            }
        }
        p += 1;
    }
    proof {
        assert forall|j: int| #[trigger] from(h, j) implies size(h, j) <= m by {
            lemma_from_obj(*c, h, j);
        }
    }
    m
}


/// The pages a collection may take when no from-space object is larger
/// than `mx` words: `floor(nf * pw / (pw - mx)) + 1`, at most `2 * nf + 1`.
pub open spec fn tail_pages(nf: int, pw: int, mx: int) -> int { (nf * pw) / (pw - mx) + 1 }

/// The reservation: the tail bound when it is smaller than `2 * nf + 1`.
pub fn reserve_pages(c: &Ctx, mx: usize) -> (r: usize)
    requires ctx_ok(*c), 1 <= mx <= c.pw - 1,
    ensures
        1 <= r <= 2 * c.nf + 1,
        r == 2 * c.nf + 1 || r == tail_pages(c.nf as int, c.pw as int, mx as int),
        r == 2 * c.nf + 1 || r * (c.pw - mx) > c.nf * c.pw,
{
    let g = 2 * c.nf + 1;
    let d = c.pw - mx;
    // Word arithmetic only (no 64-bit division on 32-bit targets); the
    // guards keep division panics out of the code (d and pw are not 0).
    if c.pw == 0 || d == 0 {
        return g;
    }
    let lim = usize::MAX / c.pw;
    if c.nf > lim {
        return g;
    }
    proof {
        let m = usize::MAX as int;
        let p = c.pw as int;
        vstd::arithmetic::div_mod::lemma_fundamental_div_mod(m, p);
        assert(m == p * (m / p) + m % p && 0 <= m % p);
        assert((c.nf as int) * p <= m) by (nonlinear_arith)
            requires c.nf as int <= m / p, m == p * (m / p) + m % p, 0 <= m % p, p >= 1;
    }
    let nw = c.nf * c.pw;
    proof {
        assert(nw as int / d as int <= nw as int) by (nonlinear_arith) requires d >= 1, nw >= 0;
        assert(nw as int <= usize::MAX);
    }
    let q0 = nw / d;
    if q0 >= g - 1 {
        return g;
    }
    let q = q0 + 1;
    proof {
        let ni: int = nw as int;
        let di: int = d as int;
        let qq: int = ni / di;
        vstd::arithmetic::div_mod::lemma_fundamental_div_mod(ni, di);
        assert(ni == di * qq + ni % di);
        assert(ni % di < di);
        assert((qq + 1) * di > ni) by (nonlinear_arith)
            requires ni == di * qq + ni % di, ni % di < di;
        assert(q == qq + 1);
    }
    if q < g { q } else { g }
}

} // verus!
