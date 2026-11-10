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

//! STUB

use vstd::prelude::*;
use crate::prims::*;
use toit_spec::types::Value;

verus! {

pub fn dispatch(i: usize, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(c.p, old(heap)), args_rel(a, old(heap)),
    ensures prim_post(c.p, old(heap), final(heap), r.0, r.1@),
{
    (PrimOutcome::NotPorted, Ghost(Value::Smi(0)))
}

} // verus!
