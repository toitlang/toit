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

//! Collections, verified: INVOKE_AT, INVOKE_AT_PUT and INVOKE_SIZE
//! (`spec::op_invoke_at`, `op_invoke_at_put`, `op_invoke_size`) on every
//! receiver `spec_helpers::fast_at` and `fast_size` handle: arrays, lists
//! (backed by an array or a large array), byte arrays, byte-array slices,
//! copy-on-write byte arrays and large arrays; anything else is the
//! verified virtual call of the operator's selector.
//!
//! `locate` follows `fast_at` and finds the element or byte the access
//! reads or writes (`Loc`), without changing anything; the handler then
//! reads it, or writes it through the model's accessors
//! (`Heap::set_element`, `set_byte_at`). The heap model knows arrays,
//! instances and byte arrays (`abs::obj_model_ok`, `Heap::bytes_len`), and
//! the fields and elements of a well-formed state are values
//! (`lemma_heap_good`), so a field word with a clear low bit is a smi.
//!
//! The operands are values (the verifier's `value_operands`, `sel_ok`).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::halt::{lemma_value_operand, lemma_word_tag};
#[cfg(verus_keep_ghost)]
use crate::calls::handler_pre;
use crate::calls::op_operator_fallback;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, cur_op, good, heap_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, lemma_at_good, cur_k};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, value_operands, sel_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{smi, u16_at, is_array, elements, obj, obj_id, is_instance, fields, is_bytes, bytes,
    class_of_obj, builtin, set_obj, false_v, LIST_CLASS, BYTE_ARRAY_SLICE_CLASS, LARGE_ARRAY_CLASS,
    BYTE_ARRAY_COW_CLASS, ARRAYLET_SIZE};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_helpers::{fast_at, fast_size, FastAt, FAST_AT_FUEL, array_at, bytes_at, cow_at, smi_val};

verus! {

// ---------------------------------------------------------------------------
// The heap's values.

/// The fields and elements of every object are values (smis or existing
/// objects).
pub open spec fn vals_good(heap: Seq<HeapObj>) -> bool {
    &&& forall|id: int, i: int| 0 <= id < heap.len() && heap[id].body is Instance
            && 0 <= i < heap[id].body->Instance_0.len() ==> #[trigger] good(heap, heap[id].body->Instance_0[i])
    &&& forall|id: int, i: int| 0 <= id < heap.len() && heap[id].body is Array
            && 0 <= i < heap[id].body->Array_0.len() ==> #[trigger] good(heap, heap[id].body->Array_0[i])
}

pub proof fn lemma_heap_good(p: &Program, g: State2)
    requires accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
    ensures vals_good(g.heap),
{
    reveal(wf);
    reveal(heap_ok);
    assert forall|id: int, i: int| 0 <= id < g.heap.len() && g.heap[id].body is Instance
            && 0 <= i < g.heap[id].body->Instance_0.len() implies #[trigger] good(g.heap, g.heap[id].body->Instance_0[i]) by {
        assert(toit_spec::v2::sound::obj_ok(p.ap@, p.cert@, g.heap, g.heap[id]));
    }
    assert forall|id: int, i: int| 0 <= id < g.heap.len() && g.heap[id].body is Array
            && 0 <= i < g.heap[id].body->Array_0.len() implies #[trigger] good(g.heap, g.heap[id].body->Array_0[i]) by {
        assert(toit_spec::v2::sound::obj_ok(p.ap@, p.cert@, g.heap, g.heap[id]));
    }
}

/// The step of INVOKE_AT, INVOKE_AT_PUT and INVOKE_SIZE, given that it is
/// not stuck, and their operands (values).
pub proof fn lemma_step_at(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        step_ok(p.ap@, p.cert@, g),
        78 <= cur_op(p.ap@, g) <= 80,
    ensures ({
        let ap = p.ap@;
        let op = cur_op(ap, g);
        &&& op == 78 ==> sp::step(ap, g) == sp::op_invoke_at(ap, g)
        &&& op == 79 ==> sp::step(ap, g) == sp::op_invoke_at_put(ap, g)
        &&& op == 80 ==> sp::step(ap, g) == sp::op_invoke_size(ap, g, u16_at(p1(ap), g.bci + 1))
        &&& sp::has_slot(g, 0) && (sp::at(g, 0) is Smi || sp::at(g, 0) is Obj)
        &&& op <= 79 ==> sp::has_slot(g, 1) && (sp::at(g, 1) is Smi || sp::at(g, 1) is Obj)
        &&& op == 79 ==> sp::has_slot(g, 2) && (sp::at(g, 2) is Smi || sp::at(g, 2) is Obj)
    }),
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let k = cur_k(ap, c, g);
    let op = cur_op(ap, g);
    if op == 78 {
        assert(value_operands(k, 2));
        lemma_value_operand(p, g, 2, 0);
        lemma_value_operand(p, g, 2, 1);
    } else if op == 79 {
        assert(value_operands(k, 3));
        lemma_value_operand(p, g, 3, 0);
        lemma_value_operand(p, g, 3, 1);
        lemma_value_operand(p, g, 3, 2);
    } else {
        assert(sel_ok(ap, c, u16_at(p1(ap), g.bci + 1), 1, k));
        lemma_at_good(ap, c, p.trusted@, g, 0);
    }
    assert(outcome_ok(ap, c, sp::step(ap, g)));
    reveal(sp::step);
}

/// INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE.
#[inline(always)]
pub fn op_array(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        78 <= opcode <= 80,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    proof {
        lemma_step_at(p, m.g@);
        lemma_instr(p.ap@, p.cert@, p.trusted@, m.g@);
        lemma_heap_good(p, m.g@);
        reveal_with_fuel(toit_spec::v2::bytecodes::opcode_length2, 1);
    }
    if opcode == 78 {
        op_invoke_at(m, env, bci, opcode)
    } else if opcode == 79 {
        op_invoke_at_put(m, env, bci, opcode)
    } else {
        let sel = code_u16(p, bci + 1);
        op_invoke_size(m, env, bci, opcode, sel)
    }
}

// ---------------------------------------------------------------------------
// Locations.

/// The element or byte an access reads or writes: element `i` of the array
/// `v` (word `w`), or byte `i` of the byte array `v`.
pub enum Loc {
    Fail,
    Elem(usize, Ghost<Value>, usize),
    Byte(usize, Ghost<Value>, usize),
}

/// The byte a put of `value` stores (`spec_helpers::bytes_at`).
pub open spec fn put_byte(value: Value) -> int {
    (value->Smi_0 as int) % 256
}

/// `r` is where the access with outcome `fa` happens: `Fail` when the
/// outcome is neither a read nor a write (a fallback or a stuck state,
/// which format 2 also turns into the fallback).
pub open spec fn loc_ok(m: Machine, r: Loc, fa: FastAt, is_put: bool, value: Value) -> bool {
    let s = as1(m.g@);
    let addr = m.addr();
    match r {
        Loc::Fail => !(fa is Get) && !(fa is Put),
        Loc::Elem(w, av, i) => {
            &&& is_array(s, av@)
            &&& w == enc(addr, av@)
            &&& i < elements(s, av@).len()
            &&& if is_put {
                &&& !obj(s, av@).ro
                &&& fa == FastAt::Put(set_obj(s, obj_id(av@),
                        HeapObj { body: Body::Array(elements(s, av@).update(i as int, value)), ..obj(s, av@) }), value)
            } else {
                fa == FastAt::Get(elements(s, av@)[i as int])
            }
        },
        Loc::Byte(w, bv, i) => {
            &&& is_bytes(s, bv@)
            &&& w == enc(addr, bv@)
            &&& i < bytes(s, bv@).len()
            &&& if is_put {
                &&& !obj(s, bv@).ro
                &&& value is Smi
                &&& fa == FastAt::Put(set_obj(s, obj_id(bv@),
                        HeapObj { body: Body::Bytes(bytes(s, bv@).update(i as int, put_byte(value) as u8)), ..obj(s, bv@) }),
                        smi(put_byte(value)))
            } else {
                fa == FastAt::Get(smi(bytes(s, bv@)[i as int] as int))
            }
        },
    }
}

/// What `locate` needs of the machine.
pub open spec fn loc_pre(p: &Program, m: Machine) -> bool {
    &&& m.refines(p)
    &&& vals_good(m.g@.heap)
}

/// A value of the heap model with its word.
pub open spec fn val_ok(m: Machine, w: usize, v: Value) -> bool {
    &&& w == enc(m.addr(), v)
    &&& good(m.g@.heap, v)
    &&& encodable(m.addr(), v)
}

pub proof fn lemma_val(p: &Program, m: Machine, w: usize, v: Value)
    requires m.refines(p), val_ok(m, w, v),
    ensures
        encodable(m.addr(), v),
        (w & 1 == 1) == (v is Obj),
        (w & 1 == 0) == !(v is Obj),
        (w & 1 != 0) == (v is Obj),
        v is Obj ==> (v->Obj_0 as int) < m.g@.heap.len(),
        v is Smi ==> w == smi_word(v->Smi_0) && smi_range(v->Smi_0 as int) && word_smi(w) == v->Smi_0,
{
    match v {
        Value::Smi(i) => {},
        _ => {},
    }
    lemma_word_tag(&m, p, w, v);
}

impl Machine {
    /// `is_instance` of the value `v` (word `w`): its field count and class.
    #[inline(always)]
    pub fn inst_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<(usize, i64)>)
        requires self.refines(p), vals_good(self.g@.heap), val_ok(*self, w, v),
        ensures
            r is Some == is_instance(as1(self.g@), v),
            r is Some ==> (r->0).0 == fields(as1(self.g@), v).len()
                && (r->0).1 == class_of_obj(as1(self.g@), v) && (r->0).0 < 0x800,
    {
        proof { lemma_val(p, *self, w, v); }
        if w & 1 == 0 {
            return None;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr())); }
        let tag = self.heap.class_tag(w, Ghost(id));
        if tag != INSTANCE_TAG && tag != TASK_TAG {
            return None;
        }
        let cid = self.heap.class_id(w, Ghost(id));
        let bits = p.class_bits.at(cid);
        let size = ((bits >> 5u16) & 0x7ffu16) as usize;
        proof {
            assert(size as int - 1 == ifc_bits(p.class_bits@, cid as int));
            assert(self.g@.heap[id].body->Instance_0.len() == size - 1);
            assert(fields(as1(self.g@), v) == self.g@.heap[id].body->Instance_0);
            assert(class_of_obj(as1(self.g@), v) == cid as int);
            assert(size <= 0x7ff) by (bit_vector) requires size == ((bits >> 5u16) & 0x7ffu16) as usize;
        }
        Some((size - 1, cid as i64))
    }

    /// Field `f` of the instance `v` (word `w`): its word and value.
    #[inline(always)]
    pub fn field_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>, f: usize) -> (r: (usize, Ghost<Value>))
        requires
            self.refines(p), vals_good(self.g@.heap), val_ok(*self, w, v),
            is_instance(as1(self.g@), v),
            f < fields(as1(self.g@), v).len(),
        ensures
            r.1@ == fields(as1(self.g@), v)[f as int],
            val_ok(*self, r.0, r.1@),
    {
        let ghost id = v->Obj_0 as int;
        proof {
            assert(good(self.g@.heap, self.g@.heap[id].body->Instance_0[f as int]));
            assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr()));
        }
        let x = self.heap.field(w, f, Ghost(id));
        (x, Ghost(fields(as1(self.g@), v)[f as int]))
    }

    /// `is_array` of the value `v` (word `w`): its length.
    #[inline(always)]
    pub fn array_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<usize>)
        requires self.refines(p), vals_good(self.g@.heap), val_ok(*self, w, v),
        ensures
            r is Some == is_array(as1(self.g@), v),
            r is Some ==> r->0 == elements(as1(self.g@), v).len() && r->0 < 0x4000_0000,
    {
        proof { lemma_val(p, *self, w, v); }
        if w & 1 == 0 {
            return None;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr())); }
        if self.heap.class_tag(w, Ghost(id)) != ARRAY_TAG {
            return None;
        }
        Some(self.heap.array_length(w, Ghost(id)))
    }

    /// `is_bytes` of the value `v` (word `w`): its length.
    #[inline(always)]
    pub fn bytes_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<usize>)
        requires self.refines(p), vals_good(self.g@.heap), val_ok(*self, w, v),
        ensures
            r is Some == is_bytes(as1(self.g@), v),
            r is Some ==> r->0 == bytes(as1(self.g@), v).len() && r->0 < MAX_BLOB_LENGTH,
    {
        proof { lemma_val(p, *self, w, v); }
        if w & 1 == 0 {
            return None;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr())); }
        if self.heap.class_tag(w, Ghost(id)) != BYTE_ARRAY_TAG {
            return None;
        }
        self.heap.bytes_len(w, Ghost(id))
    }

    /// The value `v` (word `w`) is a smi: its value.
    #[inline(always)]
    pub fn smi_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<i64>)
        requires self.refines(p), val_ok(*self, w, v),
        ensures
            r is Some == v is Smi,
            r is Some ==> r->0 == v->Smi_0 && smi_range(r->0 as int),
    {
        proof { lemma_val(p, *self, w, v); }
        if w & 1 != 0 {
            return None;
        }
        Some(smi_value(w))
    }

    /// `array_at(av, length, n)`.
    #[inline(always)]
    pub fn array_loc(&self, p: &Program, aw: usize, Ghost(av): Ghost<Value>, length: i64, n: usize,
        is_put: bool, Ghost(value): Ghost<Value>) -> (r: Loc)
        requires
            self.refines(p), vals_good(self.g@.heap), val_ok(*self, aw, av),
            is_array(as1(self.g@), av),
            n as int <= MAX_SMI,
        ensures loc_ok(*self, r, array_at(as1(self.g@), av, length as int, n as int, is_put, value), is_put, value),
    {
        proof { lemma_val(p, *self, aw, av); }
        let ghost id = av->Obj_0 as int;
        let el = self.heap.array_length(aw, Ghost(id));
        if n as i64 >= length || n >= el {
            return Loc::Fail;
        }
        if is_put && self.is_ro_word(p, aw, Ghost(id)) {
            return Loc::Fail;
        }
        Loc::Elem(aw, Ghost(av), n)
    }

    /// `bytes_at(bv, n)` of a byte array.
    #[inline(always)]
    pub fn bytes_loc(&self, p: &Program, bw: usize, Ghost(bv): Ghost<Value>, n: usize,
        is_put: bool, vw: usize, Ghost(value): Ghost<Value>) -> (r: Loc)
        requires
            self.refines(p), vals_good(self.g@.heap), val_ok(*self, bw, bv),
            is_bytes(as1(self.g@), bv),
            n as int <= MAX_SMI,
            is_put ==> val_ok(*self, vw, value),
        ensures loc_ok(*self, r, bytes_at(as1(self.g@), bv, n as int, is_put, value), is_put, value),
    {
        proof { lemma_val(p, *self, bw, bv); }
        let ghost id = bv->Obj_0 as int;
        proof { assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr())); }
        let len = match self.heap.bytes_len(bw, Ghost(id)) { Some(l) => l, None => { return Loc::Fail; } };
        if n >= len {
            return Loc::Fail;
        }
        if is_put {
            proof { lemma_val(p, *self, vw, value); }
            if vw & 1 != 0 || self.is_ro_word(p, bw, Ghost(id)) {
                return Loc::Fail;
            }
        }
        Loc::Byte(bw, Ghost(bv), n)
    }

    /// `cow_at(cv, n)` of a copy-on-write byte array (an instance).
    #[inline(always)]
    pub fn cow_loc(&self, p: &Program, cw: usize, Ghost(cv): Ghost<Value>, n: usize,
        is_put: bool, vw: usize, Ghost(value): Ghost<Value>) -> (r: Loc)
        requires
            self.refines(p), vals_good(self.g@.heap), val_ok(*self, cw, cv),
            is_instance(as1(self.g@), cv),
            n as int <= MAX_SMI,
            is_put ==> val_ok(*self, vw, value),
        ensures loc_ok(*self, r, cow_at(p1(p.ap@), as1(self.g@), cv, n as int, is_put, value), is_put, value),
    {
        let ghost s = as1(self.g@);
        let ghost ap = p.ap@;
        let (cnt, _) = match self.inst_x(p, cw, Ghost(cv)) { Some(x) => x, None => { return Loc::Fail; } };
        if cnt < 2 {
            return Loc::Fail;
        }
        if is_put {
            let (f1, Ghost(v1)) = self.field_x(p, cw, Ghost(cv), 1);
            proof {
                lemma_val(p, *self, f1, v1);
                assert(const_ok(self.g@.heap, ap.roots[2]));
                lemma_enc_inj(self.g@.heap, self.addr(), v1, ap.roots[2]);
                assert(false_v(p1(ap)) == ap.roots[2]);
            }
            if f1 == p.false_ {
                return Loc::Fail;
            }
        }
        let (f0, Ghost(v0)) = self.field_x(p, cw, Ghost(cv), 0);
        match self.bytes_x(p, f0, Ghost(v0)) {
            None => Loc::Fail,
            Some(_) => self.bytes_loc(p, f0, Ghost(v0), n, is_put, vw, Ghost(value)),
        }
    }

    /// `fast_at(rv, n, is_put, value, fuel)` (`spec_helpers::fast_at`).
    #[inline(always)]
    pub fn locate(&self, p: &Program, rw: usize, Ghost(rv): Ghost<Value>, n: usize,
        is_put: bool, vw: usize, Ghost(value): Ghost<Value>, fuel: usize) -> (r: Loc)
        requires
            self.refines(p), vals_good(self.g@.heap), val_ok(*self, rw, rv),
            n as int <= MAX_SMI,
            is_put ==> val_ok(*self, vw, value),
        ensures loc_ok(*self, r, fast_at(p1(p.ap@), as1(self.g@), rv, Value::Smi(n as i64), is_put, value, fuel as nat),
            is_put, value),
        decreases fuel, 1nat,
    {
        let ghost s = as1(self.g@);
        let ghost ap = p.ap@;
        let ghost fa = fast_at(p1(ap), s, rv, Value::Smi(n as i64), is_put, value, fuel as nat);
        proof {
            assert(p.list_class_id == builtin(p1(ap), LIST_CLASS));
            assert(p.byte_array_slice_class_id == builtin(p1(ap), BYTE_ARRAY_SLICE_CLASS));
            assert(p.large_array_class_id == builtin(p1(ap), LARGE_ARRAY_CLASS));
            assert(p.byte_array_cow_class_id == builtin(p1(ap), BYTE_ARRAY_COW_CLASS));
        }
        match self.inst_x(p, rw, Ghost(rv)) {
            Some((cnt, cid)) => {
                let is_list = cid == p.list_class_id;
                if is_list && cnt < 2 {
                    return Loc::Fail;
                }
                if is_list {
                    let (f0, Ghost(v0)) = self.field_x(p, rw, Ghost(rv), 0);
                    if let Some(alen) = self.array_x(p, f0, Ghost(v0)) {
                        let (f1, Ghost(v1)) = self.field_x(p, rw, Ghost(rv), 1);
                        return match self.smi_x(p, f1, Ghost(v1)) {
                            None => Loc::Fail,
                            Some(size) => {
                                if size > alen as i64 {
                                    Loc::Fail
                                } else {
                                    self.array_loc(p, f0, Ghost(v0), size, n, is_put, Ghost(value))
                                }
                            },
                        };
                    }
                }
                if cid == p.byte_array_slice_class_id {
                    if cnt < 3 {
                        return Loc::Fail;
                    }
                    let (f0, Ghost(v0)) = self.field_x(p, rw, Ghost(rv), 0);
                    let (f1, Ghost(v1)) = self.field_x(p, rw, Ghost(rv), 1);
                    let (f2, Ghost(v2)) = self.field_x(p, rw, Ghost(rv), 2);
                    let from = match self.smi_x(p, f1, Ghost(v1)) { Some(x) => x, None => { return Loc::Fail; } };
                    let to = match self.smi_x(p, f2, Ghost(v2)) { Some(x) => x, None => { return Loc::Fail; } };
                    let mm = from + n as i64;
                    if from < 0 || mm >= to {
                        return Loc::Fail;
                    }
                    if let Some(_) = self.bytes_x(p, f0, Ghost(v0)) {
                        return self.bytes_loc(p, f0, Ghost(v0), mm as usize, is_put, vw, Ghost(value));
                    }
                    if let Some((_, c0)) = self.inst_x(p, f0, Ghost(v0)) {
                        if c0 != p.byte_array_cow_class_id {
                            return Loc::Fail;
                        }
                        return self.cow_loc(p, f0, Ghost(v0), mm as usize, is_put, vw, Ghost(value));
                    }
                    return Loc::Fail;
                }
                if cid == p.large_array_class_id || is_list {
                    if cnt < 2 {
                        return Loc::Fail;
                    }
                    return self.large_loc(p, rw, Ghost(rv), cid == p.large_array_class_id, n, is_put, vw, Ghost(value), fuel);
                }
                if cid == p.byte_array_cow_class_id {
                    return self.cow_loc(p, rw, Ghost(rv), n, is_put, vw, Ghost(value));
                }
                Loc::Fail
            },
            None => {
                if let Some(_) = self.bytes_x(p, rw, Ghost(rv)) {
                    return self.bytes_loc(p, rw, Ghost(rv), n, is_put, vw, Ghost(value));
                }
                if let Some(len) = self.array_x(p, rw, Ghost(rv)) {
                    return self.array_loc(p, rw, Ghost(rv), len as i64, n, is_put, Ghost(value));
                }
                Loc::Fail
            },
        }
    }

    /// The large-array case of `fast_at`: a large array, or a list whose
    /// backing is not an array.
    pub fn large_loc(&self, p: &Program, rw: usize, Ghost(rv): Ghost<Value>, is_large: bool, n: usize,
        is_put: bool, vw: usize, Ghost(value): Ghost<Value>, fuel: usize) -> (r: Loc)
        requires
            self.refines(p), vals_good(self.g@.heap), val_ok(*self, rw, rv),
            n as int <= MAX_SMI,
            is_put ==> val_ok(*self, vw, value),
            is_instance(as1(self.g@), rv),
            fields(as1(self.g@), rv).len() >= 2,
            ({
                let s = as1(self.g@);
                let cid = class_of_obj(s, rv);
                let pp = p1(p.ap@);
                &&& is_large == (cid == builtin(pp, LARGE_ARRAY_CLASS))
                &&& cid == builtin(pp, LARGE_ARRAY_CLASS) || cid == builtin(pp, LIST_CLASS)
                &&& !(cid == builtin(pp, LIST_CLASS) && is_array(s, fields(s, rv)[0]))
                &&& cid != builtin(pp, BYTE_ARRAY_SLICE_CLASS)
            }),
        ensures loc_ok(*self, r, fast_at(p1(p.ap@), as1(self.g@), rv, Value::Smi(n as i64), is_put, value, fuel as nat),
            is_put, value),
        decreases fuel, 0nat,
    {
        let ghost s = as1(self.g@);
        let ghost ap = p.ap@;
        proof {
            assert(p.large_array_class_id == builtin(p1(ap), LARGE_ARRAY_CLASS));
        }
        let (f0, Ghost(v0)) = self.field_x(p, rw, Ghost(rv), 0);
        let (f1, Ghost(v1)) = self.field_x(p, rw, Ghost(rv), 1);
        let (la, size_obj) = if is_large { (rw, f0) } else { (f0, f1) };
        let ghost lav = if is_large { rv } else { v0 };
        let ghost sv = if is_large { v0 } else { v1 };
        let (lcnt, lcid) = match self.inst_x(p, la, Ghost(lav)) { Some(x) => x, None => { return Loc::Fail; } };
        if lcid != p.large_array_class_id {
            return Loc::Fail;
        }
        if lcnt < 2 {
            return Loc::Fail;
        }
        let (vector, Ghost(vv)) = self.field_x(p, la, Ghost(lav), 1);
        let size = match self.smi_x(p, size_obj, Ghost(sv)) { Some(x) => x, None => { return Loc::Fail; } };
        let vector_ok = match self.array_x(p, vector, Ghost(vv)) {
            Some(_) => true,
            None => match self.inst_x(p, vector, Ghost(vv)) {
                Some((vcnt, vcid)) => {
                    if vcid == p.large_array_class_id && vcnt >= 1 {
                        let (vs, Ghost(vsv)) = self.field_x(p, vector, Ghost(vv), 0);
                        match self.smi_x(p, vs, Ghost(vsv)) {
                            Some(x) => x < size,
                            None => false,
                        }
                    } else {
                        false
                    }
                },
                None => false,
            },
        };
        if n as i64 >= size || !vector_ok {
            return Loc::Fail;
        }
        if fuel == 0 {
            return Loc::Fail;
        }
        let ghost inner = fast_at(p1(ap), s, vv, smi(n as int / ARRAYLET_SIZE), false, value, (fuel - 1) as nat);
        proof { assert(Value::Smi((n / 500) as i64) == smi(n as int / ARRAYLET_SIZE)); }
        match self.locate(p, vector, Ghost(vv), n / 500, false, vw, Ghost(value), fuel - 1) {
            Loc::Elem(aw2, gav2, i2) => {
                let ghost av2 = gav2@;
                let ghost id2 = av2->Obj_0 as int;
                proof {
                    lemma_val(p, *self, aw2, av2);
                    assert(good(self.g@.heap, self.g@.heap[id2].body->Array_0[i2 as int]));
                    assert(obj_model_ok(self.g@.heap[id2], self.heap.class_bits(), self.addr()));
                }
                let arraylet = self.heap.element(aw2, i2, Ghost(id2));
                let ghost alv = elements(s, av2)[i2 as int];
                match self.array_x(p, arraylet, Ghost(alv)) {
                    None => Loc::Fail,
                    Some(_) => {
                        proof { assert(Value::Smi((n % 500) as i64) == smi(n as int % ARRAYLET_SIZE)); }
                        self.locate(p, arraylet, Ghost(alv), n % 500, is_put, vw, Ghost(value), fuel - 1)
                    },
                }
            },
            Loc::Byte(_, _, _) => Loc::Fail,
            Loc::Fail => Loc::Fail,
        }
    }
}

// ---------------------------------------------------------------------------
// Handlers.

impl Machine {
    /// Stores the value `x` (word `wx`) into element `n` of the array `v`
    /// (word `w`), not in the program heap: `set_obj` of `spec_helpers::array_at`.
    #[inline(always)]
    pub fn set_element_val(&mut self, p: &Program, w: usize, Ghost(v): Ghost<Value>, n: usize, wx: usize, Ghost(x): Ghost<Value>)
        requires
            old(self).refines(p),
            w == enc(old(self).addr(), v),
            v is Obj,
            (v->Obj_0 as int) < old(self).g@.heap.len(),
            old(self).g@.heap[v->Obj_0 as int].body is Array,
            n < old(self).g@.heap[v->Obj_0 as int].body->Array_0.len(),
            !old(self).g@.heap[v->Obj_0 as int].ro,
            wx == enc(old(self).addr(), x),
            encodable(old(self).addr(), x),
        ensures
            final(self).refines(p),
            final(self).g@ == (State2 {
                heap: old(self).g@.heap.update(v->Obj_0 as int, HeapObj {
                    body: Body::Array(old(self).g@.heap[v->Obj_0 as int].body->Array_0.update(n as int, x)),
                    ..old(self).g@.heap[v->Obj_0 as int]
                }),
                ..old(self).g@
            }),
            final(self).top == old(self).top,
            final(self).bci == old(self).bci,
            final(self).same_stack(old(self)),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost id = v->Obj_0 as int;
        self.heap.set_element(w, n, wx, Ghost(id), Ghost(x));
        let ghost g1 = State2 {
            heap: g0.heap.update(id, HeapObj {
                body: Body::Array(g0.heap[id].body->Array_0.update(n as int, x)),
                ..g0.heap[id]
            }),
            ..g0
        };
        self.g = Ghost(g1);
        proof {
            let objs = self.heap.objs();
            let cb = self.heap.class_bits();
            let a = self.addr();
            assert(objs == g1.heap);
            assert forall|i: int| 0 <= i < objs.len() implies #[trigger] obj_model_ok(objs[i], cb, a) by {
                assert(obj_model_ok(g0.heap[i], cb, a));
                if i == id {
                    let es = g0.heap[id].body->Array_0.update(n as int, x);
                    assert forall|j: int| 0 <= j < es.len() implies #[trigger] encodable(a, es[j]) by {
                        if j != n { assert(es[j] == g0.heap[id].body->Array_0[j]); }
                    }
                }
            }
            assert(heap_model_ok(objs, a, cb));
            assert forall|i: int| 0 <= i < g1.heap.len() implies #[trigger] g1.heap[i].ro == in_ro(p, a[i]) by {
                assert(g0.heap[i].ro == in_ro(p, a[i]));
            }
            lemma_prog_rel_update(p, g0.heap, a, id, g1.heap[id]);
            assert(g1.heap == g0.heap.update(id, g1.heap[id]));
            assert(self.refines(p));
        }
    }

    /// Stores the byte `b` into byte `n` of the byte array `v` (word `w`),
    /// not in the program heap.
    #[inline(always)]
    pub fn set_byte_val(&mut self, p: &Program, w: usize, Ghost(v): Ghost<Value>, n: usize, b: u8)
        requires
            old(self).refines(p),
            w == enc(old(self).addr(), v),
            v is Obj,
            (v->Obj_0 as int) < old(self).g@.heap.len(),
            old(self).g@.heap[v->Obj_0 as int].body is Bytes,
            n < old(self).g@.heap[v->Obj_0 as int].body->Bytes_0.len(),
            !old(self).g@.heap[v->Obj_0 as int].ro,
        ensures
            final(self).refines(p),
            final(self).g@ == (State2 {
                heap: old(self).g@.heap.update(v->Obj_0 as int, HeapObj {
                    body: Body::Bytes(old(self).g@.heap[v->Obj_0 as int].body->Bytes_0.update(n as int, b)),
                    ..old(self).g@.heap[v->Obj_0 as int]
                }),
                ..old(self).g@
            }),
            final(self).top == old(self).top,
            final(self).bci == old(self).bci,
            final(self).same_stack(old(self)),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        let ghost id = v->Obj_0 as int;
        self.heap.set_byte_at(w, n, b, Ghost(id));
        let ghost g1 = State2 {
            heap: g0.heap.update(id, HeapObj {
                body: Body::Bytes(g0.heap[id].body->Bytes_0.update(n as int, b)),
                ..g0.heap[id]
            }),
            ..g0
        };
        self.g = Ghost(g1);
        proof {
            let objs = self.heap.objs();
            let cb = self.heap.class_bits();
            let a = self.addr();
            assert(objs == g1.heap);
            assert forall|i: int| 0 <= i < objs.len() implies #[trigger] obj_model_ok(objs[i], cb, a) by {
                assert(obj_model_ok(g0.heap[i], cb, a));
            }
            assert(heap_model_ok(objs, a, cb));
            assert forall|i: int| 0 <= i < g1.heap.len() implies #[trigger] g1.heap[i].ro == in_ro(p, a[i]) by {
                assert(g0.heap[i].ro == in_ro(p, a[i]));
            }
            lemma_prog_rel_update(p, g0.heap, a, id, g1.heap[id]);
            assert(g1.heap == g0.heap.update(id, g1.heap[id]));
            assert(self.refines(p));
        }
    }

    /// Replaces the three operands of INVOKE_AT_PUT by the value `v` (word
    /// `w`) and continues after the instruction.
    #[inline(always)]
    pub fn put_result(&mut self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Ctl)
        requires
            old(self).refines(p),
            sp::has_slot(old(self).g@, 2),
            w == enc(old(self).addr(), v),
            encodable(old(self).addr(), v),
            old(self).bci + 1 < 0x1000_0000,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            final(self).g@ == sp::goto(sp::push(sp::drop(old(self).g@, 3), v), old(self).bci + 1),
    {
        let ghost m1 = *self;
        let ghost g1 = self.g@;
        proof { self.lemma_frame(p); self.lemma_at(p, 2); }
        self.drop(2);
        self.put(0, w);
        self.bci = self.bci + 1;
        let ghost g2 = sp::goto(sp::push(sp::drop(g1, 3), v), m1.bci + 1);
        self.g = Ghost(g2);
        proof {
            let h = g1.stack.len();
            assert forall|i: int| 0 <= i < h - 3 implies #[trigger] self.words()[i] == enc(m1.addr(), g2.stack[i]) by {
                assert(self.words()[i] == m1.words()[i]);
                assert(m1.words()[i] == enc_seq(m1.addr(), g1.stack)[i]);
            }
            assert(self.words() =~= enc_seq(m1.addr(), g2.stack));
            assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m1.addr(), g2.stack[i]) by {
                if i < h - 3 { assert(g2.stack[i] == g1.stack[i]); }
            }
            m1.lemma_local_step(p, self);
        }
        Ctl::Next
    }
}

/// Replacing an object by one with the same `ro` keeps the constants.
pub proof fn lemma_prog_rel_update(p: &Program, objs: Seq<HeapObj>, a: Seq<usize>, id: int, o: HeapObj)
    requires prog_rel(p, objs, a), 0 <= id < objs.len(), o.ro == objs[id].ro,
    ensures prog_rel(p, objs.update(id, o), a),
{
    let objs2 = objs.update(id, o);
    assert forall|i: int| 0 <= i < p.ap@.roots.len() implies
        #[trigger] p.roots@[i] == enc(a, p.ap@.roots[i]) && const_ok(objs2, p.ap@.roots[i]) by {
        assert(prog_rel(p, objs, a));
        assert(p.roots@[i] == enc(a, p.ap@.roots[i]));
        assert(const_ok(objs, p.ap@.roots[i]));
    }
    assert forall|i: int| 0 <= i < p.ap@.literals.len() implies
        #[trigger] p.literals@[i] == enc(a, p.ap@.literals[i]) && const_ok(objs2, p.ap@.literals[i]) by {
        assert(prog_rel(p, objs, a));
        assert(p.literals@[i] == enc(a, p.ap@.literals[i]));
        assert(const_ok(objs, p.ap@.literals[i]));
    }
}

/// The index operand `a` (word `wa`) of INVOKE_AT(_PUT): a non-negative
/// smi, else `fast_at` fails.
#[inline(always)]
pub fn index_x(m: &Machine, p: &Program, wa: usize, Ghost(a): Ghost<Value>) -> (r: Option<usize>)
    requires m.refines(p), wa == enc(m.addr(), a), encodable(m.addr(), a), a is Smi || a is Obj,
    ensures
        r is Some ==> a == Value::Smi(r->0 as i64) && r->0 as int <= MAX_SMI,
        r is None ==> !(a is Smi) || a->Smi_0 < 0,
{
    proof { lemma_word_tag(m, p, wa, a); }
    if wa & 1 != 0 {
        return None;
    }
    let n = smi_value(wa);
    if n < 0 {
        return None;
    }
    Some(n as usize)
}

/// INVOKE_AT (`spec::op_invoke_at`).
#[inline(always)]
pub fn op_invoke_at(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        opcode == 78,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_at(env.p.ap@, old(m).g@),
        sp::has_slot(old(m).g@, 0), sp::at(old(m).g@, 0) is Smi || sp::at(old(m).g@, 0) is Obj,
        sp::has_slot(old(m).g@, 1), sp::at(old(m).g@, 1) is Smi || sp::at(old(m).g@, 1) is Obj,
        vals_good(old(m).g@.heap),
        bci + 1 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost s = as1(g);
    let ghost m0 = *m;
    let ghost rv = sp::at(g, 1);
    let ghost av = sp::at(g, 0);
    proof {
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
        assert(const_ok(g.heap, ap.roots[0]));
    }
    let recv = m.at(1);
    let arg = m.at(0);
    if let Some(n) = index_x(m, p, arg, Ghost(av)) {
        let null = p.null;
        match m.locate(p, recv, Ghost(rv), n, false, null, Ghost(sp::null2(ap)), 8) {
            Loc::Elem(aw, garr, i) => {
                let ghost arr = garr@;
                let ghost id = arr->Obj_0 as int;
                let ghost x = elements(s, arr)[i as int];
                proof {
                    lemma_val(p, *m, aw, arr);
                    assert(obj_model_ok(g.heap[id], m.heap.class_bits(), m.addr()));
                }
                let w = m.heap.element(aw, i, Ghost(id));
                proof { assert(sp::op_invoke_at(ap, g) == sp::binary_result(g, x)); }
                let r = m.binary_next(p, w, Ghost(x));
                proof { lemma_matches(p, m0, *m, r); }
                return r;
            },
            Loc::Byte(bw, gba, i) => {
                let ghost ba = gba@;
                let ghost id = ba->Obj_0 as int;
                proof { lemma_val(p, *m, bw, ba); }
                let b = m.heap.byte_at(bw, i, Ghost(id));
                let ghost x = smi(b as int);
                proof {
                    lemma_smi_word_nat(b as i64);
                    assert(sp::op_invoke_at(ap, g) == sp::binary_result(g, x));
                }
                let w = smi_of(b as i64);
                let r = m.binary_next(p, w, Ghost(x));
                proof { lemma_matches(p, m0, *m, r); }
                return r;
            },
            Loc::Fail => {},
        }
    } else {
        proof { reveal_with_fuel(fast_at, 1); }
    }
    proof { assert(sp::op_invoke_at(ap, g) == sp::operator_fallback(ap, g, opcode)); }
    op_operator_fallback(m, env, bci, opcode)
}

/// INVOKE_AT_PUT (`spec::op_invoke_at_put`): stores the value and leaves it
/// (a byte array stores and leaves the value modulo 256).
#[inline(always)]
pub fn op_invoke_at_put(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        opcode == 79,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_at_put(env.p.ap@, old(m).g@),
        sp::has_slot(old(m).g@, 0), sp::at(old(m).g@, 0) is Smi || sp::at(old(m).g@, 0) is Obj,
        sp::has_slot(old(m).g@, 1), sp::at(old(m).g@, 1) is Smi || sp::at(old(m).g@, 1) is Obj,
        sp::has_slot(old(m).g@, 2), sp::at(old(m).g@, 2) is Smi || sp::at(old(m).g@, 2) is Obj,
        vals_good(old(m).g@.heap),
        bci + 1 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost s = as1(g);
    let ghost m0 = *m;
    let ghost rv = sp::at(g, 2);
    let ghost av = sp::at(g, 1);
    let ghost xv = sp::at(g, 0);
    proof {
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
        m.lemma_at(p, 2);
    }
    let recv = m.at(2);
    let arg = m.at(1);
    let value = m.at(0);
    if let Some(n) = index_x(m, p, arg, Ghost(av)) {
        match m.locate(p, recv, Ghost(rv), n, true, value, Ghost(xv), 8) {
            Loc::Elem(aw, garr, i) => {
                let ghost arr = garr@;
                proof { lemma_val(p, *m, aw, arr); }
                m.set_element_val(p, aw, Ghost(arr), i, value, Ghost(xv));
                proof {
                    let g1 = m.g@;
                    assert(sp::op_invoke_at_put(ap, g) == sp::next(sp::push(sp::drop(g1, 3), xv), 1));
                }
                let r = m.put_result(p, value, Ghost(xv));
                proof { lemma_matches(p, m0, *m, r); }
                return r;
            },
            Loc::Byte(bw, gba, i) => {
                let ghost ba = gba@;
                proof { lemma_val(p, *m, bw, ba); lemma_word_tag(m, p, value, xv); }
                let b = smi_value(value) as u8;
                proof {
                    let v = xv->Smi_0;
                    assert(b as int == (v as int) % 256) by (bit_vector)
                        requires b == ((v as i64) as u8);
                }
                m.set_byte_val(p, bw, Ghost(ba), i, b);
                let ghost x = smi(b as int);
                proof {
                    let g1 = m.g@;
                    lemma_smi_word_nat(b as i64);
                    assert(sp::op_invoke_at_put(ap, g) == sp::next(sp::push(sp::drop(g1, 3), x), 1));
                }
                let w = smi_of(b as i64);
                let r = m.put_result(p, w, Ghost(x));
                proof { lemma_matches(p, m0, *m, r); }
                return r;
            },
            Loc::Fail => {},
        }
    } else {
        proof { reveal_with_fuel(fast_at, 1); }
    }
    proof { assert(sp::op_invoke_at_put(ap, g) == sp::operator_fallback(ap, g, opcode)); }
    op_operator_fallback(m, env, bci, opcode)
}

/// INVOKE_SIZE (`spec::op_invoke_size`): `spec_helpers::fast_size`, else
/// the virtual getter.
#[inline(always)]
pub fn op_invoke_size(m: &mut Machine, env: &Env, bci: usize, opcode: u8, sel: usize) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        opcode == 80,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_size(env.p.ap@, old(m).g@, sel as int),
        sp::has_slot(old(m).g@, 0), sp::at(old(m).g@, 0) is Smi || sp::at(old(m).g@, 0) is Obj,
        vals_good(old(m).g@.heap),
        sel < 0x1_0000,
        bci + 3 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost rv = sp::at(g, 0);
    proof { m.lemma_at(p, 0); }
    let recv = m.at(0);
    match m.size_x(p, recv, Ghost(rv)) {
        Some(n) => {
            let ghost x = smi(n as int);
            proof {
                lemma_smi_word(n);
                assert(sp::op_invoke_size(ap, g, sel as int) == sp::next(sp::put(g, 0, x), 3));
            }
            let w = smi_of(n);
            m.put(0, w);
            m.bci = bci + 3;
            let ghost g1 = sp::goto(sp::put(g, 0, x), bci + 3);
            m.g = Ghost(g1);
            proof {
                assert(m.words() =~= enc_seq(m0.addr(), g1.stack));
                assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                    if i != g.stack.len() - 1 { assert(g1.stack[i] == g.stack[i]); }
                }
                m0.lemma_local_step(p, m);
                lemma_matches(p, m0, *m, Ctl::Next);
            }
            Ctl::Next
        },
        None => {
            proof { assert(sp::op_invoke_size(ap, g, sel as int) == sp::op_invoke_virtual_get(ap, g, sel as int)); }
            crate::fields::op_invoke_virtual_get(m, env, bci, opcode, sel)
        },
    }
}

impl Machine {
    /// `spec_helpers::fast_size` of the value `v` (word `w`).
    #[inline(always)]
    pub fn size_x(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<i64>)
        requires self.refines(p), vals_good(self.g@.heap), val_ok(*self, w, v),
        ensures
            r is Some == fast_size(p1(p.ap@), as1(self.g@), v) is Some,
            r is Some ==> r->0 as int == fast_size(p1(p.ap@), as1(self.g@), v)->0 && smi_range(r->0 as int),
    {
        let ghost s = as1(self.g@);
        let ghost ap = p.ap@;
        proof {
            assert(p.list_class_id == builtin(p1(ap), LIST_CLASS));
            assert(p.byte_array_slice_class_id == builtin(p1(ap), BYTE_ARRAY_SLICE_CLASS));
            assert(p.large_array_class_id == builtin(p1(ap), LARGE_ARRAY_CLASS));
            assert(p.byte_array_cow_class_id == builtin(p1(ap), BYTE_ARRAY_COW_CLASS));
        }
        match self.inst_x(p, w, Ghost(v)) {
            Some((cnt, cid)) => {
                if cid == p.list_class_id && cnt >= 2 {
                    let (f1, Ghost(v1)) = self.field_x(p, w, Ghost(v), 1);
                    self.smi_x(p, f1, Ghost(v1))
                } else if cid == p.byte_array_slice_class_id && cnt >= 3 {
                    let (f1, Ghost(v1)) = self.field_x(p, w, Ghost(v), 1);
                    let (f2, Ghost(v2)) = self.field_x(p, w, Ghost(v), 2);
                    match (self.smi_x(p, f1, Ghost(v1)), self.smi_x(p, f2, Ghost(v2))) {
                        (Some(from), Some(to)) => {
                            if 0 <= from && from <= to { Some(to - from) } else { None }
                        },
                        _ => None,
                    }
                } else if cid == p.large_array_class_id && cnt >= 1 {
                    let (f0, Ghost(v0)) = self.field_x(p, w, Ghost(v), 0);
                    self.smi_x(p, f0, Ghost(v0))
                } else if cid == p.byte_array_cow_class_id && cnt >= 1 {
                    let (f0, Ghost(v0)) = self.field_x(p, w, Ghost(v), 0);
                    match self.bytes_x(p, f0, Ghost(v0)) {
                        Some(len) => Some(len as i64),
                        None => None,
                    }
                } else {
                    None
                }
            },
            None => {
                if let Some(len) = self.bytes_x(p, w, Ghost(v)) {
                    return Some(len as i64);
                }
                if let Some(len) = self.array_x(p, w, Ghost(v)) {
                    return Some(len as i64);
                }
                None
            },
        }
    }
}

} // verus!
