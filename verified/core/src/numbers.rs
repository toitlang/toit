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

//! Numbers and identity on the heap model, verified: `spec_helpers::num_of`,
//! `compare_numbers` and `identical` of two operands (smis, doubles, large
//! integers, strings). The heap model's accessors read double bits, large
//! integer values and string bytes (`view::Heap`); numeric comparisons use the verified
//! `x_compare_mixed`. Double arithmetic uses the trusted `x_double_add`/`sub`/`mul` (host IEEE-754).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::State2;
use toit_spec::exec_step::XNum;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::as1;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{is_double, double_bits, is_large_int, large_int, is_string, str_bytes};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_helpers::{num_of, compare_numbers, compare_ints, compare_mixed, identical, Num, is_nan_bits};

verus! {

/// The class tag of an object's class, from the heap model.
pub open spec fn obj_tag(m: Machine, id: int) -> int {
    tag_bits(m.heap.class_bits(), m.g@.heap[id].class_id as int)
}

impl Machine {
    /// The class tag of the object `v` (word `w`); `None` for a smi.
    #[inline(always)]
    pub fn tag_of(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<usize>)
        requires
            self.hrefines(p),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            v is Smi || v is Obj,
        ensures
            r is None == (v is Smi),
            r is Some ==> v is Obj && (v->Obj_0 as int) < self.g@.heap.len()
                && r->0 as int == obj_tag(*self, v->Obj_0 as int)
                && obj_model_ok(self.g@.heap[v->Obj_0 as int], self.heap.class_bits(), self.addr()),
    {
        proof { crate::halt::lemma_word_tag(self, p, w, v); }
        if w & 1 == 0 {
            return None;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr())); }
        Some(self.heap.class_tag(w, Ghost(id)))
    }

    /// `spec_helpers::num_of`: a smi, a large integer or a double.
    #[inline(always)]
    pub fn num_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<XNum>)
        requires
            self.hrefines(p),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            v is Smi || v is Obj,
        ensures
            r is Some == num_of(as1(self.g@), v) is Some,
            r is Some ==> r->0@ == num_of(as1(self.g@), v)->0,
    {
        proof { crate::halt::lemma_word_tag(self, p, w, v); }
        match self.tag_of(p, w, Ghost(v)) {
            None => Some(XNum::Int(smi_value(w))),
            Some(tag) => {
                let ghost id = v->Obj_0 as int;
                if tag == LARGE_INTEGER_TAG {
                    Some(XNum::Int(self.heap.large_int(w, Ghost(id))))
                } else if tag == DOUBLE_TAG {
                    Some(XNum::Dbl(self.heap.double_bits(w, Ghost(id))))
                } else {
                    None
                }
            },
        }
    }

    /// `spec_helpers::is_double` of the operand `v` (word `w`), and then its
    /// bits.
    #[inline(always)]
    pub fn double_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<u64>)
        requires
            self.hrefines(p),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            v is Smi || v is Obj,
        ensures
            r is Some == is_double(as1(self.g@), v),
            r is Some ==> r->0 == double_bits(as1(self.g@), v),
    {
        match self.tag_of(p, w, Ghost(v)) {
            None => None,
            Some(tag) => {
                if tag == DOUBLE_TAG {
                    Some(self.heap.double_bits(w, Ghost(v->Obj_0 as int)))
                } else {
                    None
                }
            },
        }
    }

    /// `spec_helpers::compare_numbers` of two operands: 0 if one is not a
    /// number.
    #[inline(always)]
    pub fn compare_x(&self, p: &Program, w0: usize, Ghost(v0): Ghost<Value>, w1: usize, Ghost(v1): Ghost<Value>) -> (r: u8)
        requires
            self.hrefines(p),
            w0 == enc(self.addr(), v0), encodable(self.addr(), v0), v0 is Smi || v0 is Obj,
            w1 == enc(self.addr(), v1), encodable(self.addr(), v1), v1 is Smi || v1 is Obj,
        ensures r == compare_numbers(as1(self.g@), v0, v1),
    {
        let a = match self.num_x(p, w0, Ghost(v0)) { None => { return 0; }, Some(a) => a };
        let b = match self.num_x(p, w1, Ghost(v1)) { None => { return 0; }, Some(b) => b };
        match (a, b) {
            (XNum::Int(x), XNum::Int(y)) => {
                if x < y { 29 } else if x == y { 114 } else { 195 }
            },
            (a, b) => toit_spec::exec_step::x_compare_mixed(a, b),
        }
    }

    /// The bytes of the strings `id0` and `id1` are the same.
    #[inline(always)]
    pub fn same_string(&self, w0: usize, Ghost(id0): Ghost<int>, w1: usize, Ghost(id1): Ghost<int>) -> (r: bool)
        requires
            0 <= id0 < self.heap.objs().len(), 0 <= id1 < self.heap.objs().len(),
            self.heap.addrs().len() == self.heap.objs().len(),
            w0 == self.heap.addrs()[id0], w1 == self.heap.addrs()[id1],
            self.heap.objs()[id0].body is Str, self.heap.objs()[id1].body is Str,
        ensures r == (self.heap.objs()[id0].body->Str_0 == self.heap.objs()[id1].body->Str_0),
    {
        let ghost b0 = self.heap.objs()[id0].body->Str_0;
        let ghost b1 = self.heap.objs()[id1].body->Str_0;
        let n0 = self.heap.string_len(w0, Ghost(id0));
        let n1 = self.heap.string_len(w1, Ghost(id1));
        if n0 != n1 {
            return false;
        }
        let mut i: usize = 0;
        while i < n0
            invariant
                0 <= id0 < self.heap.objs().len(), 0 <= id1 < self.heap.objs().len(),
                self.heap.addrs().len() == self.heap.objs().len(),
                w0 == self.heap.addrs()[id0], w1 == self.heap.addrs()[id1],
                self.heap.objs()[id0].body is Str, self.heap.objs()[id1].body is Str,
                b0 == self.heap.objs()[id0].body->Str_0,
                b1 == self.heap.objs()[id1].body->Str_0,
                n0 == b0.len(), n0 == b1.len(),
                i <= n0,
                forall|j: int| 0 <= j < i ==> b0[j] == b1[j],
            decreases n0 - i,
        {
            if self.heap.string_byte(w0, i, Ghost(id0)) != self.heap.string_byte(w1, i, Ghost(id1)) {
                return false;
            }
            i = i + 1;
        }
        proof { assert(b0 =~= b1); }
        true
    }

    /// `spec_helpers::identical` of two operands with different words, not
    /// both smis.
    #[inline(always)]
    pub fn identical_slow(&self, p: &Program, w0: usize, Ghost(v0): Ghost<Value>, w1: usize, Ghost(v1): Ghost<Value>) -> (r: bool)
        requires
            self.hrefines(p),
            w0 == enc(self.addr(), v0), encodable(self.addr(), v0), v0 is Smi || v0 is Obj,
            w1 == enc(self.addr(), v1), encodable(self.addr(), v1), v1 is Smi || v1 is Obj,
            w0 != w1,
        ensures r == identical(as1(self.g@), v0, v1),
    {
        let ghost s = as1(self.g@);
        proof { assert(v0 != v1); }
        let t0 = match self.tag_of(p, w0, Ghost(v0)) { None => { return false; }, Some(t) => t };
        let t1 = match self.tag_of(p, w1, Ghost(v1)) { None => { return false; }, Some(t) => t };
        let ghost id0 = v0->Obj_0 as int;
        let ghost id1 = v1->Obj_0 as int;
        if t0 != t1 {
            return false;
        }
        if t0 == DOUBLE_TAG {
            return self.heap.double_bits(w0, Ghost(id0)) == self.heap.double_bits(w1, Ghost(id1));
        }
        if t0 == LARGE_INTEGER_TAG {
            return self.heap.large_int(w0, Ghost(id0)) == self.heap.large_int(w1, Ghost(id1));
        }
        if t0 == STRING_TAG {
            return self.same_string(w0, Ghost(id0), w1, Ghost(id1));
        }
        false
    }
}

/// `spec_helpers::is_nan_bits`.
#[inline(always)]
pub fn nan_bits(bits: u64) -> (r: bool)
    ensures r == is_nan_bits(bits),
{
    ((bits >> 52u64) & 0x7ffu64) == 0x7ffu64 && (bits & 0xf_ffff_ffff_ffffu64) != 0
}

} // verus!
