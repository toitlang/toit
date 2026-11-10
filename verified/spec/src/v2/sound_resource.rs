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

verus! {

/// Every resource throw of a well-formed state is a good outcome (a raise
/// whose completions are all good, or a completed outcome).
pub proof fn lemma_resource(p: Program2, c: Cert, trusted: bool, s: State2, o: Outcome2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), resource_throw(p, s, o),
    ensures outcome_ok(p, c, o), !(o is Primitive),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    assert(crate::v2::exec::wf_program2(p));
    assert(consts_ok(p, s.heap)) by { reveal(wf); }
    if (grows_stack(op) || allocates_instance(op)) && o == unwind(p, s, Unwind::Throw(out_of_memory(p))) {
        assert(good(s.heap, p.roots[ROOT_OUT_OF_MEMORY]));
        lemma_wf_unw(p, c, trusted, s);
        assert(unw_arg_ok(p, c, s, kinds_of(p, c, s, top_i(s)), Unwind::Throw(out_of_memory(p)))) by {
            reveal(pending_ok);
        }
        lemma_unwind_wf(p, c, trusted, s, Unwind::Throw(out_of_memory(p)));
    } else if grows_stack(op) && o == Outcome2::Raise(s, p.roots[ROOT_STACK_OVERFLOW]) {
        assert(good(s.heap, p.roots[ROOT_STACK_OVERFLOW]));
        lemma_raise_value(p, c, trusted, s, p.roots[ROOT_STACK_OVERFLOW]);
    } else {
        assert(allocates_double(p, s, op) && o == operator_fallback(p, s, op));
        lemma_op_site(p, c, trusted, s);
    }
}

} // verus!
