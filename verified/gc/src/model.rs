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

//! The abstract heap the collector works on.
//!
//! Object ids are stable across the collection, as in the core's
//! `State2::heap`. An object is its sequence of words; each word is either a
//! reference to an object id (`AVal::Ref`, stored as that object's tagged
//! address) or a raw word (`AVal::Raw`: the header, smis, lengths, payload
//! bits, bytes; never relocated). Which words may hold references is the
//! layout's business (`layout::lay`: one contiguous range of reference
//! slots per object); a raw word in a reference slot (a smi, a pointer
//! into the bytecodes) is never a from-space address.
//!
//! The heap before the collection (`H`): the objects, their addresses, and
//! for each from-space object its location (page index, word offset). The
//! other objects (the program heap) are outside from-space and keep their
//! addresses.

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::*;
use crate::layout::*;

verus! {

pub enum AVal {
    Ref(int),
    Raw(usize),
}

/// An object: its words, the class bits of its class (from the class table:
/// instance sizes) and the stack array word of the VM build (stacks).
pub struct AObj {
    pub words: Seq<AVal>,
    pub cbits: u16,
    pub sw: int,
}

/// The machine word of a value under the address map `a` (the core's
/// `abs::enc`: objects are their tagged address).
pub open spec fn enc(a: Seq<usize>, v: AVal) -> usize {
    match v {
        AVal::Ref(j) => if 0 <= j < a.len() { a[j] } else { 0 },
        AVal::Raw(w) => w,
    }
}

/// Word `k` of object `o` under the address map `a`.
pub open spec fn wval(o: AObj, a: Seq<usize>, k: int) -> usize {
    enc(a, o.words[k])
}

pub open spec fn raw(v: AVal) -> usize {
    match v {
        AVal::Raw(w) => w,
        AVal::Ref(_) => 0,
    }
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
// The from-space pages.

/// What the collector is given: a pointer with the heap's provenance (the
/// pages' addresses are exposed, as the core's heap is: `view::HeapMem::
/// exposed`; page pointers are `base.with_addr(start)`), the table of
/// from-space page start addresses (sorted, checked at entry), their
/// number and the words per page (all pages have the same size; the last
/// word of a page is the C++ chunk-end sentinel, so objects use at most
/// `pw - 1` words of a page).
pub struct Ctx {
    pub base: *mut usize,
    pub ftab: *mut usize,
    pub nf: usize,
    pub pw: usize,
    /// The class table (the program's class bits) and its length.
    pub ctab: *mut u16,
    pub ncls: usize,
    /// The word of a stack object where its array starts (`Stack::
    /// HEADER_SIZE / WORD_SIZE`, larger in debug builds).
    pub sw: usize,
    /// The from-space table's contents.
    pub fss: Ghost<Seq<usize>>,
    /// The class table's contents.
    pub cbs: Ghost<Seq<u16>>,
}

/// The pointer to address `s` with the heap's provenance.
pub open spec fn ppage(c: Ctx, s: int) -> *mut usize {
    ptr_mut_from_data::<usize>(PtrData::<usize> { addr: s as usize, provenance: c.base@.provenance, metadata: () })
}

/// The start address of from-space page `i`.
pub open spec fn fs(c: Ctx, i: int) -> int { c.fss@[i] as int }

/// The pointer of from-space page `i`.
pub open spec fn fptr(c: Ctx, i: int) -> *mut usize { ppage(c, fs(c, i)) }

/// The bytes of a page.
pub open spec fn pbytes(c: Ctx) -> int { c.pw * W }

/// The tagged word `w` designates a word of from-space page `i`.
pub open spec fn in_fpage(c: Ctx, i: int, w: usize) -> bool {
    fs(c, i) < w && w < fs(c, i) + pbytes(c)
}

/// The C++ `in_from_space`: a tagged word inside a from-space page.
pub open spec fn in_from(c: Ctx, w: usize) -> bool {
    w % 2 == 1 && exists|i: int| 0 <= i < c.nf && #[trigger] in_fpage(c, i, w)
}

/// The basic facts about the context (the caller's precondition).
pub open spec fn ctx_ok(c: Ctx) -> bool {
    &&& c.fss@.len() == c.nf
    &&& 2 <= c.pw <= 0x10_0000
    &&& c.nf <= 0x1_0000
    &&& c.cbs@.len() == c.ncls
    &&& c.ncls <= 0x1_0000
    &&& STACK_MIN_ARRAY_WORD <= c.sw <= 0x100
}

/// The from-space table is well formed (checked at run time by
/// `space::check_ftab`): pages word-aligned, in the address space with
/// room above, sorted and disjoint.
pub open spec fn fpages_ok(c: Ctx) -> bool {
    &&& forall|i: int| 0 <= i < c.nf ==> #[trigger] fs(c, i) % (W as int) == 0
    &&& forall|i: int| 0 <= i < c.nf ==> #[trigger] fs(c, i) + pbytes(c) < usize::MAX
    &&& forall|i: int, j: int| 0 <= i < j < c.nf ==> #[trigger] fs(c, i) + pbytes(c) <= #[trigger] fs(c, j)
}

// ---------------------------------------------------------------------------
// The heap before the collection.

pub struct H {
    pub objs: Seq<AObj>,
    pub addr: Seq<usize>,
    /// From-space objects: (page index, word offset).
    pub loc: Map<int, (int, int)>,
}

pub open spec fn obj(h: H, j: int) -> AObj { h.objs[j] }

pub open spec fn from(h: H, j: int) -> bool { h.loc.contains_key(j) }

pub open spec fn fpg(h: H, j: int) -> int { h.loc[j].0 }

pub open spec fn foff(h: H, j: int) -> int { h.loc[j].1 }

pub open spec fn size(h: H, j: int) -> int { lay(obj(h, j)).size }

/// A value in a reference slot: a reference to an object, or a raw word
/// that is not a from-space address.
pub open spec fn slot_ok(c: Ctx, n: int, v: AVal) -> bool {
    match v {
        AVal::Ref(i) => 0 <= i < n,
        AVal::Raw(w) => !in_from(c, w),
    }
}

/// Object `j`'s reference slots hold valid values.
pub open spec fn slots_ok(c: Ctx, h: H, j: int) -> bool {
    let o = obj(h, j);
    forall|k: int| lay(o).lo <= k < lay(o).hi ==> #[trigger] slot_ok(c, h.objs.len() as int, o.words[k])
}

/// A from-space object lies inside its page, below the sentinel word, at
/// its address.
pub open spec fn fobj_ok(c: Ctx, h: H, j: int) -> bool {
    &&& 0 <= fpg(h, j) < c.nf
    &&& 0 <= foff(h, j)
    &&& foff(h, j) + size(h, j) <= c.pw - 1
    &&& h.addr[j] == fs(c, fpg(h, j)) + foff(h, j) * W + 1
}

/// Two from-space objects do not overlap.
pub open spec fn fdisjoint(h: H, j1: int, j2: int) -> bool {
    fpg(h, j1) != fpg(h, j2)
    || foff(h, j1) + size(h, j1) <= foff(h, j2)
    || foff(h, j2) + size(h, j2) <= foff(h, j1)
}

/// The heap is well formed (the precondition of a collection; at M5 the
/// entry derivation establishes it, as `Heap::new` does for the core).
pub open spec fn heap_ok(c: Ctx, h: H) -> bool {
    let n = h.objs.len() as int;
    &&& h.addr.len() == n
    &&& n < 0x4000_0000
    &&& forall|j: int| 0 <= j < n ==> #[trigger] obj_ok(obj(h, j))
    &&& forall|j: int| 0 <= j < n ==> #[trigger] cls_ok(c, obj(h, j))
    &&& forall|j: int| 0 <= j < n ==> #[trigger] slots_ok(c, h, j)
    &&& forall|j: int| #[trigger] from(h, j) ==> 0 <= j < n && fobj_ok(c, h, j)
    &&& forall|j1: int, j2: int| from(h, j1) && from(h, j2) && j1 != j2 ==> #[trigger] fdisjoint(h, j1, j2)
    &&& forall|j: int| 0 <= j < n && !from(h, j) ==> !in_from(c, #[trigger] h.addr[j]) && h.addr[j] % 4 == 1
    &&& forall|j1: int, j2: int| 0 <= j1 < n && 0 <= j2 < n && !from(h, j1) && !from(h, j2) && j1 != j2
            ==> #[trigger] h.addr[j1] != #[trigger] h.addr[j2]
    &&& forall|j: int, k: int| 0 <= j < n && !from(h, j) && lay(obj(h, j)).lo <= k < lay(obj(h, j)).hi ==>
            #[trigger] prog_ref_ok(h, obj(h, j).words[k])
}

/// The program heap (the objects outside from-space, read-only) does not
/// refer to from-space objects.
pub open spec fn prog_ref_ok(h: H, v: AVal) -> bool {
    match v {
        AVal::Ref(i) => !from(h, i),
        _ => true,
    }
}

/// Word `k` of from-space object `j`'s permission key.
pub open spec fn fkey(h: H, j: int, k: int) -> (int, int) { (fpg(h, j), foff(h, j) + k) }

/// The permissions of every word of every from-space page.
pub open spec fn fshape(c: Ctx, fp: Map<(int, int), PointsTo<usize>>) -> bool {
    forall|i: int, k: int| 0 <= i < c.nf && 0 <= k < c.pw ==> #[trigger] wperm_ok(fp, (i, k), fptr(c, i), k)
}

/// The from-space words of the from-space objects, before the collection.
pub open spec fn from_ok(c: Ctx, h: H, fp: Map<(int, int), PointsTo<usize>>) -> bool {
    &&& fshape(c, fp)
    &&& forall|j: int, k: int| from(h, j) && 0 <= k < size(h, j) ==>
            (#[trigger] fp[fkey(h, j, k)]).is_init() && fp[fkey(h, j, k)].value() == wval(obj(h, j), h.addr, k)
}

/// The read-only inputs of a collection: the header permissions of the
/// objects outside from-space (`others_ok`, ghost witnesses only), the
/// permissions of the from-space table (`space::ftab_ok`) and of the class
/// table (`layout::ctab_ok`).
pub tracked struct Ro {
    pub tracked others: Map<int, PointsTo<usize>>,
    pub tracked ftp: Map<int, PointsTo<usize>>,
    pub tracked ctp: Map<int, PointsTo<u16>>,
}

/// The header permissions of the objects outside from-space (the program
/// heap). The collector reads none of them: they only show that the pages
/// it takes do not hold such an object (`vstd`'s `PointsTo::is_disjoint`).
pub open spec fn others_ok(h: H, others: Map<int, PointsTo<usize>>) -> bool {
    forall|j: int| 0 <= j < h.objs.len() && !from(h, j) ==>
        #[trigger] others.contains_key(j) && others[j].ptr()@.addr == h.addr[j] - 1
}

} // verus!
