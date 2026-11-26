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

//! The resource throws (`v2::prim::resource_throw`: stack overflow, out of
//! memory) keep the invariant.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_instr::*;
use crate::v2::sound_unwind::*;
use crate::v2::sound_raise::*;
use crate::v2::sound_virtual::*;
use crate::v2::prim::*;
use crate::v2::bytecodes::TRY;

verus! {

/// The state a resource throw starts from is well formed and small: `s`,
/// or at a TRY the try block's entry (the step's outcome).
pub proof fn lemma_resource_state(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s),
    ensures
        wf(p, c, resource_state(p, s)), small(resource_state(p, s)),
        resource_state(p, s).heap == s.heap,
{
    let s0 = resource_state(p, s);
    if s0 != s {
        lemma_instr(p, c, trusted, s);
        assert(cur_op(p, s) == TRY);
        crate::v2::sound_call_ops::lemma_step_try(p, c, trusted, s);
        assert(step(p, s) == op_try(p, s)) by { reveal(step); }
        assert(op_try(p, s) == Outcome2::Next(s0));
        assert(wf(p, c, s0));
        let slot = s.stack.len() - 1;
        let t = block_target(p, s, slot)->0;
        let s1 = push(s, Value::BlockRef(top_index(s) as usize, slot as usize));
        assert(try_call(p, s1, t, s.bci + 1) == Outcome2::Next(s0));
        assert(s0.heap == s.heap);
    }
}

/// Every resource throw of a well-formed state is a good outcome (a raise
/// whose completions are all good, or a completed outcome).
pub proof fn lemma_resource(p: Program2, c: Cert, trusted: bool, s: State2, o: Outcome2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), resource_throw(p, s, o),
    ensures outcome_ok(p, c, o), !(o is Primitive),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let s0 = resource_state(p, s);
    lemma_resource_state(p, c, trusted, s);
    assert(crate::v2::exec::wf_program2(p));
    assert(consts_ok(p, s0.heap)) by { reveal(wf); }
    if (grows_stack(op) || allocates_instance(op)) && o == unwind(p, s0, Unwind::Throw(out_of_memory(p))) {
        assert(good(s0.heap, p.roots[ROOT_OUT_OF_MEMORY]));
        lemma_wf_unw(p, c, trusted, s0);
        assert(unw_arg_ok(p, c, s0, kinds_of(p, c, s0, top_i(s0)), Unwind::Throw(out_of_memory(p)))) by {
            reveal(pending_ok);
        }
        lemma_unwind_wf(p, c, trusted, s0, Unwind::Throw(out_of_memory(p)));
    } else if grows_stack(op) && o == Outcome2::Raise(s0, p.roots[ROOT_STACK_OVERFLOW]) {
        assert(good(s0.heap, p.roots[ROOT_STACK_OVERFLOW]));
        lemma_raise_value(p, c, trusted, s0, p.roots[ROOT_STACK_OVERFLOW]);
    } else {
        assert(allocates_double(p, s, op) && o == operator_fallback(p, s, op));
        lemma_op_site(p, c, trusted, s);
    }
}

/// Language level (format note 23, "Resource failures at TRY"): a resource
/// failure never skips a finally whose try was reached. At a TRY of an
/// accepted program, every resource throw starts in the try block, whose
/// frame carries the handler flag, right above the TRY's frame and
/// returning to the instruction after the TRY: the unwinding of the error
/// pops it first and so enters the TRY's finally code (`unwind`,
/// `enter_finally`) with a pending throw.
pub proof fn lemma_try_resource_finally(p: Program2, c: Cert, trusted: bool, s: State2, o: Outcome2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s), resource_throw(p, s, o),
        cur_op(p, s) == TRY,
        s.stack.len() + 1 < 0x4000_0000, s.frames.len() + 1 < 0x4000_0000,
    ensures ({
        let s0 = resource_state(p, s);
        &&& s0.frames.len() == s.frames.len() + 1
        &&& s0.frames.drop_last() == s.frames
        &&& top(s0).handler
        &&& top(s0).ret == s.bci + 1
        &&& top(s0).base == s.stack.len()
        &&& s0.stack.drop_last() == s.stack
        &&& (o == unwind(p, s0, Unwind::Throw(out_of_memory(p)))
             || o == Outcome2::Raise(s0, p.roots[ROOT_STACK_OVERFLOW]))
        // The unwinding of an exception from the try block (or from it after
        // the heap changed: the exception's allocation, a collection) enters
        // the TRY's finally code.
        &&& forall|s2: State2, x: Value| s2.frames == s0.frames && s2.stack.len() == s0.stack.len() ==>
                #[trigger] unwind(p, s2, Unwind::Throw(x))
                    == enter_finally(p, pop_frame(s2), s.stack.len() as int, s.bci + 1, Some(Unwind::Throw(x)))
    }),
{
    lemma_instr(p, c, trusted, s);
    crate::v2::sound_call_ops::lemma_step_try(p, c, trusted, s);
    assert(step(p, s) == op_try(p, s)) by { reveal(step); }
    assert(op_try(p, s) is Next);
    let slot = s.stack.len() - 1;
    let t = block_target(p, s, slot)->0;
    let s1 = push(s, Value::BlockRef(top_index(s) as usize, slot as usize));
    let s0 = op_try(p, s)->Next_0;
    assert(try_call(p, s1, t, s.bci + 1) == Outcome2::Next(s0));
    assert(arity(p, t) == 1);
    assert(s0.frames.len() == s.frames.len() + 1);
    assert(resource_state(p, s) == s0);
    assert(s0.frames.drop_last() =~= s.frames);
    assert(s0.stack.drop_last() =~= s.stack);
    assert(!allocates_double(p, s, TRY));
    assert forall|s2: State2, x: Value| s2.frames == s0.frames && s2.stack.len() == s0.stack.len() implies
        #[trigger] unwind(p, s2, Unwind::Throw(x))
            == enter_finally(p, pop_frame(s2), s.stack.len() as int, s.bci + 1, Some(Unwind::Throw(x))) by {
        assert(top(s2) == top(s0));
        assert(unw_target(Unwind::Throw(x)) == -1);
    }
}

} // verus!
