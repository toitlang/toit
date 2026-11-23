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

//! Integer primitives: smi and large-integer arithmetic, bit operations,
//! shifts and comparisons, `count_leading_zeros`, `popcount`,
//! `object_class_id` (src/primitive_core.cc).
//!
//! Ints are 64-bit two's complement and wrap (the C++ computes in `int64`;
//! its signed overflow wraps on the supported compilers). A result in smi
//! range is a smi, otherwise a new large integer (`Primitive::integer`).
//! Functional specification: `int_val` of the result is `int_op` /
//! `int_cmp` of the arguments. Division truncates toward zero and
//! remainder has the sign of the dividend.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::view::*;
use crate::prims::*;
use crate::prims::index as ix;
use toit_spec::types::{Value, HeapObj, Body};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::good;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim_core::{int_val, large_val, smi_val, int_op, int_err, int_cmp, popcount, unop_spec,
    smi_in, int_binop_contract, int_cmp_contract, int_unop_contract, object_class_id_contract};

verus! {

pub const ADD: u8 = 0;
pub const SUB: u8 = 1;
pub const MUL: u8 = 2;
pub const DIV: u8 = 3;
pub const MOD: u8 = 4;
pub const AND: u8 = 5;
pub const OR: u8 = 6;
pub const XOR: u8 = 7;
pub const SHR: u8 = 8;
pub const USHR: u8 = 9;
pub const SHL: u8 = 10;

pub const LT: u8 = 0;
pub const LTE: u8 = 1;
pub const GT: u8 = 2;
pub const GTE: u8 = 3;
pub const EQ: u8 = 4;

/// `int_op`, computed: `Err(root)` on failure.
#[inline(always)]
pub fn int_op_exec(op: u8, x: i64, y: i64) -> (r: Result<i64, usize>)
    requires op <= SHL,
    ensures
        r is Err <==> int_op(op, x, y) is None,
        r is Err ==> r->Err_0 as int == int_err(op) && r->Err_0 < ROOT_COUNT,
        r is Ok ==> int_op(op, x, y) == Some(r->Ok_0),
{
    if op == ADD { Ok(x.wrapping_add(y)) }
    else if op == SUB { Ok(x.wrapping_sub(y)) }
    else if op == MUL { Ok(x.wrapping_mul(y)) }
    else if op == AND { Ok(x & y) }
    else if op == OR { Ok(x | y) }
    else if op == XOR { Ok(x ^ y) }
    else if op == SHR {
        if y < 0 { Err(ROOT_NEGATIVE_ARGUMENT) }
        else if y >= 64 { Ok(if x < 0 { -1 } else { 0 }) }
        else { Ok(x >> (y as u64)) }
    } else if op == USHR {
        if y < 0 { Err(ROOT_NEGATIVE_ARGUMENT) }
        else if y >= 64 { Ok(0) }
        else { Ok(((x as u64) >> (y as u64)) as i64) }
    } else if op == SHL {
        if y < 0 { Err(ROOT_NEGATIVE_ARGUMENT) }
        else if y >= 64 { Ok(0) }
        else { Ok(((x as u64) << (y as u64)) as i64) }
    } else if op == DIV {
        if y == 0 { Err(ROOT_DIVISION_BY_ZERO) }
        else if y == -1 {
            assert(toit_spec::spec_common::tdiv(x as int, -1) == -(x as int));
            let neg = 0i64.wrapping_sub(x);
            proof {
                if x == i64::MIN { assert(0i64.wrapping_sub(i64::MIN) == i64::MIN) by (compute); }
            }
            Ok(neg)
        }
        else {
            proof { crate::ops::lemma_rust_div(x as int, y as int); }
            Ok(x.checked_div(y).unwrap())
        }
    } else {
        if y == 0 { Err(ROOT_DIVISION_BY_ZERO) }
        else if y == -1 {
            assert(toit_spec::spec_common::trem(x as int, -1) == 0);
            Ok(0)
        }
        else {
            proof { crate::ops::lemma_rust_div(x as int, y as int); }
            Ok(x.checked_rem(y).unwrap())
        }
    }
}

#[inline(always)]
pub fn int_cmp_exec(op: u8, x: i64, y: i64) -> (r: bool)
    ensures r == int_cmp(op, x, y),
{
    if op == LT { x < y } else if op == LTE { x <= y } else if op == GT { x > y } else if op == GTE { x >= y } else { x == y }
}

// ---------------------------------------------------------------------------
// Arguments and results.

/// The integer argument `w` (a smi or a large integer). Out of line: one
/// copy for every primitive that decodes an integer (size diet).
#[inline(never)]
pub fn int_arg(h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<i64>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures r == int_val(h.objs(), v),
{
    proof { lemma_word(h, w, v); }
    if w & 1 == 0 {
        return Some(smi_of_word(w));
    }
    let ghost id = v->Obj_0 as int;
    proof {
        assert(obj_model_ok(h.objs()[id], h.class_bits(), h.addrs()));
    }
    let tag = h.class_tag(w, Ghost(id));
    if tag == LARGE_INTEGER_TAG {
        Some(h.large_int(w, Ghost(id)))
    } else {
        None
    }
}

/// The receiver: a smi (`smi_*`) or a large integer (`large_integer_*`).
#[inline(always)]
pub fn recv_arg(large: bool, h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<i64>)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v), good(h.objs(), v), encodable(h.addrs(), v),
    ensures r == (if large { large_val(h.objs(), v) } else { smi_val(v) }),
{
    proof { lemma_word(h, w, v); }
    if large {
        if w & 1 == 0 { None } else { int_arg(h, w, Ghost(v)) }
    } else {
        if w & 1 == 0 { Some(smi_of_word(w)) } else { None }
    }
}

/// `Primitive::integer`: a smi if `x` is in smi range, else a new large
/// integer.
pub fn int_res(heap: &mut Heap, c: &Ctx, x: i64) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)),
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> toit_spec::v2::prim_core::raw_integer_result(c.p.ap@,
            old(heap).objs(), final(heap).objs(), ret_of(c.p, r.0, r.1@), x),
        !(r.0 is Failure),
        r.0 is Success ==> int_val(final(heap).objs(), r.1@) == Some(x),
        r.0 is Success && smi_in(x) ==> *final(heap) == *old(heap) && r.1@ == Value::Smi(x),
        r.0 is NeedsGc ==> !smi_in(x),
{
    if MIN_SMI <= x && x <= MAX_SMI {
        let (w, v) = smi_res(heap, x);
        return ok(c.p, heap, w, v);
    }
    let cid = match builtin_with_tag(c.p, heap, BUILTIN_LARGE_INTEGER, LARGE_INTEGER_TAG) {
        Some(cid) => cid,
        None => return (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    };
    let ghost h0 = *heap;
    let w = c.al.large_integer(heap, c.p, x);
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

// ---------------------------------------------------------------------------
// The primitives.

/// `smi_add` .. `smi_shift_left` (`large == false`) and
/// `large_integer_add` .. `large_integer_shift_left` (`large == true`): the
/// receiver must be a smi resp. a large integer, the argument an integer
/// (else WRONG_OBJECT_TYPE).
pub fn binop(op: u8, large: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2, op <= SHL,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> int_binop_contract(c.p.ap@, op, large, a.vs@, old(heap).objs(),
            final(heap).objs(), ret_of(c.p, r.0, r.1@)),
{
    let x = match recv_arg(large, heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let y = match int_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(y) => y,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    match int_op_exec(op, x, y) {
        Err(k) => fail(c.p, heap, k),
        Ok(z) => int_res(heap, c, z),
    }
}

/// The comparisons `smi_less_than` .. `smi_equals` and
/// `large_integer_less_than` .. `large_integer_equals`.
pub fn cmpop(op: u8, large: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 2,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted),
        int_cmp_contract(c.p.ap@, op, large, a.vs@, old(heap).objs(), final(heap).objs(), ret_of(c.p, r.0, r.1@)),
{
    let x = match recv_arg(large, heap, a.w[0], Ghost(a.vs@[0])) {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let y = match int_arg(heap, a.w[1], Ghost(a.vs@[1])) {
        Some(y) => y,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    ok_bool(c.p, heap, int_cmp_exec(op, x, y))
}

pub const NEG: u8 = 0;
pub const NOT: u8 = 1;
pub const CLZ: u8 = 2;
pub const POPCOUNT: u8 = 3;

#[inline(always)]
fn popcount_exec(x: u64) -> (r: u64)
    ensures r == popcount(x, 64), r <= 64,
{
    let mut v = x;
    let mut n: u64 = 0;
    let mut k: u64 = 0;
    while k < 64
        invariant
            k <= 64, n <= k,
            n + popcount(v, (64 - k) as nat) == popcount(x, 64),
        decreases 64 - k,
    {
        n += (v % 2);
        v = v / 2;
        k += 1;
    }
    n
}

/// `smi_unary_minus`, `smi_not` (smi receiver), `large_integer_unary_minus`,
/// `large_integer_not` (large receiver), `count_leading_zeros`, `popcount`
/// (any integer: `large` is ignored).
pub fn unop(op: u8, large: bool, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1, op <= POPCOUNT,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        !(r.0 is NotPorted) ==> int_unop_contract(c.p.ap@, op, large, a.vs@, old(heap).objs(),
            final(heap).objs(), ret_of(c.p, r.0, r.1@)),
{
    let x = if op >= CLZ {
        int_arg(heap, a.w[0], Ghost(a.vs@[0]))
    } else {
        recv_arg(large, heap, a.w[0], Ghost(a.vs@[0]))
    };
    let x = match x {
        Some(x) => x,
        None => return fail(c.p, heap, ROOT_WRONG_OBJECT_TYPE),
    };
    let z = if op == NEG { 0i64.wrapping_sub(x) }
        else if op == NOT { !x }
        else if op == CLZ { (x as u64).leading_zeros() as i64 }
        else { popcount_exec(x as u64) as i64 };
    int_res(heap, c, z)
}

/// `object_class_id`: the smi class for smis, else the header's class id.
pub fn object_class_id(a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)), a.n == 1,
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        r.0 is Success,
        object_class_id_contract(c.p.ap@, a.vs@, old(heap).objs(), final(heap).objs(), ret_of(c.p, r.0, r.1@)),
{
    let w = a.w[0];
    let ghost v = a.vs@[0];
    proof { lemma_word(heap, w, v); }
    let id = if w & 1 == 0 {
        proof { assert(c.p.smi_class_id == c.p.ap@.builtin[BUILTIN_SMI as int] as i64); }
        c.p.smi_class_id
    } else {
        heap.class_id(w, Ghost(v->Obj_0 as int)) as i64
    };
    let (rw, rv) = smi_res(heap, id);
    ok(c.p, heap, rw, rv)
}

/// The integer family of the dispatch table.
#[inline(always)]
pub fn dispatch(i: usize, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)),
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@), contract(c.p, i as int, a, old(heap), final(heap), r.0, r.1@),
{
    let n = a.n;
    match i {
        ix::SMI_ADD if n == 2 => binop(ADD, false, a, heap, c),
        ix::SMI_SUBTRACT if n == 2 => binop(SUB, false, a, heap, c),
        ix::SMI_MULTIPLY if n == 2 => binop(MUL, false, a, heap, c),
        ix::SMI_DIVIDE if n == 2 => binop(DIV, false, a, heap, c),
        ix::SMI_MOD if n == 2 => binop(MOD, false, a, heap, c),
        ix::SMI_AND if n == 2 => binop(AND, false, a, heap, c),
        ix::SMI_OR if n == 2 => binop(OR, false, a, heap, c),
        ix::SMI_XOR if n == 2 => binop(XOR, false, a, heap, c),
        ix::SMI_SHIFT_RIGHT if n == 2 => binop(SHR, false, a, heap, c),
        ix::SMI_UNSIGNED_SHIFT_RIGHT if n == 2 => binop(USHR, false, a, heap, c),
        ix::SMI_SHIFT_LEFT if n == 2 => binop(SHL, false, a, heap, c),
        ix::SMI_LESS_THAN if n == 2 => cmpop(LT, false, a, heap, c),
        ix::SMI_LESS_THAN_OR_EQUAL if n == 2 => cmpop(LTE, false, a, heap, c),
        ix::SMI_GREATER_THAN if n == 2 => cmpop(GT, false, a, heap, c),
        ix::SMI_GREATER_THAN_OR_EQUAL if n == 2 => cmpop(GTE, false, a, heap, c),
        ix::SMI_EQUALS if n == 2 => cmpop(EQ, false, a, heap, c),
        ix::LARGE_INTEGER_ADD if n == 2 => binop(ADD, true, a, heap, c),
        ix::LARGE_INTEGER_SUBTRACT if n == 2 => binop(SUB, true, a, heap, c),
        ix::LARGE_INTEGER_MULTIPLY if n == 2 => binop(MUL, true, a, heap, c),
        ix::LARGE_INTEGER_DIVIDE if n == 2 => binop(DIV, true, a, heap, c),
        ix::LARGE_INTEGER_MOD if n == 2 => binop(MOD, true, a, heap, c),
        ix::LARGE_INTEGER_AND if n == 2 => binop(AND, true, a, heap, c),
        ix::LARGE_INTEGER_OR if n == 2 => binop(OR, true, a, heap, c),
        ix::LARGE_INTEGER_XOR if n == 2 => binop(XOR, true, a, heap, c),
        ix::LARGE_INTEGER_SHIFT_RIGHT if n == 2 => binop(SHR, true, a, heap, c),
        ix::LARGE_INTEGER_UNSIGNED_SHIFT_RIGHT if n == 2 => binop(USHR, true, a, heap, c),
        ix::LARGE_INTEGER_SHIFT_LEFT if n == 2 => binop(SHL, true, a, heap, c),
        ix::LARGE_INTEGER_LESS_THAN if n == 2 => cmpop(LT, true, a, heap, c),
        ix::LARGE_INTEGER_LESS_THAN_OR_EQUAL if n == 2 => cmpop(LTE, true, a, heap, c),
        ix::LARGE_INTEGER_GREATER_THAN if n == 2 => cmpop(GT, true, a, heap, c),
        ix::LARGE_INTEGER_GREATER_THAN_OR_EQUAL if n == 2 => cmpop(GTE, true, a, heap, c),
        ix::LARGE_INTEGER_EQUALS if n == 2 => cmpop(EQ, true, a, heap, c),
        ix::SMI_UNARY_MINUS if n == 1 => unop(NEG, false, a, heap, c),
        ix::SMI_NOT if n == 1 => unop(NOT, false, a, heap, c),
        ix::LARGE_INTEGER_UNARY_MINUS if n == 1 => unop(NEG, true, a, heap, c),
        ix::LARGE_INTEGER_NOT if n == 1 => unop(NOT, true, a, heap, c),
        ix::COUNT_LEADING_ZEROS if n == 1 => unop(CLZ, false, a, heap, c),
        ix::POPCOUNT if n == 1 => unop(POPCOUNT, false, a, heap, c),
        ix::OBJECT_CLASS_ID if n == 1 => object_class_id(a, heap, c),
        _ => (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    }
}

} // verus!
