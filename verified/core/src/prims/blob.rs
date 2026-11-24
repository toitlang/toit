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

//! Byte arrays, strings and blobs (src/primitive_core.cc): byte_array_*
//! (not the external ones), string_length/at/raw_at/compare/hash_code/
//! slice/add, concat_strings, blob_equals/hash_code/index_of,
//! string_rune_count, string_write_to_byte_array, the JSON helpers.
//!
//! A blob argument (`Object::byte_content`) is a string, a byte array with
//! raw bytes, or a slice or copy-on-write wrapper of one, nested at most
//! `MAX_BYTE_CONTENT_DEPTH` instances deep; `blob_arg` follows the
//! wrappers iteratively and returns a view of the bytes (`Blob`: content,
//! start, length) whose bounds are proven. A mutable blob
//! (`Object::mutable_byte_content`) is the same for byte arrays outside the
//! program heap; an immutable copy-on-write wrapper (which C++ copies,
//! allocating) is not ported.
//!
//! Functional specifications: lengths, indexing and bounds of plain strings
//! and byte arrays; the rest is at the contract level.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::view::*;
use crate::prims::*;
use crate::prims::array::{array_arg, word_arg, int32_arg, is_ro};
#[cfg(verus_keep_ghost)]
use crate::prims::array::{lemma_element_good, lemma_field_good};
use crate::prims::index as ix;
use crate::prims::fp;
use toit_spec::types::{Value, HeapObj, Body};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::good;

verus! {

pub const MAX_BYTE_CONTENT_DEPTH: usize = 8;

/// Which byte contents an argument may have.
pub const STRINGS_ONLY: u8 = 0;
pub const STRINGS_OR_BYTE_ARRAYS: u8 = 1;
/// A mutable blob (writable byte arrays).
pub const MUTABLE: u8 = 2;

/// The bytes `c[start..start+len]`.
pub struct Blob {
    pub c: Content,
    pub start: usize,
    pub len: usize,
}

pub open spec fn blob_ok(h: &Heap, b: &Blob) -> bool {
    &&& content_ok(h, &b.c)
    &&& b.start + b.len <= b.c.slen()
    &&& b.c.slen() <= usize::MAX
}

/// The result of decoding a blob argument.
pub enum BlobArg {
    Ok(Blob),
    /// Not a blob: fail with this root.
    Fail(usize),
    /// A case C++ handles: an immutable copy-on-write receiver of a mutable
    /// blob, or a byte array the model treats as opaque (a mapped file or a
    /// resource proxy, TRUSTED.md V5).
    NotPorted,
}

/// The ids and class ids the blob decoding needs.
pub struct BlobClasses {
    pub cow: usize,
    pub ba_slice: usize,
    pub str_slice: usize,
    pub str_byte_slice: usize,
}

#[inline(always)]
pub fn blob_classes(p: &Program, h: &Heap) -> (r: BlobClasses)
    requires heap_inv(p, h),
{
    BlobClasses {
        cow: p.byte_array_cow_class_id,
        ba_slice: p.byte_array_slice_class_id,
        str_slice: builtin_class(p, h, BUILTIN_STRING_SLICE),
        str_byte_slice: builtin_class(p, h, BUILTIN_STRING_BYTE_SLICE),
    }
}

/// Applies the slice ranges `has/froms/tos[0..depth]`, innermost first,
/// to the bytes `base[0..base.len()]`.
fn apply_ranges(base: Content, froms: &[i64; 8], tos: &[i64; 8], has: &[bool; 8], depth: usize) -> (r: Option<Blob>)
    requires depth <= MAX_BYTE_CONTENT_DEPTH,
    ensures r is Some ==> r->Some_0.c == base && r->Some_0.start + r->Some_0.len <= base.slen()
        && base.slen() <= usize::MAX,
{
    let mut start: usize = 0;
    let mut len: usize = base.len();
    let mut d = depth;
    while d > 0
        invariant
            d <= depth, depth <= MAX_BYTE_CONTENT_DEPTH,
            froms@.len() == 8, tos@.len() == 8, has@.len() == 8,
            start + len <= base.slen(), base.slen() <= usize::MAX,
        decreases d,
    {
        d -= 1;
        // `d & 7` is `d`: the mask lets LLVM drop the bounds checks at
        // opt-levels s and z too (no panic path, vmverify's nopanic_check.sh).
        let i = d & 7;
        assert(i == d) by (bit_vector) requires i == d & 7, d < 8;
        if has[i] {
            let f = froms[i];
            let t = tos[i];
            if !(0 <= f && f <= t && (t as u64) <= (len as u64)) { return None; }
            start = start + f as usize;
            len = (t - f) as usize;
        }
    }
    Some(Blob { c: base, start, len })
}

/// `Object::byte_content` (`mode` STRINGS_ONLY or STRINGS_OR_BYTE_ARRAYS)
/// and `Object::mutable_byte_content` (`mode` MUTABLE).
pub fn blob_arg(h: &Heap, p: &Program, k: &BlobClasses, w: usize, Ghost(v): Ghost<Value>, mode: u8) -> (r: BlobArg)
    requires
        heap_inv(p, h), mode <= MUTABLE,
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r is Ok ==> blob_ok(h, &r->Ok_0) && (mode == MUTABLE ==> r->Ok_0.c.writable()),
        r is Fail ==> r->Fail_0 == ROOT_WRONG_OBJECT_TYPE || r->Fail_0 == ROOT_PERMISSION_DENIED,
        mode == STRINGS_ONLY ==> !(r is NotPorted),
        (mode != MUTABLE && v is Obj && h.objs()[v->Obj_0 as int].body is Str) ==> r is Ok
            && r->Ok_0.c.id() == v->Obj_0 as int && r->Ok_0.start == 0
            && r->Ok_0.len == content(h.objs()[v->Obj_0 as int]).len(),
{
    proof { lemma_word(h, w, v); }
    // A string (the common case).
    if mode != MUTABLE && w & 1 == 1 {
        let ghost id = v->Obj_0 as int;
        proof {
            assert(heap_model_ok(h.objs(), h.addrs(), h.class_bits()));
            assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
        }
        if h.class_tag(w, Ghost(id)) == STRING_TAG {
            let c = h.string_content(w, Ghost(id));
            let n = c.len();
            return BlobArg::Ok(Blob { c, start: 0, len: n });
        }
    }
    let mut cur = w;
    let ghost mut cv = v;
    let mut froms: [i64; 8] = [0i64; 8];
    let mut tos: [i64; 8] = [0i64; 8];
    let mut has: [bool; 8] = [false; 8];
    let mut depth: usize = 0;
    let ghost is_str = mode != MUTABLE && v is Obj && h.objs()[v->Obj_0 as int].body is Str;
    proof {
        if v is Obj {
            let id = v->Obj_0 as int;
            assert(heap_model_ok(h.objs(), h.addrs(), h.class_bits()));
            assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
        }
    }
    loop
        invariant
            !(mode != MUTABLE && v is Obj && h.objs()[v->Obj_0 as int].body is Str),
            heap_inv(p, h), mode <= MUTABLE, depth <= MAX_BYTE_CONTENT_DEPTH,
            cur == enc(h.addrs(), cv), good(h.objs(), cv), encodable(h.addrs(), cv),
            froms@.len() == 8, tos@.len() == 8, has@.len() == 8,
        decreases MAX_BYTE_CONTENT_DEPTH + 1 - depth,
    {
        proof { lemma_word(h, cur, cv); }
        if cur & 1 == 0 { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
        let ghost id = cv->Obj_0 as int;
        proof {
            assert(heap_model_ok(h.objs(), h.addrs(), h.class_bits()));
            assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
            assert(h.objs()[id].ro == in_ro(p, h.addrs()[id]));
        }
        if mode == MUTABLE && is_ro(p, cur) { return BlobArg::Fail(ROOT_PERMISSION_DENIED); }
        let tag = h.class_tag(cur, Ghost(id));
        if tag == STRING_TAG {
            if mode == MUTABLE { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
            let base = h.string_content(cur, Ghost(id));
            return match apply_ranges(base, &froms, &tos, &has, depth) {
                Some(b) => BlobArg::Ok(b),
                None => BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE),
            };
        }
        if tag == BYTE_ARRAY_TAG {
            if mode == STRINGS_ONLY { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
            // Only the model's byte arrays (V5); C++ handles the opaque ones
            // (mapped files, resource proxies).
            if h.bytes_len(cur, Ghost(id)).is_none() { return BlobArg::NotPorted; }
            let base = h.byte_array_content(cur, Ghost(id), mode == MUTABLE);
            return match apply_ranges(base, &froms, &tos, &has, depth) {
                Some(b) => BlobArg::Ok(b),
                None => BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE),
            };
        }
        if tag != INSTANCE_TAG || depth >= MAX_BYTE_CONTENT_DEPTH { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
        let cid = h.class_id(cur, Ghost(id));
        if cid >= p.class_bits.len() { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
        let fields = (((p.class_bits.at(cid) >> 5u16) & 0x7ffu16) as usize);
        let c = cid;
        if mode != STRINGS_ONLY && c == k.cow {
            if fields < 3 { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
            proof {
                assert(h.class_bits() == p.class_bits@) by { assert(prog_rel(p, h.objs(), h.addrs())); }
                lemma_field_good(p, h, id, 0);
                lemma_field_good(p, h, id, 1);
            }
            if mode == MUTABLE {
                // Only a mutable wrapper is followed; an immutable one is
                // copied by C++ (it allocates).
                let is_mutable = h.field(cur, 1, Ghost(id));
                if is_mutable != p.true_ { return BlobArg::NotPorted; }
            }
            let next = h.field(cur, 0, Ghost(id));
            proof { cv = h.objs()[id].body->Instance_0[0]; }
            has[depth] = false;
            cur = next;
        } else if (mode != STRINGS_ONLY && c == k.ba_slice) || c == k.str_slice || c == k.str_byte_slice {
            if mode == MUTABLE && c != k.ba_slice { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
            if fields < 4 { return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE); }
            proof {
                assert(h.class_bits() == p.class_bits@) by { assert(prog_rel(p, h.objs(), h.addrs())); }
                lemma_field_good(p, h, id, 0);
                lemma_field_good(p, h, id, 1);
                lemma_field_good(p, h, id, 2);
            }
            let wrapped = h.field(cur, 0, Ghost(id));
            let fw = h.field(cur, 1, Ghost(id));
            let tw = h.field(cur, 2, Ghost(id));
            proof {
                lemma_word(h, fw, h.objs()[id].body->Instance_0[1]);
                lemma_word(h, tw, h.objs()[id].body->Instance_0[2]);
            }
            if wrapped & 1 == 0 || fw & 1 != 0 || tw & 1 != 0 {
                return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE);
            }
            froms[depth] = smi_of_word(fw);
            tos[depth] = smi_of_word(tw);
            has[depth] = true;
            proof { cv = h.objs()[id].body->Instance_0[0]; }
            cur = wrapped;
        } else {
            return BlobArg::Fail(ROOT_WRONG_OBJECT_TYPE);
        }
        depth += 1;
    }
}

/// Byte `i` of a blob.
#[inline(always)]
pub fn blob_at(h: &Heap, b: &Blob, i: usize) -> (r: u8)
    requires blob_ok(h, b), i < b.len,
    ensures r == content(h.objs()[b.c.id()])[b.start + i],
{
    h.content_at(&b.c, b.start + i)
}

/// `String::compute_hash_code_for` of a blob.
pub fn hash_of(h: &Heap, b: &Blob, from: usize, n: usize) -> (r: u16)
    requires blob_ok(h, b), from + n <= b.len,
{
    let mut hash: u16 = (n & 0xffff) as u16;
    let mut i: usize = 0;
    while i < n
        invariant blob_ok(h, b), from + n <= b.len, i <= n,
        decreases n - i,
    {
        let c = blob_at(h, b, from + i);
        hash = (31u16.wrapping_mul(hash)).wrapping_add(c as u16);
        i += 1;
    }
    if hash != STRING_NO_HASH_CODE { hash } else { 0 }
}

/// The bytes of two blobs are equal (`memcmp`).
pub fn blob_eq(h: &Heap, a: &Blob, af: usize, b: &Blob, bf: usize, n: usize) -> (r: bool)
    requires blob_ok(h, a), blob_ok(h, b), af + n <= a.len, bf + n <= b.len,
{
    let mut i: usize = 0;
    while i < n
        invariant blob_ok(h, a), blob_ok(h, b), af + n <= a.len, bf + n <= b.len, i <= n,
        decreases n - i,
    {
        if blob_at(h, a, af + i) != blob_at(h, b, bf + i) { return false; }
        i += 1;
    }
    true
}

/// `String::compare` of two blobs: -1, 0 or 1.
pub fn blob_compare(h: &Heap, a: &Blob, b: &Blob) -> (r: i64)
    requires blob_ok(h, a), blob_ok(h, b),
    ensures -1 <= r <= 1,
{
    let n = if a.len < b.len { a.len } else { b.len };
    let mut i: usize = 0;
    while i < n
        invariant blob_ok(h, a), blob_ok(h, b), n <= a.len, n <= b.len, i <= n,
        decreases n - i,
    {
        let x = blob_at(h, a, i);
        let y = blob_at(h, b, i);
        if x < y { return -1; }
        if x > y { return 1; }
        i += 1;
    }
    if a.len == b.len { 0 } else if a.len < b.len { -1 } else { 1 }
}

// ---------------------------------------------------------------------------
// Helpers for results.

/// A new string of `n` bytes (uninitialized: the caller writes them).
pub fn new_string(heap: &mut Heap, c: &Ctx, n: usize) -> (r: Option<(usize, Ghost<int>)>)
    requires heap_inv(c.p, old(heap)),
    ensures
        r is None ==> *final(heap) == *old(heap),
        r is Some ==> ({
            let (w, id) = r->Some_0;
            &&& id@ == old(heap).objs().len()
            &&& heap_post(c.p, old(heap), final(heap))
            &&& final(heap).objs().len() == id@ + 1
            &&& final(heap).objs().subrange(0, id@) == old(heap).objs()
            &&& final(heap).addrs().subrange(0, id@) == old(heap).addrs()
            &&& final(heap).addrs().len() == id@ + 1
            &&& final(heap).cptrs().len() == id@ + 1
            &&& final(heap).cptrs().subrange(0, id@) == old(heap).cptrs()
            &&& w == final(heap).addrs()[id@]
            &&& final(heap).objs()[id@].body is Str
            &&& !final(heap).objs()[id@].ro
            &&& content(final(heap).objs()[id@]).len() == n
        }),
{
    if builtin_with_tag(c.p, heap, BUILTIN_STRING, STRING_TAG).is_none() { return None; }
    let ghost h0 = *heap;
    let w = c.al.string(heap, c.p, n);
    if w == 0 { return None; }
    proof {
        let id = h0.objs().len() as int;
        assert(heap.objs()[id] == heap.objs().last());
        lemma_post_append(c.p, &h0, heap, w);
    }
    Some((w, Ghost(h0.objs().len() as int)))
}

/// Content views stay valid when objects are appended.
pub proof fn lemma_blob_mono(h0: &Heap, h1: &Heap, b: &Blob)
    requires
        blob_ok(h0, b),
        h0.objs().len() <= h1.objs().len(),
        h1.objs().subrange(0, h0.objs().len() as int) == h0.objs(),
        h1.cptrs().len() == h1.objs().len(),
        h1.cptrs().subrange(0, h0.objs().len() as int) == h0.cptrs(),
    ensures blob_ok(h1, b), h1.objs()[b.c.id()] == h0.objs()[b.c.id()],
{
    assert(h1.objs().subrange(0, h0.objs().len() as int)[b.c.id()] == h0.objs()[b.c.id()]);
    assert(h1.cptrs().subrange(0, h0.objs().len() as int)[b.c.id()] == h0.cptrs()[b.c.id()]);
}

/// Content views of other objects stay valid when one object's bytes
/// change.
pub proof fn lemma_blob_update(h0: &Heap, h1: &Heap, b: &Blob, id: int, s: Seq<u8>)
    requires
        blob_ok(h0, b), 0 <= id < h0.objs().len(), is_blob(h0.objs()[id]),
        h1.objs() == h0.objs().update(id, with_content(h0.objs()[id], s)),
        b.c.id() != id || s.len() == content(h0.objs()[id]).len(),
        h1.cptrs() == h0.cptrs(),
    ensures blob_ok(h1, b),
{
}

/// Copies the blob `b[from..from+n]` into the fresh string `(w, id)` at
/// `at`.
fn copy_into(heap: &mut Heap, c: &Ctx, dst: &Content, at: usize, b: &Blob, from: usize, n: usize,
             Ghost(h0): Ghost<Heap>)
    requires
        heap_post(c.p, &h0, old(heap)),
        content_ok(old(heap), dst), dst.writable(),
        blob_ok(old(heap), b), from + n <= b.len, at + n <= dst.slen(),
    ensures
        heap_post(c.p, &h0, final(heap)),
        final(heap).objs().len() == old(heap).objs().len(),
        final(heap).addrs() == old(heap).addrs(),
        content_ok(final(heap), dst),
        forall|x: &Blob| #[trigger] blob_ok(old(heap), x) ==> blob_ok(final(heap), x),
        forall|j: int| 0 <= j < old(heap).objs().len() && j != dst.id() ==>
            #[trigger] final(heap).objs()[j] == old(heap).objs()[j],
{
    let ghost h1 = *heap;
    heap.content_copy(dst, at, &b.c, b.start + from, n);
    proof {
        let id = dst.id();
        let o = h1.objs()[id];
        let s = content(heap.objs()[id]);
        assert(heap.objs()[id] == with_content(o, s));
        assert(heap.objs() == h1.objs().update(id, with_content(o, s)));
        lemma_post_content(c.p, &h1, heap, id, s);
        lemma_post_trans(c.p, &h0, &h1, heap);
        assert forall|x: &Blob| #[trigger] blob_ok(&h1, x) implies blob_ok(heap, x) by {
            lemma_blob_update(&h1, heap, x, id, s);
        }
    }
}

// ---------------------------------------------------------------------------
// Byte arrays.

/// A decoded `ByteArray` argument.
pub enum ByteArg {
    /// A byte array of the model (`Body::Bytes`): its id.
    Bytes(Ghost<int>),
    /// Not a byte array: the primitive fails with WRONG_OBJECT_TYPE.
    Not,
    /// A byte array the model treats as opaque (TRUSTED.md V5: a mapped file
    /// or a resource proxy): C++ handles it (`NotPorted`).
    Opaque,
}

/// A `ByteArray` argument.
#[inline(always)]
pub fn byte_array_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: ByteArg)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r is Bytes == (v is Obj && h.objs()[v->Obj_0 as int].body is Bytes),
        r is Bytes ==> r->Bytes_0@ == v->Obj_0 as int && 0 <= r->Bytes_0@ < h.objs().len()
            && w == h.addrs()[r->Bytes_0@] && h.addrs().len() == h.objs().len(),
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 { return ByteArg::Not; }
    let ghost id = v->Obj_0 as int;
    proof {
        assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
    }
    if h.class_tag(w, Ghost(id)) != BYTE_ARRAY_TAG { return ByteArg::Not; }
    if h.bytes_len(w, Ghost(id)).is_none() { return ByteArg::Opaque; }
    ByteArg::Bytes(Ghost(id))
}

/// The outcome of a primitive C++ handles.
#[inline(always)]
pub fn not_ported() -> (r: (PrimOutcome, Ghost<Value>))
    ensures r.0 is NotPorted,
{
    (PrimOutcome::NotPorted, Ghost(Value::Smi(0)))
}

/// `byte_array_is_raw_bytes`, `byte_array_length`.
pub fn byte_array_info(length: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let w = a.w[0];
    let id = match byte_array_arg(heap, w, Ghost(a.vs@[0])) {
        ByteArg::Bytes(id) => id,
        ByteArg::Not => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
        ByteArg::Opaque => return not_ported(),
    };
    // A byte array of the model has raw bytes (internal, or external with
    // the raw-bytes tag: V5).
    if !length {
        return ok_bool(c.p, heap, true);
    }
    let ct = heap.byte_array_content(w, id, false);
    let n = ct.len();
    if n > MAX_SMI as usize { return not_ported(); }
    let (rw, rv) = smi_res(heap, n as i64);
    ok(c.p, heap, rw, rv)
}

/// `byte_array_at`.
pub fn byte_array_at(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> toit_spec::v2::prim_core::byte_array_at_contract(c.p.ap@, a.vs@, old(heap).objs(), final(heap).objs(),
            ret_of(c.p, r.0, r.1@)),
{
    let w = a.w[0];
    let id = match byte_array_arg(heap, w, Ghost(a.vs@[0])) {
        ByteArg::Bytes(id) => id,
        ByteArg::Not => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
        ByteArg::Opaque => return not_ported(),
    };
    let i = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(i) => i,
        Err(k) => return fail(c.p, heap, k),
    };
    let ct = heap.byte_array_content(w, id, false);
    if i < 0 || i as usize >= ct.len() { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    let b = heap.content_at(&ct, i as usize);
    let (rw, rv) = smi_res(heap, b as i64);
    ok(c.p, heap, rw, rv)
}

/// `byte_array_at_put`: stores the low byte of an integer.
pub fn byte_array_at_put(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 3,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> toit_spec::v2::prim_core::byte_array_at_put_contract(c.p.ap@, a.vs@, old(heap).objs(), final(heap).objs(),
            ret_of(c.p, r.0, r.1@)),
{
    let w = a.w[0];
    let id = match byte_array_arg(heap, w, Ghost(a.vs@[0])) {
        ByteArg::Bytes(id) => id,
        ByteArg::Not => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
        ByteArg::Opaque => return not_ported(),
    };
    let i = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(i) => i,
        Err(k) => return fail(c.p, heap, k),
    };
    let x = match ints::int_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if is_ro(c.p, w) { return fail(c.p, heap, ROOT_PERMISSION_DENIED); }
    proof { assert(heap.objs()[id@].ro == in_ro(c.p, heap.addrs()[id@])); }
    let ct = heap.byte_array_content(w, id, true);
    if i < 0 || i as usize >= ct.len() { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    let ghost h0 = *heap;
    let b = x as u8;
    heap.content_set(&ct, i as usize, b);
    proof {
        lemma_post_content(c.p, &h0, heap, id@, content(h0.objs()[id@]).update(i as int, b));
    }
    let (rw, rv) = smi_res(heap, b as i64);
    (PrimOutcome::Success(rw), rv)
}

/// `byte_array_new(length, filler)`.
pub fn byte_array_new(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let n = match int32_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Ok(n) => n,
        Err(k) => return fail(c.p, heap, k),
    };
    let filler = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(f) => f,
        Err(k) => return fail(c.p, heap, k),
    };
    if n < 0 { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    if builtin_with_tag(c.p, heap, BUILTIN_BYTE_ARRAY, BYTE_ARRAY_TAG).is_none() {
        return (PrimOutcome::NotPorted, Ghost(Value::Smi(0)));
    }
    let ghost h0 = *heap;
    let w = c.al.byte_array(heap, c.p, n as usize);
    if w == 0 {
        proof { lemma_post_refl(c.p, heap); }
        return (PrimOutcome::NeedsGc, Ghost(Value::Smi(0)));
    }
    let ghost id = h0.objs().len() as int;
    proof {
        assert(heap.objs()[id] == heap.objs().last());
        lemma_post_append(c.p, &h0, heap, w);
        assert(heap.addrs().len() == heap.objs().len()) by {
            assert(heap_model_ok(heap.objs(), heap.addrs(), heap.class_bits()));
        }
    }
    if filler != 0 {
        let ghost h1 = *heap;
        let ct = heap.byte_array_content(w, Ghost(id), true);
        heap.content_fill(&ct, 0, n as usize, filler as u8);
        proof {
            let s = content(heap.objs()[id]);
            assert(heap.objs() == h1.objs().update(id, with_content(h1.objs()[id], s)));
            lemma_post_content(c.p, &h1, heap, id, s);
            lemma_post_trans(c.p, &h0, &h1, heap);
        }
    }
    proof {
        assert(heap.addrs()[id] == w);
    }
    (PrimOutcome::Success(w), Ghost(Value::Obj(id as usize)))
}

/// `byte_array_replace(receiver, index, source, from, to)`: memmove into a
/// mutable blob.
pub fn byte_array_replace(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 5,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let p = c.p;
    let k = blob_classes(p, heap);
    let dst = match blob_arg(heap, p, &k, a.w[0], Ghost(a.vs@[0]), MUTABLE) {
        BlobArg::Ok(b) => b,
        BlobArg::Fail(e) => return fail(p, heap, e),
        BlobArg::NotPorted => return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    };
    let index = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(i) => i,
        Err(e) => return fail(p, heap, e),
    };
    let src = match blob_arg(heap, p, &k, a.w[2], Ghost(a.vs@[2]), STRINGS_OR_BYTE_ARRAYS) {
        BlobArg::Ok(b) => b,
        BlobArg::Fail(_) => return fail(p, heap, ROOT_WRONG_BYTES_TYPE),
        BlobArg::NotPorted => return not_ported(),
    };
    let from = match int32_arg(heap, a.w[3], Ghost(a.vs@[3])) {
        Ok(i) => i,
        Err(e) => return fail(p, heap, e),
    };
    let to = match int32_arg(heap, a.w[4], Ghost(a.vs@[4])) {
        Ok(i) => i,
        Err(e) => return fail(p, heap, e),
    };
    if index < 0 || from < 0 || to < 0 || to as usize > src.len { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    let length = to - from;
    if length < 0 || index as usize + length as usize > dst.len { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    let ghost h0 = *heap;
    let n = length as usize;
    heap.content_copy(&dst.c, dst.start + index as usize, &src.c, src.start + from as usize, n);
    proof {
        let id = dst.c.id();
        let s = content(heap.objs()[id]);
        assert(heap.objs() == h0.objs().update(id, with_content(h0.objs()[id], s)));
        lemma_post_content(p, &h0, heap, id, s);
    }
    let (rw, rv) = root(p, heap, ROOT_NULL);
    (PrimOutcome::Success(rw), rv)
}

// ---------------------------------------------------------------------------
// Strings.

/// A `String` argument: its id.
#[inline(always)]
pub fn string_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<Ghost<int>>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures
        r is Some == (v is Obj && h.objs()[v->Obj_0 as int].body is Str),
        r is Some ==> r->Some_0@ == v->Obj_0 as int && 0 <= r->Some_0@ < h.objs().len()
            && w == h.addrs()[r->Some_0@] && h.addrs().len() == h.objs().len(),
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 { return None; }
    let ghost id = v->Obj_0 as int;
    proof {
        assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
    }
    if h.class_tag(w, Ghost(id)) == STRING_TAG { Some(Ghost(id)) } else { None }
}

/// A blob argument as the `ARGS` macros decode it: failing with `err`.
#[inline(always)]
pub fn blob_or_fail(heap: &Heap, c: &Ctx, k: &BlobClasses, w: usize, Ghost(v): Ghost<Value>, mode: u8, err: usize)
    -> (r: Result<Blob, (PrimOutcome, Ghost<Value>)>)
    requires
        heap_inv(c.p, heap), mode < MUTABLE, err < ROOT_COUNT,
        w == enc(heap.addrs(), v), good(heap.objs(), v), encodable(heap.addrs(), v),
    ensures
        r is Ok ==> blob_ok(heap, &r->Ok_0),
        r is Err ==> prim_post(c.p, heap, heap, r->Err_0.0, r->Err_0.1@),
        (v is Obj && heap.objs()[v->Obj_0 as int].body is Str) ==> r is Ok
            && r->Ok_0.c.id() == v->Obj_0 as int && r->Ok_0.start == 0
            && r->Ok_0.len == content(heap.objs()[v->Obj_0 as int]).len(),
{
    match blob_arg(heap, c.p, k, w, Ghost(v), mode) {
        BlobArg::Ok(b) => Ok(b),
        BlobArg::Fail(_) => Err(fail(c.p, heap, err)),
        BlobArg::NotPorted => Err(not_ported()),
    }
}

/// `string_length`.
pub fn string_length(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> toit_spec::v2::prim_core::string_length_contract(c.p.ap@, a.vs@, old(heap).objs(),
            final(heap).objs(), ret_of(c.p, r.0, r.1@)),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_ONLY, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    if b.len > MAX_SMI as usize { return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))); }
    let (rw, rv) = smi_res(heap, b.len as i64);
    ok(c.p, heap, rw, rv)
}

/// `string_at` (decodes the UTF-8 sequence at the index; null inside a
/// sequence) and `string_raw_at` (the byte).
pub fn string_at(raw: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        ({
            let v = a.vs@[0];
            let i = a.vs@[1];
            (raw && r.0 is Success && v is Obj && old(heap).objs()[v->Obj_0 as int].body is Str) ==> i is Smi
                && r.1@ == Value::Smi(content(old(heap).objs()[v->Obj_0 as int])[i->Smi_0 as int] as i64)
        }),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_ONLY, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let i = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(i) => i,
        Err(e) => return fail(c.p, heap, e),
    };
    if i < 0 || i as usize >= b.len { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    let i = i as usize;
    let x = blob_at(heap, &b, i);
    if raw || x <= 0x7f {
        let (rw, rv) = smi_res(heap, x as i64);
        return ok(c.p, heap, rw, rv);
    }
    if x < 0xc0 {
        let (rw, rv) = root(c.p, heap, ROOT_NULL);
        return ok(c.p, heap, rw, rv);
    }
    // A prefix: the sequence has 2..4 bytes in a valid string.
    let n: usize = if x < 0xe0 { 2 } else if x < 0xf0 { 3 } else if x < 0xf8 { 4 } else { 0 };
    if n == 0 || i + n > b.len { return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))); }
    let mask: u8 = if n == 2 { 0x1f } else if n == 3 { 0x0f } else { 0x07 };
    let mut cp: i64 = (x & mask) as i64;
    proof { assert((x & mask) <= mask) by (bit_vector); }
    let mut j: usize = 1;
    while j < n
        invariant
            heap_inv(c.p, heap), blob_ok(heap, &b), i + n <= b.len, 1 <= j <= n, n <= 4,
            0 <= cp < (if j == 1 { 64i64 } else if j == 2 { 4096 } else if j == 3 { 262144 } else { 16777216 }),
        decreases n - j,
    {
        let y = blob_at(heap, &b, i + j);
        proof { assert((y & 0x3f) < 64) by (bit_vector); }
        cp = cp * 64 + (y & 0x3f) as i64;
        j += 1;
    }
    let (rw, rv) = smi_res(heap, cp);
    ok(c.p, heap, rw, rv)
}

/// `string_hash_code`: the cached hash, computed and cached if missing.
pub fn string_hash_code(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let w = a.w[0];
    let id = match string_arg(heap, w, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let cached = heap.string_hash_field(w, id);
    let hash = if cached != STRING_NO_HASH_CODE {
        cached
    } else {
        let ct = heap.string_content(w, id);
        let n = ct.len();
        let b = Blob { c: ct, start: 0, len: n };
        let hash = hash_of(heap, &b, 0, b.len);
        proof { assert(heap.objs()[id@].ro == in_ro(c.p, heap.addrs()[id@])); }
        if !is_ro(c.p, w) { heap.set_string_hash_field(w, id, hash); }
        hash
    };
    let (rw, rv) = smi_res(heap, hash as i64);
    ok(c.p, heap, rw, rv)
}

/// `blob_hash_code`.
pub fn blob_hash_code(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let hash = hash_of(heap, &b, 0, b.len);
    let (rw, rv) = smi_res(heap, hash as i64);
    ok(c.p, heap, rw, rv)
}

/// `blob_equals` (also of two strings: `String::equals` compares the
/// bytes after the hash codes, which only depend on the bytes).
pub fn blob_equals(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    if a.w[0] == a.w[1] {
        // `String::equals` of the same string; the same object is equal to
        // itself as a blob too, if it is one.
        let k = blob_classes(c.p, heap);
        return match blob_arg(heap, c.p, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS) {
            BlobArg::Ok(_) => ok_bool(c.p, heap, true),
            BlobArg::Fail(_) => fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
            BlobArg::NotPorted => not_ported(),
        };
    }
    let k = blob_classes(c.p, heap);
    let x = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let y = match blob_or_fail(heap, c, &k, a.w[1], Ghost(a.vs@[1]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    if x.len != y.len { return ok_bool(c.p, heap, false); }
    let eq = blob_eq(heap, &x, 0, &y, 0, x.len);
    ok_bool(c.p, heap, eq)
}

/// `string_compare`.
pub fn string_compare(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    if a.w[0] == a.w[1] {
        let (rw, rv) = smi_res(heap, 0);
        return ok(c.p, heap, rw, rv);
    }
    let k = blob_classes(c.p, heap);
    let x = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_ONLY, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let y = match blob_or_fail(heap, c, &k, a.w[1], Ghost(a.vs@[1]), STRINGS_ONLY, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let r = blob_compare(heap, &x, &y);
    let (rw, rv) = smi_res(heap, r);
    ok(c.p, heap, rw, rv)
}

/// `blob_index_of(bytes, byte, from, to)`: the first index of the low byte
/// of `byte` in `bytes[from..to]`, or -1.
pub fn blob_index_of(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 4,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let x = match int32_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Ok(x) => x,
        Err(e) => return fail(c.p, heap, e),
    };
    let from = match word_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let to = match word_arg(heap, a.w[3], Ghost(a.vs@[3])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if !(0 <= from && from <= to && to as usize <= b.len) { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    let needle = (x & 0xff) as u8;
    let mut i = from as usize;
    let end = to as usize;
    while i < end
        invariant heap_inv(c.p, heap), blob_ok(heap, &b), end <= b.len, i <= end, end <= MAX_SMI,
        decreases end - i,
    {
        if blob_at(heap, &b, i) == needle {
            let (rw, rv) = smi_res(heap, i as i64);
            return ok(c.p, heap, rw, rv);
        }
        i += 1;
    }
    let (rw, rv) = smi_res(heap, -1);
    ok(c.p, heap, rw, rv)
}

/// `string_rune_count`: the bytes that do not continue a UTF-8 sequence.
pub fn string_rune_count(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let mut n: usize = 0;
    let mut i: usize = 0;
    while i < b.len
        invariant blob_ok(heap, &b), i <= b.len, n <= i,
        decreases b.len - i,
    {
        if blob_at(heap, &b, i) & 0xc0 != 0x80 { n += 1; }
        i += 1;
    }
    if n > MAX_SMI as usize { return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))); }
    let (rw, rv) = smi_res(heap, n as i64);
    ok(c.p, heap, rw, rv)
}

/// `is_validated_string`: a string or a string slice (the only objects
/// known to hold valid UTF-8).
fn validated_string(heap: &Heap, p: &Program, k: &BlobClasses, w: usize, Ghost(v): Ghost<Value>) -> (r: bool)
    requires
        heap_inv(p, heap),
        w == enc(heap.addrs(), v), good(heap.objs(), v), encodable(heap.addrs(), v),
{
    proof { lemma_word(heap, w, v); }
    if w & 1 == 0 { return false; }
    let ghost id = v->Obj_0 as int;
    proof { assert(obj_model_ok(heap.objs()[id], heap.class_bits(), heap.addrs())); }
    if heap.class_tag(w, Ghost(id)) == STRING_TAG { return true; }
    heap.class_id(w, Ghost(id)) == k.str_slice
}

/// `string_add`.
pub fn string_add(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    if !validated_string(heap, c.p, &k, a.w[0], Ghost(a.vs@[0])) { return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE); }
    if !validated_string(heap, c.p, &k, a.w[1], Ghost(a.vs@[1])) { return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE); }
    let x = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_ONLY, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let y = match blob_or_fail(heap, c, &k, a.w[1], Ghost(a.vs@[1]), STRINGS_ONLY, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    if x.len > MAX_BLOB_LENGTH || y.len > MAX_BLOB_LENGTH {
        return (PrimOutcome::NotPorted, Ghost(Value::Smi(0)));
    }
    let n = x.len + y.len;
    let ghost h0 = *heap;
    let (w, id) = match new_string(heap, c, n) {
        Some(r) => r,
        None => {
            proof { lemma_post_refl(c.p, heap); }
            return (PrimOutcome::NeedsGc, Ghost(Value::Smi(0)));
        },
    };
    proof {
        lemma_blob_mono(&h0, heap, &x);
        lemma_blob_mono(&h0, heap, &y);
    }
    let dst = heap.string_content(w, id);
    copy_into(heap, c, &dst, 0, &x, 0, x.len, Ghost(h0));
    copy_into(heap, c, &dst, x.len, &y, 0, y.len, Ghost(h0));
    proof { lemma_new_res(&h0, heap, w, id@); }
    (PrimOutcome::Success(w), Ghost(Value::Obj(id@ as usize)))
}

/// The new object `id` is a result.
pub proof fn lemma_new_res(h0: &Heap, h: &Heap, w: usize, id: int)
    requires
        0 <= id < 0x4000_0000,
        id == h0.objs().len(), h.objs().len() == id + 1, h.addrs().len() == id + 1,
        w == h.addrs()[id],
    ensures res_ok(h, w, Value::Obj(id as usize)),
{
}

/// `string_slice(receiver, from, to)`: the receiver itself for the whole
/// string, else a new string; the bounds must not cut a UTF-8 sequence.
pub fn string_slice(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 3,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let w = a.w[0];
    let sid = match string_arg(heap, w, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let from = match word_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let to = match word_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let ct = heap.string_content(w, sid);
    let len = ct.len();
    if from == 0 && to >= 0 && to as usize == len {
        return ok(c.p, heap, w, Ghost(a.vs@[0]));
    }
    if from < 0 || to < 0 || to as usize > len || from > to { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    let s = Blob { c: ct, start: 0, len: len };
    let f = from as usize;
    let t = to as usize;
    if f != len && blob_at(heap, &s, f) & 0xc0 == 0x80 { return fail(c.p, heap, ROOT_ILLEGAL_UTF_8); }
    if t != f && t != len && blob_at(heap, &s, t) & 0xc0 == 0x80 { return fail(c.p, heap, ROOT_ILLEGAL_UTF_8); }
    let ghost h0 = *heap;
    let (nw, id) = match new_string(heap, c, t - f) {
        Some(r) => r,
        None => {
            proof { lemma_post_refl(c.p, heap); }
            return (PrimOutcome::NeedsGc, Ghost(Value::Smi(0)));
        },
    };
    proof { lemma_blob_mono(&h0, heap, &s); }
    let dst = heap.string_content(nw, id);
    copy_into(heap, c, &dst, 0, &s, f, t - f, Ghost(h0));
    proof { lemma_new_res(&h0, heap, nw, id@); }
    (PrimOutcome::Success(nw), Ghost(Value::Obj(id@ as usize)))
}

/// `concat_strings(array)`: the concatenation of an array of strings and
/// string slices.
pub fn concat_strings(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let p = c.p;
    let aw = a.w[0];
    let aid = match array_arg(heap, aw, Ghost(a.vs@[0])) {
        Some(id) => id,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    proof { assert(obj_model_ok(heap.objs()[aid@], heap.class_bits(), heap.addrs())); }
    let k = blob_classes(p, heap);
    let n = heap.array_length(aw, aid);
    // Check the elements and sum their lengths.
    let mut total: usize = 0;
    let mut i: usize = 0;
    while i < n
        invariant
            heap_inv(p, heap), p == c.p,
            0 <= aid@ < heap.objs().len(), heap.addrs().len() == heap.objs().len(),
            aw == heap.addrs()[aid@], heap.objs()[aid@].body is Array,
            heap.objs()[aid@].body->Array_0.len() == n, i <= n,
            total <= MAX_BLOB_LENGTH,
        decreases n - i,
    {
        proof { lemma_element_good(p, heap, aid@, i as int); }
        let e = heap.element(aw, i, aid);
        let ghost ev = heap.objs()[aid@].body->Array_0[i as int];
        if !validated_string(heap, p, &k, e, Ghost(ev)) { return fail(p, heap, ROOT_WRONG_OBJECT_TYPE); }
        let b = match blob_arg(heap, p, &k, e, Ghost(ev), STRINGS_ONLY) {
            BlobArg::Ok(b) => b,
            _ => return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
        };
        if b.len > MAX_BLOB_LENGTH - total { return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))); }
        total = total + b.len;
        i += 1;
    }
    let ghost h0 = *heap;
    let (w, id) = match new_string(heap, c, total) {
        Some(r) => r,
        None => {
            proof { lemma_post_refl(c.p, heap); }
            return (PrimOutcome::NeedsGc, Ghost(Value::Smi(0)));
        },
    };
    let dst = heap.string_content(w, id);
    proof {
        assert(heap.objs()[aid@] == h0.objs()[aid@]) by {
            assert(heap.objs().subrange(0, h0.objs().len() as int)[aid@] == h0.objs()[aid@]);
        }
        assert(heap.addrs()[aid@] == h0.addrs()[aid@]) by {
            assert(heap.addrs().subrange(0, h0.addrs().len() as int)[aid@] == h0.addrs()[aid@]);
        }
        assert(heap_inv(p, heap));
    }
    let mut pos: usize = 0;
    let mut i: usize = 0;
    while i < n
        invariant
            heap_post(p, &h0, heap), heap_inv(p, heap), p == c.p,
            h0 == *old(heap),
            0 <= aid@ < heap.objs().len(), heap.addrs().len() == heap.objs().len(),
            aw == heap.addrs()[aid@], heap.objs()[aid@].body is Array,
            heap.objs()[aid@].body->Array_0.len() == n, i <= n,
            id@ == h0.objs().len(), heap.objs().len() == id@ + 1, heap.addrs().len() == id@ + 1,
            w == heap.addrs()[id@],
            content_ok(heap, &dst), dst.writable(), dst.id() == id@, dst.slen() == total,
            pos <= total, aid@ < id@,
        decreases n - i,
    {
        proof { lemma_element_good(p, heap, aid@, i as int); }
        let e = heap.element(aw, i, aid);
        let ghost ev = heap.objs()[aid@].body->Array_0[i as int];
        // The elements were checked in the first pass and nothing ran in
        // between, so these failures cannot happen.
        let b = match blob_arg(heap, p, &k, e, Ghost(ev), STRINGS_ONLY) {
            BlobArg::Ok(b) => b,
            _ => return fail_post(p, Ghost(h0), heap, ROOT_WRONG_OBJECT_TYPE),
        };
        if b.len > total - pos { return fail_post(p, Ghost(h0), heap, ROOT_WRONG_OBJECT_TYPE); }
        let ghost h1 = *heap;
        copy_into(heap, c, &dst, pos, &b, 0, b.len, Ghost(h0));
        proof {
            assert(heap.objs()[aid@] == h1.objs()[aid@]);
        }
        pos = pos + b.len;
        i += 1;
    }
    proof { lemma_new_res(&h0, heap, w, id@); }
    (PrimOutcome::Success(w), Ghost(Value::Obj(id@ as usize)))
}

/// `string_write_to_byte_array(source, dest, from, to, dest_index)`.
pub fn string_write_to_byte_array(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 5,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let p = c.p;
    let k = blob_classes(p, heap);
    let src = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let dst = match blob_arg(heap, p, &k, a.w[1], Ghost(a.vs@[1]), MUTABLE) {
        BlobArg::Ok(b) => b,
        BlobArg::Fail(e) => return fail(p, heap, e),
        BlobArg::NotPorted => return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    };
    let from = match word_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Some(n) => n,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let to = match word_arg(heap, a.w[3], Ghost(a.vs@[3])) {
        Some(n) => n,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let di = match word_arg(heap, a.w[4], Ghost(a.vs@[4])) {
        Some(n) => n,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if to == from { return ok(p, heap, a.w[1], Ghost(a.vs@[1])); }
    if from < 0 || to < 0 || to as usize > src.len || from > to { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    let n = (to - from) as usize;
    if di < 0 || di as usize > dst.len || n > dst.len - di as usize { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    let ghost h0 = *heap;
    heap.content_copy(&dst.c, dst.start + di as usize, &src.c, src.start + from as usize, n);
    proof {
        let id = dst.c.id();
        let s = content(heap.objs()[id]);
        assert(heap.objs() == h0.objs().update(id, with_content(h0.objs()[id], s)));
        lemma_post_content(p, &h0, heap, id, s);
    }
    (PrimOutcome::Success(a.w[1]), Ghost(a.vs@[1]))
}

// ---------------------------------------------------------------------------
// JSON helpers (lib/encoding/json.toit).

/// `json_skip_whitespace(bytes, offset)`.
pub fn json_skip_whitespace(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let offset = match word_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if offset < 0 { return fail(c.p, heap, ROOT_INVALID_ARGUMENT); }
    let mut i = offset as usize;
    while i < b.len
        invariant heap_inv(c.p, heap), blob_ok(heap, &b),
        decreases b.len - i,
    {
        let x = blob_at(heap, &b, i);
        if x != 0x20 && x != 0x0a && x != 0x09 && x != 0x0d { break; }
        i += 1;
    }
    if i > MAX_SMI as usize { return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))); }
    let (rw, rv) = smi_res(heap, i as i64);
    ok(c.p, heap, rw, rv)
}

/// `hash_simple_json_string(bytes, offset)`: the hash of the string up to
/// the closing quote, -1 for an escape or no quote.
pub fn hash_simple_json_string(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let offset = match word_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if offset < 0 { return fail(c.p, heap, ROOT_INVALID_ARGUMENT); }
    let start = offset as usize;
    let mut i = start;
    while i < b.len
        invariant heap_inv(c.p, heap), blob_ok(heap, &b), start <= i,
        decreases b.len - i,
    {
        let x = blob_at(heap, &b, i);
        if x == 0x5c { break; }
        if x == 0x22 {
            let hash = hash_of(heap, &b, start, i - start);
            let (rw, rv) = smi_res(heap, hash as i64);
            return ok(c.p, heap, rw, rv);
        }
        i += 1;
    }
    let (rw, rv) = smi_res(heap, -1);
    ok(c.p, heap, rw, rv)
}

/// `compare_simple_json_string(bytes, offset, string)`: the bytes at
/// `offset` are the string followed by its closing quote.
pub fn compare_simple_json_string(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 3,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let offset = match word_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let s = match blob_or_fail(heap, c, &k, a.w[2], Ghost(a.vs@[2]), STRINGS_ONLY, ROOT_WRONG_OBJECT_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    if offset < 0 { return fail(c.p, heap, ROOT_INVALID_ARGUMENT); }
    // `string.length() >= bytes.length() - offset` (signed).
    let o = offset as usize;
    if o >= b.len || s.len >= b.len - o { return ok_bool(c.p, heap, false); }
    // The first quote at or after `offset` must be right after the string.
    let mut i = o;
    while i < b.len
        invariant blob_ok(heap, &b),
        decreases b.len - i,
    {
        if blob_at(heap, &b, i) == 0x22 { break; }
        i += 1;
    }
    if i != o + s.len { return ok_bool(c.p, heap, false); }
    let eq = blob_eq(heap, &s, 0, &b, o, s.len);
    ok_bool(c.p, heap, eq)
}

/// `size_of_json_number(bytes, offset)`: the length of the number at
/// `offset`, negated for a float.
pub fn size_of_json_number(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[0], Ghost(a.vs@[0]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let offset = match word_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(n) => n,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    // `offset >= bytes.length() - 1` (signed).
    if offset < 0 || b.len == 0 || offset as usize >= b.len - 1 { return fail(c.p, heap, ROOT_INVALID_ARGUMENT); }
    let mut i = offset as usize;
    let mut is_float = false;
    while i < b.len
        invariant blob_ok(heap, &b),
        decreases b.len - i,
    {
        let x = blob_at(heap, &b, i);
        let bit = (x & 0x1f) as u32;
        proof { assert((x & 0x1f) < 32) by (bit_vector); }
        if (0x3ff6820u32 >> bit) & 1 == 0 { break; }
        if x == 0x0d { break; }
        if (0x4020u32 >> bit) & 1 != 0 { is_float = true; }
        i += 1;
    }
    if i > MAX_SMI as usize { return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))); }
    let n = i as i64;
    let (rw, rv) = smi_res(heap, if is_float { -n } else { n });
    ok(c.p, heap, rw, rv)
}

// ---------------------------------------------------------------------------
// Byte order (lib/io/byte-order.toit; a failure runs the Toit fallback).

/// Writes `n` bytes of `value` to `b[offset..]`: least significant first
/// (`big == false`) or last; each next byte is the value shifted right
/// (arithmetically) by 8 more bits.
fn put_bytes(heap: &mut Heap, c: &Ctx, b: &Blob, offset: usize, n: usize, value: i64, big: bool,
             Ghost(h0): Ghost<Heap>)
    requires
        heap_post(c.p, &h0, old(heap)), blob_ok(old(heap), b), b.c.writable(),
        offset + n <= b.len, n <= 8,
    ensures heap_post(c.p, &h0, final(heap)),
{
    let mut v = value;
    let mut k: usize = 0;
    while k < n
        invariant
            heap_post(c.p, &h0, heap), blob_ok(heap, b), b.c.writable(),
            offset + n <= b.len, k <= n,
        decreases n - k,
    {
        let i = if big { n - 1 - k } else { k };
        let ghost h1 = *heap;
        heap.content_set(&b.c, b.start + offset + i, (v & 0xff) as u8);
        proof {
            let id = b.c.id();
            let s = content(h1.objs()[id]).update(b.start + offset + i, (v & 0xff) as u8);
            lemma_post_content(c.p, &h1, heap, id, s);
            lemma_post_trans(c.p, &h0, &h1, heap);
            lemma_blob_update(&h1, heap, b, id, s);
        }
        v = v >> 8u64;
        k += 1;
    }
}

/// `read_int/uint_big/little_endian(unused, source, width, offset)`.
pub fn read_endian(signed: bool, big: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 4,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let k = blob_classes(c.p, heap);
    let b = match blob_or_fail(heap, c, &k, a.w[1], Ghost(a.vs@[1]), STRINGS_OR_BYTE_ARRAYS, ROOT_WRONG_BYTES_TYPE) {
        Ok(b) => b,
        Err(r) => return r,
    };
    let width = match int32_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Ok(x) => x,
        Err(e) => return fail(c.p, heap, e),
    };
    let offset = match word_arg(heap, a.w[3], Ghost(a.vs@[3])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    // The C++ checks in unsigned arithmetic: a negative width or offset is
    // huge. The signed reads reject width 0 (width - 1 wraps).
    if offset < 0 || width < 0 || offset as usize > b.len { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    let o = offset as usize;
    let w = width as usize;
    if signed {
        if w == 0 || w - 1 >= 8 || o + (w - 1) >= b.len { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    } else {
        if w > 8 || o + w > b.len { return fail(c.p, heap, ROOT_OUT_OF_BOUNDS); }
    }
    let mut value: u64 = 0;
    let mut k: usize = 0;
    while k < w
        invariant heap_inv(c.p, heap), blob_ok(heap, &b), o + w <= b.len, k <= w, w <= 8,
        decreases w - k,
    {
        // The most significant byte first.
        let i = if big { k } else { w - 1 - k };
        let x = blob_at(heap, &b, o + i);
        if signed && k == 0 {
            // Sign-extend the most significant byte.
            value = if x >= 0x80 { (x as u64) | 0xffff_ffff_ffff_ff00u64 } else { x as u64 };
        } else {
            value = (value << 8u64) | (x as u64);
        }
        k += 1;
    }
    ints::int_res(heap, c, value as i64)
}

/// `put_uint_big/little_endian(unused, dest, width, offset, value)`.
pub fn put_endian(big: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 5,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let p = c.p;
    let k = blob_classes(p, heap);
    let dst = match blob_arg(heap, p, &k, a.w[1], Ghost(a.vs@[1]), MUTABLE) {
        BlobArg::Ok(b) => b,
        BlobArg::Fail(e) => return fail(p, heap, e),
        BlobArg::NotPorted => return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    };
    let width = match int32_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Ok(x) => x,
        Err(e) => return fail(p, heap, e),
    };
    let offset = match word_arg(heap, a.w[3], Ghost(a.vs@[3])) {
        Some(x) => x,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let value = match ints::int_arg(heap, a.w[4], Ghost(a.vs@[4])) {
        Some(x) => x,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if offset < 0 || width < 0 || offset as usize > dst.len { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    let o = offset as usize;
    let w = width as usize;
    if big {
        // Widths 0..8 (C++: `unsigned_width > 8`; until wave 10 both accepted 9).
        if w > 8 || o + w > dst.len { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    } else {
        if w == 0 || w - 1 >= 8 || o + (w - 1) >= dst.len { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    }
    let ghost h0 = *heap;
    proof { lemma_post_refl(p, heap); }
    put_bytes(heap, c, &dst, o, w, value, big, Ghost(h0));
    let (rw, rv) = root(p, heap, ROOT_NULL);
    (PrimOutcome::Success(rw), rv)
}

/// `put_float_64/32_little_endian(unused, dest, offset, value)`. The C++
/// rejects an exact fit at the end (`offset + 8 >= length`); the Toit
/// fallback then writes it.
pub fn put_float(f64: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 4,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let p = c.p;
    let k = blob_classes(p, heap);
    let dst = match blob_arg(heap, p, &k, a.w[1], Ghost(a.vs@[1]), MUTABLE) {
        BlobArg::Ok(b) => b,
        BlobArg::Fail(e) => return fail(p, heap, e),
        BlobArg::NotPorted => return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    };
    let offset = match word_arg(heap, a.w[2], Ghost(a.vs@[2])) {
        Some(x) => x,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let x = match crate::prims::float::double_arg(heap, a.w[3], Ghost(a.vs@[3])) {
        Some(x) => x,
        None => return fail(p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let n: usize = if f64 { 8 } else { 4 };
    if offset < 0 || offset as usize > dst.len || offset as usize + n >= dst.len { return fail(p, heap, ROOT_OUT_OF_BOUNDS); }
    let bits = if f64 { x } else { fp::to_raw32(x) as u64 };
    let ghost h0 = *heap;
    proof { lemma_post_refl(p, heap); }
    put_bytes(heap, c, &dst, offset as usize, n, bits as i64, false, Ghost(h0));
    let (rw, rv) = root(p, heap, ROOT_NULL);
    (PrimOutcome::Success(rw), rv)
}

/// `int_vector_equals(x, y)`: bit `i` set if byte `i` of the two 64-bit
/// integers is equal.
pub fn int_vector_equals(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let x = match ints::int_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let y = match ints::int_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(y) => y,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let mut z = (x ^ y) as u64;
    let mut bits: u64 = 0;
    let mut i: u64 = 0;
    while i < 8
        invariant i <= 8,
        decreases 8 - i,
    {
        if z & 0xff == 0 { bits = bits | (1u64 << i); }
        z = z >> 8u64;
        i += 1;
    }
    let result = bits & 0xff;
    proof { assert(bits & 0xff <= 255) by (bit_vector); }
    let (rw, rv) = smi_res(heap, result as i64);
    ok(c.p, heap, rw, rv)
}

/// `string_from_rune(rune)`: the UTF-8 encoding of a code point (no
/// surrogates).
pub fn string_from_rune(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let rune = match int32_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Ok(x) => x,
        Err(e) => return fail(c.p, heap, e),
    };
    if rune < 0 || rune > 0x10ffff || (0xd800 <= rune && rune <= 0xdfff) {
        return fail(c.p, heap, ROOT_INVALID_ARGUMENT);
    }
    let n: usize = if rune <= 0x7f { 1 } else if rune <= 0x7ff { 2 } else if rune <= 0xffff { 3 } else { 4 };
    let ghost h0 = *heap;
    let (w, id) = match new_string(heap, c, n) {
        Some(r) => r,
        None => {
            proof { lemma_post_refl(c.p, heap); }
            return (PrimOutcome::NeedsGc, Ghost(Value::Smi(0)));
        },
    };
    let dst = heap.string_content(w, id);
    let r = rune as u32;
    let mut k: usize = 0;
    while k < n
        invariant
            heap_post(c.p, &h0, heap), content_ok(heap, &dst), dst.writable(), dst.slen() == n,
            k <= n, n <= 4, dst.id() == id@,
            id@ == h0.objs().len(), heap.objs().len() == id@ + 1, heap.addrs().len() == id@ + 1,
            w == heap.addrs()[id@],
        decreases n - k,
    {
        // Byte k: the prefix (k == 0) or a continuation byte.
        let shift: u32 = 6 * ((n - 1 - k) as u32);
        let bits = (r >> shift) as u32;
        let byte: u8 = if k > 0 { (0x80 | (bits & 0x3f)) as u8 }
            else if n == 1 { (bits & 0x7f) as u8 }
            else if n == 2 { (0xc0 | (bits & 0x1f)) as u8 }
            else if n == 3 { (0xe0 | (bits & 0x0f)) as u8 }
            else { (0xf0 | (bits & 0x07)) as u8 };
        let ghost h1 = *heap;
        heap.content_set(&dst, k, byte);
        proof {
            let s = content(h1.objs()[id@]).update(k as int, byte);
            lemma_post_content(c.p, &h1, heap, id@, s);
            lemma_post_trans(c.p, &h0, &h1, heap);
        }
        k += 1;
    }
    proof { lemma_new_res(&h0, heap, w, id@); }
    (PrimOutcome::Success(w), Ghost(Value::Obj(id@ as usize)))
}

/// The blob family of the dispatch table.
#[inline(always)]
pub fn dispatch(i: usize, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)),
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@), contract(c.p, i as int, a, old(heap), final(heap), r.0, r.1@),
{
    let n = a.n;
    match i {
        ix::BYTE_ARRAY_IS_RAW_BYTES if n == 1 => byte_array_info(false, a, heap, c),
        ix::BYTE_ARRAY_LENGTH if n == 1 => byte_array_info(true, a, heap, c),
        ix::STRING_LENGTH if n == 1 => string_length(a, heap, c),
        ix::STRING_HASH_CODE if n == 1 => string_hash_code(a, heap, c),
        ix::BLOB_HASH_CODE if n == 1 => blob_hash_code(a, heap, c),
        ix::STRING_RUNE_COUNT if n == 1 => string_rune_count(a, heap, c),
        ix::CONCAT_STRINGS if n == 1 => concat_strings(a, heap, c),
        ix::BYTE_ARRAY_AT if n == 2 => byte_array_at(a, heap, c),
        ix::BYTE_ARRAY_NEW if n == 2 => byte_array_new(a, heap, c),
        ix::STRING_AT if n == 2 => string_at(false, a, heap, c),
        ix::STRING_RAW_AT if n == 2 => string_at(true, a, heap, c),
        ix::BLOB_EQUALS if n == 2 => blob_equals(a, heap, c),
        ix::STRING_COMPARE if n == 2 => string_compare(a, heap, c),
        ix::STRING_ADD if n == 2 => string_add(a, heap, c),
        ix::JSON_SKIP_WHITESPACE if n == 2 => json_skip_whitespace(a, heap, c),
        ix::HASH_SIMPLE_JSON_STRING if n == 2 => hash_simple_json_string(a, heap, c),
        ix::SIZE_OF_JSON_NUMBER if n == 2 => size_of_json_number(a, heap, c),
        ix::BYTE_ARRAY_AT_PUT if n == 3 => byte_array_at_put(a, heap, c),
        ix::STRING_SLICE if n == 3 => string_slice(a, heap, c),
        ix::COMPARE_SIMPLE_JSON_STRING if n == 3 => compare_simple_json_string(a, heap, c),
        ix::BLOB_INDEX_OF if n == 4 => blob_index_of(a, heap, c),
        ix::BYTE_ARRAY_REPLACE if n == 5 => byte_array_replace(a, heap, c),
        ix::STRING_WRITE_TO_BYTE_ARRAY if n == 5 => string_write_to_byte_array(a, heap, c),
        ix::READ_INT_BIG_ENDIAN if n == 4 => read_endian(true, true, a, heap, c),
        ix::READ_UINT_BIG_ENDIAN if n == 4 => read_endian(false, true, a, heap, c),
        ix::READ_INT_LITTLE_ENDIAN if n == 4 => read_endian(true, false, a, heap, c),
        ix::READ_UINT_LITTLE_ENDIAN if n == 4 => read_endian(false, false, a, heap, c),
        ix::PUT_UINT_BIG_ENDIAN if n == 5 => put_endian(true, a, heap, c),
        ix::PUT_UINT_LITTLE_ENDIAN if n == 5 => put_endian(false, a, heap, c),
        ix::PUT_FLOAT_64_LITTLE_ENDIAN if n == 4 => put_float(true, a, heap, c),
        ix::PUT_FLOAT_32_LITTLE_ENDIAN if n == 4 => put_float(false, a, heap, c),
        ix::INT_VECTOR_EQUALS if n == 2 => int_vector_equals(a, heap, c),
        ix::STRING_FROM_RUNE if n == 1 => string_from_rune(a, heap, c),
        _ => (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    }
}

} // verus!
