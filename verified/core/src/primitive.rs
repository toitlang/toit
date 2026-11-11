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
use crate::prims::{self, PrimOutcome};
use toit_spec::v2::prim::PrimRet;
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
use toit_spec::v2::sound::{wf, step_ok, outcome_ok, cur_op, good};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::{with_heap2, prim_success, prim_missing, completes, plain_args, prim_spec,
    prim_returns, prim_complete, machine_completed, prim_args};
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
        reloaded(*old(m), g).refines(&env.p),
        sp::step(env.p.ap@, g) == Outcome2::Primitive(g, module, index),
        first == sp::base(g),
        arity == sp::frame_height(g),
    ensures
        exists|gx: State2, v: Value| #[trigger] prim_call_post(&env.p, *final(m), g, module, index, r.0, r.1, gx, v),
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
        handler_pre(&env.p, *old(m), bci, opcode),
        opcode == 89,
        bci + 4 < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    let p = &env.p;
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
    // A core primitive the policy resolves to the VM's own entry with the
    // method's arity: its Rust port, if there is one (no GC point, no save
    // and reload).
    if module == 0 && (index as usize) < env.core_arities.len()
        && env.core_arities.at(index as usize) as usize == arity + 1 {
        if let Some(r) = op_rust_primitive(m, env, index, arity) {
            return r;
        }
    }
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

/// A primitive's view of an argument: a block reference is the smi that
/// encodes it (`abs::block_word`), other values are themselves.
pub open spec fn norm_val(v: Value) -> Value {
    match v {
        Value::BlockRef(f, s) => Value::Smi((f * 0x1_0000 + s) as i64),
        _ => v,
    }
}

pub open spec fn norm_args(vs: Seq<Value>) -> Seq<Value> {
    Seq::new(vs.len(), |i: int| norm_val(vs[i]))
}

/// Without block references the primitive's view is the arguments.
proof fn lemma_norm_plain(vs: Seq<Value>)
    requires plain_args(vs),
    ensures norm_args(vs) == vs,
{
    assert(norm_args(vs) =~= vs) by {
        assert forall|i: int| 0 <= i < vs.len() implies norm_args(vs)[i] == vs[i] by {
            assert(!(vs[i] is BlockRef));
        }
    }
}

/// The array index of the first argument of the top frame (the arguments
/// are `mem[at]`, `mem[at - 1]`, ...).
pub open spec fn args_at(m: Machine) -> int {
    if m.base < m.len { m.len - 1 - m.base } else { 0 }
}

/// At a PRIMITIVE the Rust primitives' preconditions hold: the heap is the
/// one the abstraction describes (`prims::heap_inv`) and the frame's
/// parameters, block references as their smis, are at `args_at(m)`.
proof fn lemma_rust_args(p: &Program, m: Machine, arity: usize)
    requires
        m.inv(p),
        cur_op(p.ap@, m.g@) == 89,
        arity == sp::frame_height(m.g@),
        m.base == sp::base(m.g@),
    ensures
        prims::heap_inv(p, &m.heap),
        prims::args_ok(&m.mem, args_at(m), &m.heap, norm_args(prim_args(p.ap@, m.g@))),
        norm_args(prim_args(p.ap@, m.g@)).len() == arity,
        args_at(m) < m.len,
{
    let ap = p.ap@;
    let c = p.cert@;
    let g = m.g@;
    let h = m.heap;
    let vs = prim_args(ap, g);
    let nv = norm_args(vs);
    reveal(wf);
    toit_spec::v2::sound_prim::lemma_prim_facts(ap, c, p.trusted@, g);
    toit_spec::v2::sound_instr::lemma_instr(ap, c, p.trusted@, g);
    m.lemma_frame(p);
    // The heap.
    assert forall|i: int| 0 <= i < h.objs().len() implies
        #[trigger] toit_spec::v2::sound::basic_obj_ok(ap, h.objs(), h.objs()[i]) by {
        reveal(toit_spec::v2::sound::heap_ok);
        assert(toit_spec::v2::sound::obj_ok(ap, c, g.heap, g.heap[i]));
    }
    // The arguments.
    let k = toit_spec::v2::sound_instr::cur_k(ap, c, g);
    assert(k.len() == arity);
    assert(vs.len() == arity);
    assert forall|j: int| 0 <= j < arity implies
        #[trigger] vs[j] is BlockRef || good(g.heap, vs[j]) by {
        let n = k.len() - 1 - j;
        toit_spec::v2::sound_instr::lemma_at_conf(ap, c, p.trusted@, g, n);
        assert(vs[j] == g.stack[sp::base(g) + j]);
        assert(sp::at(g, n) == g.stack[g.stack.len() - 1 - n]);
        reveal(toit_spec::v2::sound::conf);
        if !(vs[j] is BlockRef) {
            if toit_spec::v2::verifier::top_kind(k, n) is Token && vs[j] == sp::null2(ap) {
                toit_spec::v2::sound_prim::lemma_consts_good(ap, g.heap, 0);
            }
        }
    }
    let at = args_at(m);
    assert forall|j: int| 0 <= j < nv.len() implies
        m.mem@[at - j] == enc(h.addrs(), #[trigger] nv[j])
        && good(h.objs(), nv[j]) && encodable(h.addrs(), nv[j]) by {
        assert(g.stack[sp::base(g) + j] == vs[j]);
        assert(m.words()[sp::base(g) + j] == enc(h.addrs(), g.stack[sp::base(g) + j]));
        assert(encodable(h.addrs(), g.stack[sp::base(g) + j]));
        match vs[j] {
            Value::BlockRef(f, s) => {
                assert(nv[j] == Value::Smi((f * 0x1_0000 + s) as i64));
            },
            _ => {},
        }
    }
}

/// `m1` is `m0` with a heap the primitive left (`prims::heap_post`: only
/// as `prim_heap_ok` allows, no object moved) and the ghost state with that
/// heap: it refines it.
proof fn lemma_refines_heap(p: &Program, m0: Machine, m1: Machine)
    requires
        m0.refines(p),
        prims::heap_post(p, &m0.heap, &m1.heap),
        m1.mem == m0.mem, m1.globals == m0.globals,
        m1.len == m0.len, m1.top == m0.top, m1.ftop == m0.ftop, m1.rtop == m0.rtop,
        m1.bci == m0.bci, m1.base == m0.base, m1.lim == m0.lim, m1.method == m0.method,
        m1.g@ == with_heap2(m0.g@, m1.heap.objs()),
    ensures m1.refines(p),
{
    let g0 = m0.g@;
    let a0 = m0.heap.addrs();
    let a1 = m1.heap.addrs();
    let o0 = m0.heap.objs();
    let o1 = m1.heap.objs();
    assert(heap_model_ok(o0, a0, m0.heap.class_bits()));
    assert(a0.len() == o0.len());
    assert forall|i: int| 0 <= i < g0.stack.len() implies
        enc(a1, #[trigger] g0.stack[i]) == enc(a0, g0.stack[i]) && encodable(a1, g0.stack[i]) by {
        let v = g0.stack[i];
        assert(encodable(a0, v));
        match v {
            Value::Obj(id) => { assert(a1.subrange(0, a0.len() as int)[id as int] == a0[id as int]); },
            _ => {},
        }
    }
    assert(m1.words() =~= enc_seq(a1, m1.g@.stack));
    assert forall|i: int| 0 <= i < g0.globals.len() implies
        enc(a1, #[trigger] g0.globals[i]) == enc(a0, g0.globals[i]) && encodable(a1, g0.globals[i]) by {
        let v = g0.globals[i];
        assert(encodable(a0, v));
        match v {
            Value::Obj(id) => { assert(a1.subrange(0, a0.len() as int)[id as int] == a0[id as int]); },
            _ => {},
        }
    }
    assert(m1.globals@ =~= enc_seq(a1, m1.g@.globals));
}

/// Runs the Rust port of core primitive `index` (`prims::call`) on the
/// frame's parameters and completes the step as the protocol says:
/// success returns the result from the frame, failure pushes it. No GC
/// point: the machine's cached state stays valid (no save, no reload).
/// `None` when there is no port for these arguments (`NotPorted`) or an
/// allocation did not fit (`NeedsGc`): the machine is unchanged and the
/// caller calls the C++ primitive, which collects garbage and retries as
/// the C++ protocol does.
#[inline(always)]
fn op_rust_primitive(m: &mut Machine, env: &Env, index: u16, arity: usize) -> (r: Option<Ctl>)
    requires
        old(m).inv(&env.p),
        cur_op(env.p.ap@, old(m).g@) == 89,
        sp::step(env.p.ap@, old(m).g@) == Outcome2::Primitive(old(m).g@, 0, index),
        arity == sp::frame_height(old(m).g@),
        old(m).base == sp::base(old(m).g@),
        old(m).bci + 4 < 0x1000_0000,
    ensures
        r is None ==> *final(m) == *old(m),
        r is Some ==> step_post(&env.p, *old(m), *final(m), r->Some_0),
{
    let p = &env.p;
    let ghost ap = p.ap@;
    let ghost g = m.g@;
    let ghost m0 = *m;
    let ghost vs = prim_args(ap, g);
    proof {
        lemma_rust_args(p, *m, arity);
        m.lemma_frame(p);
        lemma_shape(p, g);
    }
    let at = if m.base < m.len { m.len - 1 - m.base } else { 0 };
    let al = env.rt.allocator();
    let (r, v) = prims::call(0, index, &m.mem, at, arity, &mut m.heap, p, &al, Ghost(norm_args(vs)));
    match r {
        PrimOutcome::Success(w) => {
            let ghost h2 = m.heap.objs();
            m.g = Ghost(with_heap2(g, h2));
            proof {
                lemma_refines_heap(p, m0, *m);
                lemma_completion(p, g, index, h2, PrimRet::Success(v@), vs);
                crate::raise::lemma_shape_same(p, g, m.g@);
            }
            let ghost o = prim_success(ap, g, h2, v@);
            proof {
                lemma_source_completion(ap, g, 0, index, o);
                lemma_source_outcome(p, m0, o);
            }
            let ctl = m.do_return(env, w, Ghost(v@));
            proof { lemma_outcome_matches(p, m0, *m, ctl, o); }
            Some(ctl)
        },
        PrimOutcome::Failure(w) => {
            let ghost h2 = m.heap.objs();
            m.g = Ghost(with_heap2(g, h2));
            proof {
                lemma_refines_heap(p, m0, *m);
                lemma_completion(p, g, index, h2, PrimRet::Failure(v@), vs);
            }
            let ghost o = sp::next(sp::push(with_heap2(g, h2), v@), 4);
            proof {
                lemma_source_completion(ap, g, 0, index, o);
                lemma_source_outcome(p, m0, o);
            }
            let ctl = m.push_next(p, w, 4, Ghost(v@));
            proof { lemma_outcome_matches(p, m0, *m, ctl, o); }
            Some(ctl)
        },
        _ => None,
    }
}

/// A ported outcome of core primitive `index` (`prims::call` on the
/// arguments' primitive view) is one the spec's protocol allows for the
/// arguments themselves (`prim_returns`): the precise contracts apply to
/// plain arguments, where the views agree; otherwise only the default
/// contract, which does not depend on the arguments.
proof fn lemma_completion(p: &Program, g: State2, index: u16, h2: Seq<HeapObj>, r: PrimRet, vs: Seq<Value>)
    requires
        vs == prim_args(p.ap@, g),
        prim_spec(p.ap@, 0, index, norm_args(vs), g.heap, h2, r),
        !machine_completed(0, index),
    ensures
        prim_returns(p.ap@, g, 0, index, h2, r),
        completion(p.ap@, g, 0, index, prim_complete(p.ap@, g, h2, r)),
{
    if plain_args(vs) { lemma_norm_plain(vs); }
    assert(prim_spec(p.ap@, 0, index, vs, g.heap, h2, r));
    assert(prim_returns(p.ap@, g, 0, index, h2, r));
    assert(prim_returns(p.ap@, g, 0, index, h2, r)
        && prim_complete(p.ap@, g, h2, r) == prim_complete(p.ap@, g, h2, r));
}

/// A missing primitive (`prim::prim_missing`): raises
/// PRIMITIVE_LOOKUP_FAILED with the module and index as message.
fn op_prim_missing(m: &mut Machine, env: &Env, module: u8, index: u16) -> (r: Ctl)
    requires
        old(m).inv(&env.p),
        sp::step(env.p.ap@, old(m).g@) == Outcome2::Primitive(old(m).g@, module, index),
        old(m).bci < 0x1000_0000,
    ensures step_post(&env.p, *old(m), *final(m), r),
{
    proof {
        assert(completion(env.p.ap@, m.g@, module, index, prim_missing(env.p.ap@, m.g@)));
        lemma_source_completion(env.p.ap@, m.g@, module, index, prim_missing(env.p.ap@, m.g@));
    }
    let ghost vs = seq![Value::Smi(0), Value::Smi(0)];
    m.raise_k(env, 4, V2_MESSAGE_PRIMITIVE, [module as usize, index as usize, 0, 0], 2, Ghost(vs))
}

} // verus!
