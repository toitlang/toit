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

//! HALT, verified (`spec::op_halt`): HALT 0 yields after pushing 91 (the
//! task continues later from the spec's halted state), HALT 1 exits with
//! the smi on the stack, HALT 2 enters deep sleep, HALT 3 resets. The
//! operand of HALT 1 is a value (the verifier's `value_operands`), so a
//! word with a clear low bit is a smi. HALT 1 of a heap object raises
//! INVALID_PROGRAM (the verified raise, raise.rs).
//!
//! Also the operand lemmas the other handler families of this branch use.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::calls::handler_pre;
use toit_spec::types::Value;
use toit_spec::v2::types::{State2, Program2, Outcome2, Halt2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, cur_op};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, lemma_at_good, cur_k};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, value_operands, is_val, top_kind};

verus! {

// ---------------------------------------------------------------------------
// Operands.

/// Operand `i` of an instruction whose top `n` operands are values (the
/// verifier's `value_operands`) is a smi or an object.
pub proof fn lemma_value_operand(p: &Program, g: State2, n: int, i: int)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        value_operands(cur_k(p.ap@, p.cert@, g), n),
        0 <= i < n,
    ensures
        sp::has_slot(g, i),
        sp::at(g, i) is Smi || sp::at(g, i) is Obj,
{
    let k = cur_k(p.ap@, p.cert@, g);
    assert(is_val(top_kind(k, i)));
    lemma_at_good(p.ap@, p.cert@, p.trusted@, g, i);
}

/// The word of an encodable value: its low bit is set exactly for objects;
/// a smi word is the smi shifted left.
pub proof fn lemma_word_tag(m: &Machine, p: &Program, w: usize, v: Value)
    requires
        m.hrefines(p),
        w == enc(m.addr(), v),
        encodable(m.addr(), v),
    ensures
        (w & 1 == 1) == (v is Obj),
        (w & 1 == 0) == !(v is Obj),
        v is Obj ==> w & 3 == 1 && (v->Obj_0 as int) < m.g@.heap.len(),
        v is Smi ==> w == smi_word(v->Smi_0) && smi_range(v->Smi_0 as int)
            && word_smi(w) == v->Smi_0,
{
    match v {
        Value::Smi(i) => { lemma_smi_word(i); },
        Value::Obj(id) => { lemma_obj_not_smi(m.heap.objs(), m.addr(), id); },
        Value::BlockRef(f, s) => {
            lemma_smi_word((f * 0x1_0000 + s) as i64);
        },
        Value::Token(_, d, _, _) => { lemma_token_vals(d); },
        _ => {},
    }
}

// ---------------------------------------------------------------------------
// HALT.

/// The operand of HALT 1 is a value.
proof fn lemma_halt_exit(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        cur_op(p.ap@, g) == 100,
        p.ap@.bytecodes[g.bci + 1] == 1,
    ensures
        sp::has_slot(g, 0),
        sp::at(g, 0) is Smi || sp::at(g, 0) is Obj,
{
    lemma_instr(p.ap@, p.cert@, p.trusted@, g);
    assert(value_operands(cur_k(p.ap@, p.cert@, g), 1));
    lemma_value_operand(p, g, 1, 0);
}

/// HALT code (`spec::op_halt`).
#[inline(always)]
pub fn op_halt(m: &mut Machine, env: &Env, bci: usize, opcode: u8, code: usize) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        opcode == 100,
        code == env.p.ap@.bytecodes[bci + 1],
        sp::step(env.p.ap@, old(m).g@) == sp::op_halt(env.p.ap@, old(m).g@, code as int),
        bci + 2 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof { assert(outcome_ok(ap, p.cert@, sp::step(ap, g))); }
    if code == 0 {
        // Yield: the task continues after the instruction with 91 pushed.
        proof { lemma_smi_word_nat(91); }
        let w = smi_of(91);
        let r = m.push_next(p, w, 2, Ghost(Value::Smi(91)));
        match r {
            Ctl::Next => {},
            _ => { return r; },
        }
        let r = Ctl::Exit(RESULT_YIELDED as u32, 0);
        proof { lemma_matches(p, m0, *m, r); }
        r
    } else if code == 1 {
        proof {
            lemma_halt_exit(p, g);
            m.lemma_at(p, 0);
            lemma_word_tag(m, p, m.mem@[m.top as int], sp::at(g, 0));
        }
        let w = m.at(0);
        if w & 1 != 0 {
            // INVALID_PROGRAM.
            proof {
                assert(sp::step(ap, g) == sp::raise(ap, g, sp::INVALID_PROGRAM));
                lemma_source_step(ap, g);
            }
            return m.v_raise_invalid(env);
        }
        let v = smi_value(w);
        m.drop(1);
        m.bci = bci + 2;
        let r = Ctl::Exit(RESULT_TERMINATED as u32, v);
        proof { lemma_matches(p, m0, *m, r); }
        r
    } else if code == 2 {
        proof {
            m.lemma_at(p, 0);
            lemma_word_tag(m, p, m.mem@[m.top as int], sp::at(g, 0));
        }
        let w = m.at(0);
        let duration = if w & 1 == 0 {
            smi_value(w)
        } else {
            let ghost id = sp::at(g, 0)->Obj_0 as int;
            proof { assert(obj_model_ok(m.g@.heap[id], m.heap.class_bits(), m.addr())); }
            if m.heap.class_tag(w, Ghost(id)) == LARGE_INTEGER_TAG {
                m.heap.large_int(w, Ghost(id))
            } else {
                0
            }
        };
        m.drop(1);
        m.bci = bci + 2;
        let r = Ctl::Exit(RESULT_DEEP_SLEEP as u32, duration);
        proof { lemma_matches(p, m0, *m, r); }
        r
    } else {
        m.bci = bci + 2;
        let r = Ctl::Exit(RESULT_RESET as u32, 0);
        proof { lemma_matches(p, m0, *m, r); }
        r
    }
}

} // verus!
