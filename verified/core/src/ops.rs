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

//! The operators, verified on their smi fast paths: INVOKE_EQ, the
//! relational operators, the arithmetic and bit operators (opcodes
//! 62..=77, `spec::op_invoke_eq`, `op_invoke_relational`,
//! `op_invoke_arith`) and IDENTICAL. When both operands are smis and the
//! result is a smi, the handler replaces the operands by the result
//! (`spec::binary_result`). The other cases are verified too: doubles,
//! large integers and the mixed comparison (`numbers.rs`; double
//! arithmetic allocates the result, a GC point whose failure is the
//! spec's resource throw: the operator's method is called), IDENTICAL of
//! two distinct heap objects (contents of doubles, large integers,
//! strings), and the virtual call of the operator's selector.
//!
//! The operands are values (not block references) by the verifier's
//! `value_operands`, so a word with a clear low bit is a smi, and the
//! smi words relate to the spec's integers by bit-vector lemmas.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::calls::handler_pre;
use toit_spec::types::{Value, HeapObj};
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
use toit_spec::v2::verifier::{accepts, value_operands};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{smi, smi_ok, tdiv, trem, word_bit_size, is_double, double_bits, new_double};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_helpers::{are_smis, smi_val, identical, is_nan_bits};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_step::{smi_arith, relational_smi, relational_flag, float_arith};
#[cfg(verus_keep_ghost)]
use vstd::arithmetic::power2::pow2;
#[cfg(verus_keep_ghost)]
use vstd::arithmetic::div_mod::{rust_div, rust_rem};

verus! {

// ---------------------------------------------------------------------------
// The operands.

/// The operator opcodes of this file.
pub open spec fn binary_op(op: u8) -> bool {
    (62 <= op <= 77) || op == 96
}

/// The two operands of an operator are values, by the verifier's
/// `value_operands`.
pub proof fn lemma_operands(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        binary_op(cur_op(p.ap@, g)),
    ensures
        sp::has_slot(g, 0), sp::has_slot(g, 1), sp::binary_ok(g),
        sp::at(g, 0) is Smi || sp::at(g, 0) is Obj,
        sp::at(g, 1) is Smi || sp::at(g, 1) is Obj,
{
    let ap = p.ap@;
    let c = p.cert@;
    lemma_instr(ap, c, p.trusted@, g);
    let k = cur_k(ap, c, g);
    assert(value_operands(k, 2));
    lemma_at_good(ap, c, p.trusted@, g, 0);
    lemma_at_good(ap, c, p.trusted@, g, 1);
}

/// The step of an operator, given that it is not stuck.
pub proof fn lemma_step_op(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        step_ok(p.ap@, p.cert@, g),
        binary_op(cur_op(p.ap@, g)),
    ensures ({
        let ap = p.ap@;
        let op = cur_op(ap, g);
        &&& op == 62 ==> sp::step(ap, g) == sp::op_invoke_eq(ap, g)
        &&& 63 <= op <= 66 ==> sp::step(ap, g) == sp::op_invoke_relational(ap, g, op)
        &&& 67 <= op <= 77 ==> sp::step(ap, g) == sp::op_invoke_arith(ap, g, op)
        &&& op == 96 ==> sp::step(ap, g)
            == sp::binary_result(g, sp::boolean2(ap, identical(as1(g), sp::at(g, 1), sp::at(g, 0))))
    }),
{
    lemma_operands(p, g);
    assert(outcome_ok(p.ap@, p.cert@, sp::step(p.ap@, g)));
    reveal(sp::step);
}

/// A word of an operand is a smi word exactly if the operand is a smi.
pub proof fn lemma_tag(m: Machine, p: &Program, w: usize, v: Value)
    requires
        m.refines(p),
        w == enc(m.addr(), v),
        encodable(m.addr(), v),
        v is Smi || v is Obj,
    ensures
        (w & 1 == 0) == (v is Smi),
        v is Smi ==> w == smi_word(v->Smi_0) && smi_range(v->Smi_0 as int),
{
    match v {
        Value::Smi(i) => { lemma_smi_word(i); },
        Value::Obj(id) => { lemma_obj_not_smi(m.heap.objs(), m.addr(), id); },
        _ => {},
    }
}

pub proof fn lemma_or_tag(a: usize, b: usize)
    ensures
        ((a | b) & 1 == 0) == (a & 1 == 0 && b & 1 == 0),
        ((a & b) & 1 == 0) == (a & 1 == 0 || b & 1 == 0),
{
    assert(((a | b) & 1 == 0) == (a & 1 == 0 && b & 1 == 0)) by (bit_vector);
    assert(((a & b) & 1 == 0) == (a & 1 == 0 || b & 1 == 0)) by (bit_vector);
}

// ---------------------------------------------------------------------------
// Smi arithmetic on words.

/// OR, XOR and AND of smi words are the smi words of OR, XOR and AND.
pub proof fn lemma_smi_bitops(x: i64, y: i64)
    requires smi_range(x as int), smi_range(y as int),
    ensures
        smi_word(x) | smi_word(y) == smi_word(x | y), smi_range((x | y) as int),
        smi_word(x) ^ smi_word(y) == smi_word(x ^ y), smi_range((x ^ y) as int),
        smi_word(x) & smi_word(y) == smi_word(x & y), smi_range((x & y) as int),
{
    assert(((x + x) as usize) | ((y + y) as usize) == (((x | y) + (x | y)) as usize)
        && MIN_SMI <= (x | y) <= MAX_SMI) by (bit_vector)
        requires MIN_SMI <= x <= MAX_SMI,
            MIN_SMI <= y <= MAX_SMI;
    assert(((x + x) as usize) ^ ((y + y) as usize) == (((x ^ y) + (x ^ y)) as usize)
        && MIN_SMI <= (x ^ y) <= MAX_SMI) by (bit_vector)
        requires MIN_SMI <= x <= MAX_SMI,
            MIN_SMI <= y <= MAX_SMI;
    assert(((x + x) as usize) & ((y + y) as usize) == (((x & y) + (x & y)) as usize)
        && MIN_SMI <= (x & y) <= MAX_SMI) by (bit_vector)
        requires MIN_SMI <= x <= MAX_SMI,
            MIN_SMI <= y <= MAX_SMI;
}

/// An arithmetic shift right keeps a smi in the smi range.
pub proof fn lemma_smi_shr(x: i64, s: u64)
    requires smi_range(x as int), s < 64,
    ensures smi_range((x >> s) as int),
{
    assert(MIN_SMI <= (x >> s) <= MAX_SMI) by (bit_vector)
        requires MIN_SMI <= x <= MAX_SMI, s < 64;
}

/// For a positive dividend, Euclidean division by a negative divisor
/// truncates.
pub proof fn lemma_div_neg(n: int, d: int)
    requires n >= 0, d < 0,
    ensures n / d == -(n / (-d)),
{
    let q = n / (-d);
    let r = n % (-d);
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(n, -d);
    vstd::arithmetic::div_mod::lemma_mod_pos_bound(n, -d);
    assert(n == d * (-q) + r) by (nonlinear_arith)
        requires n == (-d) * q + r;
    // Euclidean division by `d`: the remainder `r` is in 0..|d|.
    vstd::arithmetic::div_mod::lemma_fundamental_div_mod(n, d);
    let q2 = n / d;
    let r2 = n % d;
    assert(0 <= r2 < -d);
    assert(d * (q2 + q) == r - r2) by (nonlinear_arith)
        requires n == d * q2 + r2, n == d * (-q) + r;
    if q2 + q != 0 {
        assert(d * (q2 + q) <= d || d * (q2 + q) >= -d) by (nonlinear_arith)
            requires d < 0, q2 + q != 0;
    }
}

/// Rust's division and remainder of integers are C's (`tdiv`, `trem`).
#[verifier::spinoff_prover]
pub proof fn lemma_rust_div(a: int, b: int)
    requires b != 0,
    ensures
        rust_div(a, b) == tdiv(a, b),
        rust_rem(a, b) == trem(a, b),
        b > 0 ==> -b < rust_rem(a, b) < b,
        b < 0 ==> b < rust_rem(a, b) < -b,
{
    if a > 0 {
        if b < 0 { lemma_div_neg(a, b); }
        vstd::arithmetic::div_mod::lemma_fundamental_div_mod(a, b);
    } else if a < 0 {
        if b < 0 { lemma_div_neg(-a, b); }
        vstd::arithmetic::div_mod::lemma_fundamental_div_mod(-a, b);
        assert(b * (-((-a) / b)) == -(b * ((-a) / b))) by (nonlinear_arith);
    }
    assert(0 <= (if a >= 0 { a } else { -a }) % b < (if b >= 0 { b } else { -b }));
}

/// The smi fast path of the arithmetic operators on the words `a`, `b` of
/// the smis `x`, `y` (`spec_step::smi_arith`): `Some` of the result's word
/// when it applies (and is a smi), `None` for the slow path.
#[inline(always)]
pub fn smi_arith_word(op: u8, a: usize, b: usize, Ghost(x): Ghost<i64>, Ghost(y): Ghost<i64>,
    Ghost(pp): Ghost<toit_spec::types::Program>) -> (r: Option<usize>)
    requires
        67 <= op <= 77,
        smi_range(x as int), smi_range(y as int),
        a == smi_word(x), b == smi_word(y),
        pp.word_bits == WORD_BITS,
    ensures
        r is Some ==> ({
            let o = smi_arith(pp, op, x as int, y as int);
            &&& o is Some
            &&& smi_range(o->0)
            &&& r->0 == smi_word(o->0 as i64)
        }),
        r is None ==> smi_arith(pp, op, x as int, y as int) is None,
{
    proof { lemma_smi_word(x); lemma_smi_word(y); }
    // The tagged words as signed words (2x and 2y: ADD, SUB and MUL check
    // the overflow of the word) and the smi values.
    let ai = a as isize;
    let bi = b as isize;
    let xv = smi_value(a);
    let yv = smi_value(b);
    proof { assert(xv == x && yv == y); }
    if op == 67 {
        proof { lemma_smi_bitops(x, y); }
        Some(a | b)
    } else if op == 68 {
        proof { lemma_smi_bitops(x, y); }
        Some(a ^ b)
    } else if op == 69 {
        proof { lemma_smi_bitops(x, y); }
        Some(a & b)
    } else if op == 73 {
        // 2x + 2y overflows a word exactly if x + y is not a smi.
        match ai.checked_add(bi) {
            Some(s) => Some(s as usize),
            None => None,
        }
    } else if op == 74 {
        match ai.checked_sub(bi) {
            Some(s) => Some(s as usize),
            None => None,
        }
    } else if op == 75 {
        // 2x * y overflows a word exactly if x * y is not a smi.
        let ys = yv as isize;
        proof {
            assert(ai * ys == 2 * (x * y)) by (nonlinear_arith) requires ai == x + x, ys == y;
        }
        match ai.checked_mul(ys) {
            Some(s) => Some(s as usize),
            None => None,
        }
    } else if op == 76 {
        let xs = xv;
        let ys = yv;
        match xs.checked_div(ys) {
            Some(q) => {
                proof { lemma_rust_div(x as int, y as int); }
                if MIN_SMI <= q && q <= MAX_SMI { Some(smi_of(q)) } else { None }
            },
            None => None,
        }
    } else if op == 77 {
        let xs = xv;
        let ys = yv;
        match xs.checked_rem(ys) {
            Some(q) => {
                proof { lemma_rust_div(x as int, y as int); }
                Some(smi_of(q))
            },
            None => None,
        }
    } else if op == 70 {
        // x << s as the exact product x * 2^s in i64 (s < WORD_BITS - 1 <=
        // 63; an overflow of i64 is not a smi either), then the range check.
        let xs = xv;
        let ys = yv;
        if 0 <= ys && ys < WORD_BITS as i64 - 1 {
            let pw = 1u64 << (ys as u64);
            proof {
                vstd::bits::lemma_u64_pow2_no_overflow(ys as nat);
                vstd::bits::lemma_u64_shl_is_mul(1u64, ys as u64);
                assert(ys < 63);
                vstd::arithmetic::power2::lemma_pow2_strictly_increases(ys as nat, 63);
                vstd::arithmetic::power2::lemma2_to64_rest();
            }
            let pwi = pw as i64;
            match xs.checked_mul(pwi) {
                Some(s) => {
                    if MIN_SMI <= s && s <= MAX_SMI { Some(smi_of(s)) } else { None }
                },
                None => {
                    proof {
                        let pp2 = pow2(ys as nat) as int;
                        assert(x * pp2 > MAX_SMI || x * pp2 < MIN_SMI);
                    }
                    None
                },
            }
        } else if ys == WORD_BITS as i64 - 1 && xs == 0 {
            // 0 << (WORD_BITS - 1) is the only such shift whose result is a
            // smi.
            proof {
                assert(x * pow2(ys as nat) == 0) by (nonlinear_arith) requires x == 0;
            }
            Some(0)
        } else {
            proof {
                if 0 <= ys && ys == WORD_BITS as i64 - 1 {
                    vstd::arithmetic::power2::lemma2_to64();
                    vstd::arithmetic::power2::lemma2_to64_rest();
                    let q = pow2(ys as nat) as int;
                    assert(q == 2 * (MAX_SMI + 1));
                    assert(x * q >= q || x * q <= -q) by (nonlinear_arith) requires x != 0, q > 0;
                }
            }
            None
        }
    } else if op == 71 {
        let xs = xv;
        let ys = yv;
        if 0 <= ys && ys < WORD_BITS as i64 {
            let q = xs >> (ys as u64);
            proof { lemma_smi_shr(x, ys as u64); }
            Some(smi_of(q))
        } else {
            None
        }
    } else {
        let xs = xv;
        let ys = yv;
        if 0 <= ys && ys < WORD_BITS as i64 && xs >= 0 {
            let q = xs >> (ys as u64);
            proof { lemma_smi_shr(x, ys as u64); }
            Some(smi_of(q))
        } else {
            None
        }
    }
}

// ---------------------------------------------------------------------------
// The result.

/// The word of `boolean2(b)`.
#[inline(always)]
pub fn bool_word(p: &Program, b: bool, Ghost(m): Ghost<Machine>) -> (r: usize)
    requires m.refines(p),
    ensures
        r == enc(m.addr(), sp::boolean2(p.ap@, b)),
        encodable(m.addr(), sp::boolean2(p.ap@, b)),
{
    proof {
        assert(const_ok(m.g@.heap, p.ap@.roots[1]));
        assert(const_ok(m.g@.heap, p.ap@.roots[2]));
    }
    if b { p.true_ } else { p.false_ }
}

impl Machine {
    /// Replaces the two operands by the encoding of `v` and continues
    /// after the instruction (`spec::binary_result`).
    #[inline(always)]
    pub fn binary_next(&mut self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Ctl)
        requires
            old(self).refines(p),
            sp::has_slot(old(self).g@, 1),
            w == enc(old(self).addr(), v),
            encodable(old(self).addr(), v),
            old(self).bci + 1 < 0x1000_0000,
        ensures
            r == Ctl::Next,
            final(self).refines(p),
            sp::binary_result(old(self).g@, v) == Outcome2::Next(final(self).g@),
    {
        let ghost m0 = *self;
        let ghost g0 = self.g@;
        proof { self.lemma_at(p, 1); self.lemma_frame(p); }
        self.put(1, w);
        self.drop(1);
        self.bci = self.bci + 1;
        let ghost g1 = sp::goto(sp::push(sp::drop(g0, 2), v), g0.bci + 1);
        self.g = Ghost(g1);
        proof {
            let h = g0.stack.len();
            assert forall|i: int| 0 <= i < h - 1 implies #[trigger] self.words()[i] == enc(m0.addr(), g1.stack[i]) by {
                if i < h - 2 {
                    assert(self.words()[i] == m0.words()[i]);
                    assert(m0.words()[i] == enc_seq(m0.addr(), g0.stack)[i]);
                }
            }
            assert(self.words() =~= enc_seq(m0.addr(), g1.stack));
            assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
                if i < h - 2 { assert(g1.stack[i] == g0.stack[i]); }
            }
            m0.lemma_local_step(p, self);
        }
        Ctl::Next
    }
}

// ---------------------------------------------------------------------------
// Handlers.

/// `spec_step::relational_flag`.
#[inline(always)]
pub fn rel_flag(op: u8) -> (r: u8)
    requires 63 <= op <= 66,
    ensures r == relational_flag(op),
{
    if op == 63 { 8 } else if op == 65 { 16 } else if op == 64 { 128 } else { 64 }
}

} // verus!
