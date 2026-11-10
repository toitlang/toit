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
//! `int_cmp` of the arguments' `int_val` (division and modulo only up to
//! their error cases: Verus has no spec of truncating division).
//!
//! The C++ divides by a large integer whose value is 0 or -1 (`int64`
//! division traps); such objects are never created (`Primitive::integer`
//! makes smis of small values), but the port handles them (division by
//! zero fails, -1 negates) instead of trapping.

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

verus! {

/// The integer a value denotes: a smi or a large integer.
pub open spec fn int_val(objs: Seq<HeapObj>, v: Value) -> Option<i64> {
    match v {
        Value::Smi(i) => Some(i),
        Value::Obj(id) => if (id as int) < objs.len() && objs[id as int].body is LargeInt {
            Some(objs[id as int].body->LargeInt_0)
        } else {
            None
        },
        _ => None,
    }
}

/// The large integer a value denotes (the receiver of `large_integer_*`).
pub open spec fn large_val(objs: Seq<HeapObj>, v: Value) -> Option<i64> {
    match v {
        Value::Obj(id) => int_val(objs, v),
        _ => None,
    }
}

/// The smi a value denotes.
pub open spec fn smi_val(v: Value) -> Option<i64> {
    match v {
        Value::Smi(i) => Some(i),
        _ => None,
    }
}

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

/// The binary operations (`None`: the error the C++ fails with,
/// `int_err`). Division and modulo are only specified up to the result.
pub open spec fn int_op(op: u8, x: i64, y: i64) -> Option<i64> {
    if op == ADD { Some(x.wrapping_add(y)) }
    else if op == SUB { Some(x.wrapping_sub(y)) }
    else if op == MUL { Some(x.wrapping_mul(y)) }
    else if op == AND { Some(x & y) }
    else if op == OR { Some(x | y) }
    else if op == XOR { Some(x ^ y) }
    else if op == SHR { if y < 0 { None } else if y >= 64 { Some(if x < 0 { -1i64 } else { 0i64 }) } else { Some(x >> (y as u64)) } }
    else if op == USHR { if y < 0 { None } else if y >= 64 { Some(0) } else { Some(((x as u64) >> (y as u64)) as i64) } }
    else if op == SHL { if y < 0 { None } else if y >= 64 { Some(0) } else { Some(((x as u64) << (y as u64)) as i64) } }
    else { if y == 0 { None } else { Some(0) } }
}

/// The error root of a failing `int_op`.
pub open spec fn int_err(op: u8) -> usize {
    if op == DIV || op == MOD { ROOT_DIVISION_BY_ZERO } else { ROOT_NEGATIVE_ARGUMENT }
}

pub open spec fn int_cmp(op: u8, x: i64, y: i64) -> bool {
    if op == LT { x < y } else if op == LTE { x <= y } else if op == GT { x > y } else if op == GTE { x >= y } else { x == y }
}

/// `int_op`, computed: `Err(root)` on failure.
#[inline(always)]
pub fn int_op_exec(op: u8, x: i64, y: i64) -> (r: Result<i64, usize>)
    requires op <= SHL,
    ensures
        r is Err <==> int_op(op, x, y) is None,
        r is Err ==> r->Err_0 == int_err(op),
        r is Ok && op != DIV && op != MOD ==> int_op(op, x, y) == Some(r->Ok_0),
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
        else if y == -1 { Ok(0i64.wrapping_sub(x)) }
        else { Ok(x / y) }
    } else {
        if y == 0 { Err(ROOT_DIVISION_BY_ZERO) }
        else if y == -1 { Ok(0) }
        else { Ok(x % y) }
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

/// The integer argument `w` (a smi or a large integer).
#[inline(always)]
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
        h.lemma_body_tag(id);
    }
    let tag = h.class_tag(w, Ghost(id));
    if tag == LARGE_INTEGER_TAG {
        Some(h.large_integer_value(w, Ghost(id)))
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
        !(r.0 is Failure),
        r.0 is Success ==> int_val(final(heap).objs(), r.1@) == Some(x),
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
        ({
            let x = if large { large_val(old(heap).objs(), a.vs@[0]) } else { smi_val(a.vs@[0]) };
            let y = int_val(old(heap).objs(), a.vs@[1]);
            &&& (x is None || y is None) ==> r.0 is Failure && r.1@ == c.p.ap@.roots[ROOT_WRONG_OBJECT_TYPE as int]
            &&& (x is Some && y is Some && int_op(op, x->Some_0, y->Some_0) is None) ==>
                    r.0 is Failure && r.1@ == c.p.ap@.roots[int_err(op) as int]
            &&& (r.0 is Success && op != DIV && op != MOD) ==> x is Some && y is Some
                    && int_val(final(heap).objs(), r.1@) == int_op(op, x->Some_0, y->Some_0)
        }),
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
        ({
            let x = if large { large_val(old(heap).objs(), a.vs@[0]) } else { smi_val(a.vs@[0]) };
            let y = int_val(old(heap).objs(), a.vs@[1]);
            &&& (x is None || y is None) ==> r.0 is Failure && r.1@ == c.p.ap@.roots[ROOT_WRONG_OBJECT_TYPE as int]
            &&& (x is Some && y is Some) ==> r.0 is Success && r.1@ ==
                    (if int_cmp(op, x->Some_0, y->Some_0) { c.p.ap@.roots[1] } else { c.p.ap@.roots[2] })
        }),
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

pub open spec fn popcount(x: u64, n: nat) -> nat
    decreases n,
{
    if n == 0 { 0 } else { (x % 2) as nat + popcount(x / 2, (n - 1) as nat) }
}

pub open spec fn unop_spec(op: u8, x: i64) -> i64 {
    if op == NEG { 0i64.wrapping_sub(x) }
    else if op == NOT { !x }
    else if op == POPCOUNT { popcount(x as u64, 64) as i64 }
    else { 0 }
}

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
        ({
            let x = if op >= CLZ { int_val(old(heap).objs(), a.vs@[0]) }
                else if large { large_val(old(heap).objs(), a.vs@[0]) } else { smi_val(a.vs@[0]) };
            &&& x is None ==> r.0 is Failure && r.1@ == c.p.ap@.roots[ROOT_WRONG_OBJECT_TYPE as int]
            &&& (r.0 is Success && op != CLZ) ==> x is Some
                    && int_val(final(heap).objs(), r.1@) == Some(unop_spec(op, x->Some_0))
        }),
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
        a.vs@[0] is Obj ==> r.1@ == Value::Smi(old(heap).objs()[a.vs@[0]->Obj_0 as int].class_id as i64),
        a.vs@[0] is Smi ==> r.1@ == Value::Smi(c.p.ap@.builtin[BUILTIN_SMI as int] as i64),
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
pub fn dispatch(i: usize, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)),
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    let n = a.n;
    if n == 2 {
        if i == ix::SMI_ADD { return binop(ADD, false, a, heap, c); }
        if i == ix::SMI_SUBTRACT { return binop(SUB, false, a, heap, c); }
        if i == ix::SMI_MULTIPLY { return binop(MUL, false, a, heap, c); }
        if i == ix::SMI_DIVIDE { return binop(DIV, false, a, heap, c); }
        if i == ix::SMI_MOD { return binop(MOD, false, a, heap, c); }
        if i == ix::SMI_AND { return binop(AND, false, a, heap, c); }
        if i == ix::SMI_OR { return binop(OR, false, a, heap, c); }
        if i == ix::SMI_XOR { return binop(XOR, false, a, heap, c); }
        if i == ix::SMI_SHIFT_RIGHT { return binop(SHR, false, a, heap, c); }
        if i == ix::SMI_UNSIGNED_SHIFT_RIGHT { return binop(USHR, false, a, heap, c); }
        if i == ix::SMI_SHIFT_LEFT { return binop(SHL, false, a, heap, c); }
        if i == ix::SMI_LESS_THAN { return cmpop(LT, false, a, heap, c); }
        if i == ix::SMI_LESS_THAN_OR_EQUAL { return cmpop(LTE, false, a, heap, c); }
        if i == ix::SMI_GREATER_THAN { return cmpop(GT, false, a, heap, c); }
        if i == ix::SMI_GREATER_THAN_OR_EQUAL { return cmpop(GTE, false, a, heap, c); }
        if i == ix::SMI_EQUALS { return cmpop(EQ, false, a, heap, c); }
        if i == ix::LARGE_INTEGER_ADD { return binop(ADD, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_SUBTRACT { return binop(SUB, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_MULTIPLY { return binop(MUL, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_DIVIDE { return binop(DIV, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_MOD { return binop(MOD, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_AND { return binop(AND, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_OR { return binop(OR, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_XOR { return binop(XOR, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_SHIFT_RIGHT { return binop(SHR, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_UNSIGNED_SHIFT_RIGHT { return binop(USHR, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_SHIFT_LEFT { return binop(SHL, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_LESS_THAN { return cmpop(LT, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_LESS_THAN_OR_EQUAL { return cmpop(LTE, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_GREATER_THAN { return cmpop(GT, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_GREATER_THAN_OR_EQUAL { return cmpop(GTE, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_EQUALS { return cmpop(EQ, true, a, heap, c); }
    } else if n == 1 {
        if i == ix::SMI_UNARY_MINUS { return unop(NEG, false, a, heap, c); }
        if i == ix::SMI_NOT { return unop(NOT, false, a, heap, c); }
        if i == ix::LARGE_INTEGER_UNARY_MINUS { return unop(NEG, true, a, heap, c); }
        if i == ix::LARGE_INTEGER_NOT { return unop(NOT, true, a, heap, c); }
        if i == ix::COUNT_LEADING_ZEROS { return unop(CLZ, false, a, heap, c); }
        if i == ix::POPCOUNT { return unop(POPCOUNT, false, a, heap, c); }
        if i == ix::OBJECT_CLASS_ID { return object_class_id(a, heap, c); }
    }
    (PrimOutcome::NotPorted, Ghost(Value::Smi(0)))
}

} // verus!
