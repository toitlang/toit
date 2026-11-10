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

//! PRIMITIVE, verified against the spec's protocol (`v2::prim`, "The
//! PRIMITIVE protocol"; `theorem::completion`): the step checks the frame
//! (its parameters are the arguments); the machine looks the primitive up
//! (a missing or denied primitive, or one of another arity, raises
//! PRIMITIVE_LOOKUP_FAILED: `prim_missing`), calls it, and completes by
//! the status: SUCCESS returns the result from the frame, FAILURE pushes
//! it and continues after the instruction, THROW (memory ran out after the
//! collector's retries) raises the error.
//!
//! The call is C++ (`toit_v2_call_primitive`, a GC point that may switch
//! the task). Its leaf contract (`gc_call_primitive`) is the protocol
//! itself: the status, result and the state the views represent afterwards
//! are one of the spec's completions of the step (`theorem::completion`:
//! for an ordinary primitive the default contract `prim_default` /
//! `prim_spec` over the heap; for core.task_new and core.task_transfer the
//! machine's `task_step`). Lookup, the arity check, the completion and the
//! raise are proven.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::step::*;
use crate::calls::*;
use crate::ffi::PrimitiveRef;
use crate::alloc::reload;
#[cfg(verus_keep_ghost)]
use crate::alloc::{reloaded, lemma_saved};
use toit_spec::types::{Value, HeapObj};
use toit_spec::v2::types::{State2, Program2, Outcome2};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec as sp;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::p1;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, cur_op};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::{with_heap2, prim_success, prim_missing, completes};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::theorem::{completion, outcome};
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::u16_at;

verus! {

/// What the C++ call of primitive `(module, index)` in state `g` leaves:
/// status `st`, result word `w`, and machine `m` (to be reloaded) are a
/// completion of the PRIMITIVE step (`theorem::completion`):
///
/// * SUCCESS: `prim_success(g, h2, v)` (return `v` from the frame, heap
///   `h2`), the views representing `g` with heap `h2`;
/// * FAILURE: `next(push(gx, v), 4)` for the state `gx` the views
///   represent (`g` with a new heap; after a task switch, the resumed task);
/// * THROW: `Raise(g with heap h2, v)` (an out-of-memory error, a root).
pub open spec fn prim_call_post(p: &Program, m: Machine, g: State2, module: u8, index: u16, st: usize, w: usize,
    gx: State2, v: Value) -> bool
{
    let ap = p.ap@;
    &&& reloaded(m, gx).refines(p)
    &&& w == enc(m.addr(), v)
    &&& encodable(m.addr(), v)
    &&& st == V2_PRIMITIVE_SUCCESS ==> gx.frames == g.frames && gx.tries == g.tries && gx.stack == g.stack
            && gx.fins == g.fins && gx.bci == g.bci
            && completion(ap, g, module, index, prim_success(ap, g, gx.heap, v))
            && gx == with_heap2(g, gx.heap)
    &&& st == V2_PRIMITIVE_FAILURE ==> completion(ap, g, module, index, sp::next(sp::push(gx, v), 4))
            && gx.bci + 4 < 0x1000_0000
    &&& st != V2_PRIMITIVE_SUCCESS && st != V2_PRIMITIVE_FAILURE ==>
            gx == with_heap2(g, gx.heap)
            && completion(ap, g, module, index, Outcome2::Raise(gx, v))
            && const_ok(gx.heap, v)
}

/// TRUSTED (TRUSTED.md, "Primitives"): calls the C++ primitive `prim`,
/// found by `toit_v2_lookup_primitive(module, index)` with the method's
/// arity, on the frame's parameters (object-stack positions
/// `first..first + arity`). May GC and may switch the task. Afterwards the
/// status, the result and the state the views represent are a completion
/// of the step (`prim_call_post`): the spec's PRIMITIVE protocol, with the
/// default contract of every primitive (`prim::prim_default`) and the
/// machine's task primitives (`prim::task_step`).
#[verifier::external_body]
#[inline(always)]
pub fn gc_call_primitive(m: &mut Machine, env: &Env, prim: &PrimitiveRef, arity: usize, first: usize,
    Ghost(g): Ghost<State2>, Ghost(module): Ghost<u8>, Ghost(index): Ghost<u16>) -> (r: (usize, usize))
    requires
        reloaded(*old(m), g).refines(env.p),
        sp::step(env.p.ap@, g) == Outcome2::Primitive(g, module, index),
        first == sp::base(g),
        arity == sp::frame_height(g),
    ensures
        exists|gx: State2, v: Value| #[trigger] prim_call_post(env.p, *final(m), g, module, index, r.0, r.1, gx, v),
{
    m.call_primitive_raw(env, prim, arity, first)
}

/// Every completion of the step's PRIMITIVE is a source of outcomes.
pub proof fn lemma_source_completion(ap: Program2, g: State2, module: u8, index: u16, o1: Outcome2)
    requires
        sp::step(ap, g) == Outcome2::Primitive(g, module, index),
        completion(ap, g, module, index, o1),
    ensures source(ap, g, o1),
{
    assert forall|o2: Outcome2| completes(ap, o1, o2) implies #[trigger] outcome(ap, g, o2) by {
        assert(completion(ap, g, module, index, o1) && completes(ap, o1, o2));
        assert(exists|o: Outcome2| #[trigger] completion(ap, g, module, index, o) && completes(ap, o, o2));
        match sp::step(ap, g) {
            Outcome2::Primitive(s1, mo, ix) => {
                assert(s1 == g && mo == module && ix == index);
            },
            _ => {},
        }
    }
}

/// PRIMITIVE module index (`spec::step`'s `Outcome2::Primitive`, completed
/// by the protocol).
pub fn op_primitive(m: &mut Machine, env: &Env, bci: usize, opcode: u8) -> (r: Ctl)
    requires
        handler_pre(env.p, *old(m), bci, opcode),
        opcode == 89,
        bci + 4 < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    let p = env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    proof {
        toit_spec::v2::sound_instr::lemma_instr(ap, p.cert@, p.trusted@, g);
        reveal_with_fuel(toit_spec::v2::bytecodes::opcode_length2, 1);
        assert(outcome_ok(ap, p.cert@, sp::step(ap, g)));
        m.lemma_frame(p);
        lemma_shape(p, g);
    }
    let module = p.code.at(bci + 1);
    let index = code_u16(p, bci + 2) as u16;
    proof {
        assert(sp::step(ap, g) == Outcome2::Primitive(g, module, index)) by { reveal(sp::step); }
        assert(ap.methods[m.method as int] == method_info(p.methods@[m.method as int], p.max_height));
    }
    let arity = p.methods.at(m.method).arity as usize;
    let found = env.rt.lookup_primitive(module as usize, index as usize);
    let prim = match found {
        Some((prim, a)) => {
            if a != arity {
                return op_prim_missing(m, env, module, index);
            }
            prim
        },
        None => {
            return op_prim_missing(m, env, module, index);
        },
    };
    m.save();
    proof { lemma_saved(p, *m); }
    let base = m.base;
    let (st, w) = gc_call_primitive(m, env, &prim, arity, base, Ghost(g), Ghost(module), Ghost(index));
    let ghost (gx, v) = choose|gx: State2, v: Value| #[trigger] prim_call_post(p, *m, g, module, index, st, w, gx, v);
    reload(m, p, Ghost(gx));
    if st == V2_PRIMITIVE_SUCCESS {
        let ghost o = prim_success(ap, g, gx.heap, v);
        proof {
            lemma_source_completion(ap, g, module, index, o);
            lemma_source_outcome(p, m0, o);
            crate::raise::lemma_shape_same(p, g, gx);
        }
        let r = m.do_return(env, w, Ghost(v));
        proof { lemma_outcome_matches(p, m0, *m, r, o); }
        return r;
    }
    if st == V2_PRIMITIVE_FAILURE {
        let ghost o = sp::next(sp::push(gx, v), 4);
        proof {
            lemma_source_completion(ap, g, module, index, o);
            lemma_source_outcome(p, m0, o);
        }
        let r = m.push_next(p, w, 4, Ghost(v));
        proof { lemma_outcome_matches(p, m0, *m, r, o); }
        return r;
    }
    proof {
        lemma_source_completion(ap, g, module, index, Outcome2::Raise(gx, v));
        crate::raise::lemma_shape_same(p, g, gx);
    }
    m.raise_with(env, Ghost(m0), w, Ghost(v), V2_MESSAGE_NONE, [0, 0, 0, 0], 0, Ghost(Seq::empty()))
}

/// A missing primitive (`prim::prim_missing`): raises
/// PRIMITIVE_LOOKUP_FAILED with the module and index as message.
fn op_prim_missing(m: &mut Machine, env: &Env, module: u8, index: u16) -> (r: Ctl)
    requires
        old(m).inv(env.p),
        sp::step(env.p.ap@, old(m).g@) == Outcome2::Primitive(old(m).g@, module, index),
        old(m).bci < 0x1000_0000,
    ensures step_post(env.p, *old(m), *final(m), r),
{
    proof {
        assert(completion(env.p.ap@, m.g@, module, index, prim_missing(env.p.ap@, m.g@)));
        lemma_source_completion(env.p.ap@, m.g@, module, index, prim_missing(env.p.ap@, m.g@));
    }
    let ghost vs = seq![Value::Smi(0), Value::Smi(0)];
    m.raise_k(env, 4, V2_MESSAGE_PRIMITIVE, [module as usize, index as usize, 0, 0], 2, Ghost(vs))
}

} // verus!
