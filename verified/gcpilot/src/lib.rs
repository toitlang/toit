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

//! GC proof pilot, route B: the young-generation copy (a Cheney scavenge of
//! a from-space into a to-space, with forwarding headers and the scan loop)
//! in Rust, proved with Verus for heaps of arbitrary size. Not linked into
//! the VM. See README.md next to Cargo.toml for what is and is not covered.
//!
//! The property (`scavenge`'s contract): the abstract heap (`H::objs`, object
//! ids stable) is unchanged; every young object reachable from the roots is
//! copied once (`St::pos`, its position in copy order), its words in
//! to-space are its abstract words encoded under the new address map
//! (`St::addr2`), every reference slot of a copy and every root refers to a
//! copied young object or to a non-young object, whose address is
//! unchanged. That is the core's `refines` over the live objects with the
//! same ghost state and new addresses (README: "The property").

#![no_std]
#![allow(unused_imports)]

use vstd::prelude::*;
use vstd::raw_ptr::*;
use vstd::set_lib::*;

pub mod scavenge;



verus! {

#[cfg(target_pointer_width = "64")]
global size_of usize == 8;
#[cfg(target_pointer_width = "32")]
global size_of usize == 4;

/// Bytes per word.
#[cfg(target_pointer_width = "64")]
pub const W: usize = 8;
#[cfg(target_pointer_width = "32")]
pub const W: usize = 4;

// ---------------------------------------------------------------------------
// Pointer arithmetic: the same trusted item as verified/core/src/view.rs
// (TRUSTED.md section 0, "Rust and target semantics"), restated here because
// this crate does not depend on the core.

pub open spec fn modulus() -> int { usize::MAX as int + 1 }

pub open spec fn wrap(x: int) -> usize { (x % modulus()) as usize }

pub open spec fn at_index(base: *mut usize, i: int) -> *mut usize {
    ptr_mut_from_data::<usize>(PtrData::<usize> {
        addr: wrap(base@.addr + i * size_of::<usize>()),
        provenance: base@.provenance,
        metadata: (),
    })
}

/// TRUSTED (as in verified/core/src/view.rs): `pointer::wrapping_add`.
pub assume_specification<T>[<*mut T>::wrapping_add](p: *mut T, count: usize) -> (q: *mut T)
    ensures q == ptr_mut_from_data::<T>(PtrData::<T> {
        addr: wrap(p@.addr + count * size_of::<T>()), provenance: p@.provenance, metadata: () }),
    opens_invariants none
    no_unwind;

// ---------------------------------------------------------------------------
// The abstract heap. Object ids are stable across the collection (as in the
// core's `State2::heap`); a value is a small integer (an even word), a
// reference to an object id, or a raw payload word (lengths, doubles,
// bytes: never interpreted as a reference).

pub enum AVal {
    Smi(usize),
    Ref(int),
    Raw(usize),
}

/// An object: its header word and the words after it.
pub struct AObj {
    pub hdr: usize,
    pub slots: Seq<AVal>,
}

/// The machine word of a value under the address map `a` (the core's
/// `abs::enc`: objects are their tagged address).
pub open spec fn enc(a: Seq<usize>, v: AVal) -> usize {
    match v {
        AVal::Smi(w) => w,
        AVal::Ref(j) => if 0 <= j < a.len() { a[j] } else { 0 },
        AVal::Raw(w) => w,
    }
}

pub open spec fn words(o: AObj) -> int { 1 + o.slots.len() as int }

/// Word `off` of object `o` under the address map `a` (the core's
/// `view::word_val`, for this pilot's layout).
pub open spec fn wval(o: AObj, a: Seq<usize>, off: int) -> usize {
    if off == 0 { o.hdr } else { enc(a, o.slots[off - 1]) }
}

/// The pilot's object layout, decoded from the header (the VM decodes the
/// class id through the class table: README, "Simplifications"). Bit 0 is
/// clear (a forwarding header is a tagged address, bit 0 set); kind 0: an
/// instance with `hdr / 8` reference fields; kind 1: an array (length word,
/// then reference elements); kind 2: a raw object (length word, then raw
/// words).
pub open spec fn kind(h: usize) -> int { (h as int / 2) % 4 }

pub open spec fn nfields(h: usize) -> int { h as int / 8 }

/// The first reference slot (word offset).
pub open spec fn ref_lo(o: AObj) -> int {
    if kind(o.hdr) == 0 { 1 } else if kind(o.hdr) == 1 { 2 } else { words(o) }
}

pub open spec fn is_ref_slot(o: AObj, off: int) -> bool { ref_lo(o) <= off < words(o) }

pub open spec fn val_ok(v: AVal, n: int, refslot: bool) -> bool {
    if refslot {
        match v {
            AVal::Smi(w) => w % 2 == 0,
            AVal::Ref(j) => 0 <= j < n,
            AVal::Raw(_) => false,
        }
    } else {
        v is Raw
    }
}

pub open spec fn obj_ok(o: AObj, n: int) -> bool {
    &&& o.hdr % 2 == 0
    &&& kind(o.hdr) < 3
    &&& kind(o.hdr) == 0 ==> o.slots.len() == nfields(o.hdr)
    &&& kind(o.hdr) != 0 ==> o.slots.len() >= 1 && o.slots[0] == AVal::Raw((o.slots.len() - 1) as usize)
    &&& forall|i: int| 0 <= i < o.slots.len() ==> #[trigger] sok(o, n, i)
}

/// Slot `i` (word `i + 1`) holds a value of its kind.
pub open spec fn sok(o: AObj, n: int, i: int) -> bool { val_ok(o.slots[i], n, is_ref_slot(o, i + 1)) }

/// The heap before the collection: the objects, their current addresses,
/// the from-space word index of each young object, and the used prefix of
/// from-space.
pub struct H {
    pub objs: Seq<AObj>,
    pub addr: Seq<usize>,
    pub fidx: Map<int, int>,
    pub fused: int,
}

pub open spec fn obj(h: H, j: int) -> AObj { h.objs[j] }

pub open spec fn young(h: H, j: int) -> bool { h.fidx.contains_key(j) }

/// The from-space word indices of young object `j`.
pub open spec fn extent(h: H, j: int) -> Set<int> { set_int_range(h.fidx[j], h.fidx[j] + words(obj(h, j))) }

pub open spec fn disjoint(h: H, j1: int, j2: int) -> bool {
    h.fidx[j1] + words(obj(h, j1)) <= h.fidx[j2] || h.fidx[j2] + words(obj(h, j2)) <= h.fidx[j1]
}

/// The two spaces: base pointers, their addresses, lengths in words.
pub struct Ctx {
    pub fptr: *mut usize,
    pub fstart: usize,
    pub flen: usize,
    pub tptr: *mut usize,
    pub tstart: usize,
    pub tlen: usize,
}

pub open spec fn faddr(c: Ctx, i: int) -> int { c.fstart + i * W + 1 }

pub open spec fn taddr(c: Ctx, i: int) -> int { c.tstart + i * W + 1 }

/// The C++ `in_from_space`: a tagged word inside from-space.
pub open spec fn in_from(c: Ctx, w: usize) -> bool {
    w % 2 == 1 && w > c.fstart && w - c.fstart < c.flen * W
}

pub open spec fn ctx_ok(c: Ctx) -> bool {
    &&& c.fstart == c.fptr@.addr
    &&& c.tstart == c.tptr@.addr
    &&& c.fstart % W == 0
    &&& c.tstart % W == 0
    &&& c.fstart + c.flen * W + 1 <= usize::MAX
    &&& c.tstart + c.tlen * W + 1 <= usize::MAX
    &&& c.flen <= c.tlen
}

pub open spec fn slot_ok(perms: Map<int, PointsTo<usize>>, base: *mut usize, i: int) -> bool {
    perms.contains_key(i) && perms[i].ptr() == at_index(base, i)
}

pub open spec fn shape(perms: Map<int, PointsTo<usize>>, base: *mut usize, len: int) -> bool {
    forall|i: int| 0 <= i < len ==> #[trigger] slot_ok(perms, base, i)
}

pub open spec fn fval(fp: Map<int, PointsTo<usize>>, h: H, j: int, off: int) -> PointsTo<usize> {
    fp[h.fidx[j] + off]
}

/// The heap is well formed (the precondition of a scavenge): the facts the
/// VM's allocator and the previous collection establish (TRUSTED.md V2 for
/// the core's view of it).
pub open spec fn heap_ok(c: Ctx, h: H) -> bool {
    &&& h.addr.len() == h.objs.len()
    &&& 0 <= h.fused <= c.flen
    &&& forall|j: int| 0 <= j < h.objs.len() ==> #[trigger] obj_ok(obj(h, j), h.objs.len() as int)
    &&& forall|j: int| #[trigger] young(h, j) ==>
            0 <= j < h.objs.len() && 0 <= h.fidx[j] && h.fidx[j] + words(obj(h, j)) <= h.fused
            && h.addr[j] == faddr(c, h.fidx[j])
    &&& forall|j1: int, j2: int| young(h, j1) && young(h, j2) && j1 != j2 ==> #[trigger] disjoint(h, j1, j2)
    &&& forall|j: int| 0 <= j < h.objs.len() && !young(h, j) ==> !in_from(c, #[trigger] h.addr[j])
}

/// The from-space words of the young objects, before the collection.
pub open spec fn from_ok(c: Ctx, h: H, fp: Map<int, PointsTo<usize>>) -> bool {
    &&& shape(fp, c.fptr, c.flen as int)
    &&& forall|j: int, off: int| young(h, j) && 0 <= off < words(obj(h, j)) ==>
            (#[trigger] fval(fp, h, j, off)).is_init() && fval(fp, h, j, off).value() == wval(obj(h, j), h.addr, off)
}

// ---------------------------------------------------------------------------
// The collector's state and the Cheney invariant.

/// Permissions of the two spaces and of the root array, and the ghost
/// bookkeeping: copied ids in copy order with their to-space word indices,
/// each copied id's position, the new address map, and the from-space
/// words of the copied objects (for the capacity argument).
pub tracked struct St {
    pub tracked fp: Map<int, PointsTo<usize>>,
    pub tracked tp: Map<int, PointsTo<usize>>,
    pub tracked rp: Map<int, PointsTo<usize>>,
    pub ghost order: Seq<int>,
    pub ghost starts: Seq<int>,
    pub ghost pos: Map<int, int>,
    pub ghost addr2: Seq<usize>,
    pub ghost used: Set<int>,
}

pub open spec fn copied(st: St, j: int) -> bool { st.pos.contains_key(j) }

/// The end of the copy of the `k`th copied object.
pub open spec fn send(h: H, st: St, k: int) -> int { st.starts[k] + words(obj(h, st.order[k])) }

pub open spec fn slot(h: H, st: St, k: int, off: int) -> AVal { obj(h, st.order[k]).slots[off - 1] }

pub open spec fn tval(st: St, k: int, off: int) -> PointsTo<usize> { st.tp[st.starts[k] + off] }

/// A processed reference does not refer to an uncopied young object.
pub open spec fn closed(h: H, st: St, v: AVal) -> bool {
    match v {
        AVal::Ref(j) => !young(h, j) || copied(st, j),
        _ => true,
    }
}

/// The address map of to-space word `t` when the words below `p` are
/// processed.
pub open spec fn amap(h: H, st: St, t: int, p: int) -> Seq<usize> {
    if t < p { st.addr2 } else { h.addr }
}

/// The Cheney invariant: `free` is the copy pointer, the to-space words
/// below `p` are processed (the scan pointer, at word granularity).
pub open spec fn inv(c: Ctx, h: H, st: St, free: int, p: int) -> bool {
    let n = st.order.len() as int;
    &&& shape(st.fp, c.fptr, c.flen as int)
    &&& shape(st.tp, c.tptr, c.tlen as int)
    &&& st.starts.len() == n + 1
    &&& st.starts[0] == 0
    &&& forall|k: int| 0 <= k < n ==> #[trigger] send(h, st, k) == st.starts[k + 1]
    &&& forall|k: int| 0 <= k < n ==> 0 <= #[trigger] st.starts[k] && send(h, st, k) <= free
    &&& forall|k1: int, k2: int| #![trigger send(h, st, k1), st.starts[k2]] 0 <= k1 < k2 < n ==> send(h, st, k1) <= st.starts[k2]
    &&& free == st.starts[n]
    &&& 0 <= p <= free <= h.fused
    &&& forall|k: int| 0 <= k < n ==> young(h, #[trigger] st.order[k]) && st.pos.contains_key(st.order[k]) && st.pos[st.order[k]] == k
    &&& forall|j: int| #[trigger] copied(st, j) ==> 0 <= st.pos[j] < n && st.order[st.pos[j]] == j
    &&& st.addr2.len() == h.objs.len()
    &&& forall|j: int| 0 <= j < h.objs.len() ==> #[trigger] st.addr2[j] ==
            (if copied(st, j) { taddr(c, st.starts[st.pos[j]]) as usize } else { h.addr[j] })
    // From-space: an uncopied young object is intact; a copied one has a
    // forwarding header.
    &&& forall|j: int, off: int| young(h, j) && !copied(st, j) && 0 <= off < words(obj(h, j)) ==>
            (#[trigger] fval(st.fp, h, j, off)).is_init() && fval(st.fp, h, j, off).value() == wval(obj(h, j), h.addr, off)
    &&& forall|j: int| young(h, j) && #[trigger] copied(st, j) ==>
            fval(st.fp, h, j, 0).is_init() && fval(st.fp, h, j, 0).value() == st.addr2[j]
    // To-space: the copies, processed below p.
    &&& forall|k: int, off: int| 0 <= k < n && 0 <= off < words(obj(h, st.order[k])) ==>
            (#[trigger] tval(st, k, off)).is_init()
            && tval(st, k, off).value() == wval(obj(h, st.order[k]), amap(h, st, st.starts[k] + off, p), off)
    &&& forall|k: int, off: int| 0 <= k < n && 0 <= off < words(obj(h, st.order[k])) && st.starts[k] + off < p
            && is_ref_slot(obj(h, st.order[k]), off) ==>
            closed(h, st, #[trigger] slot(h, st, k, off))
    // Capacity: the from-space words of the copied objects.
    &&& st.used.len() == free
    &&& st.used.subset_of(set_int_range(0, h.fused))
    &&& forall|j: int| #[trigger] young(h, j) && !copied(st, j) ==> st.used.disjoint(extent(h, j))
}

/// The roots: words `0..ri` processed.
pub open spec fn roots_ok(h: H, st: St, rptr: *mut usize, rv: Seq<AVal>, ri: int) -> bool {
    &&& shape(st.rp, rptr, rv.len() as int)
    &&& 0 <= ri <= rv.len()
    &&& forall|i: int| 0 <= i < rv.len() ==> #[trigger] val_ok(rv[i], h.objs.len() as int, true)
    &&& forall|i: int| 0 <= i < rv.len() ==> (#[trigger] st.rp[i]).is_init()
            && st.rp[i].value() == enc(if i < ri { st.addr2 } else { h.addr }, rv[i])
    &&& forall|i: int| 0 <= i < ri ==> closed(h, st, #[trigger] rv[i])
}

/// What a step of the collector keeps of the state before it.
pub open spec fn grows(h: H, s0: St, s1: St) -> bool {
    &&& s0.order.len() <= s1.order.len()
    &&& forall|k: int| 0 <= k < s0.order.len() ==> #[trigger] s1.order[k] == s0.order[k]
    &&& forall|k: int| 0 <= k <= s0.order.len() ==> #[trigger] s1.starts[k] == s0.starts[k]
    &&& forall|j: int| #[trigger] copied(s0, j) ==> copied(s1, j) && s1.pos[j] == s0.pos[j]
    &&& forall|j: int| 0 <= j < s0.addr2.len() && (copied(s0, j) || !young(h, j)) ==> #[trigger] s1.addr2[j] == s0.addr2[j]
    &&& forall|j: int| 0 <= j < s0.addr2.len() && !young(h, j) ==> !copied(s1, j)
    &&& s1.rp == s0.rp
}

// ---------------------------------------------------------------------------
// Arithmetic lemmas.

pub proof fn lemma_w()
    ensures W == size_of::<usize>(), W >= 4, W % 2 == 0,
{
}

pub proof fn lemma_tag(base: int, i: int)
    requires base % (W as int) == 0, i >= 0, base >= 0,
    ensures (base + i * W + 1) % 2 == 1,
{
    lemma_w();
    let q = base / (W as int);
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(base, W as int);
    assert(base == q * W);
    assert(base + i * W + 1 == 2 * (q * (W as int / 2) + i * (W as int / 2)) + 1) by (nonlinear_arith)
        requires base == q * W, W as int == 2 * (W as int / 2);
}

pub proof fn lemma_index(base: int, i: int)
    requires i >= 0,
    ensures (i * W + 1) / (W as int) == i,
{
    lemma_w();
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod_converse(i * W + 1, W as int, i, 1);
}

pub proof fn lemma_mul_le(i: int, n: int)
    requires 0 <= i <= n,
    ensures 0 <= i * W <= n * W,
{
    lemma_w();
    assert(0 <= i * W <= n * W) by (nonlinear_arith) requires 0 <= i <= n, W >= 0;
}

pub proof fn lemma_mul_lt(i: int, n: int)
    requires 0 <= i < n,
    ensures i * W + 1 < n * W,
{
    lemma_w();
    assert(i * W + 1 < n * W) by (nonlinear_arith) requires 0 <= i < n, W >= 2;
}

/// A value's word depends on the address map only through its referent.
pub proof fn lemma_enc_same(a1: Seq<usize>, a2: Seq<usize>, v: AVal)
    requires
        a1.len() == a2.len(),
        v matches AVal::Ref(j) ==> (0 <= j < a1.len() ==> a1[j] == a2[j]),
    ensures enc(a1, v) == enc(a2, v),
{
}

// ---------------------------------------------------------------------------
// Memory access.

#[inline(always)]
pub fn rd(ptr: *mut usize, i: usize, Tracked(perms): Tracked<&Map<int, PointsTo<usize>>>) -> (v: usize)
    requires slot_ok(*perms, ptr, i as int), perms[i as int].is_init(),
    ensures v == perms[i as int].value(),
    no_unwind
{
    *ptr_ref(ptr.wrapping_add(i), Tracked(perms.tracked_borrow(i as int)))
}

#[inline(always)]
pub fn wr(ptr: *mut usize, i: usize, v: usize, Tracked(perms): Tracked<&mut Map<int, PointsTo<usize>>>)
    requires slot_ok(*old(perms), ptr, i as int),
    ensures
        final(perms).dom() == old(perms).dom(),
        slot_ok(*final(perms), ptr, i as int),
        final(perms)[i as int].is_init(),
        final(perms)[i as int].value() == v,
        forall|k: int| k != i ==> #[trigger] final(perms)[k] == old(perms)[k],
    no_unwind
{
    ptr_mut_write(ptr.wrapping_add(i), Tracked(perms.tracked_borrow_mut(i as int)), v);
}

/// The size in words of an object from its header and second word (only
/// read for kinds 1 and 2), and its first reference slot.
#[inline(always)]
pub fn layout(h: usize, second: usize) -> (r: (usize, usize))
    requires kind(h) != 0 ==> second < usize::MAX - 2,
             h as int / 8 < usize::MAX,
    ensures
        kind(h) == 0 ==> r.1 == 1 + nfields(h) && r.0 == 1,
        kind(h) == 1 ==> r.1 == 2 + second && r.0 == 2,
        kind(h) >= 2 ==> r.1 == 2 + second && r.0 == r.1,
{
    let k = (h / 2) % 4;
    if k == 0 {
        (1, 1 + h / 8)
    } else if k == 1 {
        (2, 2 + second)
    } else {
        (2 + second, 2 + second)
    }
}

} // verus!

verus! {

/// A young object of a well-formed heap is an object of it, well formed.
pub proof fn lemma_young_obj(c: Ctx, h: H, j: int)
    requires heap_ok(c, h), young(h, j),
    ensures
        0 <= j < h.objs.len(), obj_ok(obj(h, j), h.objs.len() as int),
        0 <= h.fidx[j], h.fidx[j] + words(obj(h, j)) <= h.fused,
        h.addr[j] == faddr(c, h.fidx[j]),
{
    assert(young(h, j));
    assert(obj_ok(obj(h, j), h.objs.len() as int));
}

/// Slot `off - 1` of a well-formed object holds a value of its kind.
pub proof fn lemma_slot(o: AObj, n: int, off: int)
    requires obj_ok(o, n), 1 <= off < words(o),
    ensures val_ok(o.slots[off - 1], n, is_ref_slot(o, off)),
{
    assert(sok(o, n, off - 1));
}

} // verus!
