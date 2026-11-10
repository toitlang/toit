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

//! Arrays, verified: the plain-array fast paths of INVOKE_AT, INVOKE_AT_PUT
//! and INVOKE_SIZE (`spec::op_invoke_at`, `op_invoke_at_put`,
//! `op_invoke_size`, i.e. the `is_array` case of `spec_helpers::fast_at`
//! and `fast_size`). The heap model knows arrays (`abs::obj_model_ok`: the
//! array tag is exactly `Body::Array`, the length word is the length,
//! elements are encodable), and elements are read and written through the
//! model's accessors (`Heap::array_length`, `element`, `set_element`).
//!
//! The operands are values (the verifier's `value_operands`, `sel_ok`), so
//! a word with a clear low bit is a smi. The handler checks what the spec
//! checks: the index is a non-negative smi below the length, and a stored
//! array is not in the program heap. Every other receiver (lists, byte
//! arrays, slices, large arrays, copy-on-write byte arrays), an index out
//! of range, a store into the program heap and the virtual-call fallback
//! hand the whole instruction to `step_unverified` (before changing
//! anything).

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::halt::{lemma_value_operand, lemma_word_tag};
#[cfg(verus_keep_ghost)]
use crate::calls::handler_pre;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, cur_op};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, lemma_at_good, cur_k};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, value_operands, sel_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{smi, u16_at, is_array, elements, obj};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_helpers::{fast_at, fast_size, FastAt, FAST_AT_FUEL};

verus! {

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

/// `fast_at` of an array and an index in range: `array_at`.
proof fn lemma_fast_at_array(ap: Program2, g: State2, rv: Value, av: Value, n: int, is_put: bool, x: Value)
    requires
        is_array(as1(g), rv),
        av is Smi,
        av->Smi_0 as int == n,
        0 <= n < elements(as1(g), rv).len(),
    ensures
        fast_at(p1(ap), as1(g), rv, av, is_put, x, FAST_AT_FUEL)
            == toit_spec::spec_helpers::array_at(as1(g), rv, elements(as1(g), rv).len() as int, n, is_put, x),
        !is_put ==> toit_spec::spec_helpers::array_at(as1(g), rv, elements(as1(g), rv).len() as int, n, is_put, x)
            == FastAt::Get(elements(as1(g), rv)[n]),
        is_put && !obj(as1(g), rv).ro ==> toit_spec::spec_helpers::array_at(as1(g), rv, elements(as1(g), rv).len() as int, n, is_put, x)
            == FastAt::Put(toit_spec::spec_common::set_obj(as1(g), toit_spec::spec_common::obj_id(rv),
                HeapObj { body: Body::Array(elements(as1(g), rv).update(n, x)), ..obj(as1(g), rv) }), x),
{
    assert(!toit_spec::spec_common::is_instance(as1(g), rv));
    assert(!toit_spec::spec_common::is_bytes(as1(g), rv));
    reveal_with_fuel(fast_at, 1);
}

/// INVOKE_AT, INVOKE_AT_PUT, INVOKE_SIZE: the array fast paths.
#[inline(always)]
pub fn op_array(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        78 <= opcode <= 80,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    proof {
        lemma_step_at(p, m.g@);
        lemma_instr(p.ap@, p.cert@, p.trusted@, m.g@);
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

impl Machine {
    /// The value `v` (word `w`, a smi or an object) is an array: its id.
    #[inline(always)]
    pub fn array_id(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: bool)
        requires
            self.refines(p),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            v is Smi || v is Obj,
        ensures
            r == is_array(as1(self.g@), v),
            r ==> v is Obj && (v->Obj_0 as int) < self.g@.heap.len(),
    {
        proof { lemma_word_tag(self, p, w, v); }
        if w & 1 == 0 {
            return false;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr())); }
        self.heap.class_tag(w, Ghost(id)) == ARRAY_TAG
    }

    /// The index `a` (word `wa`, a smi or an object) of the array `v`
    /// (word `w`): a non-negative smi below the length.
    #[inline(always)]
    pub fn array_index(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>, wa: usize, Ghost(a): Ghost<Value>) -> (r: Option<usize>)
        requires
            self.refines(p),
            w == enc(self.addr(), v),
            v is Obj,
            (v->Obj_0 as int) < self.g@.heap.len(),
            is_array(as1(self.g@), v),
            wa == enc(self.addr(), a),
            encodable(self.addr(), a),
            a is Smi || a is Obj,
        ensures
            r is Some ==> a is Smi && a->Smi_0 as int == r->0 as int
                && r->0 < elements(as1(self.g@), v).len(),
            r is None ==> !(a is Smi) || a->Smi_0 < 0 || a->Smi_0 >= elements(as1(self.g@), v).len(),
    {
        proof { lemma_word_tag(self, p, wa, a); }
        if wa & 1 != 0 {
            return None;
        }
        let n = (wa as i64) >> 1u64;
        if n < 0 {
            return None;
        }
        let ghost id = v->Obj_0 as int;
        let length = self.heap.array_length(w, Ghost(id));
        if n as usize >= length {
            return None;
        }
        Some(n as usize)
    }

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
}

/// Replacing an object by one with the same `ro` keeps the constants.
proof fn lemma_prog_rel_update(p: &Program, objs: Seq<HeapObj>, a: Seq<usize>, id: int, o: HeapObj)
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

/// Element `n` of the array `v` is encodable.
proof fn lemma_element(p: &Program, m: &Machine, v: Value, n: int)
    requires
        m.refines(p),
        v is Obj,
        (v->Obj_0 as int) < m.g@.heap.len(),
        m.g@.heap[v->Obj_0 as int].body is Array,
        0 <= n < m.g@.heap[v->Obj_0 as int].body->Array_0.len(),
    ensures encodable(m.addr(), m.g@.heap[v->Obj_0 as int].body->Array_0[n]),
{
    assert(obj_model_ok(m.g@.heap[v->Obj_0 as int], m.heap.class_bits(), m.addr()));
}

/// INVOKE_AT (`spec::op_invoke_at`) on an array and an index in range.
#[inline(always)]
pub fn op_invoke_at(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        opcode == 78,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_at(env.p.ap@, old(m).g@),
        sp::has_slot(old(m).g@, 0), sp::at(old(m).g@, 0) is Smi || sp::at(old(m).g@, 0) is Obj,
        sp::has_slot(old(m).g@, 1), sp::at(old(m).g@, 1) is Smi || sp::at(old(m).g@, 1) is Obj,
        bci + 1 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost rv = sp::at(g, 1);
    let ghost av = sp::at(g, 0);
    proof {
        m.lemma_at(p, 0);
        m.lemma_at(p, 1);
    }
    let recv = m.at(1);
    let arg = m.at(0);
    if !m.array_id(p, recv, Ghost(rv)) {
        return step_unverified(m, env, bci, opcode);
    }
    let n = match m.array_index(p, recv, Ghost(rv), arg, Ghost(av)) {
        None => { return step_unverified(m, env, bci, opcode); },
        Some(n) => n,
    };
    let ghost id = rv->Obj_0 as int;
    let ghost x = g.heap[id].body->Array_0[n as int];
    proof { lemma_element(p, m, rv, n as int); }
    let w = m.heap.element(recv, n, Ghost(id));
    proof {
        lemma_fast_at_array(ap, g, rv, av, n as int, false, sp::null2(ap));
        assert(sp::op_invoke_at(ap, g) == sp::binary_result(g, x));
    }
    let r = m.binary_next(p, w, Ghost(x));
    proof { lemma_matches(p, m0, *m, r); }
    r
}

/// INVOKE_AT_PUT (`spec::op_invoke_at_put`) on an array outside the
/// program heap and an index in range: stores the value and leaves it.
#[inline(always)]
pub fn op_invoke_at_put(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        opcode == 79,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_at_put(env.p.ap@, old(m).g@),
        sp::has_slot(old(m).g@, 0), sp::at(old(m).g@, 0) is Smi || sp::at(old(m).g@, 0) is Obj,
        sp::has_slot(old(m).g@, 1), sp::at(old(m).g@, 1) is Smi || sp::at(old(m).g@, 1) is Obj,
        sp::has_slot(old(m).g@, 2), sp::at(old(m).g@, 2) is Smi || sp::at(old(m).g@, 2) is Obj,
        bci + 1 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
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
    if !m.array_id(p, recv, Ghost(rv)) {
        return step_unverified(m, env, bci, opcode);
    }
    let n = match m.array_index(p, recv, Ghost(rv), arg, Ghost(av)) {
        None => { return step_unverified(m, env, bci, opcode); },
        Some(n) => n,
    };
    let ghost id = rv->Obj_0 as int;
    if m.is_ro_word(p, recv, Ghost(id)) {
        return step_unverified(m, env, bci, opcode);
    }
    m.set_element_val(p, recv, Ghost(rv), n, value, Ghost(xv));
    let ghost m1 = *m;
    let ghost g1 = m.g@;
    proof {
        let o = obj(as1(g), rv);
        let s1 = toit_spec::spec_common::set_obj(as1(g), id,
            HeapObj { body: Body::Array(elements(as1(g), rv).update(n as int, xv)), ..o });
        lemma_fast_at_array(ap, g, rv, av, n as int, true, xv);
        assert(s1.heap == g1.heap);
        assert(sp::op_invoke_at_put(ap, g) == sp::next(sp::push(sp::drop(g1, 3), xv), 1));
        m.lemma_frame(p);
    }
    m.drop(2);
    m.put(0, value);
    m.bci = bci + 1;
    let ghost g2 = sp::goto(sp::push(sp::drop(g1, 3), xv), bci + 1);
    m.g = Ghost(g2);
    proof {
        let h = g.stack.len();
        assert forall|i: int| 0 <= i < h - 3 implies #[trigger] m.words()[i] == enc(m1.addr(), g2.stack[i]) by {
            assert(m.words()[i] == m1.words()[i]);
            assert(m1.words()[i] == enc_seq(m1.addr(), g1.stack)[i]);
        }
        assert(m.words() =~= enc_seq(m1.addr(), g2.stack));
        assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m1.addr(), g2.stack[i]) by {
            if i < h - 3 { assert(g2.stack[i] == g1.stack[i]); }
        }
        m1.lemma_local_step(p, m);
        lemma_matches(p, m0, *m, Ctl::Next);
    }
    Ctl::Next
}

/// INVOKE_SIZE (`spec::op_invoke_size`) on an array: its length.
#[inline(always)]
pub fn op_invoke_size(m: &mut Machine, env: &Env, bci: usize, opcode: u8, sel: usize) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        opcode == 80,
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_size(env.p.ap@, old(m).g@, sel as int),
        sp::has_slot(old(m).g@, 0), sp::at(old(m).g@, 0) is Smi || sp::at(old(m).g@, 0) is Obj,
        bci + 3 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost rv = sp::at(g, 0);
    proof { m.lemma_at(p, 0); }
    let recv = m.at(0);
    if !m.array_id(p, recv, Ghost(rv)) {
        return step_unverified(m, env, bci, opcode);
    }
    let ghost id = rv->Obj_0 as int;
    proof { assert(obj_model_ok(g.heap[id], m.heap.class_bits(), m.addr())); }
    let length = m.heap.array_length(recv, Ghost(id));
    proof {
        lemma_smi_word_nat(length as i64);
        assert(fast_size(p1(ap), as1(g), rv) == Some(length as int));
    }
    let w = smi_of(length as i64);
    m.put(0, w);
    m.bci = bci + 3;
    let ghost g1 = sp::goto(sp::put(g, 0, smi(length as int)), bci + 3);
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
}

} // verus!
