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

//! The loop steps on registers (proposal, verified/spec/format/
//! 19-builtins-proposal.md): LOOP_REPEAT and LOOP_ARRAY. Each refines
//! `spec::op_loop_repeat` / `op_loop_array`: either the taken step (the
//! counter incremented, the top popped, the block and a value pushed, a
//! backward branch) or the fall-through (the top popped). No heap writes;
//! LOOP_ARRAY reads the array through the heap view's checked accessors.

use vstd::prelude::*;
use crate::layout::*;
use crate::view::*;
use crate::abs::*;
use crate::exec::*;
use crate::regs::*;
use toit_spec::types::Value;
use toit_spec::v2::types::{State2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::as1;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{is_array, elements};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_helpers::smi_val;
#[cfg(verus_keep_ghost)]
use crate::arrays::{vals_good, val_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::good;

verus! {

/// The state after a taken loop step: counter `n` becomes `i + 1`, the top
/// is popped, the block (slot `n + 1`) and `v` are pushed, the bci is
/// `target`.
pub open spec fn taken_state(g: State2, n: int, i: i64, v: Value, target: int) -> State2 {
    sp::goto(sp::push(sp::push(sp::drop(sp::put(g, n, Value::Smi((i + 1) as i64)), 1), sp::at(g, n + 1)), v), target)
}

/// The taken step on registers: `wn` is the word of `i + 1`, `wv` the word
/// of `v`.
#[inline(always)]
fn taken_r(m: &mut Machine, r: &mut Regs, p: &Program, n: usize, wn: usize, wv: usize, d: usize,
    Ghost(i): Ghost<i64>, Ghost(v): Ghost<Value>, Ghost(target): Ghost<usize>)
    requires
        rpre(p, *old(m), *old(r)),
        1 <= n, sp::has_slot(old(m).g@, n + 1),
        smi_range(i + 1), wn == smi_word((i + 1) as i64),
        encodable(old(m).addr(), v), wv == enc(old(m).addr(), v),
        d <= old(r).ip@,
        old(r).ip@ < 0x1000_0000,
        target as int == old(r).ip@ - d,
    ensures
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), Outcome2::Next(taken_state(old(m).g@, n as int, i, v, target as int))),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    let ghost vb = sp::at(g0, n + 1);
    proof {
        m0.lemma_at(p, n as int);
        m0.lemma_at(p, n + 1);
        m0.lemma_at(p, 0);
        lemma_smi_word((i + 1) as i64);
    }
    let wb = at(m, r, n + 1);
    r.sp.write(n, wn, &mut m.mem);
    r.sp.write(0, wb, &mut m.mem);
    let s = r.sp.offset(-1);
    s.write(0, wv, &mut m.mem);
    r.sp = s;
    r.ip = r.ip.offset(-(d as isize));
    let ghost g1 = taken_state(g0, n as int, i, v, target as int);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        let hh = m0.height();
        assert(m0.words().len() == enc_seq(m0.addr(), g0.stack).len());
        assert(g0.stack.len() == hh);
        assert(m1.words() =~= m0.words().update(hh - 1 - n, wn).update(hh - 1, wb).push(wv));
        assert(enc(m0.addr(), Value::Smi((i + 1) as i64)) == wn);
        assert(g1.stack =~= g0.stack.update(hh - 1 - n, Value::Smi((i + 1) as i64)).update(hh - 1, vb).push(v));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            if j < hh - 1 && j != hh - 1 - n { assert(g1.stack[j] == g0.stack[j]); }
        }
        lemma_local(p, m0, m1, g1);
    }
}

/// The fall-through: pops the top, continues after the 4-byte step.
#[inline(always)]
fn fall_r(m: &mut Machine, r: &mut Regs, p: &Program)
    requires
        rpre(p, *old(m), *old(r)),
        sp::has_slot(old(m).g@, 1),
        old(r).ip@ + 4 < 0x1000_0000,
    ensures
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::next(sp::drop(old(m).g@, 1), 4)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    proof { m0.lemma_at(p, 0); }
    r.sp = r.sp.offset(1);
    r.ip = r.ip.offset(4);
    let ghost g1 = sp::goto(sp::drop(g0, 1), g0.bci + 4);
    m.g = Ghost(g1);
    proof {
        let m1 = m.with(*r);
        assert(g1.stack =~= g0.stack.subrange(0, g0.stack.len() - 1));
        assert(m1.words() =~= m0.words().subrange(0, m0.height() - 1));
        assert(m1.words() =~= enc_seq(m0.addr(), g1.stack));
        assert forall|j: int| 0 <= j < g1.stack.len() implies #[trigger] encodable(m0.addr(), g1.stack[j]) by {
            assert(g1.stack[j] == g0.stack[j]);
        }
        lemma_local(p, m0, m1, g1);
    }
}

/// LOOP_REPEAT n: counter slot `n`, block `n + 1`, limit `n + 2`; the taken
/// step branches back by `d` (to `target`, inside the method by the spec).
#[inline(always)]
pub fn op_loop_repeat(m: &mut Machine, r: &mut Regs, p: &Program, n: usize, d: usize, Ghost(target): Ghost<usize>) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        !(sp::op_loop_repeat(p.ap@, old(m).g@, target as int, n as int, 4) is Stuck),
        sp::at(old(m).g@, n as int) is Smi || sp::at(old(m).g@, n as int) is Obj,
        sp::at(old(m).g@, n as int + 2) is Smi || sp::at(old(m).g@, n as int + 2) is Obj,
        old(r).ip@ + 4 < 0x1000_0000,
        d <= old(r).ip@,
        target as int == old(r).ip@ - d,
        n < 256,
    ensures
        c == Ctl::Next,
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::op_loop_repeat(p.ap@, old(m).g@, target as int, n as int, 4)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    let ghost vc = sp::at(g0, n as int);
    let ghost vl = sp::at(g0, n + 2);
    proof {
        assert(sp::loop_slots_ok(g0, n as int, n + 1, n + 2, n + 2));
        m0.lemma_at(p, n as int);
        m0.lemma_at(p, n + 2);
    }
    let wc = at(m, r, n);
    let wl = at(m, r, n + 2);
    proof {
        crate::ops::lemma_tag(m0, p, wc, vc);
        crate::ops::lemma_tag(m0, p, wl, vl);
        crate::ops::lemma_or_tag(wc, wl);
        if vc is Smi { lemma_smi_word(vc->Smi_0); }
        if vl is Smi { lemma_smi_word(vl->Smi_0); }
    }
    if (wc | wl) & 1 == 0 && (wc as isize) < (wl as isize) {
        let ghost i = vc->Smi_0;
        proof {
            assert(i < vl->Smi_0);
            lemma_smi_word((i + 1) as i64);
        }
        // counter < limit, so counter + 1 is a smi; its word is the
        // counter's plus 2.
        let wn = ((wc as isize) + 2) as usize;
        taken_r(m, r, p, n, wn, wc, d, Ghost(i), Ghost(vc), Ghost(target));
        proof {
            assert(sp::op_loop_repeat(p.ap@, g0, target as int, n as int, 4)
                == Outcome2::Next(taken_state(g0, n as int, i, vc, target as int)));
        }
        Ctl::Next
    } else {
        fall_r(m, r, p);
        Ctl::Next
    }
}

/// LOOP_ARRAY n: counter slot `n`, block `n + 1`, end `n + 2`, array
/// `n + 3`.
#[inline(always)]
pub fn op_loop_array(m: &mut Machine, r: &mut Regs, p: &Program, n: usize, d: usize, Ghost(target): Ghost<usize>) -> (c: Ctl)
    requires
        rpre(p, *old(m), *old(r)),
        vals_good(old(m).g@.heap),
        !(sp::op_loop_array(p.ap@, old(m).g@, target as int, n as int, 4) is Stuck),
        sp::at(old(m).g@, n as int) is Smi || sp::at(old(m).g@, n as int) is Obj,
        sp::at(old(m).g@, n as int + 2) is Smi || sp::at(old(m).g@, n as int + 2) is Obj,
        sp::at(old(m).g@, n as int + 3) is Smi || sp::at(old(m).g@, n as int + 3) is Obj,
        old(r).ip@ + 4 < 0x1000_0000,
        d <= old(r).ip@,
        target as int == old(r).ip@ - d,
        n < 256,
    ensures
        c == Ctl::Next,
        rsame(*old(m), *final(m)),
        rnext(p, *final(m), *final(r), sp::op_loop_array(p.ap@, old(m).g@, target as int, n as int, 4)),
{
    let ghost m0 = m.with(*r);
    let ghost g0 = m.g@;
    let ghost s = as1(g0);
    let ghost vc = sp::at(g0, n as int);
    let ghost ve = sp::at(g0, n + 2);
    let ghost va = sp::at(g0, n + 3);
    proof {
        assert(sp::loop_slots_ok(g0, n as int, n + 1, n + 2, n + 3));
        m0.lemma_at(p, n as int);
        m0.lemma_at(p, n + 2);
        m0.lemma_at(p, n + 3);
    }
    let wc = at(m, r, n);
    let we = at(m, r, n + 2);
    proof {
        crate::ops::lemma_tag(m0, p, wc, vc);
        crate::ops::lemma_tag(m0, p, we, ve);
        crate::ops::lemma_or_tag(wc, we);
        if vc is Smi { lemma_smi_word(vc->Smi_0); }
        if ve is Smi { lemma_smi_word(ve->Smi_0); }
    }
    if (wc | we) & 1 == 0 && (wc as isize) >= 0 && (wc as isize) < (we as isize) {
        let ghost i = vc->Smi_0;
        proof {
            assert(0 <= i < ve->Smi_0);
            lemma_smi_word((i + 1) as i64);
            assert(m.hrefines(p));
        }
        let wa = at(m, r, n + 3);
        proof { assert(val_ok(*m, wa, va)) by { assert(good(g0.heap, va)); } }
        let iu = ((wc as isize) >> 1usize) as usize;
        proof { assert(iu == i); }
        match m.array_x(p, wa, Ghost(va)) {
            Some(len) => {
                if iu < len {
                    let ghost id = va->Obj_0 as int;
                    let ghost x = elements(s, va)[i as int];
                    proof {
                        crate::arrays::lemma_val(p, *m, wa, va);
                        assert(obj_model_ok(g0.heap[id], m.heap.class_bits(), m.addr()));
                        assert(encodable(m.addr(), x));
                    }
                    let wx = m.heap.element(wa, iu, Ghost(id));
                    let wn = ((wc as isize) + 2) as usize;
                    taken_r(m, r, p, n, wn, wx, d, Ghost(i), Ghost(x), Ghost(target));
                    proof {
                        assert(sp::loop_array_go(g0, n as int, n + 2, n + 3));
                        assert(sp::op_loop_array(p.ap@, g0, target as int, n as int, 4)
                            == Outcome2::Next(taken_state(g0, n as int, i, x, target as int)));
                    }
                    return Ctl::Next;
                }
            },
            None => {},
        }
    }
    proof { assert(!sp::loop_array_go(g0, n as int, n + 2, n + 3)); }
    fall_r(m, r, p);
    Ctl::Next
}

} // verus!
