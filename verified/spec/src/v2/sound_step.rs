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

//! Preservation and progress for one step: the dispatch over the opcode
//! families.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_instr::*;

verus! {

/// Every step from a well-formed state of an accepted program is not
/// stuck, keeps the invariant, and so do the completions of a PRIMITIVE.
pub proof fn lemma_step(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s),
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    lemma_families(op);
    if fam_local(op) {
        crate::v2::sound_local_ops::lemma_step_local(p, c, trusted, s);
    } else if fam_field(op) {
        crate::v2::sound_field::lemma_step_field(p, c, trusted, s);
    } else if fam_block(op) {
        crate::v2::sound_block::lemma_step_block(p, c, trusted, s);
    } else if fam_call(op) {
        crate::v2::sound_call_ops::lemma_step_call(p, c, trusted, s);
    } else if fam_virtual(op) {
        crate::v2::sound_virtual::lemma_step_virtual(p, c, trusted, s);
    } else if fam_tail(op) {
        crate::v2::sound_tail::lemma_step_tail(p, c, trusted, s);
    } else if fam_unwind(op) {
        crate::v2::sound_unwind_ops::lemma_step_unwind(p, c, trusted, s);
    } else {
        crate::v2::sound_prim::lemma_step_prim(p, c, trusted, s);
    }
}

} // verus!
