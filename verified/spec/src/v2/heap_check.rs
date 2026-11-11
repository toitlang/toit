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
use crate::xvec::*;
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
        if !x_good(Ghost(h), n, ix(vs, i)) {
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
    if o.class_id == ix(p.builtin, 19) {
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

// ---------------------------------------------------------------------------
// The heap check, one object at a time.

/// `loaded_obj_ok` reads the heap only through `good`, i.e. its length.
pub proof fn lemma_loaded_obj_mono(p: Program2, h1: Seq<HeapObj>, h2: Seq<HeapObj>, o: HeapObj)
    requires loaded_obj_ok(p, h1, o), h1.len() <= h2.len(),
    ensures loaded_obj_ok(p, h2, o),
{
    match o.body {
        Body::Instance(f) => {
            assert forall|i: int| 0 <= i < f.len() implies good(h2, #[trigger] f[i]) by { assert(good(h1, f[i])); }
        },
        Body::Array(e) => {
            assert forall|i: int| 0 <= i < e.len() implies good(h2, #[trigger] e[i]) by { assert(good(h1, e[i])); }
        },
        _ => {},
    }
}

/// The objects of the program heap, in id order, from VM memory (the
/// trusted conversion, vmverify's `from_vm`), each with the number of
/// objects found so far (every reference in the objects so far is below
/// it).
pub trait ObjStream {
    fn next_obj(&mut self) -> Option<(ExecObj, usize)>;
}

/// `x_loaded_ok` without the heap in memory: checks the objects as `s`
/// yields them. Accepts only if the heap they form (`r.1`, the objects in
/// order) satisfies `loaded_ok` for every certificate with global count
/// `global_count`. An object is checked against the count `s` gives with
/// it; at the end every such count must be at most the number of objects,
/// so the checks hold for the whole heap (`lemma_loaded_obj_mono`).
pub fn x_loaded_ok_stream<S: ObjStream>(p: &VProgram, s: &mut S, global_count: u64, globals: &[Value]) -> (r: (bool, Ghost<Seq<HeapObj>>))
    requires wf_program2(vview(p)),
    ensures r.0 ==> forall|c: Cert| c.global_count == global_count as int ==> #[trigger] loaded_ok(vview(p), c, r.1@, globals@),
{
    let ghost pv = vview(p);
    let ghost mut h: Seq<HeapObj> = Seq::empty();
    let mut count: usize = 0;
    // The largest count an object was checked against.
    let mut bound: usize = 0;
    loop
        invariant
            wf_program2(pv), pv == vview(p), h.len() == count, count <= 0x2000_0000,
            forall|i: int| 0 <= i < count ==> loaded_obj_ok(pv, Seq::new(bound as nat, |j: int| h[i]), #[trigger] h[i]),
        ensures
            wf_program2(pv), pv == vview(p), h.len() == count, count < 0x2000_0000,
            forall|i: int| 0 <= i < count ==> loaded_obj_ok(pv, Seq::new(bound as nat, |j: int| h[i]), #[trigger] h[i]),
        decreases 0x2000_0000 - count,
    {
        if count >= 0x1fff_ffff {
            return (false, Ghost(h));
        }
        match s.next_obj() {
            None => break,
            Some((o, n)) => {
                let ghost hn = Seq::new(n as nat, |j: int| o@);
                if !x_loaded_obj_ok(p, Ghost(hn), n, &o) {
                    return (false, Ghost(h));
                }
                let new_bound = if n > bound { n } else { bound };
                proof {
                    assert forall|i: int| 0 <= i < count implies
                        loaded_obj_ok(pv, Seq::new(new_bound as nat, |j: int| h[i]), #[trigger] h[i]) by {
                        lemma_loaded_obj_mono(pv, Seq::new(bound as nat, |j: int| h[i]), Seq::new(new_bound as nat, |j: int| h[i]), h[i]);
                    }
                    lemma_loaded_obj_mono(pv, hn, Seq::new(new_bound as nat, |j: int| o@), o@);
                    h = h.push(o@);
                    assert forall|i: int| 0 <= i < count + 1 implies
                        loaded_obj_ok(pv, Seq::new(new_bound as nat, |j: int| h[i]), #[trigger] h[i]) by {
                        if i < count {
                            assert(h[i] == h.drop_last()[i]);
                        }
                    }
                }
                bound = new_bound;
                count += 1;
            },
        }
    }
    if bound > count {
        return (false, Ghost(h));
    }
    proof {
        assert forall|i: int| 0 <= i < h.len() implies loaded_obj_ok(pv, h, #[trigger] h[i]) by {
            lemma_loaded_obj_mono(pv, Seq::new(bound as nat, |j: int| h[i]), h, h[i]);
        }
    }
    if !(x_all_good(Ghost(h), count, p.roots) && x_all_good(Ghost(h), count, p.literals)) {
        return (false, Ghost(h));
    }
    let ok = globals.len() as u64 == global_count && x_all_good(Ghost(h), count, globals);
    proof {
        if ok {
            assert(count < 0x2000_0000);
            assert(consts_ok(pv, h));
            assert(loaded_heap_ok(pv, h));
            assert forall|c: Cert| c.global_count == global_count as int implies #[trigger] loaded_ok(vview(p), c, h, globals@) by {}
        }
    }
    (ok, Ghost(h))
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
