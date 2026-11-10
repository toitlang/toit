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

//! The precise primitive contracts of `v2::prim` (`smi_add`, `array_at`,
//! `array_at_put`) are satisfiable: on a well-formed heap the result they
//! prescribe also meets the default contract, so `prim_spec` is not empty
//! where it is refined. (The theorem does not need this; it validates the
//! shape of `prim_spec` for primitives ported to Rust later.)

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::prim::*;
#[cfg(verus_only)]
use crate::spec_common::{smi, smi_ok};

verus! {

/// An unchanged well-formed heap meets the heap part of the contract.
pub proof fn lemma_prim_heap_refl(p: Program2, c: Cert, h: Seq<HeapObj>)
    requires heap_ok(p, c, h), h.len() < 0x4000_0000,
    ensures prim_heap_ok(p, h, h),
{
    reveal(heap_ok);
    assert forall|i: int| 0 <= i < h.len() && #[trigger] h[i].class_id as int == task_class(p) implies
        task_fields_kept(h[i], h[i]) by { lemma_kept_refl(h[i]); }
    assert forall|i: int| 0 <= i < h.len() implies basic_obj_ok(p, h, #[trigger] h[i]) by {
        assert(obj_ok(p, c, h, h[i]));
    }
}

/// `smi_add` of two smis with a smi sum.
pub proof fn lemma_smi_add_spec(p: Program2, c: Cert, h: Seq<HeapObj>, a: i64, b: i64)
    requires heap_ok(p, c, h), h.len() < 0x4000_0000, smi_ok(p1(p), a + b),
    ensures prim_spec(p, 0, PRIM_SMI_ADD as u16, seq![Value::Smi(a), Value::Smi(b)], h, h,
        PrimRet::Success(smi(a + b))),
{
    lemma_prim_heap_refl(p, c, h);
}

/// `array_at` inside the array, and outside it.
pub proof fn lemma_array_at_spec(p: Program2, c: Cert, h: Seq<HeapObj>, arr: Value, i: i64, id: int, e: Seq<Value>)
    requires
        crate::v2::exec::wf_program2(p), heap_ok(p, c, h), consts_ok(p, h), h.len() < 0x4000_0000,
        array_of(h, arr) == Some((id, e)),
    ensures ({
        let args = seq![arr, Value::Smi(i)];
        &&& 0 <= i < e.len() ==>
                prim_spec(p, 0, PRIM_ARRAY_AT as u16, args, h, h, PrimRet::Success(e[i as int]))
        &&& !(0 <= i < e.len()) && -0x8000_0000 <= i < 0x8000_0000 ==>
                prim_spec(p, 0, PRIM_ARRAY_AT as u16, args, h, h, PrimRet::Failure(p.roots[ROOT_OUT_OF_BOUNDS]))
    }),
{
    lemma_prim_heap_refl(p, c, h);
    if 0 <= i < e.len() {
        reveal(heap_ok);
        assert(obj_ok(p, c, h, h[id]));
        assert(good(h, e[i as int]));
    }
}

/// `array_at_put` with an `int` index on an array of the program heap
/// fails with PERMISSION_DENIED (after decoding the index, as C++).
pub proof fn lemma_array_at_put_ro_spec(p: Program2, c: Cert, h: Seq<HeapObj>, arr: Value, i: i64, v: Value,
    id: int, e: Seq<Value>)
    requires
        heap_ok(p, c, h), h.len() < 0x4000_0000,
        array_of(h, arr) == Some((id, e)),
        h[id].ro,
        -0x8000_0000 <= i < 0x8000_0000,
        crate::v2::exec::wf_program2(p), consts_ok(p, h),
    ensures
        prim_spec(p, 0, PRIM_ARRAY_AT_PUT as u16, seq![arr, Value::Smi(i), v], h, h,
            PrimRet::Failure(p.roots[ROOT_PERMISSION_DENIED])),
{
    lemma_prim_heap_refl(p, c, h);
}

/// `array_at_put` inside a writable array stores the value.
pub proof fn lemma_array_at_put_spec(p: Program2, c: Cert, h: Seq<HeapObj>, arr: Value, i: i64, v: Value,
    id: int, e: Seq<Value>)
    requires
        heap_ok(p, c, h), h.len() < 0x4000_0000,
        array_of(h, arr) == Some((id, e)),
        !h[id].ro,
        0 <= i < e.len(),
        i < 0x8000_0000,
        good(h, v),
    ensures ({
        let h2 = h.update(id, HeapObj { body: Body::Array(e.update(i as int, v)), ..h[id] });
        prim_spec(p, 0, PRIM_ARRAY_AT_PUT as u16, seq![arr, Value::Smi(i), v], h, h2, PrimRet::Success(v))
    }),
{
    let o2 = HeapObj { body: Body::Array(e.update(i as int, v)), ..h[id] };
    let h2 = h.update(id, o2);
    reveal(heap_ok);
    assert(obj_ok(p, c, h, h[id]));
    assert forall|j: int| 0 <= j < h.len() implies {
        &&& (#[trigger] h2[j]).class_id == h[j].class_id
        &&& h[j].body is Stack2 ==> h2[j].body == h[j].body
        &&& !(h[j].body is Stack2) ==> !(h2[j].body is Stack2)
        &&& h[j].class_id as int == task_class(p) ==> task_fields_kept(h[j], h2[j])
    } by {
        if j != id { lemma_kept_refl(h[j]); }
    }
    assert forall|j: int| 0 <= j < h2.len() implies basic_obj_ok(p, h2, #[trigger] h2[j]) by {
        assert(obj_ok(p, c, h, h[j]));
        if j == id {
            assert forall|k: int| 0 <= k < e.len() implies good(h2, #[trigger] e.update(i as int, v)[k]) by {
                if k != i { assert(good(h, e[k])); }
            }
        } else {
            match h[j].body {
                Body::Instance(f) => {
                    assert forall|k: int| 0 <= k < f.len() implies good(h2, #[trigger] f[k]) by { assert(good(h, f[k])); }
                },
                Body::Array(f) => {
                    assert forall|k: int| 0 <= k < f.len() implies good(h2, #[trigger] f[k]) by { assert(good(h, f[k])); }
                },
                _ => {},
            }
        }
    }
    assert(prim_heap_ok(p, h, h2));
}

} // verus!
