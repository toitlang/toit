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

//! Inline allocation on permissions: the fresh words `ffi::Runtime::bump`
//! hands out become a new object of the heap model (`Heap::append`).

use vstd::prelude::*;
use vstd::raw_ptr::*;
use crate::layout::*;
use crate::view::*;
use toit_spec::types::{HeapObj, Body, Value};

verus! {

/// The fresh memory at untagged address `a`, as a pointer with the
/// exposed provenance `prov` (the heap's).
pub open spec fn fresh_ptr_of(prov: Provenance, a: usize) -> *mut usize {
    ptr_mut_from_data::<usize>(PtrData::<usize> { addr: a, provenance: prov, metadata: () })
}

/// `perms` are the permissions of the `n` words at `a` (the keys `0..n`).
pub open spec fn fresh_perms(perms: Map<int, PointsTo<usize>>, prov: Provenance, a: usize, n: int) -> bool {
    forall|k: int| 0 <= k < n ==> #[trigger] perms.contains_key(k) && perms[k].ptr() == at_index(fresh_ptr_of(prov, a), k)
}

/// Word `j` of the 64-bit payload `b` (`value_word`).
#[cfg(target_pointer_width = "64")]
#[inline(always)]
pub fn value_word_x(b: u64, j: usize) -> (r: usize)
    requires j < VALUE_WORDS,
    ensures r == value_word(b, j as int),
{
    b as usize
}

#[cfg(target_pointer_width = "32")]
#[inline(always)]
pub fn value_word_x(b: u64, j: usize) -> (r: usize)
    requires j < VALUE_WORDS,
    ensures r == value_word(b, j as int),
{
    if j == 0 { (b & 0xffff_ffffu64) as usize } else { (b >> 32u64) as usize }
}

/// A value of the model stays encoded the same when an address is
/// appended.
pub proof fn lemma_enc_push(addrs: Seq<usize>, x: usize, v: Value)
    requires crate::abs::encodable(addrs, v),
    ensures crate::abs::enc(addrs.push(x), v) == crate::abs::enc(addrs, v),
{
    match v {
        Value::Obj(id) => { assert(addrs.push(x)[id as int] == addrs[id as int]); },
        _ => {},
    }
}

/// The words of an object stay as `word_val` says when an address is
/// appended.
pub proof fn lemma_word_val_push(o: HeapObj, cb: Seq<u16>, addrs: Seq<usize>, x: usize, k: int, v: usize)
    requires crate::abs::obj_model_ok(o, cb, addrs), word_val(o, cb, addrs, k, v), is_word(o, k),
    ensures word_val(o, cb, addrs.push(x), k, v),
{
    if k != 0 {
        match o.body {
            Body::Instance(f) => { lemma_enc_push(addrs, x, f[k - INSTANCE_FIELDS_WORD]); },
            Body::Array(e) => {
                if k != ARRAY_LENGTH_WORD { lemma_enc_push(addrs, x, e[k - ARRAY_ELEMENTS_WORD]); }
            },
            _ => {},
        }
    }
}

/// Appends the object `o` at the fresh words `a..` (untagged), whose
/// permissions `perms` hold its words: the heap invariant stays (a new
/// object id, its address `a + HEAP_TAG`, a content pointer that no view
/// reads: `o` is no blob).
pub proof fn append_mem(tracked m: &mut HeapMem, tracked perms: Map<int, PointsTo<usize>>, a: usize, o: HeapObj)
    requires
        heap_ok(*old(m)),
        crate::abs::heap_model_ok(old(m).objs, old(m).addrs, old(m).class_bits),
        fresh_perms(perms, old(m).exposed@, a, obj_words(o)),
        a + WORD_SIZE * obj_words(o) <= usize::MAX,
        forall|k: int| 0 <= k < obj_words(o) ==> #[trigger] perms[k].is_init()
            && word_val(o, old(m).class_bits, old(m).addrs.push((a + HEAP_TAG) as usize), k, perms[k].value()),
        forall|k: int| #[trigger] is_word(o, k) <==> 0 <= k < obj_words(o),
        !is_blob(o),
        (o.class_id as int) < old(m).class_bits.len(),
        (old(m).class_bits[o.class_id as int] & 0xf) as usize != BYTE_ARRAY_TAG,
    ensures
        heap_ok(*final(m)),
        final(m).objs == old(m).objs.push(o),
        final(m).addrs == old(m).addrs.push((a + HEAP_TAG) as usize),
        final(m).cptrs.len() == old(m).cptrs.len() + 1,
        final(m).cptrs.subrange(0, old(m).cptrs.len() as int) == old(m).cptrs,
        final(m).class_bits == old(m).class_bits,
        final(m).exposed == old(m).exposed,
{
    let ghost m0 = *m;
    let n = m0.objs.len() as int;
    let nw = obj_words(o);
    let r = (a + HEAP_TAG) as usize;
    let tracked mut ps = perms;
    move_words(&mut m.words, &mut ps, n, nw);
    m.objs = m0.objs.push(o);
    m.addrs = m0.addrs.push(r);
    m.cptrs = m0.cptrs.push(addr_ptr(m0, 0));
    assert(m.cptrs.subrange(0, m0.cptrs.len() as int) =~= m0.cptrs);
    assert forall|id: int| 0 <= id < m.objs.len() implies #[trigger] obj_fits(*m, id) by {
        if id < n {
            assert(obj_fits(m0, id));
            assert(m.objs[id] == m0.objs[id] && m.addrs[id] == m0.addrs[id]);
        }
    }
    assert forall|id: int, k: int| 0 <= id < m.objs.len() && is_word(m.objs[id], k) implies #[trigger] word_ok(*m, id, k) by {
        if id < n {
            assert(m.objs[id] == m0.objs[id] && m.addrs[id] == m0.addrs[id]);
            assert(word_ok(m0, id, k));
            assert(m.words.contains_key((id, k)) == m0.words.contains_key((id, k)));
            assert(m.words[(id, k)] == m0.words[(id, k)]);
            assert(obj_ptr(*m, id) == obj_ptr(m0, id));
            assert(crate::abs::obj_model_ok(m0.objs[id], m0.class_bits, m0.addrs));
            lemma_word_val_push(m0.objs[id], m0.class_bits, m0.addrs, r, k, m0.words[(id, k)].value());
        } else {
            assert(id == n);
            assert(is_word(o, k));
            assert(0 <= k < nw);
            assert(m.words.contains_key((n, k)));
            assert(m.words[(id, k)] == perms[k]);
            assert(obj_ptr(*m, id) == fresh_ptr_of(m0.exposed@, a));
            assert(perms.contains_key(k) && perms[k].ptr() == at_index(fresh_ptr_of(m0.exposed@, a), k));
            assert(m.words[(id, k)].ptr() == at_index(obj_ptr(*m, id), k));
            assert(perms[k].is_init());
            assert(m.objs[id] == o);
            assert(m.class_bits == m0.class_bits);
            assert(word_val(o, m0.class_bits, m0.addrs.push(r), k, perms[k].value()));
            assert(word_val(m.objs[id], m.class_bits, m.addrs, k, m.words[(id, k)].value()));
        }
        assert(word_ok(*m, id, k));
    }
    assert(m.objs.subrange(0, n) =~= m0.objs);
    assert(m.addrs.subrange(0, n) =~= m0.addrs);
    lemma_append_blobs(m0, *m, n);
}

/// Moves the permissions `ps[0..k)` to `words[(n, 0..k))`; the keys of
/// `words` with another first component stay.
pub proof fn move_words(tracked words: &mut Map<(int, int), PointsTo<usize>>, tracked ps: &mut Map<int, PointsTo<usize>>,
                    n: int, k: int)
    requires
        k >= 0,
        forall|j: int| 0 <= j < k ==> #[trigger] old(ps).contains_key(j),
    ensures
        forall|j: int| 0 <= j < k ==> #[trigger] final(words).contains_key((n, j)) && final(words)[(n, j)] == old(ps)[j],
        forall|key: (int, int)| key.0 != n || !(0 <= key.1 < k) ==>
            (#[trigger] final(words).contains_key(key) == old(words).contains_key(key))
            && final(words)[key] == old(words)[key],
    decreases k,
{
    if k > 0 {
        let ghost ps0 = *ps;
        let ghost w0 = *words;
        let tracked p = ps.tracked_remove(k - 1);
        words.tracked_insert((n, k - 1), p);
        assert forall|j: int| 0 <= j < k - 1 implies #[trigger] ps.contains_key(j) by {
            assert(ps0.contains_key(j));
        }
        let ghost w1 = *words;
        let ghost ps1 = *ps;
        move_words(words, ps, n, k - 1);
        assert forall|j: int| 0 <= j < k implies #[trigger] words.contains_key((n, j)) && words[(n, j)] == ps0[j] by {
            if j < k - 1 {
                assert(ps1[j] == ps0[j]);
            } else {
                assert(w1.contains_key((n, j)) && w1[(n, j)] == p);
            }
        }
    }
}

/// The blobs are unchanged by an appended object that is none.
pub proof fn lemma_append_blobs(m0: HeapMem, m1: HeapMem, n: int)
    requires
        blob_mem_ok(m0),
        n == m0.objs.len(),
        m1.objs.len() == n + 1, m1.addrs.len() == n + 1, m1.cptrs.len() == n + 1,
        m1.objs.subrange(0, n) == m0.objs, m1.addrs.subrange(0, n) == m0.addrs,
        m1.cptrs.subrange(0, n) == m0.cptrs,
        m1.halves == m0.halves, m1.bwords == m0.bwords, m1.bytes == m0.bytes,
        m1.exposed == m0.exposed, m1.class_bits == m0.class_bits,
        !is_blob(m1.objs[n]),
        (m1.objs[n].class_id as int) < m1.class_bits.len(),
        (m1.class_bits[m1.objs[n].class_id as int] & 0xf) as usize != BYTE_ARRAY_TAG,
    ensures blob_mem_ok(m1),
{
    assert forall|j: int| 0 <= j < n implies m1.objs[j] == m0.objs[j] && m1.addrs[j] == m0.addrs[j]
        && m1.cptrs[j] == m0.cptrs[j] by {
        assert(m1.objs.subrange(0, n)[j] == m0.objs[j]);
        assert(m1.addrs.subrange(0, n)[j] == m0.addrs[j]);
        assert(m1.cptrs.subrange(0, n)[j] == m0.cptrs[j]);
    }
    assert forall|j: int| 0 <= j < m1.objs.len() && m1.objs[j].body is Str implies #[trigger] str_ok(m1, j) by {
        assert(j < n);
        assert(m1.objs[j] == m0.objs[j]);
        assert(str_ok(m0, j));
        assert forall|i: int| 0 <= i < content(m1.objs[j]).len() implies #[trigger] byte_ok(m1, j, i) by {
            assert(byte_ok(m0, j, i));
        }
    }
    assert forall|j: int| 0 <= j < m1.objs.len() && (m1.objs[j].body is Bytes || is_ba_class(m1, j))
        implies #[trigger] ba_ok(m1, j) by {
        assert(j < n);
        assert(m1.objs[j] == m0.objs[j]);
        assert(is_ba_class(m0, j) == is_ba_class(m1, j));
        assert(ba_ok(m0, j));
        if m1.objs[j].body is Bytes {
            assert forall|i: int| 0 <= i < content(m1.objs[j]).len() implies #[trigger] byte_ok(m1, j, i) by {
                assert(byte_ok(m0, j, i));
            }
        }
    }
}


} // verus!
