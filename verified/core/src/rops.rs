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

//! The operators on registers (DESIGN.md "Run loop"): INVOKE_EQ, the
//! relational operators, the arithmetic and bit operators (opcodes
//! 62..=77) and IDENTICAL, with the proofs of `ops.rs`.
//!
//! Natively: two smis (the inline fast paths of `ops.rs`), the number
//! comparisons of doubles and large integers, equality of identical
//! operands and null, IDENTICAL of any two values (`numbers.rs`, on the
//! heap part of the machine), and the arithmetic of two doubles
//! (`arith_double`, out of line: the allocation of the result is a GC
//! point, after which `room::regain` re-derives the registers). The virtual
//! call of the operator's selector (`spec::operator_fallback`) is
//! `rcalls::op_invoke_virtual`, which takes the call's fast path.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use crate::room::*;
use crate::step::*;
use crate::ops::{smi_arith_word, bool_word, rel_flag};
#[cfg(verus_keep_ghost)]
use crate::ops::{lemma_operands, lemma_tag, lemma_or_tag};
use toit_spec::types::{Value, HeapObj};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::lemma_instr;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{smi, is_double, double_bits, new_double};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_helpers::{smi_val, identical, is_nan_bits};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_step::{smi_arith, relational_smi, float_arith};

verus! {

// ---------------------------------------------------------------------------
// The result.

/// Replaces the two operands by the encoding `w` of `v` and continues after
/// the instruction (`spec::binary_result`).
#[inline(always)]
pub fn rbinary_next(m: &mut Machine, r: &mut Regs, p: &Program, w: usize, Ghost(v): Ghost<Value>)
    requires
        m_ok(p, *old(m), *old(r)),
        sp::has_slot(old(m).g@, 1),
        w == enc(old(m).addr(), v),
        encodable(old(m).addr(), v),
        old(r).ip@ + 1 < 0x1000_0000,
    ensures
        rnext(p, *final(m), *final(r), sp::binary_result(old(m).g@, v)),
        rsame(*old(m), *final(m)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, 1); m0.lemma_frame(p); }
    r.sp.write(1, w, &mut m.mem);
    r.sp = r.sp.offset(1);
    r.ip = r.ip.offset(1 as isize);
    let ghost g1 = sp::goto(sp::push(sp::drop(g0, 2), v), g0.bci + 1);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let h = g0.stack.len();
        assert forall|i: int| 0 <= i < h - 1 implies #[trigger] m1.words()[i] == enc(m0.addr(), g1.stack[i]) by {
            if i < h - 2 {
                assert(m1.words()[i] == m0.words()[i]);
                assert(m0.words()[i] == enc_seq(m0.addr(), g0.stack)[i]);
            }
        }
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|i: int| 0 <= i < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[i]) by {
            if i < h - 2 { assert(g1.stack[i] == g0.stack[i]); }
        }
        lemma_local(p, m0, m1, g1);
    }
}

/// A step inside the top frame that implements the spec's step ends the
/// handler: `rpost` with `Next`.
pub proof fn lemma_rnext_post(p: &Program, m0: Machine, r0: Regs, m1: Machine, r1: Regs)
    requires
        rinv(p, m0, r0),
        step_ok(p.ap@, p.cert@, m0.g@),
        rnext(p, m1, r1, sp::step(p.ap@, m0.g@)),
        rsame(m0, m1),
    ensures rpost(p, m0, r0, m1, r1, Ctl::Next),
{
    lemma_matches(p, m0.with(r0), m1.with(r1), Ctl::Next);
    lemma_room_same(p, m0.with(r0), m1.with(r1));
}

/// The virtual call of the operator's selector (`spec::operator_fallback`).
#[inline(always)]
pub fn rfallback(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        62 <= opcode <= 79,
        toit_spec::v2::prim::grows_stack(opcode),
        opcode != 97,
        sp::step(env.p.ap@, old(m).g@) == sp::operator_fallback(env.p.ap@, old(m).g@, opcode),
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    proof { assert(env.p.ap@.invoke_offsets.len() == 19); }
    let sel = env.p.invoke_offsets.at((opcode - 62) as usize) as i64;
    let n = if opcode == 79 { 3 } else { 2 };
    crate::rcalls::op_invoke_virtual(m, r, env, bci, opcode, sel, n, 1)
}

// ---------------------------------------------------------------------------
// Handlers.

/// INVOKE_EQ (`spec::op_invoke_eq`): two smis are equal exactly if their
/// words are; identical operands (equal unless a NaN), null and the number
/// comparison natively; else the virtual call of `==`.
#[inline(always)]
pub fn op_invoke_eq(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_eq(env.p.ap@, old(m).g@),
        opcode == 62,
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    let ghost v0 = sp::at(g, 1);
    let ghost v1 = sp::at(g, 0);
    let ghost s1 = as1(g);
    proof {
        lemma_operands(p, g);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
    }
    let a0 = at(m, r, 1);
    let a1 = at(m, r, 0);
    proof {
        lemma_tag(w0, p, a0, v0);
        lemma_tag(w0, p, a1, v1);
        lemma_or_tag(a0, a1);
        lemma_enc_inj(g.heap, w0.addr(), v0, v1);
    }
    if (a0 | a1) & 1 == 0 {
        proof {
            assert(!is_double(s1, v0));
            assert(v0 != sp::null2(ap) && v1 != sp::null2(ap));
            assert(sp::op_invoke_eq(ap, g) == sp::binary_result(g, sp::boolean2(ap, v0 == v1)));
        }
        let w = bool_word(p, a0 == a1, Ghost(w0));
        rbinary_next(m, r, p, w, Ghost(sp::boolean2(ap, v0 == v1)));
        proof { lemma_rnext_post(p, m0, r0, *m, *r); }
        return Ctl::Next;
    }
    proof {
        assert(const_ok(g.heap, ap.roots[0]));
        lemma_enc_inj(g.heap, w0.addr(), v0, sp::null2(ap));
        lemma_enc_inj(g.heap, w0.addr(), v1, sp::null2(ap));
    }
    if a0 == a1 {
        let nan = match m.double_x(p, a0, Ghost(v0)) {
            Some(bits) => crate::numbers::nan_bits(bits),
            None => false,
        };
        let ghost bv = !(is_double(s1, v0) && is_nan_bits(double_bits(s1, v0)));
        proof { assert(sp::op_invoke_eq(ap, g) == sp::binary_result(g, sp::boolean2(ap, bv))); }
        let w = bool_word(p, !nan, Ghost(w0));
        rbinary_next(m, r, p, w, Ghost(sp::boolean2(ap, bv)));
        proof { lemma_rnext_post(p, m0, r0, *m, *r); }
        return Ctl::Next;
    }
    if a0 == p.null || a1 == p.null {
        proof { assert(sp::op_invoke_eq(ap, g) == sp::binary_result(g, sp::false2(ap))); }
        let w = bool_word(p, false, Ghost(w0));
        rbinary_next(m, r, p, w, Ghost(sp::boolean2(ap, false)));
        proof { lemma_rnext_post(p, m0, r0, *m, *r); }
        return Ctl::Next;
    }
    let cmp = m.compare_x(p, a0, Ghost(v0), a1, Ghost(v1));
    if cmp != 0 {
        let b = (cmp & 32) != 0;
        proof { assert(sp::op_invoke_eq(ap, g) == sp::binary_result(g, sp::boolean2(ap, b))); }
        let w = bool_word(p, b, Ghost(w0));
        rbinary_next(m, r, p, w, Ghost(sp::boolean2(ap, b)));
        proof { lemma_rnext_post(p, m0, r0, *m, *r); }
        return Ctl::Next;
    }
    proof { assert(sp::op_invoke_eq(ap, g) == sp::operator_fallback(ap, g, opcode)); }
    rfallback(m, r, env, bci, opcode)
}

/// INVOKE_LT, INVOKE_GT, INVOKE_LTE, INVOKE_GTE
/// (`spec::op_invoke_relational`): smi words as signed words are ordered
/// like the smis; other numbers by `compare_numbers`; else the virtual
/// call.
#[inline(always)]
pub fn op_invoke_relational(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_relational(env.p.ap@, old(m).g@, opcode),
        63 <= opcode <= 66,
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    let ghost v0 = sp::at(g, 1);
    let ghost v1 = sp::at(g, 0);
    proof {
        lemma_operands(p, g);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
    }
    let a0 = at(m, r, 1);
    let a1 = at(m, r, 0);
    proof {
        lemma_tag(w0, p, a0, v0);
        lemma_tag(w0, p, a1, v1);
        lemma_or_tag(a0, a1);
    }
    if (a0 | a1) & 1 == 0 {
        let x = a0 as isize;
        let y = a1 as isize;
        let b = if opcode == 63 { x < y } else if opcode == 64 { x > y } else if opcode == 65 { x <= y } else { x >= y };
        let ghost bv = relational_smi(opcode, smi_val(v0), smi_val(v1));
        proof {
            lemma_smi_word(v0->Smi_0);
            lemma_smi_word(v1->Smi_0);
            assert(b == bv);
            assert(sp::op_invoke_relational(ap, g, opcode) == sp::binary_result(g, sp::boolean2(ap, bv)));
        }
        let w = bool_word(p, b, Ghost(w0));
        rbinary_next(m, r, p, w, Ghost(sp::boolean2(ap, bv)));
        proof { lemma_rnext_post(p, m0, r0, *m, *r); }
        return Ctl::Next;
    }
    let cmp = m.compare_x(p, a0, Ghost(v0), a1, Ghost(v1));
    if cmp != 0 {
        let b = (cmp & rel_flag(opcode)) != 0;
        proof { assert(sp::op_invoke_relational(ap, g, opcode) == sp::binary_result(g, sp::boolean2(ap, b))); }
        let w = bool_word(p, b, Ghost(w0));
        rbinary_next(m, r, p, w, Ghost(sp::boolean2(ap, b)));
        proof { lemma_rnext_post(p, m0, r0, *m, *r); }
        return Ctl::Next;
    }
    proof { assert(sp::op_invoke_relational(ap, g, opcode) == sp::operator_fallback(ap, g, opcode)); }
    rfallback(m, r, env, bci, opcode)
}

/// INVOKE_BIT_OR .. INVOKE_MOD (`spec::op_invoke_arith`): the smi fast
/// path (`smi_arith_word`); ADD, SUB and MUL of two doubles allocate the
/// result (`arith_double`); anything else is the virtual call.
#[inline(always)]
pub fn op_invoke_arith(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_invoke_arith(env.p.ap@, old(m).g@, opcode),
        67 <= opcode <= 77,
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    let ghost v0 = sp::at(g, 1);
    let ghost v1 = sp::at(g, 0);
    proof {
        lemma_operands(p, g);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
    }
    let a0 = at(m, r, 1);
    let a1 = at(m, r, 0);
    proof {
        lemma_tag(w0, p, a0, v0);
        lemma_tag(w0, p, a1, v1);
        lemma_or_tag(a0, a1);
    }
    if (a0 | a1) & 1 == 0 {
        let ghost x = v0->Smi_0;
        let ghost y = v1->Smi_0;
        match smi_arith_word(opcode, a0, a1, Ghost(x), Ghost(y), Ghost(p1(ap))) {
            Some(w) => {
                let ghost v = smi(smi_arith(p1(ap), opcode, smi_val(v0), smi_val(v1))->0);
                proof { assert(sp::op_invoke_arith(ap, g, opcode) == sp::binary_result(g, v)); }
                rbinary_next(m, r, p, w, Ghost(v));
                proof { lemma_rnext_post(p, m0, r0, *m, *r); }
                return Ctl::Next;
            },
            None => {
                proof {
                    assert(!toit_spec::spec_helpers::are_floats(as1(g), v0, v1));
                    assert(sp::op_invoke_arith(ap, g, opcode) == sp::operator_fallback(ap, g, opcode));
                }
                return rfallback(m, r, env, bci, opcode);
            },
        }
    }
    if opcode == 73 || opcode == 74 || opcode == 75 {
        if let Some(x) = m.double_x(p, a0, Ghost(v0)) {
            if let Some(y) = m.double_x(p, a1, Ghost(v1)) {
                let bits = if opcode == 73 {
                    toit_spec::exec_step::x_double_add(x, y)
                } else if opcode == 74 {
                    toit_spec::exec_step::x_double_sub(x, y)
                } else {
                    toit_spec::exec_step::x_double_mul(x, y)
                };
                proof { assert(bits == float_arith(opcode, x, y)); }
                let (r2, c) = arith_double(m, *r, env, bci, opcode, bits);
                crate::regs::set_regs(r, r2);
                return c;
            }
        }
    }
    proof { assert(sp::op_invoke_arith(ap, g, opcode) == sp::operator_fallback(ap, g, opcode)); }
    rfallback(m, r, env, bci, opcode)
}

/// Replaces the two operands by a new double with `bits` (a GC point, out
/// of line): the registers are written back, the double is allocated, and
/// `room::regain` derives the registers again. Out of memory is the
/// resource throw of the allocation (the operator's method is called, on
/// the machine, as `ops::op_new_double` does).
#[inline(never)]
pub fn arith_double(m: &mut Machine, r: Regs, env: &Env, bci: usize, opcode: u8, bits: u64) -> (res: (Regs, Ctl))
    requires
        rhandler_pre(&env.p, *old(m), r, bci, opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::binary_result(
            sp::alloc2(old(m).g@, new_double(as1(old(m).g@), p1(env.p.ap@), bits)), sp::new_ref2(old(m).g@)),
        sp::has_slot(old(m).g@, 1),
        toit_spec::v2::prim::allocates_double(env.p.ap@, old(m).g@, opcode),
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), r, *final(m), res.0, res.1),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost w0 = m.with(r);
    proof { assert(0 <= bci < ap.bytecodes.len()) by { lemma_instr(ap, p.cert@, p.trusted@, g); } }
    let ghost m00 = *old(m);
    // Inline in new space (no GC point): the registers stay.
    let wb = crate::alloc::bump_double(m, env, bits, Ghost(r), Ghost(g));
    if wb != 0 {
        let ghost g1 = sp::alloc2(g, new_double(as1(g), p1(ap), bits));
        m.g = Ghost(g1);
        proof {
            assert(m.with(r).refines(p));
            assert(m.rok(r));
            assert(m.addr().len() == g1.heap.len());
            assert(sp::has_slot(g1, 1));
        }
        let mut r2 = r;
        rbinary_next(m, &mut r2, p, wb, Ghost(sp::new_ref2(g)));
        proof { lemma_rnext_post(p, m00, r, *m, r2); }
        return (r2, Ctl::Next);
    }
    let len0 = m.len;
    m.sync(r, &env.p);
    m.save();
    proof { crate::alloc::lemma_saved(p, *m); }
    let (w, moved) = crate::alloc::gc_allocate_double(m, env, bits, Ghost(g));
    let ghost d = new_double(as1(g), p1(ap), bits);
    let ghost g2 = choose|g2: State2| #[trigger] crate::alloc::gc_alloc_post(p, *m, g, g2, d, w, moved);
    if w != 0 && !moved {
        // Nothing moved (the heap's epoch is unchanged): the registers stay.
        let ghost g1 = sp::alloc2(g, new_double(as1(g), p1(ap), bits));
        proof { assert(crate::alloc::reloaded(*m, g1) == (Machine { g: Ghost(g1), ..*m })); }
        m.g = Ghost(g1);
        proof {
            assert(m.with(r) == *m);
            assert(m.rok(r));
            assert(m.addr().len() == g1.heap.len());
            assert(sp::has_slot(g1, 1));
        }
        let mut r2 = r;
        rbinary_next(m, &mut r2, p, w, Ghost(sp::new_ref2(g)));
        proof { lemma_rnext_post(p, m00, r, *m, r2); }
        return (r2, Ctl::Next);
    }
    if w == 0 {
        // Out of memory after the collections: the resource throw of a
        // double allocation in the collected state, the call of the
        // operator's method (`prim::resource_throw`).
        crate::alloc::reload(m, p, Ghost(g2));
        let ghost m1 = *m;
        proof {
            crate::step::lemma_inv_gc(p, w0, m1);
            toit_spec::v2::gc::lemma_gc_steps_double(ap, g, g2, opcode);
            crate::step::lemma_unchecked_ok(p, g2);
            crate::step::lemma_small(p, &m1);
            toit_spec::v2::sound_step::lemma_step(ap, p.cert@, p.trusted@, g2);
            assert(toit_spec::v2::prim::resource_throw(ap, g2, sp::operator_fallback(ap, g2, opcode)));
            lemma_source_resource(ap, g2, sp::operator_fallback(ap, g2, opcode));
        }
        let c = crate::calls::fallback_src(m, env, bci, opcode);
        proof { toit_spec::v2::gc::lemma_gc_steps_refl(ap, g); }
        match crate::step::resume(m, env, c, Ghost(m1)) {
            (Some(r2), Ctl::Next) => {
                proof {
                    toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.with(r2).g@);
                    crate::step::lemma_steps_post_gc(p, w0, m1, m.with(r2), m.with(r2), Ctl::Next);
                }
                return (r2, Ctl::Next);
            },
            (_, c2) => {
                proof {
                    toit_spec::v2::gc::lemma_gc_steps_refl(ap, m.g@);
                    crate::step::lemma_steps_post_gc(p, w0, m1, *m, *m, c2);
                }
                return (r, c2);
            },
        }
    }
    // Allocated after the collections: the step, then the collections.
    let ghost g1 = sp::alloc2(g2, d);
    crate::alloc::reload(m, p, Ghost(g1));
    proof {
        toit_spec::v2::gc::lemma_gc_steps_shape(ap, g, g2);
        assert(m.addr().len() == g1.heap.len());
        assert(sp::has_slot(g1, 1));
    }
    let c = m.binary_next(p, w, Ghost(sp::new_ref2(g2)));
    proof {
        assert(sp::step(ap, g) == Outcome2::Next(toit_spec::v2::gc::alloc_push(g, d, 2, 1)));
        assert(m.g@ == toit_spec::v2::gc::alloc_push(g2, d, 2, 1));
        crate::step::lemma_alloc_gc(p, w0, *m, c, g2, d, 2, 1);
    }
    let ghost m2 = *m;
    match regain(m, env, len0, Ghost(w0)) {
        Some(r2) => {
            proof {
                toit_spec::v2::gc::lemma_gc_steps_refl(ap, g);
                crate::step::lemma_step_post_gc(p, w0, w0, m2, m.with(r2), Ctl::Next);
            }
            (r2, Ctl::Next)
        },
        None => (r, Ctl::Stuck(stuck::LIMIT)),
    }
}

/// IDENTICAL (`spec::identical`): equal words are identical values; a smi
/// is identical only to itself; two distinct heap objects compare by
/// contents for doubles, large integers and strings (`identical_slow`).
#[inline(always)]
pub fn op_identical(m: &mut Machine, r: &mut Regs, env: &Env, bci: usize, opcode: u8) -> (c: Ctl)
    requires
        rhandler_pre(&env.p, *old(m), *old(r), bci, opcode),
        sp::step(env.p.ap@, old(m).g@)
            == sp::binary_result(old(m).g@, sp::boolean2(env.p.ap@,
                identical(as1(old(m).g@), sp::at(old(m).g@, 1), sp::at(old(m).g@, 0)))),
        opcode == 96,
        bci + 1 < 0x1000_0000,
    ensures rpost(&env.p, *old(m), *old(r), *final(m), *final(r), c),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost r0 = *r;
    let ghost w0 = m.with(*r);
    let ghost v0 = sp::at(g, 1);
    let ghost v1 = sp::at(g, 0);
    proof {
        lemma_operands(p, g);
        w0.lemma_at(p, 0);
        w0.lemma_at(p, 1);
    }
    let a0 = at(m, r, 1);
    let a1 = at(m, r, 0);
    proof {
        lemma_tag(w0, p, a0, v0);
        lemma_tag(w0, p, a1, v1);
        lemma_or_tag(a0, a1);
    }
    let same = a0 == a1;
    let b = if same || (a0 & a1) & 1 == 0 {
        proof {
            lemma_enc_inj(g.heap, w0.addr(), v0, v1);
            assert(same == identical(as1(g), v0, v1));
        }
        same
    } else {
        m.identical_slow(p, a0, Ghost(v0), a1, Ghost(v1))
    };
    let w = bool_word(p, b, Ghost(w0));
    rbinary_next(m, r, p, w, Ghost(sp::boolean2(ap, b)));
    proof { lemma_rnext_post(p, m0, r0, *m, *r); }
    Ctl::Next
}

} // verus!
