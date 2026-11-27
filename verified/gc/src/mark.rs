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

//! The mark phase of the in-place collector (README section 16): the
//! objects the roots reach get their start word's bit in the VM's mark
//! bitmap (one bit per heap word, `GcMetadata`; the caller gives a table of
//! each heap page's bitmap address and the permissions of those words). The
//! heap is only read. A fixed mark stack (`MSTACK` entries) holds marked
//! objects whose slots are not visited yet; a push onto a full stack only
//! marks and sets the overflow flag, and when the stack runs empty with the
//! flag set every marked object is visited again (a walk over the set bits
//! of every page), until a walk ends without overflow.
//!
//! Ghost state (`Mk`): the marked objects in marking order with, for each,
//! the root or the earlier marked object and slot it was found through
//! (soundness: every marked object is reachable); the black objects (all
//! slots visited; their from-space referents are marked); the objects on
//! the stack. A marked object that is not black is on the stack, or the
//! overflow flag is set, or (during a walk) it lies after the walk's
//! position (completeness: at the end every marked object is black, so the
//! marked set is closed and holds every from-space object a root reaches).

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
use crate::statement::*;

verus! {

/// Entries of the mark stack (a power of two: indices are masked, so that
/// the compiled code has no bounds check).
pub const MSTACK: usize = 64;

pub proof fn lemma_mask(i: usize)
    requires i < MSTACK,
    ensures i & ((MSTACK - 1) as usize) == i,
{
    assert(i & 63usize == i) by (bit_vector) requires i < 64usize;
}

// ---------------------------------------------------------------------------
// The mark bitmap.

/// The bitmap's description: a table of `nf` words, the address of each
/// from-space page's mark bits (`pw / 32` 32-bit words, bit `k % 32` of word
/// `k / 32` for the page's word `k`), and a pointer with the bitmap's
/// provenance.
pub struct MCtx {
    pub mtab: *mut usize,
    pub mbase: *mut u32,
    pub mss: Ghost<Seq<usize>>,
}

/// 32-bit words of a page's mark bits.
pub open spec fn mwords(c: Ctx) -> int { c.pw as int / 32 }

/// The pointer to mark word `w` of page `i`.
pub open spec fn mptr(m: MCtx, i: int, w: int) -> *mut u32 {
    ptr_mut_from_data::<u32>(PtrData::<u32> { addr: (m.mss@[i] + 4 * w) as usize, provenance: m.mbase@.provenance, metadata: () })
}

pub open spec fn mctx_ok(c: Ctx, m: MCtx) -> bool {
    &&& m.mss@.len() == c.nf
    &&& c.pw % 32 == 0
    &&& m.mtab@.addr + c.nf * W <= usize::MAX
    &&& forall|i: int| 0 <= i < c.nf ==> #[trigger] m.mss@[i] + 4 * mwords(c) <= usize::MAX
}

/// The bitmap table's permissions.
pub open spec fn mtab_ok(c: Ctx, m: MCtx, mtp: Map<int, PointsTo<usize>>) -> bool {
    forall|i: int| 0 <= i < c.nf ==> #[trigger] wperm_ok(mtp, i, m.mtab, i) && mtp[i].is_init() && mtp[i].value() == m.mss@[i]
}

/// The permissions of every mark word.
pub open spec fn mperm(c: Ctx, m: MCtx, mb: Map<(int, int), PointsTo<u32>>) -> bool {
    forall|i: int, w: int| 0 <= i < c.nf && 0 <= w < mwords(c) ==>
        #[trigger] mb.contains_key((i, w)) && mb[(i, w)].ptr() == mptr(m, i, w)
}

/// ... holding values.
pub open spec fn mshape(c: Ctx, m: MCtx, mb: Map<(int, int), PointsTo<u32>>) -> bool {
    &&& mperm(c, m, mb)
    &&& forall|i: int, w: int| 0 <= i < c.nf && 0 <= w < mwords(c) ==> (#[trigger] mb[(i, w)]).is_init()
}

pub open spec fn bit(x: u32, b: int) -> bool { (x >> (b as u32)) & 1u32 == 1u32 }

/// The mark bit of word `k` of page `i`.
pub open spec fn mbit(mb: Map<(int, int), PointsTo<u32>>, i: int, k: int) -> bool {
    bit(mb[(i, k / 32)].value(), k % 32)
}

pub proof fn lemma_bit_set(x: u32, b: u32, b2: u32)
    requires b < 32, b2 < 32,
    ensures
        ((x | (1u32 << b)) >> b2) & 1u32 == 1u32 <==> (b2 == b || (x >> b2) & 1u32 == 1u32),
{
    assert(((x | (1u32 << b)) >> b2) & 1u32 == 1u32 <==> (b2 == b || (x >> b2) & 1u32 == 1u32)) by (bit_vector)
        requires b < 32, b2 < 32;
}

pub proof fn lemma_bit_read(x: u32, b: u32)
    requires b < 32,
    ensures ((x >> b) & 1u32 == 1u32) == ((x >> b) & 1u32 != 0u32),
{
    assert(((x >> b) & 1u32 == 1u32) == ((x >> b) & 1u32 != 0u32)) by (bit_vector);
}

/// No bit at or above `b` in `x` when `x >> b` is zero.
pub proof fn lemma_bits_zero(x: u32, b: u32, b2: u32)
    requires b <= b2 < 32, x >> b == 0u32,
    ensures (x >> b2) & 1u32 != 1u32,
{
    assert((x >> b2) & 1u32 != 1u32) by (bit_vector) requires b <= b2 < 32, x >> b == 0u32;
}

pub proof fn lemma_shift_bit(x: u32, b: u32)
    requires b < 32,
    ensures ((x >> b) & 1u32 == 1u32) == (((x >> b) & 1u32) == 1u32),
{
}

/// The zero word has no bit.
pub proof fn lemma_zero_bits(b: u32)
    requires b < 32,
    ensures (0u32 >> b) & 1u32 != 1u32,
{
    assert((0u32 >> b) & 1u32 != 1u32) by (bit_vector) requires b < 32;
}

/// Reads entry `i` of the bitmap table.
#[inline(always)]
pub fn mtab_at(c: &Ctx, m: &MCtx, i: usize, Tracked(mtp): Tracked<&Map<int, PointsTo<usize>>>) -> (s: usize)
    requires ctx_ok(*c), mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp), i < c.nf,
    ensures s == m.mss@[i as int],
{
    proof {
        lemma_w();
        assert(wperm_ok(*mtp, i as int, m.mtab, i as int));
        assert(i * W <= c.nf * W) by (nonlinear_arith) requires i <= c.nf, W > 0;
    }
    rd(m.mtab, i, Ghost(i as int), Tracked(mtp))
}

/// The pointer to mark word `w` of the page whose bits start at `s`.
#[inline(always)]
pub fn mword_ptr(c: &Ctx, m: &MCtx, s: usize, w: usize, Ghost(i): Ghost<int>) -> (p: *mut u32)
    requires ctx_ok(*c), mctx_ok(*c, *m), 0 <= i < c.nf, s == m.mss@[i], w < mwords(*c),
    ensures p == mptr(*m, i, w as int),
{
    proof { assert(m.mss@[i] + 4 * mwords(*c) <= usize::MAX); }
    m.mbase.with_addr(s + 4 * w)
}

// ---------------------------------------------------------------------------
// The ghost state.

pub tracked struct Mk {
    /// The marked objects, in marking order, and their positions.
    pub ghost order: Seq<int>,
    pub ghost pos: Map<int, int>,
    /// For each: the root (`-1 - i`, 0) or (earlier object's position,
    /// slot) it was found through.
    pub ghost parent: Seq<(int, int)>,
    /// The objects whose slots are all visited.
    pub ghost black: Set<int>,
    /// The objects on the mark stack, bottom first.
    pub ghost sid: Seq<int>,
    /// The mark words.
    pub tracked mb: Map<(int, int), PointsTo<u32>>,
}

pub open spec fn marked(mk: Mk, j: int) -> bool { mk.pos.contains_key(j) }

pub open spec fn mbk_ok(h: H, mk: Mk) -> bool {
    let n = mk.order.len() as int;
    &&& mk.parent.len() == n
    &&& forall|k: int| 0 <= k < n ==> from(h, #[trigger] mk.order[k]) && mk.pos.contains_key(mk.order[k]) && mk.pos[mk.order[k]] == k
    &&& forall|j: int| #[trigger] marked(mk, j) ==> 0 <= mk.pos[j] < n && mk.order[mk.pos[j]] == j
}

/// Marked object `k` was found through a root or through a reference slot
/// of an earlier marked object.
pub open spec fn mparent_ok(h: H, mk: Mk, rv: Seq<AVal>, k: int) -> bool {
    let p = mk.parent[k].0;
    let s = mk.parent[k].1;
    if p < 0 {
        0 <= -1 - p < rv.len() && rv[-1 - p] == AVal::Ref(mk.order[k])
    } else {
        p < k && is_ref(obj(h, mk.order[p]), s) && obj(h, mk.order[p]).words[s] == AVal::Ref(mk.order[k])
    }
}

pub open spec fn mpar_ok(h: H, mk: Mk, rv: Seq<AVal>) -> bool {
    forall|k: int| 0 <= k < mk.order.len() ==> #[trigger] mparent_ok(h, mk, rv, k)
}

/// The parent a newly marked object `j` gets.
pub open spec fn mnew_parent_ok(h: H, mk: Mk, rv: Seq<AVal>, j: int, par: (int, int)) -> bool {
    if par.0 < 0 {
        0 <= -1 - par.0 < rv.len() && rv[-1 - par.0] == AVal::Ref(j)
    } else {
        par.0 < mk.order.len() && is_ref(obj(h, mk.order[par.0]), par.1) && obj(h, mk.order[par.0]).words[par.1] == AVal::Ref(j)
    }
}

/// The bits are the marked objects' start words.
pub open spec fn bits_ok(c: Ctx, m: MCtx, h: H, mk: Mk) -> bool {
    &&& mshape(c, m, mk.mb)
    &&& forall|j: int| #[trigger] from(h, j) ==> (mbit(mk.mb, fpg(h, j), foff(h, j)) <==> marked(mk, j))
    &&& forall|i: int, k: int| 0 <= i < c.nf && 0 <= k < c.pw && #[trigger] mbit(mk.mb, i, k) ==>
            exists|j: int| #[trigger] from(h, j) && h.loc[j] == (i, k)
}

/// A from-space referent of a slot of a black object is marked.
pub open spec fn black_ok(h: H, mk: Mk) -> bool {
    &&& forall|j: int| #[trigger] mk.black.contains(j) ==> marked(mk, j)
    &&& forall|j: int, s: int| mk.black.contains(j) && is_ref(obj(h, j), s) && #[trigger] obj(h, j).words[s] is Ref
            && from(h, obj(h, j).words[s]->Ref_0) ==> marked(mk, obj(h, j).words[s]->Ref_0)
}

/// The mark stack holds the addresses of distinct marked, non-black objects.
pub open spec fn stack_ok(h: H, mk: Mk, stk: Seq<usize>, sp: int) -> bool {
    &&& stk.len() == MSTACK
    &&& 0 <= sp == mk.sid.len() <= MSTACK
    &&& mk.sid.no_duplicates()
    &&& forall|q: int| 0 <= q < sp ==> marked(mk, #[trigger] mk.sid[q]) && !mk.black.contains(mk.sid[q])
            && stk[q] == h.addr[mk.sid[q]]
}

pub open spec fn mk_inv(c: Ctx, m: MCtx, h: H, mk: Mk, rv: Seq<AVal>, stk: Seq<usize>, sp: int) -> bool {
    &&& mbk_ok(h, mk)
    &&& mpar_ok(h, mk, rv)
    &&& bits_ok(c, m, h, mk)
    &&& black_ok(h, mk)
    &&& stack_ok(h, mk, stk, sp)
}

/// Object `j` lies at or after word `lo` of page `lp`.
pub open spec fn after(h: H, j: int, lp: int, lo: int) -> bool {
    fpg(h, j) > lp || (fpg(h, j) == lp && foff(h, j) >= lo)
}

/// A marked object that is not black is on the stack, or the overflow flag
/// is set, or it lies at or after (`lp`, `lo`); except object `x` (the one
/// being visited; -1: none).
pub open spec fn pend_ok(h: H, mk: Mk, ovf: bool, lp: int, lo: int, x: int) -> bool {
    forall|j: int| #[trigger] marked(mk, j) && !mk.black.contains(j) && j != x ==> mk.sid.contains(j) || ovf || after(h, j, lp, lo)
}

/// The marking only grows.
pub open spec fn mgrow(mk0: Mk, mk1: Mk) -> bool {
    &&& mk0.order.len() <= mk1.order.len()
    &&& forall|k: int| 0 <= k < mk0.order.len() ==> mk1.order[k] == mk0.order[k] && mk1.parent[k] == mk0.parent[k]
    &&& forall|j: int| #[trigger] marked(mk0, j) ==> marked(mk1, j) && mk1.pos[j] == mk0.pos[j]
    &&& mk0.black.subset_of(mk1.black)
}

pub proof fn lemma_mgrow_trans(mk0: Mk, mk1: Mk, mk2: Mk)
    requires mgrow(mk0, mk1), mgrow(mk1, mk2),
    ensures mgrow(mk0, mk2),
{
    assert forall|j: int| #[trigger] marked(mk0, j) implies marked(mk2, j) && mk2.pos[j] == mk0.pos[j] by {
        assert(marked(mk1, j));
    }
}

/// At most every object is marked.
pub proof fn lemma_mbound(h: H, mk: Mk)
    requires mbk_ok(h, mk), forall|j: int| #[trigger] from(h, j) ==> 0 <= j < h.objs.len(),
    ensures mk.order.len() <= h.objs.len(),
{
    let s = mk.order.to_set();
    assert(mk.order.no_duplicates()) by {
        assert forall|a: int, b: int| 0 <= a < mk.order.len() && 0 <= b < mk.order.len() && a != b implies
            mk.order[a] != mk.order[b] by {
            assert(mk.pos[mk.order[a]] == a && mk.pos[mk.order[b]] == b);
        }
    }
    mk.order.unique_seq_to_set();
    lemma_int_range(0, h.objs.len() as int);
    assert forall|j: int| #[trigger] s.contains(j) implies set_int_range(0, h.objs.len() as int).contains(j) by {
        let k = choose|k: int| 0 <= k < mk.order.len() && mk.order[k] == j;
        assert(from(h, mk.order[k]));
    }
    lemma_len_subset(s, set_int_range(0, h.objs.len() as int));
}

// ---------------------------------------------------------------------------
// Marking a value.

/// The from-space location of the object a from-space word designates.
pub proof fn lemma_decode(c: Ctx, h: H, v: AVal, w: usize, pi: int)
    requires
        ctx_ok(c), fpages_ok(c), heap_ok(c, h),
        w == enc(h.addr, v), slot_ok(c, h.objs.len() as int, v),
        w % 2 == 1, 0 <= pi < c.nf, in_fpage(c, pi, w),
    ensures
        v is Ref, from(h, v->Ref_0), fpg(h, v->Ref_0) == pi,
        (w - 1 - fs(c, pi)) / (W as int) == foff(h, v->Ref_0),
        h.addr[v->Ref_0] == w,
{
    assert(in_from(c, w));
    let j = v->Ref_0;
    assert(v is Ref);
    assert(0 <= j < h.objs.len());
    if !from(h, j) {
        assert(!in_from(c, h.addr[j]));
    }
    lemma_from_addr(c, h, j);
    lemma_one_page(c, pi, fpg(h, j), w);
    lemma_from_obj(c, h, j);
    lemma_offset(fs(c, pi), foff(h, j));
}

/// Two from-space objects at one location are one.
pub proof fn lemma_one_obj(c: Ctx, h: H, j1: int, j2: int)
    requires heap_ok(c, h), from(h, j1), from(h, j2), h.loc[j1] == h.loc[j2],
    ensures j1 == j2,
{
    if j1 != j2 {
        assert(fdisjoint(h, j1, j2));
        lemma_from_obj(c, h, j1);
        lemma_from_obj(c, h, j2);
    }
}

/// Visits a value: if it designates an unmarked from-space object, marks it
/// (its bit, the ghost order) and pushes it, or sets the overflow flag when
/// the stack is full.
pub fn mark_val(c: &Ctx, m: &MCtx, w: usize, stk: &mut [usize; MSTACK], sp: &mut usize, ovf: &mut bool,
                Ghost(h): Ghost<H>, Ghost(v): Ghost<AVal>, Ghost(par): Ghost<(int, int)>, Ghost(rv): Ghost<Seq<AVal>>,
                Ghost(lp): Ghost<int>, Ghost(lo): Ghost<int>, Ghost(ex): Ghost<int>,
                Tracked(mk): Tracked<&mut Mk>, Tracked(ro): Tracked<&Ro>, Tracked(mtp): Tracked<&Map<int, PointsTo<usize>>>)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), heap_ok(*c, h), mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
        mk_inv(*c, *m, h, *old(mk), rv, old(stk)@, *old(sp) as int),
        pend_ok(h, *old(mk), *old(ovf), lp, lo, ex),
        w == enc(h.addr, v), slot_ok(*c, h.objs.len() as int, v),
        v matches AVal::Ref(j) ==> (from(h, j) && !marked(*old(mk), j) ==> mnew_parent_ok(h, *old(mk), rv, j, par)),
    ensures
        mk_inv(*c, *m, h, *final(mk), rv, final(stk)@, *final(sp) as int),
        pend_ok(h, *final(mk), *final(ovf), lp, lo, ex),
        mgrow(*old(mk), *final(mk)),
        final(mk).black == old(mk).black,
        v matches AVal::Ref(j) ==> (from(h, j) ==> marked(*final(mk), j)),
        final(mk).order.len() <= old(mk).order.len() + 1,
        *final(sp) <= *old(sp) + (final(mk).order.len() - old(mk).order.len()),
        *final(sp) >= *old(sp),
        *old(ovf) ==> *final(ovf),
        *final(ovf) && !*old(ovf) ==> final(mk).order.len() > old(mk).order.len(),
        forall|q: int| 0 <= q < old(mk).sid.len() ==> #[trigger] final(mk).sid[q] == old(mk).sid[q],
        final(mk).sid.len() <= old(mk).sid.len() + 1,
        final(mk).sid.len() > old(mk).sid.len() ==> !marked(*old(mk), final(mk).sid[final(mk).sid.len() - 1]),
{
    let ghost mk0 = *mk;
    if w % 2 == 1 {
        let pi = find_page(c, w, Tracked(&ro.ftp));
        if pi < c.nf {
            let ghost j = v->Ref_0;
            let s = ftab_at(c, pi, Tracked(&ro.ftp));
            proof {
                lemma_decode(*c, h, v, w, pi as int);
                lemma_from_obj(*c, h, j);
                lemma_w();
            }
            let off = (w - 1 - s) / W;
            let ms = mtab_at(c, m, pi, Tracked(mtp));
            let wi = off / 32;
            let b = (off % 32) as u32;
            proof {
                assert(off < c.pw);
                assert(wi < mwords(*c)) by {
                    vstd::arithmetic::div_mod::lemma_div_is_ordered(off as int, c.pw as int - 1, 32);
                    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(c.pw as int, 32);
                    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(c.pw as int - 1, 32);
                }
                assert(mk.mb.contains_key((pi as int, wi as int)));
            }
            let p = mword_ptr(c, m, ms, wi, Ghost(pi as int));
            let x: u32 = *ptr_ref(p, Tracked(mk.mb.tracked_borrow((pi as int, wi as int))));
            proof {
                assert(mbit(mk0.mb, pi as int, off as int) == bit(x, b as int));
                assert(mbit(mk0.mb, fpg(h, j), foff(h, j)) <==> marked(mk0, j));
            }
            if (x >> b) & 1u32 == 0 {
                let nx: u32 = x | (1u32 << b);
                ptr_mut_write(p, Tracked(mk.mb.tracked_borrow_mut((pi as int, wi as int))), nx);
                proof {
                    let k = mk0.order.len() as int;
                    mk.order = mk0.order.push(j);
                    mk.pos = mk0.pos.insert(j, k);
                    mk.parent = mk0.parent.push(par);
                }
                if *sp < MSTACK {
                    proof { lemma_mask(*sp); }
                    stk[*sp & (MSTACK - 1)] = w;
                    proof { mk.sid = mk0.sid.push(j); }
                    *sp = *sp + 1;
                } else {
                    *ovf = true;
                }
                proof {
                    let mk1 = *mk;
                    let k = mk0.order.len() as int;
                    assert(!marked(mk0, j));
                    // The bookkeeping.
                    assert forall|kk: int| 0 <= kk < mk1.order.len() implies from(h, #[trigger] mk1.order[kk])
                        && mk1.pos.contains_key(mk1.order[kk]) && mk1.pos[mk1.order[kk]] == kk by {
                        if kk < k {
                            assert(mk1.order[kk] == mk0.order[kk]);
                            assert(mk0.order[kk] != j);
                        }
                    }
                    assert forall|jj: int| #[trigger] marked(mk1, jj) implies 0 <= mk1.pos[jj] < mk1.order.len()
                        && mk1.order[mk1.pos[jj]] == jj by {
                        if jj != j { assert(marked(mk0, jj)); }
                    }
                    assert(mbk_ok(h, mk1));
                    assert forall|kk: int| 0 <= kk < mk1.order.len() implies #[trigger] mparent_ok(h, mk1, rv, kk) by {
                        if kk < k {
                            assert(mparent_ok(h, mk0, rv, kk));
                            if mk0.parent[kk].0 >= 0 {
                                assert(mk1.order[mk0.parent[kk].0] == mk0.order[mk0.parent[kk].0]);
                            }
                        } else {
                            assert(mnew_parent_ok(h, mk0, rv, j, par));
                            if par.0 >= 0 {
                                assert(mk1.order[par.0] == mk0.order[par.0]);
                            }
                        }
                    }
                    // The bits.
                    assert forall|i2: int, w2: int| 0 <= i2 < c.nf && 0 <= w2 < mwords(*c) implies
                        #[trigger] mk1.mb.contains_key((i2, w2)) && mk1.mb[(i2, w2)].ptr() == mptr(*m, i2, w2)
                        && mk1.mb[(i2, w2)].is_init() by {
                        assert(mk0.mb.contains_key((i2, w2)) && mk0.mb[(i2, w2)].is_init());
                    }
                    assert forall|i2: int, k2: int| #![trigger mbit(mk1.mb, i2, k2)] 0 <= i2 < c.nf && 0 <= k2 < c.pw implies
                        mbit(mk1.mb, i2, k2) == (mbit(mk0.mb, i2, k2) || (i2 == pi && k2 == off)) by {
                        if i2 == pi && k2 / 32 == wi as int {
                            lemma_bit_set(x, b, (k2 % 32) as u32);
                            if k2 % 32 == b as int {
                                vstd::arithmetic::div_mod::lemma_fundamental_div_mod(k2, 32);
                                vstd::arithmetic::div_mod::lemma_fundamental_div_mod(off as int, 32);
                            }
                        } else {
                            if i2 == pi && k2 == off { assert(k2 / 32 == wi as int); }
                        }
                    }
                    assert forall|jj: int| #[trigger] from(h, jj) implies (mbit(mk1.mb, fpg(h, jj), foff(h, jj)) <==> marked(mk1, jj)) by {
                        lemma_from_obj(*c, h, jj);
                        assert(mbit(mk1.mb, fpg(h, jj), foff(h, jj)) == (mbit(mk0.mb, fpg(h, jj), foff(h, jj)) || (fpg(h, jj) == pi && foff(h, jj) == off)));
                        if fpg(h, jj) == pi && foff(h, jj) == off { lemma_one_obj(*c, h, jj, j); }
                    }
                    assert forall|i2: int, k2: int| 0 <= i2 < c.nf && 0 <= k2 < c.pw && #[trigger] mbit(mk1.mb, i2, k2) implies
                        exists|jj: int| #[trigger] from(h, jj) && h.loc[jj] == (i2, k2) by {
                        if !mbit(mk0.mb, i2, k2) {
                            assert(i2 == pi && k2 == off);
                            assert(from(h, j) && h.loc[j] == (i2, k2));
                        }
                    }
                    assert(bits_ok(*c, *m, h, mk1));
                    assert(black_ok(h, mk1)) by {
                        assert forall|jj: int| #[trigger] mk1.black.contains(jj) implies marked(mk1, jj) by {
                            assert(marked(mk0, jj));
                        }
                        assert forall|jj: int, s2: int| mk1.black.contains(jj) && is_ref(obj(h, jj), s2) && #[trigger] obj(h, jj).words[s2] is Ref
                            && from(h, obj(h, jj).words[s2]->Ref_0) implies marked(mk1, obj(h, jj).words[s2]->Ref_0) by {
                            assert(marked(mk0, obj(h, jj).words[s2]->Ref_0));
                        }
                    }
                    assert(stack_ok(h, mk1, stk@, *sp as int)) by {
                        if mk1.sid.len() > mk0.sid.len() {
                            assert(!mk0.sid.contains(j));
                            assert forall|a: int, bb: int| 0 <= a < mk1.sid.len() && 0 <= bb < mk1.sid.len() && a != bb implies
                                mk1.sid[a] != mk1.sid[bb] by {
                                if a < mk0.sid.len() && bb < mk0.sid.len() {} else if a < mk0.sid.len() {
                                    assert(mk1.sid[a] == mk0.sid[a]);
                                } else {
                                    assert(mk1.sid[bb] == mk0.sid[bb]);
                                }
                            }
                        }
                        assert forall|q: int| 0 <= q < *sp implies marked(mk1, #[trigger] mk1.sid[q]) && !mk1.black.contains(mk1.sid[q])
                            && stk@[q] == h.addr[mk1.sid[q]] by {
                            if q < mk0.sid.len() {
                                assert(mk1.sid[q] == mk0.sid[q]);
                                assert(marked(mk0, mk0.sid[q]));
                            } else {
                                assert(mk1.sid[q] == j);
                                assert(!mk0.black.contains(j));
                            }
                        }
                    }
                    assert forall|jj: int| #[trigger] marked(mk1, jj) && !mk1.black.contains(jj) && jj != ex implies
                        mk1.sid.contains(jj) || *ovf || after(h, jj, lp, lo) by {
                        if jj == j {
                            if mk1.sid.len() > mk0.sid.len() { assert(mk1.sid[mk1.sid.len() - 1] == j); }
                        } else {
                            assert(marked(mk0, jj));
                            if mk0.sid.contains(jj) {
                                let q = choose|q: int| 0 <= q < mk0.sid.len() && mk0.sid[q] == jj;
                                assert(mk1.sid[q] == jj);
                            }
                        }
                    }
                    assert forall|jj: int| #[trigger] marked(mk0, jj) implies marked(mk1, jj) && mk1.pos[jj] == mk0.pos[jj] by {}
                }
            } else {
                proof { lemma_bit_read(x, b); }
            }
        } else {
            proof {
                if v is Ref && from(h, v->Ref_0) { lemma_from_addr(*c, h, v->Ref_0); }
            }
        }
    } else {
        proof {
            if v is Ref && from(h, v->Ref_0) { lemma_from_addr(*c, h, v->Ref_0); }
        }
    }
}


// ---------------------------------------------------------------------------
// Visiting an object.

/// The raw words of a from-space object are where `obj_layout` reads them.
pub proof fn lemma_raw_at(c: Ctx, h: H, fp: Map<(int, int), PointsTo<usize>>, j: int)
    requires heap_ok(c, h), from_ok(c, h, fp), from(h, j),
    ensures raw_words_at(fp, fptr(c, fpg(h, j)), fpg(h, j), foff(h, j), obj(h, j)),
{
    lemma_from_obj(c, h, j);
    let o = obj(h, j);
    assert forall|k: int| 0 <= k < lay(o).size && #[trigger] o.words[k] is Raw implies
        wperm_ok(fp, (fpg(h, j), foff(h, j) + k), fptr(c, fpg(h, j)), foff(h, j) + k) && fp[(fpg(h, j), foff(h, j) + k)].is_init()
        && fp[(fpg(h, j), foff(h, j) + k)].value() == raw(o.words[k]) by {
        assert(fkey(h, j, k) == (fpg(h, j), foff(h, j) + k));
        assert(fp[fkey(h, j, k)].is_init());
    }
}

/// Visits the reference slots of marked object `j` (at word `off` of page
/// `pi`, which starts at `s`): marks their from-space referents; `j` is
/// black afterwards. Returns `j`'s size.
pub fn scan_obj(c: &Ctx, m: &MCtx, pi: usize, s: usize, off: usize, stk: &mut [usize; MSTACK], sp: &mut usize, ovf: &mut bool,
                Ghost(h): Ghost<H>, Ghost(j): Ghost<int>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(lp): Ghost<int>, Ghost(lo): Ghost<int>,
                Tracked(mk): Tracked<&mut Mk>, Tracked(ro): Tracked<&Ro>, Tracked(mtp): Tracked<&Map<int, PointsTo<usize>>>,
                Tracked(fp): Tracked<&Map<(int, int), PointsTo<usize>>>) -> (sz: usize)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
        mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
        mk_inv(*c, *m, h, *old(mk), rv, old(stk)@, *old(sp) as int),
        pend_ok(h, *old(mk), *old(ovf), lp, lo, j),
        from(h, j), marked(*old(mk), j), !old(mk).sid.contains(j),
        pi == fpg(h, j), off == foff(h, j), s == fs(*c, pi as int),
    ensures
        mk_inv(*c, *m, h, *final(mk), rv, final(stk)@, *final(sp) as int),
        pend_ok(h, *final(mk), *final(ovf), lp, lo, -1),
        mgrow(*old(mk), *final(mk)),
        final(mk).black == old(mk).black.insert(j),
        *final(sp) <= *old(sp) + (final(mk).order.len() - old(mk).order.len()),
        *old(ovf) ==> *final(ovf),
        *final(ovf) && !*old(ovf) ==> final(mk).order.len() > old(mk).order.len(),
        sz == size(h, j),
{
    let ghost mk0 = *mk;
    let ghost o = obj(h, j);
    proof {
        lemma_from_obj(*c, h, j);
        lemma_raw_at(*c, h, *fp, j);
        assert(fs(*c, pi as int) + pbytes(*c) < usize::MAX);
    }
    let page = c.base.with_addr(s);
    proof { assert(page == fptr(*c, pi as int)); }
    let (sz, lo_s, hi_s) = obj_layout(c, page, off, Ghost(pi as int), Tracked(fp), Ghost(o), Ghost(c.pw as int), Tracked(&ro.ctp));
    let mut si = lo_s;
    while si < hi_s
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
            mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
            mk_inv(*c, *m, h, *mk, rv, stk@, *sp as int),
            pend_ok(h, *mk, *ovf, lp, lo, j),
            from(h, j), marked(*mk, j), !mk.sid.contains(j),
            pi == fpg(h, j), off == foff(h, j), page == fptr(*c, pi as int),
            o == obj(h, j), sz == lay(o).size, lo_s == lay(o).lo, hi_s == lay(o).hi,
            lo_s <= si <= hi_s, hi_s <= sz, off + sz <= c.pw - 1,
            mgrow(mk0, *mk), mk.black == mk0.black,
            *sp <= *old(sp) + (mk.order.len() - mk0.order.len()),
            *old(ovf) ==> *ovf,
            *ovf && !*old(ovf) ==> mk.order.len() > mk0.order.len(),
            forall|s2: int| lo_s <= s2 < si && #[trigger] o.words[s2] is Ref && from(h, o.words[s2]->Ref_0) ==> marked(*mk, o.words[s2]->Ref_0),
        decreases hi_s - si,
    {
        let ghost mk1 = *mk;
        proof {
            lemma_w();
            assert(fkey(h, j, si as int) == (pi as int, off + si));
            assert(wperm_ok(*fp, (pi as int, off + si), fptr(*c, pi as int), off + si));
            assert(fp[fkey(h, j, si as int)].is_init());
            assert(fs(*c, pi as int) + pbytes(*c) < usize::MAX);
            assert((off + si) * W <= c.pw * W) by (nonlinear_arith) requires off + si <= c.pw, W > 0;
            assert(slots_ok(*c, h, j));
            assert(slot_ok(*c, h.objs.len() as int, o.words[si as int]));
            assert(mk1.order[mk1.pos[j]] == j);
        }
        let w = rd(page, off + si, Ghost((pi as int, off + si)), Tracked(fp));
        mark_val(c, m, w, stk, sp, ovf, Ghost(h), Ghost(o.words[si as int]), Ghost((mk1.pos[j], si as int)), Ghost(rv),
                 Ghost(lp), Ghost(lo), Ghost(j), Tracked(mk), Tracked(ro), Tracked(mtp));
        proof {
            lemma_mgrow_trans(mk0, mk1, *mk);
            assert(marked(*mk, j));
            if mk.sid.contains(j) {
                let q = choose|q: int| 0 <= q < mk.sid.len() && mk.sid[q] == j;
                if q < mk1.sid.len() { assert(mk1.sid[q] == j); }
                else { assert(q == mk.sid.len() - 1); }
            }
            assert forall|s2: int| lo_s <= s2 < si + 1 && #[trigger] o.words[s2] is Ref && from(h, o.words[s2]->Ref_0) implies
                marked(*mk, o.words[s2]->Ref_0) by {
                if s2 < si { assert(marked(mk1, o.words[s2]->Ref_0)); }
            }
        }
        si += 1;
    }
    proof {
        let mk1 = *mk;
        mk.black = mk1.black.insert(j);
        let mk2 = *mk;
        assert(mbk_ok(h, mk2)) by {
            assert forall|jj: int| #[trigger] marked(mk2, jj) implies 0 <= mk2.pos[jj] < mk2.order.len() && mk2.order[mk2.pos[jj]] == jj by {
                assert(marked(mk1, jj));
            }
            assert forall|k: int| 0 <= k < mk2.order.len() implies from(h, #[trigger] mk2.order[k]) && mk2.pos.contains_key(mk2.order[k]) && mk2.pos[mk2.order[k]] == k by {
                assert(mk1.order[k] == mk2.order[k]);
            }
        }
        assert(black_ok(h, mk2)) by {
            assert forall|jj: int| #[trigger] mk2.black.contains(jj) implies marked(mk2, jj) by {
                if jj != j { assert(mk1.black.contains(jj)); }
            }
            assert forall|jj: int, s2: int| mk2.black.contains(jj) && is_ref(obj(h, jj), s2) && #[trigger] obj(h, jj).words[s2] is Ref
                && from(h, obj(h, jj).words[s2]->Ref_0) implies marked(mk2, obj(h, jj).words[s2]->Ref_0) by {
                if jj != j { assert(mk1.black.contains(jj)); }
            }
        }
        assert(stack_ok(h, mk2, stk@, *sp as int)) by {
            assert forall|q: int| 0 <= q < *sp implies marked(mk2, #[trigger] mk2.sid[q]) && !mk2.black.contains(mk2.sid[q])
                && stk@[q] == h.addr[mk2.sid[q]] by {
                assert(mk1.sid[q] != j);
            }
        }
        assert(bits_ok(*c, *m, h, mk2));
        assert(mpar_ok(h, mk2, rv)) by {
            assert forall|k: int| 0 <= k < mk2.order.len() implies #[trigger] mparent_ok(h, mk2, rv, k) by {
                assert(mparent_ok(h, mk1, rv, k));
            }
        }
        assert(pend_ok(h, mk2, *ovf, lp, lo, -1)) by {
            assert forall|jj: int| #[trigger] marked(mk2, jj) && !mk2.black.contains(jj) && jj != -1 implies
                mk2.sid.contains(jj) || *ovf || after(h, jj, lp, lo) by {
                assert(marked(mk1, jj) && !mk1.black.contains(jj) && jj != j);
            }
        }
        assert forall|jj: int| #[trigger] marked(mk0, jj) implies marked(mk2, jj) && mk2.pos[jj] == mk0.pos[jj] by {
            assert(marked(mk1, jj));
        }
    }
    sz
}

/// Pops and visits objects until the stack is empty.
pub fn empty_stack(c: &Ctx, m: &MCtx, stk: &mut [usize; MSTACK], sp: &mut usize, ovf: &mut bool,
                   Ghost(h): Ghost<H>, Ghost(rv): Ghost<Seq<AVal>>, Ghost(lp): Ghost<int>, Ghost(lo): Ghost<int>,
                   Tracked(mk): Tracked<&mut Mk>, Tracked(ro): Tracked<&Ro>, Tracked(mtp): Tracked<&Map<int, PointsTo<usize>>>,
                   Tracked(fp): Tracked<&Map<(int, int), PointsTo<usize>>>)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
        mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
        mk_inv(*c, *m, h, *old(mk), rv, old(stk)@, *old(sp) as int),
        pend_ok(h, *old(mk), *old(ovf), lp, lo, -1),
    ensures
        mk_inv(*c, *m, h, *final(mk), rv, final(stk)@, *final(sp) as int),
        pend_ok(h, *final(mk), *final(ovf), lp, lo, -1),
        mgrow(*old(mk), *final(mk)),
        *final(sp) == 0,
        *old(ovf) ==> *final(ovf),
        *final(ovf) && !*old(ovf) ==> final(mk).order.len() > old(mk).order.len(),
{
    let ghost mk0 = *mk;
    proof { lemma_mbound(h, *mk); }
    while *sp > 0
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
            mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
            mk_inv(*c, *m, h, *mk, rv, stk@, *sp as int),
            pend_ok(h, *mk, *ovf, lp, lo, -1),
            mgrow(mk0, *mk),
            mk.order.len() <= h.objs.len(),
            *old(ovf) ==> *ovf,
            *ovf && !*old(ovf) ==> mk.order.len() > mk0.order.len(),
        decreases 2 * (h.objs.len() - mk.order.len()) + *sp,
    {
        let ghost mk1 = *mk;
        *sp = *sp - 1;
        proof { lemma_mask(*sp); }
        let a = stk[*sp & (MSTACK - 1)];
        let ghost j = mk1.sid[*sp as int];
        proof {
            mk.sid = mk1.sid.drop_last();
            let mk2 = *mk;
            assert(marked(mk1, j) && !mk1.black.contains(j) && a == h.addr[j]);
            assert(from(h, j));
            assert(!mk2.sid.contains(j)) by {
                if mk2.sid.contains(j) {
                    let q = choose|q: int| 0 <= q < mk2.sid.len() && mk2.sid[q] == j;
                    assert(mk1.sid[q] == mk1.sid[*sp as int]);
                }
            }
            assert(stack_ok(h, mk2, stk@, *sp as int)) by {
                assert forall|q: int| 0 <= q < *sp implies marked(mk2, #[trigger] mk2.sid[q]) && !mk2.black.contains(mk2.sid[q])
                    && stk@[q] == h.addr[mk2.sid[q]] by {
                    assert(mk2.sid[q] == mk1.sid[q]);
                }
            }
            assert(pend_ok(h, mk2, *ovf, lp, lo, j)) by {
                assert forall|jj: int| #[trigger] marked(mk2, jj) && !mk2.black.contains(jj) && jj != j implies
                    mk2.sid.contains(jj) || *ovf || after(h, jj, lp, lo) by {
                    assert(marked(mk1, jj));
                    assert(from(h, jj));
                    if mk1.sid.contains(jj) {
                        let q = choose|q: int| 0 <= q < mk1.sid.len() && mk1.sid[q] == jj;
                        assert(q != *sp as int);
                        assert(mk2.sid[q] == jj);
                    }
                }
            }
            assert(mpar_ok(h, mk2, rv)) by {
                assert forall|k: int| 0 <= k < mk2.order.len() implies #[trigger] mparent_ok(h, mk2, rv, k) by {
                    assert(mparent_ok(h, mk1, rv, k));
                }
            }
            lemma_from_addr(*c, h, j);
            lemma_from_obj(*c, h, j);
        }
        let pi = find_page(c, a, Tracked(&ro.ftp));
        proof {
            if pi == c.nf { assert(!in_fpage(*c, fpg(h, j), a)); }
            lemma_one_page(*c, pi as int, fpg(h, j), a);
        }
        let s = ftab_at(c, pi, Tracked(&ro.ftp));
        proof { lemma_offset(s as int, foff(h, j)); lemma_w(); }
        let off = (a - 1 - s) / W;
        let ghost mk2 = *mk;
        scan_obj(c, m, pi, s, off, stk, sp, ovf, Ghost(h), Ghost(j), Ghost(rv), Ghost(lp), Ghost(lo),
                 Tracked(mk), Tracked(ro), Tracked(mtp), Tracked(fp));
        proof {
            assert forall|jj: int| #[trigger] marked(mk1, jj) implies marked(mk2, jj) && mk2.pos[jj] == mk1.pos[jj] by {}
            assert(mgrow(mk1, mk2));
            lemma_mgrow_trans(mk1, mk2, *mk);
            lemma_mgrow_trans(mk0, mk1, *mk);
            lemma_mbound(h, *mk);
        }
    }
}

// ---------------------------------------------------------------------------
// Walking the marked objects.

/// The word index and bit of a page word.
pub proof fn lemma_word_of(k: int, q: int)
    requires 0 <= k <= q < 32 * (k / 32) + 32,
    ensures q / 32 == k / 32, q % 32 >= k % 32, q % 32 == q - 32 * (k / 32),
{
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(k, 32);
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(q, 32);
    let wk = k / 32;
    let wq = q / 32;
    assert(wq == wk) by (nonlinear_arith)
        requires q == 32 * wq + q % 32, 0 <= q % 32 < 32, 32 * wk <= q < 32 * wk + 32;
}

/// The first marked word of page `pi` at or after `k`, or `pw`.
pub fn next_marked(c: &Ctx, m: &MCtx, pi: usize, ms: usize, k0: usize, Tracked(mb): Tracked<&Map<(int, int), PointsTo<u32>>>) -> (r: usize)
    requires
        ctx_ok(*c), mctx_ok(*c, *m), mshape(*c, *m, *mb), pi < c.nf, ms == m.mss@[pi as int], k0 <= c.pw,
    ensures
        k0 <= r <= c.pw,
        forall|q: int| k0 <= q < r ==> !#[trigger] mbit(*mb, pi as int, q),
        r < c.pw ==> mbit(*mb, pi as int, r as int),
{
    let mut k = k0;
    while k < c.pw
        invariant
            ctx_ok(*c), mctx_ok(*c, *m), mshape(*c, *m, *mb), pi < c.nf, ms == m.mss@[pi as int],
            k0 <= k <= c.pw,
            forall|q: int| k0 <= q < k ==> !#[trigger] mbit(*mb, pi as int, q),
        decreases c.pw - k,
    {
        let wi = k / 32;
        let b = (k % 32) as u32;
        proof {
            vstd::arithmetic::div_mod::lemma_fundamental_div_mod(k as int, 32);
            vstd::arithmetic::div_mod::lemma_fundamental_div_mod(c.pw as int, 32);
            assert(wi < mwords(*c)) by (nonlinear_arith)
                requires k < c.pw, k == 32 * (k / 32) + k % 32, c.pw == 32 * (c.pw / 32) + c.pw % 32, c.pw % 32 == 0, 0 <= k % 32 < 32,
                    wi == k / 32, mwords(*c) == c.pw / 32;
            assert(mb.contains_key((pi as int, wi as int)));
        }
        let p = mword_ptr(c, m, ms, wi, Ghost(pi as int));
        let x: u32 = *ptr_ref(p, Tracked(mb.tracked_borrow((pi as int, wi as int))));
        if x >> b == 0 {
            proof {
                assert((wi + 1) * 32 <= c.pw) by (nonlinear_arith)
                    requires wi < c.pw / 32, c.pw == 32 * (c.pw / 32) + c.pw % 32, c.pw % 32 == 0;
                assert forall|q: int| k0 <= q < (wi + 1) * 32 implies !#[trigger] mbit(*mb, pi as int, q) by {
                    if q >= k {
                        lemma_word_of(k as int, q);
                        lemma_bits_zero(x, b, (q % 32) as u32);
                    }
                }
            }
            k = (wi + 1) * 32;
        } else if (x >> b) & 1u32 == 1u32 {
            return k;
        } else {
            k = k + 1;
        }
    }
    k
}

/// Visits every marked object again (after a mark-stack overflow), page by
/// page, emptying the stack after each.
pub fn rescan(c: &Ctx, m: &MCtx, stk: &mut [usize; MSTACK], sp: &mut usize, ovf: &mut bool,
              Ghost(h): Ghost<H>, Ghost(rv): Ghost<Seq<AVal>>,
              Tracked(mk): Tracked<&mut Mk>, Tracked(ro): Tracked<&Ro>, Tracked(mtp): Tracked<&Map<int, PointsTo<usize>>>,
              Tracked(fp): Tracked<&Map<(int, int), PointsTo<usize>>>)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
        mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
        mk_inv(*c, *m, h, *old(mk), rv, old(stk)@, *old(sp) as int),
        *old(sp) == 0, !*old(ovf),
    ensures
        mk_inv(*c, *m, h, *final(mk), rv, final(stk)@, *final(sp) as int),
        pend_ok(h, *final(mk), *final(ovf), c.nf as int, 0, -1),
        mgrow(*old(mk), *final(mk)),
        *final(sp) == 0,
        *final(ovf) ==> final(mk).order.len() > old(mk).order.len(),
{
    let ghost mk0 = *mk;
    proof {
        assert forall|jj: int| #[trigger] marked(mk0, jj) && !mk0.black.contains(jj) && jj != -1 implies
            mk0.sid.contains(jj) || *ovf || after(h, jj, 0, 0) by {
            lemma_from_obj(*c, h, jj);
        }
    }
    let mut pi: usize = 0;
    while pi < c.nf
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
            mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
            mk_inv(*c, *m, h, *mk, rv, stk@, *sp as int),
            pend_ok(h, *mk, *ovf, pi as int, 0, -1),
            mgrow(mk0, *mk), *sp == 0, pi <= c.nf,
            *ovf ==> mk.order.len() > mk0.order.len(),
        decreases c.nf - pi,
    {
        let s = ftab_at(c, pi, Tracked(&ro.ftp));
        let ms = mtab_at(c, m, pi, Tracked(mtp));
        let mut k: usize = 0;
        while k < c.pw
            invariant
                ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
                mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
                mk_inv(*c, *m, h, *mk, rv, stk@, *sp as int),
                pend_ok(h, *mk, *ovf, pi as int, k as int, -1),
                mgrow(mk0, *mk), *sp == 0, pi < c.nf, k <= c.pw,
                s == fs(*c, pi as int), ms == m.mss@[pi as int],
                *ovf ==> mk.order.len() > mk0.order.len(),
            decreases c.pw - k,
        {
            let k2 = next_marked(c, m, pi, ms, k, Tracked(&mk.mb));
            if k2 == c.pw {
                proof {
                    assert forall|jj: int| #[trigger] marked(*mk, jj) && !mk.black.contains(jj) && jj != -1 implies
                        mk.sid.contains(jj) || *ovf || after(h, jj, pi as int, c.pw as int) by {
                        if !mk.sid.contains(jj) && !*ovf && fpg(h, jj) == pi as int && foff(h, jj) >= k {
                            assert(from(h, jj));
                            assert(mbit(mk.mb, fpg(h, jj), foff(h, jj)));
                            lemma_from_obj(*c, h, jj);
                        }
                    }
                }
                k = c.pw;
            } else {
                let ghost mk1 = *mk;
                let ghost j = choose|j: int| #[trigger] from(h, j) && h.loc[j] == (pi as int, k2 as int);
                proof {
                    assert(mbit(mk1.mb, pi as int, k2 as int));
                    assert(exists|jj: int| #[trigger] from(h, jj) && h.loc[jj] == (pi as int, k2 as int));
                    assert(from(h, j) && h.loc[j] == (pi as int, k2 as int));
                    assert(mbit(mk1.mb, fpg(h, j), foff(h, j)));
                    assert(marked(mk1, j));
                    assert(!mk1.sid.contains(j));
                    lemma_from_obj(*c, h, j);
                    assert forall|jj: int| #[trigger] marked(mk1, jj) && !mk1.black.contains(jj) && jj != j implies
                        mk1.sid.contains(jj) || *ovf || after(h, jj, pi as int, k2 as int) by {
                        if !mk1.sid.contains(jj) && !*ovf && fpg(h, jj) == pi as int && k <= foff(h, jj) < k2 {
                            assert(from(h, jj));
                            assert(mbit(mk1.mb, fpg(h, jj), foff(h, jj)));
                        }
                    }
                }
                let sz = scan_obj(c, m, pi, s, k2, stk, sp, ovf, Ghost(h), Ghost(j), Ghost(rv), Ghost(pi as int), Ghost(k2 as int),
                                  Tracked(mk), Tracked(ro), Tracked(mtp), Tracked(fp));
                let ghost mk2 = *mk;
                empty_stack(c, m, stk, sp, ovf, Ghost(h), Ghost(rv), Ghost(pi as int), Ghost(k2 as int),
                            Tracked(mk), Tracked(ro), Tracked(mtp), Tracked(fp));
                proof {
                    lemma_mgrow_trans(mk1, mk2, *mk);
                    lemma_mgrow_trans(mk0, mk1, *mk);
                    let mk3 = *mk;
                    assert(mk3.black.contains(j));
                    assert forall|jj: int| #[trigger] marked(mk3, jj) && !mk3.black.contains(jj) && jj != -1 implies
                        mk3.sid.contains(jj) || *ovf || after(h, jj, pi as int, k2 + sz) by {
                        if !mk3.sid.contains(jj) && !*ovf && fpg(h, jj) == pi as int && k2 <= foff(h, jj) < k2 + sz {
                            assert(from(h, jj));
                            lemma_from_obj(*c, h, jj);
                            if jj != j {
                                assert(fdisjoint(h, jj, j));
                            }
                        }
                    }
                }
                k = k2 + sz;
            }
        }
        proof {
            assert forall|jj: int| #[trigger] marked(*mk, jj) && !mk.black.contains(jj) && jj != -1 implies
                mk.sid.contains(jj) || *ovf || after(h, jj, pi + 1, 0) by {
                if !mk.sid.contains(jj) && !*ovf && fpg(h, jj) == pi as int {
                    assert(from(h, jj));
                    lemma_from_obj(*c, h, jj);
                }
            }
        }
        pi += 1;
    }
}

// ---------------------------------------------------------------------------
// The mark phase.

/// Clears the mark bits of every from-space page.
pub fn clear_bits(c: &Ctx, m: &MCtx, Tracked(mtp): Tracked<&Map<int, PointsTo<usize>>>, Tracked(mb): Tracked<&mut Map<(int, int), PointsTo<u32>>>)
    requires ctx_ok(*c), mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp), mperm(*c, *m, *old(mb)),
    ensures
        mshape(*c, *m, *final(mb)),
        forall|i: int, w: int| 0 <= i < c.nf && 0 <= w < mwords(*c) ==> (#[trigger] final(mb)[(i, w)]).value() == 0u32,
{
    let mut pi: usize = 0;
    let nw = c.pw / 32;
    while pi < c.nf
        invariant
            ctx_ok(*c), mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp), mperm(*c, *m, *mb), pi <= c.nf, nw == mwords(*c),
            forall|i: int, w: int| 0 <= i < pi && 0 <= w < mwords(*c) ==> (#[trigger] mb[(i, w)]).is_init() && mb[(i, w)].value() == 0u32,
        decreases c.nf - pi,
    {
        let ms = mtab_at(c, m, pi, Tracked(mtp));
        let mut wi: usize = 0;
        while wi < nw
            invariant
                ctx_ok(*c), mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp), mperm(*c, *m, *mb), pi < c.nf, nw == mwords(*c),
                wi <= nw, ms == m.mss@[pi as int],
                forall|i: int, w: int| 0 <= i < pi && 0 <= w < mwords(*c) ==> (#[trigger] mb[(i, w)]).is_init() && mb[(i, w)].value() == 0u32,
                forall|w: int| 0 <= w < wi ==> (#[trigger] mb[(pi as int, w)]).is_init() && mb[(pi as int, w)].value() == 0u32,
            decreases nw - wi,
        {
            let p = mword_ptr(c, m, ms, wi, Ghost(pi as int));
            proof { assert(mb.contains_key((pi as int, wi as int))); }
            let ghost mb0 = *mb;
            ptr_mut_write(p, Tracked(mb.tracked_borrow_mut((pi as int, wi as int))), 0u32);
            proof {
                assert forall|i: int, w: int| 0 <= i < c.nf && 0 <= w < mwords(*c) implies
                    #[trigger] mb.contains_key((i, w)) && mb[(i, w)].ptr() == mptr(*m, i, w) by {
                    assert(mb0.contains_key((i, w)));
                }
                assert forall|i: int, w: int| 0 <= i < pi && 0 <= w < mwords(*c) implies (#[trigger] mb[(i, w)]).is_init() && mb[(i, w)].value() == 0u32 by {
                    assert(mb0[(i, w)].is_init());
                }
                assert forall|w: int| 0 <= w < wi + 1 implies (#[trigger] mb[(pi as int, w)]).is_init() && mb[(pi as int, w)].value() == 0u32 by {
                    if w < wi { assert(mb0[(pi as int, w)].is_init()); }
                }
            }
            wi += 1;
        }
        pi += 1;
    }
}

/// Every from-space object a path from the roots leads to is marked: the
/// roots' referents are marked and every marked object is black.
pub proof fn lemma_mpath(c: Ctx, h: H, mk: Mk, rv: Seq<AVal>, p: Seq<int>, j: int, k: int)
    requires
        heap_ok(c, h), black_ok(h, mk),
        forall|j2: int| #[trigger] marked(mk, j2) ==> mk.black.contains(j2),
        forall|i: int| 0 <= i < rv.len() && #[trigger] rv[i] is Ref && from(h, rv[i]->Ref_0) ==> marked(mk, rv[i]->Ref_0),
        path(h, rv, p, j), 0 <= k < p.len(),
    ensures from(h, p[k]) ==> marked(mk, p[k]),
    decreases k,
{
    if k == 0 {
        let i = choose|i: int| 0 <= i < rv.len() && #[trigger] rv[i] == AVal::Ref(p[0]);
        assert(rv[i] is Ref);
    } else {
        lemma_mpath(c, h, mk, rv, p, j, k - 1);
        let a = p[k - 1];
        assert(0 <= a < h.objs.len() && refers(h, a, p[k]));
        let s = choose|s: int| is_ref(obj(h, a), s) && #[trigger] obj(h, a).words[s] == AVal::Ref(p[k]);
        if from(h, a) {
            assert(mk.black.contains(a));
            assert(obj(h, a).words[s] is Ref);
        } else {
            assert(prog_ref_ok(h, obj(h, a).words[s]));
        }
    }
}

/// Every marked object is reachable: through its parent chain.
pub proof fn lemma_mreach(c: Ctx, h: H, mk: Mk, rv: Seq<AVal>, k: int)
    requires heap_ok(c, h), mbk_ok(h, mk), mpar_ok(h, mk, rv), 0 <= k < mk.order.len(),
    ensures reachable(h, rv, mk.order[k]),
    decreases k,
{
    assert(mparent_ok(h, mk, rv, k));
    let p = mk.parent[k].0;
    let j = mk.order[k];
    if p < 0 {
        let q = seq![j];
        assert(rv[-1 - p] == AVal::Ref(q[0]));
        assert(path(h, rv, q, j));
    } else {
        lemma_mreach(c, h, mk, rv, p);
        let j2 = mk.order[p];
        let q0 = choose|q0: Seq<int>| #[trigger] path(h, rv, q0, j2);
        assert(from(h, j2));
        lemma_from_obj(c, h, j2);
        assert(refers(h, j2, j));
        let q = q0.push(j);
        assert forall|mm: int| 0 <= mm < q.len() - 1 implies 0 <= #[trigger] q[mm] < h.objs.len() && refers(h, q[mm], q[mm + 1]) by {
            if mm < q0.len() - 1 {
                assert(q0[mm] == q[mm] && q0[mm + 1] == q[mm + 1]);
            } else {
                assert(q[mm] == j2 && q[mm + 1] == j);
            }
        }
        assert(q[0] == q0[0]);
        assert(path(h, rv, q, j));
    }
}

/// The marking is complete: the marked from-space objects are exactly the
/// reachable ones.
pub open spec fn mark_done(c: Ctx, m: MCtx, h: H, mk: Mk, rv: Seq<AVal>) -> bool {
    &&& mbk_ok(h, mk)
    &&& mpar_ok(h, mk, rv)
    &&& bits_ok(c, m, h, mk)
    &&& black_ok(h, mk)
    &&& forall|j: int| #[trigger] marked(mk, j) ==> mk.black.contains(j)
    &&& forall|j: int| #[trigger] from(h, j) ==> (marked(mk, j) <==> reachable(h, rv, j))
}

/// THE MARK PHASE: clears the bitmap, marks the roots' referents, empties
/// the stack, and walks the marked objects again while the stack
/// overflowed. Afterwards the bits are exactly the start words of the
/// from-space objects the roots reach. The heap is only read.
pub fn mark(c: &Ctx, m: &MCtx, rptr: *mut usize, rlen: usize, Ghost(h): Ghost<H>, Ghost(rv): Ghost<Seq<AVal>>,
            Tracked(ro): Tracked<&Ro>, Tracked(mtp): Tracked<&Map<int, PointsTo<usize>>>,
            Tracked(fp): Tracked<&Map<(int, int), PointsTo<usize>>>, Tracked(rp): Tracked<&Map<int, PointsTo<usize>>>,
            Tracked(mb): Tracked<Map<(int, int), PointsTo<u32>>>) -> (r: Tracked<Mk>)
    requires
        ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
        mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp), mperm(*c, *m, mb),
        roots_in(*c, h, *rp, rptr, rv), rv.len() == rlen,
    ensures
        mark_done(*c, *m, h, r@, rv),
{
    let tracked mut mb = mb;
    clear_bits(c, m, Tracked(mtp), Tracked(&mut mb));
    let tracked mut mk = Mk { order: Seq::empty(), pos: Map::empty(), parent: Seq::empty(), black: Set::empty(), sid: Seq::empty(), mb: mb };
    let mut stk: [usize; MSTACK] = [0usize; MSTACK];
    let mut sp: usize = 0;
    let mut ovf = false;
    proof {
        assert forall|j: int| #[trigger] from(h, j) implies (mbit(mk.mb, fpg(h, j), foff(h, j)) <==> marked(mk, j)) by {
            lemma_from_obj(*c, h, j);
            vstd::arithmetic::div_mod::lemma_div_is_ordered(foff(h, j), c.pw as int - 1, 32);
            vstd::arithmetic::div_mod::lemma_fundamental_div_mod(c.pw as int, 32);
            vstd::arithmetic::div_mod::lemma_fundamental_div_mod(c.pw as int - 1, 32);
            assert(mk.mb[(fpg(h, j), foff(h, j) / 32)].value() == 0u32);
            lemma_zero_bits((foff(h, j) % 32) as u32);
        }
        assert forall|i: int, k: int| 0 <= i < c.nf && 0 <= k < c.pw && #[trigger] mbit(mk.mb, i, k) implies
            exists|j: int| #[trigger] from(h, j) && h.loc[j] == (i, k) by {
            vstd::arithmetic::div_mod::lemma_div_is_ordered(k, c.pw as int - 1, 32);
            vstd::arithmetic::div_mod::lemma_fundamental_div_mod(c.pw as int, 32);
            vstd::arithmetic::div_mod::lemma_fundamental_div_mod(c.pw as int - 1, 32);
            assert(mk.mb[(i, k / 32)].value() == 0u32);
            lemma_zero_bits((k % 32) as u32);
        }
        assert(stk@.len() == MSTACK);
    }
    // The roots.
    let mut i: usize = 0;
    while i < rlen
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
            mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
            roots_in(*c, h, *rp, rptr, rv), rv.len() == rlen, i <= rlen,
            mk_inv(*c, *m, h, mk, rv, stk@, sp as int),
            pend_ok(h, mk, ovf, c.nf as int, 0, -1),
            forall|i2: int| 0 <= i2 < i && #[trigger] rv[i2] is Ref && from(h, rv[i2]->Ref_0) ==> marked(mk, rv[i2]->Ref_0),
        decreases rlen - i,
    {
        proof {
            lemma_w();
            assert(wperm_ok(*rp, i as int, rptr, i as int));
            assert(i * W <= rlen * W) by (nonlinear_arith) requires i <= rlen, W >= 1;
        }
        let w = rd(rptr, i, Ghost(i as int), Tracked(rp));
        let ghost mk1 = mk;
        mark_val(c, m, w, &mut stk, &mut sp, &mut ovf, Ghost(h), Ghost(rv[i as int]), Ghost((-1 - i, 0int)), Ghost(rv),
                 Ghost(c.nf as int), Ghost(0), Ghost(-1), Tracked(&mut mk), Tracked(ro), Tracked(mtp));
        proof {
            assert forall|i2: int| 0 <= i2 < i + 1 && #[trigger] rv[i2] is Ref && from(h, rv[i2]->Ref_0) implies marked(mk, rv[i2]->Ref_0) by {
                if i2 < i { assert(marked(mk1, rv[i2]->Ref_0)); }
            }
        }
        i += 1;
    }
    let ghost mkr = mk;
    empty_stack(c, m, &mut stk, &mut sp, &mut ovf, Ghost(h), Ghost(rv), Ghost(c.nf as int), Ghost(0),
                Tracked(&mut mk), Tracked(ro), Tracked(mtp), Tracked(fp));
    proof { lemma_mbound(h, mk); }
    while ovf
        invariant
            ctx_ok(*c), fpages_ok(*c), ftab_ok(*c, ro.ftp), ctab_ok(*c, ro.ctp), heap_ok(*c, h), from_ok(*c, h, *fp),
            mctx_ok(*c, *m), mtab_ok(*c, *m, *mtp),
            mk_inv(*c, *m, h, mk, rv, stk@, sp as int),
            pend_ok(h, mk, ovf, c.nf as int, 0, -1),
            sp == 0, mgrow(mkr, mk), mk.order.len() <= h.objs.len(),
        decreases h.objs.len() - mk.order.len() + (if ovf { 1int } else { 0int }),
    {
        ovf = false;
        let ghost mk1 = mk;
        rescan(c, m, &mut stk, &mut sp, &mut ovf, Ghost(h), Ghost(rv), Tracked(&mut mk), Tracked(ro), Tracked(mtp), Tracked(fp));
        proof {
            lemma_mgrow_trans(mkr, mk1, mk);
            lemma_mbound(h, mk);
        }
    }
    proof {
        assert forall|j: int| #[trigger] marked(mk, j) implies mk.black.contains(j) by {
            if !mk.black.contains(j) {
                assert(mk.sid.len() == 0);
                assert(from(h, j));
                lemma_from_obj(*c, h, j);
                assert(!after(h, j, c.nf as int, 0));
            }
        }
        assert forall|i2: int| 0 <= i2 < rv.len() && #[trigger] rv[i2] is Ref && from(h, rv[i2]->Ref_0) implies marked(mk, rv[i2]->Ref_0) by {
            assert(marked(mkr, rv[i2]->Ref_0));
        }
        assert forall|j: int| #[trigger] from(h, j) implies (marked(mk, j) <==> reachable(h, rv, j)) by {
            if marked(mk, j) {
                lemma_mreach(*c, h, mk, rv, mk.pos[j]);
            }
            if reachable(h, rv, j) {
                let p = choose|p: Seq<int>| #[trigger] path(h, rv, p, j);
                lemma_mpath(*c, h, mk, rv, p, j, p.len() - 1);
            }
        }
    }
    Tracked(mk)
}
} // verus!
