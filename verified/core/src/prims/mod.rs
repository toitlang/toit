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

//! The primitives an untrusted program may call (docs/sandbox-policy.md),
//! ported to Rust and verified.
//!
//! Entry point: `call` (the dispatch table is `dispatch`). Its contract is
//! the oracle assumption of the soundness theorem (`sound::prim_heap_ok`,
//! the result a `good` value): for a heap the core's abstraction describes
//! (`heap_inv`) and arguments that encode values of it (`args_ok`), the
//! primitive
//!
//! - keeps `heap_inv` (the heap model stays well formed and related to the
//!   program, so the caller re-establishes `Machine::refines`),
//! - changes the heap only as `prim_heap_ok` allows and never moves an
//!   object (`heap_post`: the old addresses are a prefix of the new ones,
//!   so every word of the stack and globals keeps encoding its value),
//! - returns the encoding of an encodable `good` value on success and
//!   failure (`res_ok`),
//! - never reaches a GC point: an allocation that does not fit returns
//!   `NeedsGc` (the heap may have grown, still under `heap_post`); the
//!   caller collects garbage and calls the primitive again, as the C++
//!   primitive path does for `ALLOCATION_FAILED`,
//! - returns `NotPorted` without touching the heap for primitives (or
//!   cases of them) that stay in C++.
//!
//! Every heap access goes through the trusted views of `view.rs` with
//! their preconditions proven here; allocation goes through
//! `ffi::Allocator` (no GC). Behavior follows the C++ primitive of the
//! same name in src/primitive_core.cc, failures included (the error is the
//! program root the C++ `FAIL` names).
//!
//! The families: `ints` (smi and large-integer arithmetic, comparison and
//! bit operations), `array` (arrays and `list_add`), `blob` (byte arrays,
//! strings, blob helpers), `float` (doubles). The verified PRIMITIVE handler
//! (`primitive::op_primitive`) calls `call` where the policy resolves the VM's
//! own primitive.

use vstd::prelude::*;
use crate::layout::*;
use crate::abs::*;
use crate::exec::*;
use crate::view::*;
use crate::ffi::Allocator;
use crate::prims::index as ix;
use toit_spec::types::{Value, HeapObj, Body};
use toit_spec::v2::types::Program2;
use toit_spec::v2::prim::PrimRet;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim::{prim_spec, prim_default, prim_refined, resource_error, array_of};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::prim_core::{core_contract, int32_val, array_val};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{prim_heap_ok, basic_obj_ok, good, task_class, task_fields_kept};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::{task_class_ok, is_field_class, class_count, ifc};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::exec::wf_program2;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::types::p1;
#[cfg(verus_keep_ghost)]
use toit_spec::spec_common::{class_tag, instance_field_count, builtin, TASK_CLASS};

pub mod index;
pub mod ints;
pub mod array;
pub mod blob;
pub mod float;
pub mod fp;

verus! {

/// The result of a primitive.
pub enum PrimOutcome {
    /// Success: the result value's word (the primitive returns it).
    Success(usize),
    /// Failure: the error value's word (pushed; the Toit code after the
    /// `#primitive` handles it).
    Failure(usize),
    /// An allocation did not fit: collect garbage and call again.
    NeedsGc,
    /// Not ported (or a case of it that stays in C++): call the C++
    /// primitive. The heap is unchanged.
    NotPorted,
}

impl PrimOutcome {
    #[inline(always)]
    pub fn not_ported(&self) -> (r: bool)
        ensures r == (*self is NotPorted),
    {
        match self { PrimOutcome::NotPorted => true, _ => false }
    }
}

// ---------------------------------------------------------------------------
// The contract.

/// The heap as the core's abstraction describes it (the heap parts of
/// `Machine::refines`), plus the well-formedness of every object the
/// soundness proof keeps (`wf`) and the task class the verifier checks
/// (`accepts`).
pub open spec fn heap_inv(p: &Program, h: &Heap) -> bool {
    let objs = h.objs();
    let addr = h.addrs();
    &&& heap_model_ok(objs, addr, h.class_bits())
    &&& h.class_bits() == p.class_bits@
    &&& forall|i: int| 0 <= i < objs.len() ==> #[trigger] objs[i].ro == in_ro(p, addr[i])
    &&& prog_rel(p, objs, addr)
    &&& forall|i: int| 0 <= i < objs.len() ==> #[trigger] basic_obj_ok(p.ap@, objs, objs[i])
    &&& task_class_ok(p.ap@)
    &&& wf_program2(p.ap@)
}

/// The arguments: `vs[k]` is at `mem[at - k]` (object-stack position
/// `base + k` with `at = len - 1 - base`), each a value of the heap.
pub open spec fn args_ok(mem: &StackMem, at: int, h: &Heap, vs: Seq<Value>) -> bool {
    &&& vs.len() <= at + 1
    &&& at < mem@.len()
    &&& forall|k: int| 0 <= k < vs.len() ==> mem@[at - k] == enc(h.addrs(), #[trigger] vs[k])
    &&& forall|k: int| 0 <= k < vs.len() ==> good(h.objs(), #[trigger] vs[k])
            && encodable(h.addrs(), vs[k])
}

/// The heap after a primitive: still described by the abstraction, changed
/// only as `prim_heap_ok` allows, no object moved.
pub open spec fn heap_post(p: &Program, h0: &Heap, h1: &Heap) -> bool {
    &&& heap_inv(p, h1)
    &&& prim_heap_ok(p.ap@, h0.objs(), h1.objs())
    &&& h0.addrs().len() <= h1.addrs().len()
    &&& h1.addrs().subrange(0, h0.addrs().len() as int) == h0.addrs()
}

/// A result: the word of an encodable value of the heap.
pub open spec fn res_ok(h: &Heap, w: usize, v: Value) -> bool {
    &&& w == enc(h.addrs(), v)
    &&& good(h.objs(), v)
    &&& encodable(h.addrs(), v)
}

/// The contract of every primitive (`call` and each family's functions).
pub open spec fn prim_post(p: &Program, h0: &Heap, h1: &Heap, r: PrimOutcome, v: Value) -> bool {
    match r {
        PrimOutcome::Success(w) => heap_post(p, h0, h1) && res_ok(h1, w, v),
        PrimOutcome::Failure(w) => heap_post(p, h0, h1) && res_ok(h1, w, v),
        PrimOutcome::NeedsGc => *h1 == *h0,
        PrimOutcome::NotPorted => *h1 == *h0,
    }
}

/// The spec's view of an outcome (`prim::PrimRet`). `NeedsGc` is the
/// protocol's `OutOfMemory` with ALLOCATION_FAILED: the caller collects
/// garbage and calls again, and after its retries (the C++ protocol, as
/// the ALLOCATE handler's) completes the PRIMITIVE with that error. The
/// heap the last attempt leaves is a `prim_heap_ok` extension of the heap
/// before the first (`lemma_post_trans`, and a GC keeps the abstraction),
/// so the `OutOfMemory` outcome satisfies `prim_spec`.
pub open spec fn ret_of(p: &Program, r: PrimOutcome, v: Value) -> PrimRet {
    match r {
        PrimOutcome::Success(_) => PrimRet::Success(v),
        PrimOutcome::Failure(_) => PrimRet::Failure(v),
        _ => PrimRet::OutOfMemory(p.ap@.roots[ROOT_ALLOCATION_FAILED as int]),
    }
}

/// The per-primitive contract (`prim_core::core_contract`) of core
/// primitive `i`, for a ported outcome.
pub open spec fn contract(p: &Program, i: int, a: &Args, h0: &Heap, h1: &Heap, r: PrimOutcome, v: Value) -> bool {
    !(r is NotPorted) ==> core_contract(p.ap@, i, a.vs@, h0.objs(), h1.objs(), ret_of(p, r, v))
}

/// The primitive's arguments: the encoded words and their values.
pub struct Args {
    pub w: [usize; 6],
    pub n: usize,
    pub vs: Ghost<Seq<Value>>,
}

pub open spec fn args_rel(a: &Args, h: &Heap) -> bool {
    &&& a.n == a.vs@.len()
    &&& a.n <= 6
    &&& forall|k: int| 0 <= k < a.n ==> a.w@[k] == enc(h.addrs(), #[trigger] a.vs@[k])
    &&& forall|k: int| 0 <= k < a.n ==> good(h.objs(), #[trigger] a.vs@[k])
            && encodable(h.addrs(), a.vs@[k])
}

/// The context of a primitive call: the program and the allocator.
pub struct Ctx<'a> {
    pub p: &'a Program,
    pub al: &'a Allocator,
}

/// Runs primitive `module`:`index` with the `n` arguments at object-stack
/// array index `at` downwards (`mem[at]`, `mem[at - 1]`, ...).
#[inline(always)]
pub fn call(module: u8, index: u16, mem: &StackMem, at: usize, n: usize, heap: &mut Heap,
            p: &Program, al: &Allocator, Ghost(vs): Ghost<Seq<Value>>) -> (r: (PrimOutcome, Ghost<Value>))
    requires
        // Only a primitive the verified table (the policy's) allows.
        toit_spec::v2::verifier::prim_allowed(p.cert@.prim_arity, module as int, index as int),
        heap_inv(p, old(heap)),
        args_ok(mem, at as int, old(heap), vs),
        n == vs.len(),
    ensures
        prim_post(p, old(heap), final(heap), r.0, r.1@),
        // The protocol of the spec (prim::prim_returns): what the spec
        // allows the primitive to return (`prim_spec`: the default
        // contract refined per primitive, `prim_core::core_contract`).
        !(r.0 is NotPorted) ==>
            prim_spec(p.ap@, module, index, vs, old(heap).objs(), final(heap).objs(), ret_of(p, r.0, r.1@)),
        // The task primitives are completed by the machine (C++).
        toit_spec::v2::prim::machine_completed(module, index) ==> r.0 is NotPorted,
        // The ports of `never_falls_back` complete the primitive in Rust.
        module == 0 && never_falls_back(index as int, n as int) ==> completes(r.0),
{
    if module != 0 || n > 6 {
        return (PrimOutcome::NotPorted, Ghost(Value::Smi(0)));
    }
    let mut w = [0usize; 6];
    let mut k = 0;
    while k < n
        invariant
            k <= n, n <= 6, n == vs.len(), args_ok(mem, at as int, heap, vs),
            forall|j: int| 0 <= j < k ==> w@[j] == mem@[at - j],
            w@.len() == 6,
        decreases n - k,
    {
        w[k] = mem.read(at - k);
        k += 1;
    }
    let a = Args { w, n, vs: Ghost(vs) };
    proof {
        assert forall|k: int| 0 <= k < a.n implies a.w@[k] == enc(heap.addrs(), #[trigger] a.vs@[k]) by {
            assert(mem@[at - k] == enc(heap.addrs(), vs[k]));
        }
    }
    let ctx = Ctx { p, al };
    let ghost h0 = *heap;
    let r = dispatch(index, &a, heap, &ctx);
    proof {
        if !(r.0 is NotPorted) {
            lemma_default(p, &h0, heap, r.0, r.1@);
            assert forall|j: int| 0 <= j < h0.objs().len() && (#[trigger] h0.objs()[j]).body is Array
                implies h0.objs()[j].body->Array_0.len() < 0x4000_0000 by {
                assert(obj_model_ok(h0.objs()[j], h0.class_bits(), h0.addrs()));
            }
            assert(prog_rel(p, h0.objs(), h0.addrs()));
            lemma_refined(p, index, vs, h0.objs(), heap.objs(), ret_of(p, r.0, r.1@));
        }
    }
    r
}

/// The contract implies the spec's default contract.
pub proof fn lemma_default(p: &Program, h0: &Heap, h1: &Heap, r: PrimOutcome, v: Value)
    requires heap_inv(p, h0), prim_post(p, h0, h1, r, v), !(r is NotPorted),
    ensures prim_default(p.ap@, h0.objs(), h1.objs(), ret_of(p, r, v)),
{
    if r is NeedsGc { lemma_post_refl(p, h0); }
}

/// The per-primitive contracts imply the spec's examples (`prim_refined`),
/// with the same arguments (`prim_spec`).
pub proof fn lemma_refined(p: &Program, index: u16, vs: Seq<Value>, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet)
    requires
        core_contract(p.ap@, index as int, vs, h, h2, r),
        prim_default(p.ap@, h, h2, r),
        p.ap@.word_bits == WORD_BITS,
        forall|j: int| 0 <= j < h.len() && (#[trigger] h[j]).body is Array ==> h[j].body->Array_0.len() < 0x4000_0000,
    ensures
        prim_spec(p.ap@, 0, index, vs, h, h2, r),
{
    let ap = p.ap@;
    if index == 51 {
        lemma_smi_add_refined(ap, vs, h, h2, r);
    } else if index == 14 {
        lemma_array_at_refined(ap, vs, h, h2, r);
    } else if index == 15 {
        lemma_array_at_put_refined(ap, vs, h, h2, r);
    } else {
        assert(prim_refined(ap, 0, index, vs, h, h2, r));
    }
}

pub proof fn lemma_smi_add_refined(ap: Program2, vs: Seq<Value>, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet)
    requires
        toit_spec::v2::prim_core::int_binop_contract(ap, 0, false, vs, h, h2, r),
        ap.word_bits == WORD_BITS,
    ensures toit_spec::v2::prim::smi_add_spec(ap, vs, h, h2, r),
{
    if vs.len() == 2 {
        match (vs[0], vs[1]) {
            (Value::Smi(a), Value::Smi(b)) => {
                if toit_spec::spec_common::smi_ok(p1(ap), a + b) {
                    let z = a.wrapping_add(b);
                    assert(z == a + b);
                    assert(toit_spec::v2::prim_core::smi_in(z));
                    assert(toit_spec::v2::prim_core::int_op(0, a, b) == Some(z));
                }
            },
            _ => {},
        }
    }
}

pub proof fn lemma_array_at_refined(ap: Program2, vs: Seq<Value>, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet)
    requires toit_spec::v2::prim_core::array_at_contract(ap, vs, h, h2, r), forall|j: int| 0 <= j < h.len() && (#[trigger] h[j]).body is Array ==> h[j].body->Array_0.len() < 0x4000_0000,
    ensures toit_spec::v2::prim::array_at_spec(ap, vs, h, h2, r),
{
    if vs.len() == 2 {
        match vs[0] {
            Value::Obj(id) => {
                if (id as int) < h.len() {
                    match h[id as int].body { Body::Array(e) => {}, _ => {} }
                }
            },
            _ => {},
        }
    }
}

pub proof fn lemma_array_at_put_refined(ap: Program2, vs: Seq<Value>, h: Seq<HeapObj>, h2: Seq<HeapObj>, r: PrimRet)
    requires toit_spec::v2::prim_core::array_at_put_contract(ap, vs, h, h2, r), forall|j: int| 0 <= j < h.len() && (#[trigger] h[j]).body is Array ==> h[j].body->Array_0.len() < 0x4000_0000,
    ensures toit_spec::v2::prim::array_at_put_spec(ap, vs, h, h2, r),
{
    if vs.len() == 3 {
        match vs[0] {
            Value::Obj(id) => {
                if (id as int) < h.len() {
                    match h[id as int].body { Body::Array(e) => {}, _ => {} }
                }
            },
            _ => {},
        }
    }
}

/// The family of core primitive `i` that has a Rust port (1 integers, 2
/// arrays, 3 blobs, 4 floats; 0: none). The VM masks the primitives
/// without a port out of the core arities (`toit_v2_core_ported`), so that
/// their PRIMITIVE goes to C++ directly.
#[inline(always)]
pub fn family(i: usize) -> (f: u8)
    ensures
        (i == 115 || i == 116) ==> f == 0,
        forall|n: int| #[trigger] never_falls_back_ints(i as int, n) ==> f == 1,
        forall|n: int| #[trigger] never_falls_back_arrays(i as int, n) ==> f == 2,
        forall|n: int| #[trigger] never_falls_back_blobs(i as int, n) ==> f == 3,
        forall|n: int| #[trigger] never_falls_back_floats(i as int, n) ==> f == 4,
{
    match i {
        ix::SMI_ADD
            | ix::SMI_SUBTRACT
            | ix::SMI_MULTIPLY
            | ix::SMI_DIVIDE
            | ix::SMI_MOD
            | ix::SMI_AND
            | ix::SMI_OR
            | ix::SMI_XOR
            | ix::SMI_SHIFT_RIGHT
            | ix::SMI_UNSIGNED_SHIFT_RIGHT
            | ix::SMI_SHIFT_LEFT
            | ix::SMI_LESS_THAN
            | ix::SMI_LESS_THAN_OR_EQUAL
            | ix::SMI_GREATER_THAN
            | ix::SMI_GREATER_THAN_OR_EQUAL
            | ix::SMI_EQUALS
            | ix::LARGE_INTEGER_ADD
            | ix::LARGE_INTEGER_SUBTRACT
            | ix::LARGE_INTEGER_MULTIPLY
            | ix::LARGE_INTEGER_DIVIDE
            | ix::LARGE_INTEGER_MOD
            | ix::LARGE_INTEGER_AND
            | ix::LARGE_INTEGER_OR
            | ix::LARGE_INTEGER_XOR
            | ix::LARGE_INTEGER_SHIFT_RIGHT
            | ix::LARGE_INTEGER_UNSIGNED_SHIFT_RIGHT
            | ix::LARGE_INTEGER_SHIFT_LEFT
            | ix::LARGE_INTEGER_LESS_THAN
            | ix::LARGE_INTEGER_LESS_THAN_OR_EQUAL
            | ix::LARGE_INTEGER_GREATER_THAN
            | ix::LARGE_INTEGER_GREATER_THAN_OR_EQUAL
            | ix::LARGE_INTEGER_EQUALS
            | ix::SMI_UNARY_MINUS
            | ix::SMI_NOT
            | ix::LARGE_INTEGER_UNARY_MINUS
            | ix::LARGE_INTEGER_NOT
            | ix::COUNT_LEADING_ZEROS
            | ix::POPCOUNT
            | ix::OBJECT_CLASS_ID
            => 1,
        ix::ARRAY_LENGTH
            | ix::ARRAY_AT
            | ix::ARRAY_AT_PUT
            | ix::ARRAY_NEW
            | ix::ARRAY_EXPAND
            | ix::ARRAY_REPLACE
            | ix::LIST_ADD
            | ix::REBUILD_HASH_INDEX
            => 2,
        ix::BYTE_ARRAY_IS_RAW_BYTES
            | ix::BYTE_ARRAY_LENGTH
            | ix::STRING_LENGTH
            | ix::STRING_HASH_CODE
            | ix::BLOB_HASH_CODE
            | ix::STRING_RUNE_COUNT
            | ix::CONCAT_STRINGS
            | ix::BYTE_ARRAY_AT
            | ix::BYTE_ARRAY_NEW
            | ix::STRING_AT
            | ix::STRING_RAW_AT
            | ix::BLOB_EQUALS
            | ix::STRING_COMPARE
            | ix::STRING_ADD
            | ix::JSON_SKIP_WHITESPACE
            | ix::HASH_SIMPLE_JSON_STRING
            | ix::SIZE_OF_JSON_NUMBER
            | ix::BYTE_ARRAY_AT_PUT
            | ix::STRING_SLICE
            | ix::COMPARE_SIMPLE_JSON_STRING
            | ix::BLOB_INDEX_OF
            | ix::BYTE_ARRAY_REPLACE
            | ix::STRING_WRITE_TO_BYTE_ARRAY
            | ix::READ_INT_BIG_ENDIAN | ix::READ_UINT_BIG_ENDIAN | ix::READ_INT_LITTLE_ENDIAN
            | ix::READ_UINT_LITTLE_ENDIAN | ix::PUT_UINT_BIG_ENDIAN | ix::PUT_UINT_LITTLE_ENDIAN
            | ix::PUT_FLOAT_64_LITTLE_ENDIAN | ix::PUT_FLOAT_32_LITTLE_ENDIAN
            | ix::INT_VECTOR_EQUALS | ix::STRING_FROM_RUNE
            => 3,
        ix::FLOAT_UNARY_MINUS
            | ix::FLOAT_SQRT
            | ix::FLOAT_CEIL
            | ix::FLOAT_FLOOR
            | ix::FLOAT_TRUNC
            | ix::FLOAT_SIGN
            | ix::FLOAT_IS_NAN
            | ix::FLOAT_IS_FINITE
            | ix::FLOAT_TO_RAW
            | ix::FLOAT_TO_RAW32
            | ix::NUMBER_TO_FLOAT
            | ix::NUMBER_TO_INTEGER
            | ix::RAW_TO_FLOAT
            | ix::RAW32_TO_FLOAT
            | ix::FLOAT_ADD
            | ix::FLOAT_SUBTRACT
            | ix::FLOAT_MULTIPLY
            | ix::FLOAT_DIVIDE
            | ix::FLOAT_MOD
            | ix::FLOAT_LESS_THAN
            | ix::FLOAT_LESS_THAN_OR_EQUAL
            | ix::FLOAT_GREATER_THAN
            | ix::FLOAT_GREATER_THAN_OR_EQUAL
            | ix::FLOAT_EQUALS
            | ix::COMPARE_TO
            | ix::MIN_SPECIAL_COMPARE_TO
            => 4,
        _ => 0,
    }
}

/// The core primitives (index `i`, arity `n`) whose Rust port never falls
/// back to the C++ primitive: with these arguments every call ends in
/// `Success` or `Failure`, never `NotPorted` or `NeedsGc` (`prims::call`,
/// `rarrays::rust_primitive_r`). So for an untrusted process the C++
/// primitive behind these ports does not run (verified/core/OBLIGATIONS.md,
/// "Ports that never fall back"). The one list: verified/tools/contract_check.toit
/// reads it (one `(i == ix::NAME && n == ARITY)` per line) to count the C++
/// behind these ports as unreachable from untrusted code, and checks each
/// arity against `index::TABLE`. By family (`family`).
pub open spec fn never_falls_back(i: int, n: int) -> bool {
    ||| never_falls_back_ints(i, n)
    ||| never_falls_back_arrays(i, n)
    ||| never_falls_back_blobs(i, n)
    ||| never_falls_back_floats(i, n)
}

/// Integers: results in the smi range, no allocation.
pub open spec fn never_falls_back_ints(i: int, n: int) -> bool {
    ||| (i == ix::SMI_MOD && n == 2)
    ||| (i == ix::SMI_SHIFT_RIGHT && n == 2)
    ||| (i == ix::SMI_NOT && n == 1)
    ||| (i == ix::COUNT_LEADING_ZEROS && n == 1)
    ||| (i == ix::POPCOUNT && n == 1)
    ||| (i == ix::OBJECT_CLASS_ID && n == 1)
    ||| (i == ix::SMI_LESS_THAN && n == 2)
    ||| (i == ix::SMI_LESS_THAN_OR_EQUAL && n == 2)
    ||| (i == ix::SMI_GREATER_THAN && n == 2)
    ||| (i == ix::SMI_GREATER_THAN_OR_EQUAL && n == 2)
    ||| (i == ix::SMI_EQUALS && n == 2)
    ||| (i == ix::LARGE_INTEGER_LESS_THAN && n == 2)
    ||| (i == ix::LARGE_INTEGER_LESS_THAN_OR_EQUAL && n == 2)
    ||| (i == ix::LARGE_INTEGER_GREATER_THAN && n == 2)
    ||| (i == ix::LARGE_INTEGER_GREATER_THAN_OR_EQUAL && n == 2)
    ||| (i == ix::LARGE_INTEGER_EQUALS && n == 2)
}

/// Arrays: no allocation, no list backing.
pub open spec fn never_falls_back_arrays(i: int, n: int) -> bool {
    ||| (i == ix::ARRAY_LENGTH && n == 1)
    ||| (i == ix::ARRAY_AT && n == 2)
    ||| (i == ix::ARRAY_AT_PUT && n == 3)
    ||| (i == ix::ARRAY_REPLACE && n == 5)
    ||| (i == ix::REBUILD_HASH_INDEX && n == 2)
    ||| (i == ix::LIST_ADD && n == 2)
}

/// Strings and blobs: strings only (no opaque byte array), no allocation;
/// the byte-array accessors, which read an opaque byte array's tag and
/// length as the C++ does.
pub open spec fn never_falls_back_blobs(i: int, n: int) -> bool {
    ||| (i == ix::STRING_HASH_CODE && n == 1)
    ||| (i == ix::STRING_RAW_AT && n == 2)
    ||| (i == ix::STRING_COMPARE && n == 2)
    ||| (i == ix::INT_VECTOR_EQUALS && n == 2)
    ||| (i == ix::BYTE_ARRAY_IS_RAW_BYTES && n == 1)
    ||| (i == ix::BYTE_ARRAY_LENGTH && n == 1)
    ||| (i == ix::BYTE_ARRAY_AT && n == 2)
    ||| (i == ix::BYTE_ARRAY_AT_PUT && n == 3)
}

/// Floats: no new double.
pub open spec fn never_falls_back_floats(i: int, n: int) -> bool {
    ||| (i == ix::FLOAT_SIGN && n == 1)
    ||| (i == ix::FLOAT_IS_NAN && n == 1)
    ||| (i == ix::FLOAT_IS_FINITE && n == 1)
    ||| (i == ix::FLOAT_LESS_THAN && n == 2)
    ||| (i == ix::FLOAT_LESS_THAN_OR_EQUAL && n == 2)
    ||| (i == ix::FLOAT_GREATER_THAN && n == 2)
    ||| (i == ix::FLOAT_GREATER_THAN_OR_EQUAL && n == 2)
    ||| (i == ix::FLOAT_EQUALS && n == 2)
    ||| (i == ix::COMPARE_TO && n == 2)
    ||| (i == ix::MIN_SPECIAL_COMPARE_TO && n == 2)
}

/// A primitive outcome that completes the PRIMITIVE without C++.
pub open spec fn completes(r: PrimOutcome) -> bool {
    r is Success || r is Failure
}

/// The dispatch table of the core module.
#[inline(always)]
pub fn dispatch(index: u16, a: &Args, heap: &mut Heap, c: &Ctx) -> (r: (PrimOutcome, Ghost<Value>))
    requires
        heap_inv(c.p, old(heap)),
        args_rel(a, old(heap)),
    ensures
        prim_post(c.p, old(heap), final(heap), r.0, r.1@),
        contract(c.p, index as int, a, old(heap), final(heap), r.0, r.1@),
        (index == 115 || index == 116) ==> r.0 is NotPorted,
        never_falls_back(index as int, a.n as int) ==> completes(r.0),
{
    let i = index as usize;
    proof {
        if never_falls_back(index as int, a.n as int) {
            assert(i as int == index as int);
            assert(never_falls_back_ints(i as int, a.n as int) || never_falls_back_arrays(i as int, a.n as int)
                || never_falls_back_blobs(i as int, a.n as int) || never_falls_back_floats(i as int, a.n as int));
        }
    }
    match family(i) {
        1 => ints::dispatch(i, a, heap, c),
        2 => array::dispatch(i, a, heap, c),
        3 => blob::dispatch(i, a, heap, c),
        4 => float::dispatch(i, a, heap, c),
        _ => (PrimOutcome::NotPorted, Ghost(Value::Smi(0))),
    }
}

// ---------------------------------------------------------------------------
// Values.

/// The word of a value: the low bit is set exactly for objects; a smi
/// word is the smi shifted left.
pub proof fn lemma_word(h: &Heap, w: usize, v: Value)
    requires
        heap_model_ok(h.objs(), h.addrs(), h.class_bits()),
        w == enc(h.addrs(), v),
        good(h.objs(), v),
        encodable(h.addrs(), v),
    ensures
        (w & 1 == 1) == (v is Obj),
        (w & 1 == 0) == (v is Smi),
        v is Obj ==> w & 3 == 1 && (v->Obj_0 as int) < h.objs().len() && w == h.addrs()[v->Obj_0 as int],
        v is Smi ==> w == smi_word(v->Smi_0) && smi_range(v->Smi_0 as int)
            && word_smi(w) == v->Smi_0,
{
    match v {
        Value::Smi(i) => { lemma_smi_word(i); },
        Value::Obj(id) => { lemma_obj_not_smi(h.objs(), h.addrs(), id); },
        _ => {},
    }
}

/// The value of a smi word.
#[inline(always)]
pub fn smi_of_word(w: usize) -> (r: i64)
    ensures r == word_smi(w),
{
    smi_value(w)
}

/// The smi value `v` (in range) as a result.
#[inline(always)]
pub fn smi_res(h: &Heap, v: i64) -> (r: (usize, Ghost<Value>))
    requires smi_range(v as int),
    ensures res_ok(h, r.0, r.1@), r.1@ == Value::Smi(v),
{
    proof { lemma_smi_word(v); }
    (smi_of(v), Ghost(Value::Smi(v)))
}

/// Program root `k` (null, true, false, the error strings).
#[inline(always)]
pub fn root(p: &Program, h: &Heap, k: usize) -> (r: (usize, Ghost<Value>))
    requires heap_inv(p, h), k < ROOT_COUNT,
    ensures res_ok(h, r.0, r.1@), r.1@ == p.ap@.roots[k as int],
{
    proof {
        assert(prog_rel(p, h.objs(), h.addrs()));
        assert(p.roots@.len() == p.ap@.roots.len());
        assert(p.roots@[k as int] == enc(h.addrs(), p.ap@.roots[k as int]));
        assert(const_ok(h.objs(), p.ap@.roots[k as int]));
    }
    (p.roots.at(k), Ghost(p.ap@.roots[k as int]))
}

/// A failure with error root `k`.
#[inline(always)]
pub fn fail(p: &Program, h: &Heap, k: usize) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(p, h), k < ROOT_COUNT,
    ensures r.0 is Failure, prim_post(p, h, h, r.0, r.1@), r.1@ == p.ap@.roots[k as int],
{
    proof { lemma_post_refl(p, h); }
    let (w, v) = root(p, h, k);
    (PrimOutcome::Failure(w), v)
}

/// A failure with error root `k` after the heap changed from `h0`.
#[inline(always)]
pub fn fail_post(p: &Program, Ghost(h0): Ghost<Heap>, h: &Heap, k: usize) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_post(p, &h0, h), k < ROOT_COUNT,
    ensures r.0 is Failure, prim_post(p, &h0, h, r.0, r.1@), r.1@ == p.ap@.roots[k as int],
{
    let (w, v) = root(p, h, k);
    (PrimOutcome::Failure(w), v)
}

/// A success with the encoded value `(w, v)` and the heap unchanged.
#[inline(always)]
pub fn ok(p: &Program, h: &Heap, w: usize, Ghost(v): Ghost<Value>) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(p, h), res_ok(h, w, v),
    ensures r.0 == PrimOutcome::Success(w), r.1@ == v, prim_post(p, h, h, r.0, r.1@),
{
    proof { lemma_post_refl(p, h); }
    (PrimOutcome::Success(w), Ghost(v))
}

/// `true` or `false`.
#[inline(always)]
pub fn ok_bool(p: &Program, h: &Heap, b: bool) -> (r: (PrimOutcome, Ghost<Value>))
    requires heap_inv(p, h),
    ensures
        r.0 is Success, prim_post(p, h, h, r.0, r.1@),
        r.1@ == (if b { p.ap@.roots[1] } else { p.ap@.roots[2] }),
{
    let (w, v) = root(p, h, if b { ROOT_TRUE } else { ROOT_FALSE });
    ok(p, h, w, v)
}

/// The class id of the builtin class `k` (`Program::builtin_class_ids`).
#[inline(always)]
pub fn builtin_class(p: &Program, h: &Heap, k: usize) -> (r: usize)
    requires heap_inv(p, h), k < BUILTIN_COUNT,
    ensures r == p.ap@.builtin[k as int],
{
    proof {
        assert(prog_rel(p, h.objs(), h.addrs()));
        assert(p.builtin@[k as int] == smi_word(p.ap@.builtin[k as int] as i64));
        lemma_smi_word(p.ap@.builtin[k as int] as i64);
    }
    smi_of_word(p.builtin.at(k)) as usize
}

/// The class `k` exists and has tag `tag` (the builtin classes of strings,
/// byte arrays, doubles and large integers do; checked, not assumed).
#[inline(always)]
pub fn builtin_with_tag(p: &Program, h: &Heap, k: usize, tag: usize) -> (r: Option<usize>)
    requires heap_inv(p, h), k < BUILTIN_COUNT,
    ensures r is Some ==> ({
        let cid = r->Some_0;
        &&& cid == p.ap@.builtin[k as int]
        &&& cid < h.class_bits().len()
        &&& class_tag_of(h.class_bits(), cid as int) == tag as int
    }),
{
    let cid = builtin_class(p, h, k);
    if cid >= p.class_bits.len() { return None; }
    let bits = p.class_bits.at(cid);
    if (bits & 0xf) as usize != tag { return None; }
    Some(cid)
}

// ---------------------------------------------------------------------------
// Heap lemmas.

pub proof fn lemma_post_refl(p: &Program, h: &Heap)
    requires heap_inv(p, h),
    ensures heap_post(p, h, h),
{
    assert(h.addrs().subrange(0, h.addrs().len() as int) =~= h.addrs());
    let objs = h.objs();
    assert forall|i: int| 0 <= i < objs.len() implies {
        &&& (#[trigger] objs[i]).class_id == objs[i].class_id
        &&& objs[i].body is Stack2 ==> objs[i].body == objs[i].body
        &&& !(objs[i].body is Stack2) ==> !(objs[i].body is Stack2)
        &&& objs[i].class_id as int == task_class(p.ap@) ==> task_fields_kept(objs[i], objs[i])
    } by {
        match objs[i].body {
            Body::Instance(f) => {},
            _ => {},
        }
    }
}

pub proof fn lemma_post_trans(p: &Program, h0: &Heap, h1: &Heap, h2: &Heap)
    requires heap_post(p, h0, h1), heap_post(p, h1, h2),
    ensures heap_post(p, h0, h2),
{
    let a = h0.objs(); let b = h1.objs(); let c = h2.objs();
    let n0 = h0.addrs().len() as int;
    let n1 = h1.addrs().len() as int;
    assert forall|i: int| 0 <= i < a.len() implies {
        &&& (#[trigger] c[i]).class_id == a[i].class_id
        &&& a[i].body is Stack2 ==> c[i].body == a[i].body
        &&& !(a[i].body is Stack2) ==> !(c[i].body is Stack2)
        &&& a[i].class_id as int == task_class(p.ap@) ==> task_fields_kept(a[i], c[i])
    } by {
        assert(b[i].class_id == a[i].class_id);
        assert(c[i].class_id == b[i].class_id);
    }
    assert forall|i: int| a.len() <= i < c.len() implies !((#[trigger] c[i]).body is Stack2)
            && c[i].class_id as int != task_class(p.ap@) by {
        if i < b.len() {
            assert(!(b[i].body is Stack2) && b[i].class_id as int != task_class(p.ap@));
        }
    }
    assert forall|i: int| 0 <= i < n0 implies h2.addrs()[i] == h0.addrs()[i] by {
        assert(h1.addrs().subrange(0, n0)[i] == h0.addrs()[i]);
        assert(h2.addrs().subrange(0, n1)[i] == h1.addrs()[i]);
    }
    assert(h2.addrs().subrange(0, n0) =~= h0.addrs());
}

/// `good` and `encodable` survive appending objects.
pub proof fn lemma_good_mono(objs: Seq<HeapObj>, objs2: Seq<HeapObj>, addr: Seq<usize>, addr2: Seq<usize>, v: Value)
    requires
        good(objs, v), encodable(addr, v),
        objs.len() <= objs2.len(), addr.len() <= addr2.len(),
        addr2.subrange(0, addr.len() as int) == addr,
    ensures
        good(objs2, v), encodable(addr2, v), enc(addr2, v) == enc(addr, v),
{
    match v {
        Value::Obj(id) => {
            assert(addr2.subrange(0, addr.len() as int)[id as int] == addr[id as int]);
        },
        _ => {},
    }
}

/// The program tables stay related when objects keep their read-only flag
/// and address and new objects are appended.
pub proof fn lemma_prog_rel_mono(p: &Program, h0: &Heap, h1: &Heap)
    requires
        prog_rel(p, h0.objs(), h0.addrs()),
        h0.objs().len() <= h1.objs().len(),
        h0.addrs().len() == h0.objs().len(),
        h0.addrs().len() <= h1.addrs().len(),
        h1.addrs().subrange(0, h0.addrs().len() as int) == h0.addrs(),
        forall|i: int| 0 <= i < h0.objs().len() ==> (#[trigger] h1.objs()[i]).ro == h0.objs()[i].ro,
    ensures prog_rel(p, h1.objs(), h1.addrs()),
{
    let ap = p.ap@;
    let o0 = h0.objs(); let a0 = h0.addrs(); let o1 = h1.objs(); let a1 = h1.addrs();
    assert forall|i: int| 0 <= i < ap.roots.len() implies
        #[trigger] p.roots@[i] == enc(a1, ap.roots[i]) && const_ok(o1, ap.roots[i]) by {
        assert(prog_rel(p, o0, a0));
        assert(p.roots@[i] == enc(a0, ap.roots[i]));
        assert(const_ok(o0, ap.roots[i]));
        match ap.roots[i] {
            Value::Obj(id) => { assert(a1.subrange(0, a0.len() as int)[id as int] == a0[id as int]); },
            _ => {},
        }
    }
    assert forall|i: int| 0 <= i < ap.literals.len() implies
        #[trigger] p.literals@[i] == enc(a1, ap.literals[i]) && const_ok(o1, ap.literals[i]) by {
        assert(prog_rel(p, o0, a0));
        assert(p.literals@[i] == enc(a0, ap.literals[i]));
        assert(const_ok(o0, ap.literals[i]));
        match ap.literals[i] {
            Value::Obj(id) => { assert(a1.subrange(0, a0.len() as int)[id as int] == a0[id as int]); },
            _ => {},
        }
    }
}

/// The contents of a body are good values (for the bodies that hold
/// values).
pub open spec fn body_good(objs: Seq<HeapObj>, addr: Seq<usize>, b: Body) -> bool {
    match b {
        Body::Instance(f) => forall|i: int| 0 <= i < f.len() ==> good(objs, #[trigger] f[i]) && encodable(addr, f[i]),
        Body::Array(e) => forall|i: int| 0 <= i < e.len() ==> good(objs, #[trigger] e[i]) && encodable(addr, e[i]),
        _ => true,
    }
}

/// An object stays modelled and well formed when objects are appended
/// (and no address changes).
pub proof fn lemma_obj_mono(ap: Program2, o0: Seq<HeapObj>, a0: Seq<usize>, o1: Seq<HeapObj>, a1: Seq<usize>,
                            cb: Seq<u16>, o: HeapObj)
    requires
        obj_model_ok(o, cb, a0), basic_obj_ok(ap, o0, o),
        o0.len() <= o1.len(), a0.len() <= a1.len(),
        a1.subrange(0, a0.len() as int) == a0,
    ensures obj_model_ok(o, cb, a1), basic_obj_ok(ap, o1, o),
{
    match o.body {
        Body::Instance(f) => {
            assert forall|k: int| 0 <= k < f.len() implies #[trigger] encodable(a1, f[k]) by {
                assert(encodable(a0, f[k]));
                assert(good(o0, f[k]));
                lemma_good_mono(o0, o1, a0, a1, f[k]);
            }
            assert forall|k: int| 0 <= k < f.len() implies good(o1, #[trigger] f[k]) by {
                assert(encodable(a0, f[k]));
                assert(good(o0, f[k]));
                lemma_good_mono(o0, o1, a0, a1, f[k]);
            }
        },
        Body::Array(e) => {
            assert forall|k: int| 0 <= k < e.len() implies #[trigger] encodable(a1, e[k]) by {
                assert(encodable(a0, e[k]));
                assert(good(o0, e[k]));
                lemma_good_mono(o0, o1, a0, a1, e[k]);
            }
            assert forall|k: int| 0 <= k < e.len() implies good(o1, #[trigger] e[k]) by {
                assert(encodable(a0, e[k]));
                assert(good(o0, e[k]));
                lemma_good_mono(o0, o1, a0, a1, e[k]);
            }
        },
        _ => {},
    }
}

/// The body agrees with the class tag for the kinds the heap model ties to
/// tags besides instances and arrays (`abs::obj_model_ok`; a byte array of
/// the model has the byte-array tag, not every such object is one: V5).
pub open spec fn tags_ok(o: HeapObj, cb: Seq<u16>) -> bool {
    let t = class_tag_of(cb, o.class_id as int);
    &&& (o.body is Double) == (t == DOUBLE_TAG as int)
    &&& (o.body is LargeInt) == (t == LARGE_INTEGER_TAG as int)
    &&& (o.body is Str) == (t == STRING_TAG as int)
    &&& (o.body is Bytes) ==> t == BYTE_ARRAY_TAG as int
    &&& (o.body is Bytes) ==> o.body->Bytes_0.len() < MAX_BLOB_LENGTH
}

/// A new or replaced object that is not an instance of a class with
/// fields, whose body agrees with its class tag and holds good values,
/// is modelled and well formed.
pub proof fn lemma_obj_new(ap: Program2, o1: Seq<HeapObj>, a1: Seq<usize>, cb: Seq<u16>, o: HeapObj)
    requires
        cb == ap.class_bits,
        (o.class_id as int) < cb.len(),
        ({
            let t = class_tag_of(cb, o.class_id as int);
            &&& (o.body is Instance) == (t == INSTANCE_TAG as int || t == TASK_TAG as int)
            &&& (o.body is Array) == (t == ARRAY_TAG as int)
        }),
        o.body is Instance ==> o.body->Instance_0.len() == ifc_bits(cb, o.class_id as int),
        o.body is Array ==> o.body->Array_0.len() < 0x4000_0000,
        !(o.body is Stack2) && !(o.body is Stack),
        body_good(o1, a1, o.body),
        tags_ok(o, cb),
    ensures obj_model_ok(o, cb, a1), basic_obj_ok(ap, o1, o),
{
    let cid = o.class_id as int;
    assert(class_tag(p1(ap), cid) == cb[cid] & 0xf);
    assert(instance_field_count(p1(ap), cid) == ifc_bits(cb, cid));
    match o.body {
        Body::Instance(f) => {
            assert forall|k: int| 0 <= k < f.len() implies #[trigger] encodable(a1, f[k]) by {}
            assert forall|k: int| 0 <= k < f.len() implies good(o1, #[trigger] f[k]) by {}
        },
        Body::Array(e) => {
            assert forall|k: int| 0 <= k < e.len() implies #[trigger] encodable(a1, e[k]) by {}
            assert forall|k: int| 0 <= k < e.len() implies good(o1, #[trigger] e[k]) by {}
        },
        _ => {},
    }
}

/// The parts of `prim_heap_ok` about the old objects, for objects that
/// keep their class and are not suspended stacks.
pub open spec fn kept(ap: Program2, o: HeapObj, o2: HeapObj) -> bool {
    &&& o2.class_id == o.class_id
    &&& o.body is Stack2 ==> o2.body == o.body
    &&& !(o.body is Stack2) ==> !(o2.body is Stack2)
    &&& o.class_id as int == task_class(ap) ==> task_fields_kept(o, o2)
}

pub proof fn lemma_kept_refl(ap: Program2, o: HeapObj)
    ensures kept(ap, o, o),
{
    match o.body { Body::Instance(f) => {}, _ => {} }
}

/// Appending an object of the expected class, with modeled fields and
/// well-formed contents, preserves the heap invariant.
pub proof fn lemma_post_append(p: &Program, h0: &Heap, h1: &Heap, r: usize)
    requires
        heap_inv(p, h0),
        appended(h0, h1, r, p.ro_start, p.ro_size),
        ({
            let o = h1.objs().last();
            let cb = h1.class_bits();
            let t = class_tag_of(cb, o.class_id as int);
            &&& (o.class_id as int) < cb.len()
            &&& t != TASK_TAG as int
            &&& (o.body is Instance) == (t == INSTANCE_TAG as int)
            &&& (o.body is Instance) ==> o.body->Instance_0.len() == ifc_bits(cb, o.class_id as int)
            &&& (o.body is Array) == (t == ARRAY_TAG as int)
            &&& !(o.body is Stack2) && !(o.body is Stack)
            &&& body_good(h1.objs(), h1.addrs(), o.body)
            &&& (o.body is Array ==> o.body->Array_0.len() < 0x4000_0000)
            &&& tags_ok(o, cb)
        }),
    ensures heap_post(p, h0, h1),
{
    let ap = p.ap@;
    let o0 = h0.objs(); let a0 = h0.addrs(); let o1 = h1.objs(); let a1 = h1.addrs();
    let n = o0.len() as int;
    let cb = h1.class_bits();
    let o = o1[n];
    assert(heap_model_ok(o0, a0, cb));
    assert(prog_rel(p, o0, a0));
    assert(cb == ap.class_bits);
    assert(o1.last() == o);
    assert forall|i: int| 0 <= i < n implies #[trigger] o1[i] == o0[i] by {
        assert(o1.subrange(0, n)[i] == o0[i]);
    }
    assert forall|i: int| 0 <= i < n implies #[trigger] a1[i] == a0[i] by {
        assert(a1.subrange(0, n)[i] == a0[i]);
    }
    // addrs_ok
    assert forall|i: int, j: int| 0 <= i < a1.len() && 0 <= j < a1.len() && i != j
            implies #[trigger] a1[i] != #[trigger] a1[j] by {
        if i < n && j < n { assert(a0[i] != a0[j]); }
        else if i < n { assert(a0[i] != r); }
        else if j < n { assert(a0[j] != r); }
    }
    assert forall|i: int| 0 <= i < a1.len() implies #[trigger] a1[i] & 3 == 1 by {
        if i < n { assert(a0[i] & 3 == 1); }
    }
    assert(addrs_ok(o1, a1));
    // Model and well-formedness of every object.
    assert forall|i: int| #![trigger o1[i]] 0 <= i < o1.len() implies obj_model_ok(o1[i], cb, a1)
        && basic_obj_ok(ap, o1, o1[i]) by {
        if i < n {
            assert(o1[i] == o0[i]);
            assert(obj_model_ok(o0[i], cb, a0));
            assert(basic_obj_ok(ap, o0, o0[i]));
            lemma_obj_mono(ap, o0, a0, o1, a1, cb, o0[i]);
        } else {
            assert(i == n);
            lemma_obj_new(ap, o1, a1, cb, o);
        }
    }
    assert(heap_model_ok(o1, a1, cb));
    assert forall|i: int| 0 <= i < o1.len() implies basic_obj_ok(ap, o1, #[trigger] o1[i]) by {
        assert(o1[i] == o1[i]);
    }
    // Read-only flags.
    assert forall|i: int| 0 <= i < o1.len() implies #[trigger] o1[i].ro == in_ro(p, a1[i]) by {
        if i < n { assert(o0[i].ro == in_ro(p, a0[i])); }
    }
    lemma_prog_rel_mono(p, h0, h1);
    // prim_heap_ok.
    assert forall|i: int| 0 <= i < o0.len() implies {
        &&& (#[trigger] o1[i]).class_id == o0[i].class_id
        &&& o0[i].body is Stack2 ==> o1[i].body == o0[i].body
        &&& !(o0[i].body is Stack2) ==> !(o1[i].body is Stack2)
        &&& o0[i].class_id as int == task_class(ap) ==> task_fields_kept(o0[i], o1[i])
    } by {
        assert(o1[i] == o0[i]);
        lemma_kept_refl(ap, o0[i]);
    }
    assert forall|i: int| o0.len() <= i < o1.len() implies !((#[trigger] o1[i]).body is Stack2)
            && o1[i].class_id as int != task_class(ap) by {
        assert(i == n);
        assert(task_class_ok(ap));
        if o.class_id as int == task_class(ap) {
            assert(class_tag(p1(ap), task_class(ap)) == TASK_TAG);
            assert(class_tag(p1(ap), o.class_id as int) == cb[o.class_id as int] & 0xf);
        }
    }
    assert(a1.subrange(0, a0.len() as int) =~= a0);
}

/// Replacing a mutable object `id` by `o2` (same class, read-only flag and
/// kind of body, same instance length, good contents, task fields kept)
/// keeps the heap invariant. A read-only object (the program heap) cannot
/// be replaced: `prim_heap_ok` keeps it unchanged.
pub proof fn lemma_post_update(p: &Program, h0: &Heap, h1: &Heap, id: int, o2: HeapObj)
    requires
        heap_inv(p, h0),
        0 <= id < h0.objs().len(),
        h1.objs() == h0.objs().update(id, o2),
        h1.addrs() == h0.addrs(),
        h1.class_bits() == h0.class_bits(),
        ({
            let o = h0.objs()[id];
            &&& o2.class_id == o.class_id
            &&& o2.ro == o.ro
            &&& !o.ro
            &&& (o2.body is Instance) == (o.body is Instance)
            &&& (o2.body is Array) == (o.body is Array)
            &&& !(o.body is Stack2) && !(o2.body is Stack2) && !(o2.body is Stack)
            &&& (o.body is Instance ==> o2.body->Instance_0.len() == o.body->Instance_0.len())
            &&& (o.body is Array ==> o2.body->Array_0.len() == o.body->Array_0.len())
            &&& (o2.body is Str) == (o.body is Str)
            &&& (o2.body is Bytes) == (o.body is Bytes)
            &&& (o2.body is Double) == (o.body is Double)
            &&& (o2.body is LargeInt) == (o.body is LargeInt)
            &&& (o.body is Bytes ==> o2.body->Bytes_0.len() == o.body->Bytes_0.len())
            &&& body_good(h1.objs(), h1.addrs(), o2.body)
            &&& (o.class_id as int == task_class(p.ap@) ==> task_fields_kept(o, o2))
        }),
    ensures heap_post(p, h0, h1),
{
    let ap = p.ap@;
    let o0 = h0.objs(); let a0 = h0.addrs(); let o1 = h1.objs(); let a1 = h1.addrs();
    let cb = h1.class_bits();
    let o = o0[id];
    assert(heap_model_ok(o0, a0, cb));
    assert(prog_rel(p, o0, a0));
    assert(cb == ap.class_bits);
    assert(a1.subrange(0, a0.len() as int) =~= a0);
    assert(obj_model_ok(o, cb, a0));
    assert(basic_obj_ok(ap, o0, o));
    // The replaced object: same class and kind of body as before.
    {
        let cid = o.class_id as int;
        let t = class_tag_of(cb, cid);
        assert((o.body is Instance) == (t == INSTANCE_TAG as int || t == TASK_TAG as int));
        if o.body is Instance {
            assert(o2.body->Instance_0.len() == ifc_bits(cb, cid));
        }
        lemma_obj_new(ap, o1, a1, cb, o2);
    }
    assert forall|i: int| #![trigger o1[i]] 0 <= i < o1.len() implies obj_model_ok(o1[i], cb, a1)
        && basic_obj_ok(ap, o1, o1[i]) by {
        if i != id {
            assert(o1[i] == o0[i]);
            assert(obj_model_ok(o0[i], cb, a0));
            assert(basic_obj_ok(ap, o0, o0[i]));
            lemma_obj_mono(ap, o0, a0, o1, a1, cb, o0[i]);
        } else {
            assert(o1[i] == o2);
        }
    }
    assert(heap_model_ok(o1, a1, cb));
    assert forall|i: int| 0 <= i < o1.len() implies basic_obj_ok(ap, o1, #[trigger] o1[i]) by {
        assert(o1[i] == o1[i]);
    }
    assert forall|i: int| 0 <= i < o1.len() implies #[trigger] o1[i].ro == in_ro(p, a1[i]) by {
        assert(o0[i].ro == in_ro(p, a0[i]));
    }
    lemma_prog_rel_mono(p, h0, h1);
    assert forall|i: int| 0 <= i < o0.len() implies {
        &&& (#[trigger] o1[i]).class_id == o0[i].class_id
        &&& o0[i].body is Stack2 ==> o1[i].body == o0[i].body
        &&& !(o0[i].body is Stack2) ==> !(o1[i].body is Stack2)
        &&& o0[i].class_id as int == task_class(ap) ==> task_fields_kept(o0[i], o1[i])
    } by {
        if i != id {
            assert(o1[i] == o0[i]);
            lemma_kept_refl(ap, o0[i]);
        }
    }
}

/// A body of bytes: replacing the bytes of a mutable string or byte array
/// keeps the heap invariant.
pub proof fn lemma_post_content(p: &Program, h0: &Heap, h1: &Heap, id: int, s: Seq<u8>)
    requires
        heap_inv(p, h0),
        0 <= id < h0.objs().len(),
        is_blob(h0.objs()[id]),
        !h0.objs()[id].ro,
        h1.objs() == h0.objs().update(id, with_content(h0.objs()[id], s)),
        h0.objs()[id].body is Bytes ==> s.len() == content(h0.objs()[id]).len(),
        h1.addrs() == h0.addrs(),
        h1.class_bits() == h0.class_bits(),
    ensures heap_post(p, h0, h1),
{
    lemma_post_update(p, h0, h1, id, with_content(h0.objs()[id], s));
}

} // verus!
