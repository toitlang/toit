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

//! The loader's contract `loaded_ok` (`v2::sound`), checked on a loaded
//! program. `x_loaded_ok` (Verus) is proven to return exactly
//! `loaded_ok(vview(p), c@, heap, globals)`: object classes exist,
//! instances of classes with fields have their class's field count, every
//! reference in the heap, the roots, the literals and the globals is in
//! range, and the heap has no machine objects (suspended stacks, tasks).
//! The VM can run it on an untrusted launch next to `check::verify`.
//! `check_heap` (plain Rust) only wraps it for `toit_spec_verify` and
//! words the rejection.

use vstd::prelude::*;
use alloc::vec::Vec;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::sound::*;
use crate::v2::verifier::*;
use crate::v2::check::{x_is_field_class, x_ifc};
use crate::v2::vprog::*;
#[cfg(verus_only)]
use crate::v2::exec::wf_program2;

verus! {

/// The abstract heap of the exec objects.
pub open spec fn hview(heap: &Vec<ExecObj>) -> Seq<HeapObj> {
    heap@.map_values(|o: ExecObj| o@)
}

/// `v` is a value of a heap with `n` objects.
pub fn x_good(Ghost(h): Ghost<Seq<HeapObj>>, n: usize, v: Value) -> (r: bool)
    requires h.len() == n,
    ensures r == good(h, v),
{
    match v {
        Value::Smi(_) => true,
        Value::Obj(id) => id < n,
        _ => false,
    }
}

/// Every element of `vs` is a value of a heap with `n` objects.
pub fn x_all_good(Ghost(h): Ghost<Seq<HeapObj>>, n: usize, vs: &[Value]) -> (r: bool)
    requires h.len() == n,
    ensures r == forall|i: int| 0 <= i < vs@.len() ==> good(h, #[trigger] vs@[i]),
{
    let mut i = 0;
    while i < vs.len()
        invariant h.len() == n, 0 <= i <= vs.len(), forall|j: int| 0 <= j < i ==> good(h, #[trigger] vs@[j]),
        decreases vs.len() - i,
    {
        if !x_good(Ghost(h), n, vs[i]) {
            return false;
        }
        i += 1;
    }
    true
}

/// An object of the program heap (`loaded_obj_ok`).
pub fn x_loaded_obj_ok(p: &VProgram, Ghost(h): Ghost<Seq<HeapObj>>, n: usize, o: &ExecObj) -> (r: bool)
    requires wf_program2(vview(p)), h.len() == n,
    ensures r == loaded_obj_ok(vview(p), h, o@),
{
    let ghost pv = vview(p);
    let cl = o.class_id as usize;
    if cl >= p.class_bits.len() {
        return false;
    }
    if o.class_id == p.builtin[19] {
        return false;
    }
    let fc = x_is_field_class(p, cl as i64) && x_ifc(p, cl) >= 1;
    proof { assert(fc == (is_field_class(pv, o.class_id as int) && ifc(pv, o.class_id as int) >= 1)); }
    match &o.body {
        ExecBody::Instance(f) => {
            if fc && f.len() as u64 != x_ifc(p, cl) as u64 {
                return false;
            }
            x_all_good(Ghost(h), n, f.as_slice())
        },
        ExecBody::Array(e) => {
            if fc {
                return false;
            }
            x_all_good(Ghost(h), n, e.as_slice())
        },
        ExecBody::Stack(_, _) => false,
        ExecBody::Stack2(_, _, _, _, _) => false,
        _ => !fc,
    }
}

/// The heap part of the loader's contract. `Err(i)` names a failing
/// object, `Err(u64::MAX)` a heap too large or a bad root or literal.
pub fn x_loaded_heap_ok(p: &VProgram, heap: &Vec<ExecObj>) -> (r: Result<(), u64>)
    requires wf_program2(vview(p)),
    ensures r is Ok <==> loaded_heap_ok(vview(p), hview(heap)),
{
    let ghost h = hview(heap);
    let n = heap.len();
    if n >= 0x2000_0000 {
        return Err(u64::MAX);
    }
    let mut i = 0;
    while i < n
        invariant
            wf_program2(vview(p)), h == hview(heap), n == heap.len(), h.len() == n, 0 <= i <= n,
            forall|j: int| 0 <= j < i ==> loaded_obj_ok(vview(p), h, #[trigger] h[j]),
        decreases n - i,
    {
        proof { assert(h[i as int] == heap@[i as int]@); }
        if !x_loaded_obj_ok(p, Ghost(h), n, &heap[i]) {
            return Err(i as u64);
        }
        i += 1;
    }
    if !(x_all_good(Ghost(h), n, p.roots) && x_all_good(Ghost(h), n, p.literals)) {
        return Err(u64::MAX);
    }
    Ok(())
}

/// The loader's contract `loaded_ok` for a certificate with global count
/// `global_count` (the only part of the certificate it reads).
pub fn x_loaded_ok(p: &VProgram, global_count: u64, heap: &Vec<ExecObj>, globals: &Vec<Value>) -> (r: bool)
    requires wf_program2(vview(p)),
    ensures forall|c: Cert| c.global_count == global_count as int ==> r == #[trigger] loaded_ok(vview(p), c, hview(heap), globals@),
{
    let ghost h = hview(heap);
    if x_loaded_heap_ok(p, heap).is_err() {
        return false;
    }
    globals.len() as u64 == global_count && x_all_good(Ghost(h), heap.len(), globals.as_slice())
}

} // verus!

/// `toit_spec_verify`'s early check of the heap part of the loader's
/// contract, for the rejection message; the verdict uses `x_loaded_ok`.
#[cfg(not(verus_keep_ghost))]
pub fn check_heap(p: &VProgram, heap: &Vec<ExecObj>) -> Result<(), alloc::string::String> {
    if !crate::v2::check::x_wf_program2(p) {
        return Err(alloc::string::String::from("malformed program tables"));
    }
    match x_loaded_heap_ok(p, heap) {
        Err(i) if i == u64::MAX => Err(alloc::string::String::from("heap too large, or a bad reference in the roots or literals")),
        Err(i) => Err(alloc::format!("object {} is malformed, a machine object or dangling", i)),
        Ok(()) => Ok(()),
    }
}
