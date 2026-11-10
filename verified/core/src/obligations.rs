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

//! The end-to-end statement the proof half of Phase 4 has to close
//! (OBLIGATIONS.md, item E2E). NOT PROVEN: `end_to_end_no_fatal` is an
//! `external_body` proof function, so Verus takes it as an axiom. Nothing
//! in the crate uses it; it is here so that the statement is written down
//! in the terms of the core and checked for well-formedness.
//!
//! The predicates are uninterpreted placeholders for definitions of the
//! spec crate (verified/spec), which the core crate cannot import yet
//! (verified/check.sh runs Verus on each crate alone):
//!
//! - `accepted`: `toit_spec::v2::verifier::accepts(pview(p))`, the
//!   structural verifier (Phase 3, `check::verify` proven equal to it).
//! - `loaded`: `loaded_ok` of verified/spec/SOUNDNESS.md for the program
//!   and the state the loader builds (heap and tables).
//! - `abstracts`: the abstraction function from the machine (object-stack
//!   words, frame records, heap words) to a `State2`, with `small` (the
//!   size bound of SOUNDNESS.md) holding.
//! - `reachable`: the abstract state is reachable by `spec::step` from the
//!   initial state.
//!
//! The intended proof: `theorem_soundness` gives "no reachable state is
//! stuck"; the per-handler refinement (handler result == `spec::step`
//! under `abstracts`) then shows the handler takes no `Ctl::Stuck` path.

use vstd::prelude::*;
use crate::exec::*;

verus! {

pub uninterp spec fn accepted(p: &Program) -> bool;

pub uninterp spec fn loaded(p: &Program) -> bool;

pub uninterp spec fn abstracts(p: &Program, m: &Machine) -> bool;

pub uninterp spec fn reachable(p: &Program, m: &Machine) -> bool;

/// The machine never takes a `Ctl::Stuck` path (a failed run-time check or
/// a fatal path) in its next step.
pub uninterp spec fn next_step_not_stuck(p: &Program, m: &Machine) -> bool;

/// UNPROVEN (OBLIGATIONS.md, E2E): for an accepted and loaded program,
/// every reachable machine state takes a step that is not stuck.
#[verifier::external_body]
pub proof fn end_to_end_no_fatal(p: &Program, m: &Machine)
    requires
        accepted(p),
        loaded(p),
        m.stack_ok(),
        abstracts(p, m),
        reachable(p, m),
    ensures
        next_step_not_stuck(p, m),
{
}

} // verus!
