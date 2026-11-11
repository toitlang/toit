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

//! The program as the verifier reads it: borrowed tables.
//!
//! `VProgram` holds slices of the tables instead of owned vectors, so the
//! VM can hand the verifier its own memory (the bytecodes in flash, the
//! method records, the dispatch table, ...) without copying it.
//! `vview(p)` is the same `Program2` that `pview2` gives for an
//! `ExecProgram` with the same contents (`vprogram_of` builds one from an
//! `ExecProgram` and proves it).
//!
//! The method table is the VM's own (format note 21): a 4-byte record per
//! method, the entry in the high 24 bits and the arity in the low 8, and
//! the rest in the method's header, which ends at the entry. `vdecode`
//! is the decoding the core and the verifier share (the core reads the
//! same memory without bounds checks, under `table_ok`, which the loader
//! checks); every method has the program's global max height, as in the
//! loader and in the VM. The entries of all but blocks are odd, so that
//! every u16 field of a header is 2-byte aligned (one 16-bit load on
//! targets without unaligned loads, format note 21).

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::types::*;
use crate::v2::types::*;

verus! {

// ---------------------------------------------------------------------------
// The method records and headers (format note 21).

/// A record: the entry (absolute bci of the first instruction) in the high
/// 24 bits ...
pub const RECORD_ENTRY_SHIFT: u32 = 8;
/// ... and the arity in the low 8.
pub const RECORD_ARITY_MASK: u32 = 0xff;
/// The kind byte of a header (the byte before the entry): the kind ...
pub const KIND_MASK: u8 = 0x3;
/// ... and, for a method, that its receiver range is one class (or none).
pub const KIND_SINGLE: u8 = 0x4;
/// How far before the entry a header's fields start (u16, little endian):
/// the selector and the receiver range of methods and accessors, the
/// field index of an accessor, the captured count of a lambda.
pub const SELECTOR_BACK: usize = 3;
pub const RECV_START_BACK: usize = 5;
pub const RECV_END_BACK: usize = 7;
pub const ACCESSOR_AUX_BACK: usize = 9;
pub const LAMBDA_AUX_BACK: usize = 3;

/// A decoded method (`toit::V2Method`): the body at `entry..body_end`.
#[derive(Clone, Copy)]
pub struct VMethod {
    pub entry: u32,
    pub body_end: u32,
    pub selector: u16,
    pub aux: u16,
    pub recv_start: u16,
    pub recv_end: u16,
    pub arity: u8,
    pub kind: u8,
}

impl VMethod {
    /// The bci after the body.
    pub open spec fn end_spec(self) -> usize {
        self.body_end as usize
    }

    #[inline(always)]
    pub fn end(&self) -> (r: usize)
        ensures r == self.end_spec(),
    {
        self.body_end as usize
    }
}

/// Byte `k` of the bytecodes, 0 outside them.
pub open spec fn byte_at(code: Seq<u8>, k: int) -> u8 {
    if 0 <= k < code.len() { code[k] } else { 0 }
}

/// The little-endian u16 at `k`.
pub open spec fn u16_at(code: Seq<u8>, k: int) -> u16 {
    (byte_at(code, k) as u16) | ((byte_at(code, k + 1) as u16) << 8u16)
}

pub open spec fn rec_entry(r: u32) -> u32 {
    r >> RECORD_ENTRY_SHIFT
}

pub open spec fn rec_arity(r: u32) -> u8 {
    (r & RECORD_ARITY_MASK) as u8
}

/// The kind byte of the header that ends at `e`.
pub open spec fn kind_byte(code: Seq<u8>, e: int) -> u8 {
    byte_at(code, e - 1)
}

/// The bytes of a header with kind byte `b` (the kind byte included): a
/// block has only the kind byte, a lambda its captured count, a method
/// its selector and receiver range (one u16 for one class or none, two
/// for a range), an accessor its selector, range and field index.
pub open spec fn hdr_size(b: u8) -> int {
    let k = b & KIND_MASK;
    if k == 3 { 1 } else if k == 2 { 3 } else if k == 1 { 9 } else if b & KIND_SINGLE != 0 { 5 } else { 7 }
}

/// The start of the header of record `r` (0 if it would be negative).
pub open spec fn hdr_start(code: Seq<u8>, r: u32) -> int {
    let e = rec_entry(r) as int;
    let s = e - hdr_size(kind_byte(code, e));
    if s < 0 { 0 } else { s }
}

/// The receiver range end of a method or accessor with kind byte `b` and
/// range start `rs`, whose header ends at `e`.
pub open spec fn recv_end_of(code: Seq<u8>, e: int, b: u8, rs: u16) -> u16 {
    if b & KIND_SINGLE == 0 {
        u16_at(code, e - RECV_END_BACK)
    } else if rs < 0xffff {
        (rs + 1) as u16
    } else {
        0xffff
    }
}

/// Method `i` of the records `recs` with the headers in `code`: total (a
/// read outside the bytecodes is 0), so that any table means something.
pub open spec fn vdecode(code: Seq<u8>, recs: Seq<u32>, i: int) -> VMethod {
    let r = recs[i];
    let e = rec_entry(r) as int;
    let b = kind_byte(code, e);
    let k = b & KIND_MASK;
    let rs = u16_at(code, e - RECV_START_BACK);
    VMethod {
        entry: rec_entry(r),
        body_end: if i + 1 < recs.len() {
            hdr_start(code, recs[i + 1]) as u32
        } else if code.len() < 0x1_0000_0000 {
            code.len() as u32
        } else {
            0
        },
        selector: if k < 2 { u16_at(code, e - SELECTOR_BACK) } else { 0xffff },
        aux: if k == 1 {
            u16_at(code, e - ACCESSOR_AUX_BACK)
        } else if k == 2 {
            u16_at(code, e - LAMBDA_AUX_BACK)
        } else {
            0
        },
        recv_start: if k < 2 { rs } else { 0xffff },
        recv_end: if k < 2 { recv_end_of(code, e, b, rs) } else { 0xffff },
        arity: rec_arity(r),
        kind: k,
    }
}

/// The header of record `r` lies inside the bytecodes, before its entry,
/// and its kind byte is canonical (0 to 4: the kind, or 4 for a method of
/// one class or none), so that a kind is one compare of the kind byte.
/// The entry of a method, accessor or lambda is odd: the u16 fields at
/// the odd distances before it are at even offsets (aligned loads when
/// the bytecodes are 2-byte aligned).
pub open spec fn rec_ok(code: Seq<u8>, r: u32) -> bool {
    let e = rec_entry(r) as int;
    &&& 1 <= e <= code.len()
    &&& hdr_size(kind_byte(code, e)) <= e
    &&& kind_byte(code, e) <= 4
    &&& (kind_byte(code, e) == 3 || e % 2 == 1)
}

/// Every header of the table lies inside the bytecodes, before its entry:
/// what the core needs to read them without bounds checks (part of the
/// loader's contract, `prog_rel`; checked by the loader and by
/// `x_table_ok`).
pub open spec fn table_ok(code: Seq<u8>, recs: Seq<u32>) -> bool {
    forall|i: int| 0 <= i < recs.len() ==> #[trigger] rec_ok(code, recs[i])
}

/// The method table as the verifier reads it: the records and the
/// bytecodes holding the headers. Its view is the decoded table.
#[derive(Clone, Copy)]
pub struct MTable<'a> {
    pub code: &'a [u8],
    pub recs: &'a [u32],
}

impl<'a> View for MTable<'a> {
    type V = Seq<VMethod>;

    open spec fn view(&self) -> Seq<VMethod> {
        Seq::new(self.recs@.len(), |i: int| vdecode(self.code@, self.recs@, i))
    }
}

/// `byte_at(code, e - d)`.
#[inline(always)]
fn x_byte_before(code: &[u8], e: usize, d: usize) -> (r: u8)
    ensures r == byte_at(code@, e - d),
{
    if d <= e && e - d < code.len() { crate::xvec::ix(code, e - d) } else { 0 }
}

/// `u16_at(code, e - d)`, for `d >= 1`.
#[inline(always)]
fn x_u16_before(code: &[u8], e: usize, d: usize) -> (r: u16)
    requires d >= 1,
    ensures r == u16_at(code@, e - d),
{
    let lo = x_byte_before(code, e, d);
    let hi = x_byte_before(code, e, d - 1);
    proof { assert(e - (d - 1) == (e - d) + 1); }
    (lo as u16) | ((hi as u16) << 8)
}

/// `hdr_size(b)`.
#[inline(always)]
pub fn x_hdr_size(b: u8) -> (r: usize)
    ensures r == hdr_size(b), 1 <= r <= 9,
{
    let k = b & KIND_MASK;
    if k == 3 { 1 } else if k == 2 { 3 } else if k == 1 { 9 } else if b & KIND_SINGLE != 0 { 5 } else { 7 }
}

impl<'a> MTable<'a> {
    pub open spec fn spec_len(&self) -> usize {
        self.recs.len()
    }

    #[inline(always)]
    pub fn len(&self) -> (r: usize)
        ensures r == self@.len(), r == self.spec_len(),
    {
        self.recs.len()
    }

    /// The start of record `r`'s header (`hdr_start`).
    fn x_hdr_start(&self, r: u32) -> (s: usize)
        ensures s as int == hdr_start(self.code@, r), s < 0x100_0000,
    {
        let e = (r >> RECORD_ENTRY_SHIFT) as usize;
        proof { assert(r >> RECORD_ENTRY_SHIFT < 0x100_0000) by (bit_vector); }
        let b = x_byte_before(self.code, e, 1);
        let h = x_hdr_size(b);
        if h <= e { e - h } else { 0 }
    }

    /// Method `i`, decoded (`vdecode`).
    pub fn at(&self, i: usize) -> (r: VMethod)
        requires i < self@.len(),
        ensures r == self@[i as int],
    {
        let r = crate::xvec::ix(self.recs, i);
        let e = (r >> RECORD_ENTRY_SHIFT) as usize;
        proof { assert(r >> RECORD_ENTRY_SHIFT < 0x100_0000) by (bit_vector); }
        let b = x_byte_before(self.code, e, 1);
        let k = b & KIND_MASK;
        let rs = x_u16_before(self.code, e, RECV_START_BACK);
        let selector = if k < 2 { x_u16_before(self.code, e, SELECTOR_BACK) } else { 0xffff };
        let aux = if k == 1 {
            x_u16_before(self.code, e, ACCESSOR_AUX_BACK)
        } else if k == 2 {
            x_u16_before(self.code, e, LAMBDA_AUX_BACK)
        } else {
            0
        };
        let recv_end = if k >= 2 {
            0xffff
        } else if b & KIND_SINGLE == 0 {
            x_u16_before(self.code, e, RECV_END_BACK)
        } else if rs < 0xffff {
            rs + 1
        } else {
            0xffff
        };
        let body_end: u32 = if i < self.recs.len() - 1 {
            self.x_hdr_start(crate::xvec::ix(self.recs, i + 1)) as u32
        } else if (self.code.len() as u64) < 0x1_0000_0000u64 {
            self.code.len() as u32
        } else {
            0
        };
        VMethod {
            entry: r >> RECORD_ENTRY_SHIFT,
            body_end,
            selector,
            aux,
            recv_start: if k < 2 { rs } else { 0xffff },
            recv_end,
            arity: (r & RECORD_ARITY_MASK) as u8,
            kind: k,
        }
    }

    /// Method `i`, if there is one.
    pub fn get(&self, i: usize) -> (r: Option<VMethod>)
        ensures r is Some <==> i < self@.len(), r is Some ==> r->0 == self@[i as int],
    {
        if i < self.recs.len() { Some(self.at(i)) } else { None }
    }
}

/// `table_ok`: every header lies inside the bytecodes, before its entry,
/// with a canonical kind byte; every entry but a block's is odd.
pub fn x_table_ok(code: &[u8], recs: &[u32]) -> (r: bool)
    ensures r == table_ok(code@, recs@),
{
    let mut i = 0;
    while i < recs.len()
        invariant 0 <= i <= recs@.len(), forall|j: int| 0 <= j < i ==> #[trigger] rec_ok(code@, recs@[j]),
        decreases recs@.len() - i,
    {
        let r = crate::xvec::ix(recs, i);
        let e = (r >> RECORD_ENTRY_SHIFT) as usize;
        proof { assert(r >> RECORD_ENTRY_SHIFT < 0x100_0000) by (bit_vector); }
        if !(1 <= e && e <= code.len()) {
            proof { assert(!rec_ok(code@, recs@[i as int])); }
            return false;
        }
        let b = crate::xvec::ix(code, e - 1);
        if x_hdr_size(b) > e || b > 4 || (b != 3 && e % 2 == 0) {
            proof { assert(!rec_ok(code@, recs@[i as int])); }
            return false;
        }
        i += 1;
    }
    true
}

pub open spec fn minfo(m: VMethod, max_height: u16) -> MethodInfo {
    MethodInfo {
        arity: m.arity,
        kind: m.kind,
        max_height,
        selector: m.selector,
        aux: m.aux,
        recv_start: m.recv_start,
        recv_end: m.recv_end,
        entry: m.entry as usize,
        end: m.end_spec(),
    }
}

pub struct VProgram<'a> {
    pub word_bits: u8,
    /// The program's global max height (every method's `max_height`).
    pub max_height: u16,
    pub bytecodes: &'a [u8],
    pub methods: MTable<'a>,
    pub dispatch: &'a [i32],
    pub class_bits: &'a [u16],
    pub class_check_ids: &'a [u16],
    pub interface_check_offsets: &'a [u16],
    pub invoke_offsets: &'a [i32],
    pub entry_points: &'a [i32],
    pub builtin: &'a [u16],
    pub roots: &'a [Value],
    pub literals: &'a [Value],
    /// The unchecked mode (`Program2::unchecked`): the unchecked twins of
    /// the field accesses are allowed (trusted programs only, format note
    /// 20).
    pub unchecked: bool,
}

pub open spec fn vview(p: &VProgram) -> Program2 {
    Program2 {
        word_bits: p.word_bits,
        bytecodes: p.bytecodes@,
        methods: Seq::new(p.methods@.len(), |i: int| minfo(p.methods@[i], p.max_height)),
        dispatch: p.dispatch@,
        class_bits: p.class_bits@,
        class_check_ids: p.class_check_ids@,
        interface_check_offsets: p.interface_check_offsets@,
        invoke_offsets: p.invoke_offsets@,
        entry_points: p.entry_points@,
        builtin: p.builtin@,
        roots: p.roots@,
        literals: p.literals@,
        unchecked: p.unchecked,
    }
}

/// Method `m` of the abstract program.
pub open spec fn vinfo(p: &VProgram, m: int) -> MethodInfo {
    vview(p).methods[m]
}

/// `info(vview(p), m)`.
pub fn x_info(p: &VProgram, m: usize) -> (r: MethodInfo)
    requires m < p.methods@.len(),
    ensures r == vview(p).methods[m as int], r == vinfo(p, m as int),
{
    let v = p.methods.at(m);
    MethodInfo {
        arity: v.arity,
        kind: v.kind,
        max_height: p.max_height,
        selector: v.selector,
        aux: v.aux,
        recv_start: v.recv_start,
        recv_end: v.recv_end,
        entry: v.entry as usize,
        end: v.end(),
    }
}

/// The method table of an `ExecProgram` in the VM's layout (its records
/// and bytecodes), if it decodes to the program's methods, each with the
/// max height `h`.
pub fn vmethods_of<'a>(e: &'a ExecProgram, h: u16) -> (r: Option<MTable<'a>>)
    ensures
        r is Some ==> r->0@.len() == e.methods@.len()
            && forall|i: int| 0 <= i < e.methods@.len() ==> #[trigger] minfo(r->0@[i], h) == e.methods@[i],
{
    let t = MTable { code: e.bytecodes.as_slice(), recs: e.recs.as_slice() };
    if t.len() != e.methods.len() { return None; }
    let mut i = 0;
    while i < e.methods.len()
        invariant
            0 <= i <= e.methods@.len(), t@.len() == e.methods@.len(),
            forall|j: int| 0 <= j < i ==> #[trigger] minfo(t@[j], h) == e.methods@[j],
        decreases e.methods@.len() - i,
    {
        let m = e.methods[i];
        let v = t.at(i);
        if m.max_height != h || m.arity != v.arity || m.kind != v.kind || m.selector != v.selector
            || m.aux != v.aux || m.recv_start != v.recv_start || m.recv_end != v.recv_end
            || m.entry != v.entry as usize || m.end != v.end() {
            return None;
        }
        proof { assert(minfo(t@[i as int], h) == e.methods@[i as int]); }
        i += 1;
    }
    Some(t)
}

/// The program view of an `ExecProgram` (the dump path), with its method
/// table in the VM's layout (from `vmethods_of`).
pub fn vprogram_of<'a>(e: &'a ExecProgram, methods: MTable<'a>, h: u16) -> (r: VProgram<'a>)
    requires
        methods@.len() == e.methods@.len(),
        forall|i: int| 0 <= i < e.methods@.len() ==> #[trigger] minfo(methods@[i], h) == e.methods@[i],
    ensures vview(&r) == pview2(e),
{
    let r = VProgram {
        word_bits: e.word_bits,
        max_height: h,
        bytecodes: e.bytecodes.as_slice(),
        methods,
        dispatch: e.dispatch.as_slice(),
        class_bits: e.class_bits.as_slice(),
        class_check_ids: e.class_check_ids.as_slice(),
        interface_check_offsets: e.interface_check_offsets.as_slice(),
        invoke_offsets: e.invoke_offsets.as_slice(),
        entry_points: e.entry_points.as_slice(),
        builtin: e.builtin.as_slice(),
        roots: e.roots.as_slice(),
        literals: e.literals.as_slice(),
        unchecked: false,
    };
    proof { assert(vview(&r).methods =~= pview2(e).methods); }
    r
}

/// The max height of an `ExecProgram`'s methods (all equal in format 2).
pub fn max_height_of(e: &ExecProgram) -> u16 {
    if e.methods.len() > 0 { e.methods[0].max_height } else { 0 }
}

} // verus!
