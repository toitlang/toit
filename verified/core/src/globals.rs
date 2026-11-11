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

//! Lazy and dynamic globals, verified.
//!
//! LOAD_GLOBAL_VAR_LAZY(_WIDE) (`spec::op_load_global_lazy`): a value that
//! is not a lazy initializer is pushed; an initializer is replaced by the
//! call of the `run_global_initializer` entry point with the index and the
//! initializer (`spec::call_static`, like INVOKE_STATIC: room for the frame
//! first, then the receiver check of the entry method, whose receiver is
//! the index smi). The verifier's `entry_ok` gives the entry method and
//! its arity (2); a failing receiver check raises AS_CHECK_FAILED in the
//! state with the two arguments pushed (raise.rs, `v_raise_none_from`).
//!
//! LOAD_GLOBAL_VAR_DYNAMIC and STORE_GLOBAL_VAR_DYNAMIC
//! (`spec::op_load_global_dynamic`, `spec::op_store_global_dynamic`): the
//! index operand is a value (the verifier's `value_operands`), so a word
//! with a clear low bit is a smi; the spec checks that it is a smi in range
//! (INVALID_PROGRAM otherwise, the verified raise), and so does the
//! handler.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
#[cfg(verus_keep_ghost)]
use crate::halt::{lemma_value_operand, lemma_word_tag};
#[cfg(verus_keep_ghost)]
use crate::calls::handler_pre;
use toit_spec::types::Value;
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, cur_op};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound_instr::{lemma_instr, cur_k};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{accepts, value_operands, tables_ok, entry_ok};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{smi, builtin, LAZY_INITIALIZER_CLASS, RUN_GLOBAL_INITIALIZER};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::{p1, as1};

verus! {

/// The operands of the dynamic global instructions are values: the index
/// of LOAD_GLOBAL_VAR_DYNAMIC (slot 0), the index and the value of
/// STORE_GLOBAL_VAR_DYNAMIC (slots 1 and 0).
pub proof fn lemma_dynamic_operands(p: &Program, g: State2)
    requires
        accepts(p.ap@, p.cert@, p.trusted@), wf(p.ap@, p.cert@, g),
        cur_op(p.ap@, g) == 34 || cur_op(p.ap@, g) == 37,
    ensures
        sp::has_slot(g, 0),
        sp::at(g, 0) is Smi || sp::at(g, 0) is Obj,
        cur_op(p.ap@, g) == 37 ==> sp::has_slot(g, 1) && (sp::at(g, 1) is Smi || sp::at(g, 1) is Obj),
{
    lemma_instr(p.ap@, p.cert@, p.trusted@, g);
    let k = cur_k(p.ap@, p.cert@, g);
    if cur_op(p.ap@, g) == 34 {
        assert(value_operands(k, 1));
        lemma_value_operand(p, g, 1, 0);
    } else {
        assert(value_operands(k, 2));
        lemma_value_operand(p, g, 2, 0);
        lemma_value_operand(p, g, 2, 1);
    }
}

impl Machine {
    /// The value `v` (word `w`) is a lazy initializer (`spec::is_lazy`).
    #[inline(always)]
    pub fn is_lazy_word(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: bool)
        requires
            self.hrefines(p),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
        ensures r == sp::is_lazy(p.ap@, self.g@, v),
    {
        proof { lemma_word_tag(self, p, w, v); }
        if w & 1 == 0 {
            return false;
        }
        let ghost id = v->Obj_0 as int;
        proof { assert(obj_model_ok(self.g@.heap[id], self.heap.class_bits(), self.addr())); }
        let cid = self.heap.class_id(w, Ghost(id));
        if cid != p.lazy_initializer_class_id {
            return false;
        }
        let tag = self.heap.class_tag(w, Ghost(id));
        tag == INSTANCE_TAG || tag == TASK_TAG
    }

    /// `spec::global_index` of the value `v` (word `w`, a smi or an object).
    #[inline(always)]
    pub fn dyn_global_index(&self, p: &Program, w: usize, Ghost(v): Ghost<Value>) -> (r: Option<usize>)
        requires
            self.hrefines(p),
            w == enc(self.addr(), v),
            encodable(self.addr(), v),
            v is Smi || v is Obj,
        ensures
            r is None ==> sp::global_index(self.g@, v) is None,
            r is Some ==> sp::global_index(self.g@, v) == Some(r->0 as int)
                && r->0 < self.g@.globals.len(),
    {
        proof {
            lemma_word_tag(self, p, w, v);
            assert(self.globals@.len() == enc_seq(self.addr(), self.g@.globals).len());
        }
        if w & 1 != 0 {
            return None;
        }
        let i = smi_value(w);
        if i < 0 || i as usize >= self.globals.len() {
            return None;
        }
        Some(i as usize)
    }
}

/// LOAD_GLOBAL_VAR_LAZY(_WIDE) gi (`spec::op_load_global_lazy`).
#[inline(always)]
pub fn op_load_global_lazy(m: &mut Machine, env: &Env, bci: usize, opcode: u8, gi: usize, len: usize) -> (r: Ctl)
    requires
        handler_pre(&env.p, *old(m), bci, opcode),
        toit_spec::v2::prim::grows_stack(opcode),
        sp::step(env.p.ap@, old(m).g@) == sp::op_load_global_lazy(env.p.ap@, old(m).g@, gi as int, len as int),
        gi < 0x1_0000,
        bci + len < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        assert(m.globals@.len() == enc_seq(m.addr(), g.globals).len());
        assert(enc_seq(m.addr(), g.globals)[gi as int] == enc(m.addr(), g.globals[gi as int]));
    }
    let ghost v = g.globals[gi as int];
    let w = m.globals.at(gi);
    if !m.is_lazy_word(p, w, Ghost(v)) {
        let r = m.push_next(p, w, len, Ghost(v));
        proof { lemma_matches(p, m0, *m, r); }
        return r;
    }
    if let Some(c) = ensure_room(m, env) {
        return c;
    }
    // The entry method (`entry_ok`: a method of arity 2).
    proof {
        assert(tables_ok(ap, p.cert@));
        assert(entry_ok(ap, p.cert@, RUN_GLOBAL_INITIALIZER, 2));
        assert(ap.entry_points.len() == 9);
    }
    let d = p.entry_points.at(ENTRY_RUN_GLOBAL_INITIALIZER);
    let t = p.dispatch.at(d as usize) as usize;
    let info = p.method(t);
    let ghost g2 = sp::push(sp::push(g, smi(gi as int)), v);
    proof {
        assert(t as int == sp::entry_method(ap, RUN_GLOBAL_INITIALIZER));
        assert(ap.methods[t as int] == method_info(p.minfo(t as int), p.max_height));
        assert(sp::at(g2, 1) == smi(gi as int));
        assert(toit_spec::spec_common::class_id_of(p1(ap), as1(g2), smi(gi as int)) == p.smi_class_id);
    }
    let ghost m1 = *m;
    proof { lemma_smi_word_nat(gi as i64); }
    let wi = smi_of(gi as i64);
    let _ = m.push(wi);
    let _ = m.push(w);
    m.g = Ghost(g2);
    proof {
        assert(m.words() =~= enc_seq(m1.addr(), g2.stack));
        assert forall|i: int| 0 <= i < g2.stack.len() implies #[trigger] encodable(m1.addr(), g2.stack[i]) by {
            if i < g.stack.len() { assert(g2.stack[i] == g.stack[i]); }
        }
        m1.lemma_local_step(p, m);
    }
    // The receiver (the index smi) is in the entry method's receiver range.
    if info.recv_start != NO_VALUE {
        let cid = p.smi_class_id;
        if !((info.recv_start as usize) <= cid && cid < info.recv_end as usize) {
            proof {
                assert(sp::step(ap, g) == sp::raise(ap, g2, sp::AS_CHECK_FAILED));
                lemma_source_step(ap, g);
                crate::calls::lemma_shape(p, g);
                crate::raise::lemma_shape_stack(p, g, g2);
            }
            return m.v_raise_none_from(env, Ghost(m0), 1);
        }
    }
    proof { assert(sp::step(ap, g) == sp::call(ap, g2, t as int, bci + len)); }
    let r = m.push_call(env, t, bci + len);
    proof { lemma_matches(p, m0, *m, r); }
    r
}

} // verus!
