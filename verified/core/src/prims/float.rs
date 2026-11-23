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

//! Float primitives (src/primitive_core.cc): arithmetic, comparisons,
//! sign/NaN/finite tests, sqrt/ceil/floor/trunc, the conversions
//! number_to_float, number_to_integer, float_to_raw(32), raw(32)_to_float,
//! and compare_to / min_special_compare_to (`Interpreter::compare_numbers`).
//!
//! Comparisons, sign, NaN and finiteness have exact binary64 contracts. Other float
//! operations use trusted scalar functions. The proofs cover argument decoding,
//! the allocation of the result and the heap contract. float_round,
//! float_to_string and float_parse stay in C++.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::view::*;
use crate::prims::*;
use crate::prims::index as ix;
use crate::prims::fp;
use toit_spec::types::{Value, HeapObj, Body};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::good;

verus! {

/// A `double` argument: its bits. Out of line, as `num_arg` and
/// `ints::int_arg`: one copy for every primitive that decodes one (size
/// diet).
#[inline(never)]
pub fn double_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<u64>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures r is Some <==> (v is Obj && h.objs()[v->Obj_0 as int].body is Double),
        r is Some ==> r->Some_0 == h.objs()[v->Obj_0 as int].body->Double_0,
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 { return None; }
    let ghost id = v->Obj_0 as int;
    proof {
        assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
    }
    if h.class_tag(w, Ghost(id)) == DOUBLE_TAG { Some(h.double_bits(w, Ghost(id))) } else { None }
}

/// A number (`compare_numbers`, `to_double`): (is an integer, its value
/// as i64 bits or its double bits).
#[inline(never)]
pub fn num_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<(bool, u64)>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures r == match toit_spec::v2::prim_core::int_val(h.objs(), v) {
        Some(i) => Some((true, i as u64)),
        None => match toit_spec::v2::prim_core::double_val(h.objs(), v) {
            Some(bits) => Some((false, bits)), None => None,
        },
    },
{
    match ints::int_arg(h, w, Ghost(v)) {
        Some(i) => Some((true, i as u64)),
        None => match double_arg(h, w, Ghost(v)) {
            Some(b) => Some((false, b)),
            None => None,
        },
    }
}

/// A new double with the given bits.
pub fn double_res(heap: &mut Heap, c: &Ctx, bits: u64) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)),
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> toit_spec::v2::prim_core::boxed_result(c.p.ap@, old(heap).objs(), final(heap).objs(),
            ret_of(c.p, r.0, r.1@), toit_spec::spec_common::DOUBLE_CLASS, Body::Double(bits)),
        !(r.0 is Failure),
        r.0 is Success ==> ({
            let v = r.1@;
            &&& v is Obj
            &&& final(heap).objs()[v->Obj_0 as int].body == Body::Double(bits)
        }),
{
    if builtin_with_tag(c.p, heap, BUILTIN_DOUBLE, DOUBLE_TAG).is_none() {
        return (PrimOutcome::NotPorted, Ghost(Value::Smi(0)));
    }
    let ghost h0 = *heap;
    let w = c.al.double(heap, c.p, bits);
    if w == 0 {
        proof { lemma_post_refl(c.p, heap); }
        return (PrimOutcome::NeedsGc, Ghost(Value::Smi(0)));
    }
    let ghost id = h0.objs().len() as int;
    proof {
        assert(heap.objs()[id] == heap.objs().last());
        assert(heap.objs() =~= h0.objs().push(heap.objs().last()));
        lemma_post_append(c.p, &h0, heap, w);
    }
    (PrimOutcome::Success(w), Ghost(Value::Obj(id as usize)))
}

/// float_add .. float_mod (`op` 0..4).
pub fn float_binop(op: u8, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let x = match double_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let y = match double_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(y) => y,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    double_res(heap, c, fp::binop(op, x, y))
}

/// float_unary_minus, float_sqrt, float_ceil, float_floor, float_trunc
/// (`op` 0..4).
pub fn float_unop(op: u8, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        op == 0 ==> contract(c.p, ix::FLOAT_UNARY_MINUS as int, a, old(heap), final(heap), r.0, r.1@),
        2 <= op <= 4 ==> contract(c.p, ix::FLOAT_CEIL as int + op as int - 2, a, old(heap), final(heap), r.0, r.1@),
{
    let x = match double_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let bits = if op == 0 { x ^ 0x8000_0000_0000_0000 } else if op == 1 { fp::libm_unop(op, x) }
        else { fp::round_integral(op, x) };
    let result = double_res(heap, c, bits);
    proof { if 2 <= op <= 4 { assert(toit_spec::v2::prim_core::integral_round_result(op, x, bits)); } }
    result
}

/// float_less_than .. float_equals (`op` 0..4).
pub fn float_compare(op: u8, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        toit_spec::v2::prim_core::float_cmp_contract(c.p.ap@, op, a.vs@, old(heap).objs(),
            final(heap).objs(), ret_of(c.p, r.0, r.1@)),
{
    let x = match double_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let y = match double_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(y) => y,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    ok_bool(c.p, heap, fp::compare(op, x, y))
}

/// float_sign (0), float_is_nan (1), float_is_finite (2), float_to_raw
/// (3), float_to_raw32 (4).
pub fn float_query(op: u8, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        op <= 2 ==> toit_spec::v2::prim_core::float_classify_contract(c.p.ap@,
            toit_spec::v2::prim_core::I_FLOAT_SIGN + op, a.vs@, old(heap).objs(), final(heap).objs(),
            ret_of(c.p, r.0, r.1@)),
        op == 3 ==> contract(c.p, ix::FLOAT_TO_RAW as int, a, old(heap), final(heap), r.0, r.1@),
        op == 4 ==> contract(c.p, ix::FLOAT_TO_RAW32 as int, a, old(heap), final(heap), r.0, r.1@),
        // float_to_raw: the bits as an integer.
        (op == 3 && r.0 is Success) ==> a.vs@[0] is Obj
            && old(heap).objs()[a.vs@[0]->Obj_0 as int].body is Double
            && toit_spec::v2::prim_core::int_val(final(heap).objs(), r.1@)
                == Some(old(heap).objs()[a.vs@[0]->Obj_0 as int].body->Double_0 as i64),
{
    let x = match double_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if op == 0 {
        let (rw, rv) = smi_res(heap, fp::sign(x));
        ok(c.p, heap, rw, rv)
    } else if op == 1 {
        ok_bool(c.p, heap, crate::numbers::nan_bits(x))
    } else if op == 2 {
        ok_bool(c.p, heap, fp::is_finite(x))
    } else if op == 3 {
        ints::int_res(heap, c, x as i64)
    } else {
        // `Primitive::integer`: a large integer on 32-bit targets when the
        // bits do not fit a smi.
        let raw = fp::to_raw32(x);
        let result = ints::int_res(heap, c, raw as i64);
        proof { assert(toit_spec::v2::prim_core::narrowing_result(x, raw)); }
        result
    }
}

/// number_to_float (`to_double`: an integer or a double).
pub fn number_to_float(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, ix::NUMBER_TO_FLOAT as int, a, old(heap), final(heap), r.0, r.1@),
{
    match num_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        None => fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
        Some((true, i)) => {
            proof {
                let value = toit_spec::v2::prim_core::int_val(heap.objs(), a.vs@[0])->Some_0;
                assert(i as i64 == value) by (bit_vector) requires i == value as u64;
            }
            double_res(heap, c, fp::from_int(i as i64))
        },
        Some((false, b)) => double_res(heap, c, b),
    }
}

/// number_to_integer: an integer as is, a double truncated.
pub fn number_to_integer(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, ix::NUMBER_TO_INTEGER as int, a, old(heap), final(heap), r.0, r.1@),
{
    if ints::int_arg(heap, a.w[0], Ghost(a.vs@[0])).is_some() {
        return ok(c.p, heap, a.w[0], Ghost(a.vs@[0]));
    }
    let x = match double_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    match fp::to_int(x) {
        None => fail(c.p, heap, ROOT_INVALID_ARGUMENT),
        Some(None) => fail(c.p, heap, ROOT_OUT_OF_RANGE),
        Some(Some(i)) => ints::int_res(heap, c, i),
    }
}

/// raw_to_float (`int64`) and raw32_to_float (fails OUT_OF_RANGE above 32
/// bits).
pub fn raw_to_float(raw32: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, if raw32 { ix::RAW32_TO_FLOAT as int } else { ix::RAW_TO_FLOAT as int },
            a, old(heap), final(heap), r.0, r.1@),
        (!raw32 && r.0 is Success) ==> ({
            let x = toit_spec::v2::prim_core::int_val(old(heap).objs(), a.vs@[0]);
            &&& x is Some && r.1@ is Obj
            &&& final(heap).objs()[r.1@->Obj_0 as int].body == Body::Double(x->Some_0 as u64)
        }),
{
    let x = match ints::int_arg(heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    if !raw32 { return double_res(heap, c, x as u64); }
    let u = x as u64;
    assert(((u >> 32) == 0) == (0 <= x && x <= 0xffff_ffff)) by (bit_vector) requires u == x as u64;
    if (u >> 32u64) != 0 { return fail(c.p, heap, ROOT_OUT_OF_RANGE); }
    let bits = fp::from_raw32(u as u32);
    let result = double_res(heap, c, bits);
    proof { assert(toit_spec::v2::prim_core::widening_result(x as u32, bits)); }
    result
}

/// compare_to (the result -1, 0, 1) and min_special_compare_to (the
/// LESS_FOR_MIN flag); INVALID_ARGUMENT unless both are numbers.
pub fn compare_to(min_special: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, if min_special { ix::MIN_SPECIAL_COMPARE_TO as int } else { ix::COMPARE_TO as int },
            a, old(heap), final(heap), r.0, r.1@),
{
    let x = num_arg(heap, a.w[0], Ghost(a.vs@[0]));
    let y = num_arg(heap, a.w[1], Ghost(a.vs@[1]));
    let (xi, xb, yi, yb) = match (x, y) {
        (Some((xi, xb)), Some((yi, yb))) => (xi, xb, yi, yb),
        _ => return fail(c.p, heap, ROOT_INVALID_ARGUMENT),
    };
    let result = fp::compare_numbers(xi, xb, yi, yb);
    proof {
        use toit_spec::spec_helpers::Num;
        use toit_spec::v2::prim_core::{int_val, numeric_arg};
        if xi {
            let i = int_val(heap.objs(), a.vs@[0])->Some_0;
            assert(i as u64 as i64 == i) by (bit_vector);
        }
        if yi {
            let i = int_val(heap.objs(), a.vs@[1])->Some_0;
            assert(i as u64 as i64 == i) by (bit_vector);
        }
        assert(numeric_arg(heap.objs(), a.vs@[0]) ==
            Some(if xi { Num::Int(xb as i64 as int) } else { Num::Dbl(xb) }));
        assert(numeric_arg(heap.objs(), a.vs@[1]) ==
            Some(if yi { Num::Int(yb as i64 as int) } else { Num::Dbl(yb) }));
    }
    if min_special {
        ok_bool(c.p, heap, result & 4 != 0)
    } else {
        let v = (result & 3) as i64 - 2;
        proof { assert((result & 3) <= 3) by (bit_vector); }
        let (rw, rv) = smi_res(heap, v);
        ok(c.p, heap, rw, rv)
    }
}

/// The float family of the dispatch table.
#[inline(always)]
pub fn dispatch(i: usize, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)),
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@), contract(c.p, i as int, a, old(heap), final(heap), r.0, r.1@),
{
    let n = a.n;
    match i {
        ix::FLOAT_UNARY_MINUS if n == 1 => float_unop(0, a, heap, c),
        ix::FLOAT_SQRT if n == 1 => float_unop(1, a, heap, c),
        ix::FLOAT_CEIL if n == 1 => float_unop(2, a, heap, c),
        ix::FLOAT_FLOOR if n == 1 => float_unop(3, a, heap, c),
        ix::FLOAT_TRUNC if n == 1 => float_unop(4, a, heap, c),
        ix::FLOAT_SIGN if n == 1 => float_query(0, a, heap, c),
        ix::FLOAT_IS_NAN if n == 1 => float_query(1, a, heap, c),
        ix::FLOAT_IS_FINITE if n == 1 => float_query(2, a, heap, c),
        ix::FLOAT_TO_RAW if n == 1 => float_query(3, a, heap, c),
        ix::FLOAT_TO_RAW32 if n == 1 => float_query(4, a, heap, c),
        ix::NUMBER_TO_FLOAT if n == 1 => number_to_float(a, heap, c),
        ix::NUMBER_TO_INTEGER if n == 1 => number_to_integer(a, heap, c),
        ix::RAW_TO_FLOAT if n == 1 => raw_to_float(false, a, heap, c),
        ix::RAW32_TO_FLOAT if n == 1 => raw_to_float(true, a, heap, c),
        ix::FLOAT_ADD if n == 2 => float_binop(0, a, heap, c),
        ix::FLOAT_SUBTRACT if n == 2 => float_binop(1, a, heap, c),
        ix::FLOAT_MULTIPLY if n == 2 => float_binop(2, a, heap, c),
        ix::FLOAT_DIVIDE if n == 2 => float_binop(3, a, heap, c),
        ix::FLOAT_MOD if n == 2 => float_binop(4, a, heap, c),
        ix::FLOAT_LESS_THAN if n == 2 => float_compare(0, a, heap, c),
        ix::FLOAT_LESS_THAN_OR_EQUAL if n == 2 => float_compare(1, a, heap, c),
        ix::FLOAT_GREATER_THAN if n == 2 => float_compare(2, a, heap, c),
        ix::FLOAT_GREATER_THAN_OR_EQUAL if n == 2 => float_compare(3, a, heap, c),
        ix::FLOAT_EQUALS if n == 2 => float_compare(4, a, heap, c),
        ix::COMPARE_TO if n == 2 => compare_to(false, a, heap, c),
        ix::MIN_SPECIAL_COMPARE_TO if n == 2 => compare_to(true, a, heap, c),
        _ => (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    }
}

} // verus!
