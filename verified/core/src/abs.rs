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

//! The abstraction: how the core's concrete state represents a state of the
//! specification (`toit_spec::v2::spec`).
//!
//! The coupling goes from the abstract state to the words: `enc(addr, v)`
//! is the machine word of the abstract value `v` under the heap model's
//! object addresses `addr`, and `Machine::refines` says that every word of
//! the object stack, every frame record and every global is the encoding of
//! the matching part of the ghost state `Machine::g` (a `State2`). This
//! direction is a function, whereas reading an abstract state off the
//! words is not: a block reference `BlockRef(f, s)` and the smi
//! `f << 20 | s` are the same word, and an object's address changes with
//! every GC. The ghost state disambiguates; `abs(m)` of DESIGN.md is
//! `m.g@`, constrained by `m.refines(p)`.
//!
//! The program tables are related to the abstract program (`Program2`)
//! by `prog_rel`, established by the loader (an assumption of the run
//! loop, see `theorem.rs`).

use vstd::prelude::*;
use crate::layout::*;
use crate::ffi::V2Method;
use crate::view::*;
use toit_spec::types::{Value, Frame, Handler, MethodInfo, HeapObj, Body};
use toit_spec::v2::types::{State2, Program2};
use toit_spec::v2::verifier::Cert;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::spec::*;
#[cfg(verus_keep_ghost)]
use toit_spec::v2::sound::{wf, small};
#[cfg(verus_keep_ghost)]
use toit_spec::v2::verifier::accepts;

verus! {

global size_of usize == 8;

// ---------------------------------------------------------------------------
// Words.

/// The word of the smi `v` (`Smi::from`): `v << 1`, two's complement.
pub open spec fn smi_word(v: i64) -> usize {
    (v + v) as usize
}

pub open spec fn smi_range(v: int) -> bool {
    MIN_SMI <= v <= MAX_SMI
}

/// A block reference `(f, s)` is the smi `f << BLOCK_SLOT_BITS | s`.
pub open spec fn block_word(f: usize, s: usize) -> usize {
    smi_word((f * 0x10_0000 + s) as i64)
}

/// The machine word of an abstract value. Objects are their address in the
/// heap model (`Heap::addrs`); format-1 values never occur in format 2.
pub open spec fn enc(addr: Seq<usize>, v: Value) -> usize {
    match v {
        Value::Smi(i) => smi_word(i),
        Value::Obj(id) => if id < addr.len() { addr[id as int] } else { 0 },
        Value::BlockRef(f, s) => block_word(f, s),
        _ => 0,
    }
}

pub open spec fn enc_seq(addr: Seq<usize>, vs: Seq<Value>) -> Seq<usize> {
    Seq::new(vs.len(), |i: int| enc(addr, vs[i]))
}

/// The heap model is well formed: one tagged, distinct address per object.
pub open spec fn addrs_ok(objs: Seq<HeapObj>, addr: Seq<usize>) -> bool {
    &&& addr.len() == objs.len()
    &&& objs.len() < 0x4000_0000
    &&& forall|i: int| 0 <= i < addr.len() ==> #[trigger] addr[i] & 3 == 1
    &&& forall|i: int, j: int| 0 <= i < addr.len() && 0 <= j < addr.len() && i != j
            ==> #[trigger] addr[i] != #[trigger] addr[j]
}

/// Instance field count and class tag of class `cid` by the class bits
/// (`spec_common::instance_field_count`, `class_tag`).
pub open spec fn ifc_bits(cb: Seq<u16>, cid: int) -> int {
    (((cb[cid] >> 5u16) & 0x7ffu16) as int) - 1
}

pub open spec fn tag_bits(cb: Seq<u16>, cid: int) -> int {
    (cb[cid] & 0xfu16) as int
}

/// TRUSTED (heap integrity, TRUSTED.md "Heap model"): an object of the
/// model agrees with its header and contents: its class exists; it is an
/// instance exactly if its class has the instance or task tag, with the
/// class' field count; its fields are encodable values.
pub open spec fn obj_model_ok(o: HeapObj, cb: Seq<u16>, addr: Seq<usize>) -> bool {
    let cid = o.class_id as int;
    &&& cid < cb.len()
    &&& (o.body is Instance) == (tag_bits(cb, cid) == INSTANCE_TAG as int || tag_bits(cb, cid) == TASK_TAG as int)
    &&& match o.body {
        Body::Instance(f) => f.len() == ifc_bits(cb, cid)
            && forall|i: int| 0 <= i < f.len() ==> #[trigger] encodable(addr, f[i]),
        _ => true,
    }
}

pub open spec fn heap_model_ok(objs: Seq<HeapObj>, addr: Seq<usize>, cb: Seq<u16>) -> bool {
    &&& addrs_ok(objs, addr)
    &&& forall|i: int| 0 <= i < objs.len() ==> #[trigger] obj_model_ok(objs[i], cb, addr)
}

/// The encodable values (all values of a well-formed format-2 state are).
pub open spec fn encodable(addr: Seq<usize>, v: Value) -> bool {
    match v {
        Value::Smi(i) => smi_range(i as int),
        Value::Obj(id) => id < addr.len(),
        Value::BlockRef(f, s) => f < 0x100_0000_0000 && s < 0x10_0000,
        _ => false,
    }
}

// ---------------------------------------------------------------------------
// Smi facts (bit vectors).

pub proof fn lemma_smi_word(v: i64)
    requires smi_range(v as int),
    ensures
        smi_word(v) & 1 == 0,
        (smi_word(v) as i64) >> 1u64 == v,
        smi_word(v) as i64 == v + v,
{
    assert(((v + v) as usize) & 1 == 0 && (((v + v) as usize) as i64) >> 1u64 == v
        && ((v + v) as usize) as i64 == v + v) by (bit_vector)
        requires -0x4000_0000_0000_0000i64 <= v <= 0x3fff_ffff_ffff_ffffi64;
}

pub proof fn lemma_smi_word_inj(a: i64, b: i64)
    requires smi_range(a as int), smi_range(b as int),
    ensures (smi_word(a) == smi_word(b)) == (a == b),
{
    lemma_smi_word(a);
    lemma_smi_word(b);
}

/// A heap-tagged word is not a smi.
pub proof fn lemma_heap_tag(a: usize)
    requires a & 3 == 1,
    ensures a & 1 == 1,
{
    assert(a & 3 == 1 ==> a & 1 == 1) by (bit_vector);
}

/// A small non-negative smi is twice its value.
pub proof fn lemma_smi_word_nat(v: i64)
    requires 0 <= v <= 0x3fff_ffff_ffff_ffff,
    ensures smi_word(v) == 2 * v,
{
    assert(((v + v) as usize) as int == 2 * v) by (bit_vector)
        requires 0 <= v <= 0x3fff_ffff_ffff_ffffi64;
}

/// Encodings of distinct encodable values differ, except a block
/// reference and the smi with the same bits.
pub proof fn lemma_enc_inj(objs: Seq<HeapObj>, addr: Seq<usize>, a: Value, b: Value)
    requires
        addrs_ok(objs, addr),
        encodable(addr, a), encodable(addr, b),
        !(a is BlockRef || b is BlockRef),
    ensures (enc(addr, a) == enc(addr, b)) == (a == b),
{
    match a {
        Value::Smi(x) => {
            lemma_smi_word(x);
            match b {
                Value::Smi(y) => { lemma_smi_word_inj(x, y); },
                Value::Obj(j) => {
                    assert(addr[j as int] & 3 == 1);
                    lemma_heap_tag(addr[j as int]);
                },
                _ => {},
            }
        },
        Value::Obj(i) => {
            assert(addr[i as int] & 3 == 1);
            lemma_heap_tag(addr[i as int]);
            match b {
                Value::Smi(y) => { lemma_smi_word(y); },
                Value::Obj(j) => {
                    if i != j {
                        assert(addr[i as int] != addr[j as int]);
                    }
                },
                _ => {},
            }
        },
        _ => {},
    }
}

/// A heap reference is not a smi word.
pub proof fn lemma_obj_not_smi(objs: Seq<HeapObj>, addr: Seq<usize>, id: usize)
    requires addrs_ok(objs, addr), id < addr.len(),
    ensures enc(addr, Value::Obj(id)) & 1 == 1, enc(addr, Value::Obj(id)) & 3 == 1,
{
    assert(addr[id as int] & 3 == 1);
    lemma_heap_tag(addr[id as int]);
}

// ---------------------------------------------------------------------------
// The program.

/// The method table entry of the abstract program for a `V2Method`; every
/// method's frame bound is the program's global maximum height (format note
/// 15).
pub open spec fn method_info(m: V2Method, max_height: usize) -> MethodInfo {
    MethodInfo {
        arity: m.arity,
        kind: m.kind,
        max_height: max_height as u16,
        selector: m.selector,
        aux: m.aux,
        recv_start: m.recv_start,
        recv_end: m.recv_end,
        entry: m.entry as usize,
        end: m.end as usize,
    }
}

/// A root or literal: a smi, or an object of the program heap (which never
/// moves).
pub open spec fn const_ok(objs: Seq<HeapObj>, v: Value) -> bool {
    match v {
        Value::Smi(i) => smi_range(i as int),
        Value::Obj(id) => id < objs.len() && objs[id as int].ro,
        _ => false,
    }
}

/// The program tables are the abstract program `p.ap@` (the loader's
/// contract, assumed by the run loop: see `theorem.rs`).
pub open spec fn prog_rel(p: &crate::exec::Program, objs: Seq<HeapObj>, addr: Seq<usize>) -> bool {
    let ap = p.ap@;
    &&& ap.word_bits == 64
    &&& p.code@ == ap.bytecodes
    &&& p.methods@.len() == ap.methods.len()
    &&& forall|i: int| 0 <= i < ap.methods.len() ==>
            #[trigger] ap.methods[i] == method_info(p.methods@[i], p.max_height)
    &&& p.max_height < 0x1_0000
    &&& p.dispatch@ == ap.dispatch
    &&& p.class_bits@ == ap.class_bits
    &&& p.class_check_ids@ == ap.class_check_ids
    &&& p.interface_check_offsets@ == ap.interface_check_offsets
    &&& p.invoke_offsets@ == ap.invoke_offsets
    &&& p.entry_points@ == ap.entry_points
    &&& p.builtin@.len() == ap.builtin.len()
    &&& forall|k: int| 0 <= k < ap.builtin.len() ==>
            #[trigger] p.builtin@[k] == smi_word(ap.builtin[k] as i64)
    &&& p.roots@.len() == ap.roots.len()
    &&& forall|i: int| 0 <= i < ap.roots.len() ==>
            #[trigger] p.roots@[i] == enc(addr, ap.roots[i]) && const_ok(objs, ap.roots[i])
    &&& p.literals@.len() == ap.literals.len()
    &&& forall|i: int| 0 <= i < ap.literals.len() ==>
            #[trigger] p.literals@[i] == enc(addr, ap.literals[i]) && const_ok(objs, ap.literals[i])
    // null, true and false are (distinct) objects.
    &&& ap.roots.len() > 2
    &&& ap.roots[0] is Obj && ap.roots[1] is Obj && ap.roots[2] is Obj
    &&& p.null == p.roots@[0]
    &&& p.true_ == p.roots@[1]
    &&& p.false_ == p.roots@[2]
    &&& p.code@.len() < 0x1000_0000
    // The builtin class ids the handlers use.
    &&& p.smi_class_id == ap.builtin[BUILTIN_SMI as int] as i64
    &&& p.list_class_id == ap.builtin[BUILTIN_LIST as int] as i64
    &&& p.byte_array_slice_class_id == ap.builtin[BUILTIN_BYTE_ARRAY_SLICE as int] as i64
    &&& p.byte_array_cow_class_id == ap.builtin[BUILTIN_BYTE_ARRAY_COW as int] as i64
    &&& p.large_array_class_id == ap.builtin[BUILTIN_LARGE_ARRAY as int] as i64
    &&& p.lazy_initializer_class_id == ap.builtin[BUILTIN_LAZY_INITIALIZER as int] as i64
}

// ---------------------------------------------------------------------------
// Frames.

/// The handler word of a frame record: 0, or `height | bci << 32` of the
/// frame's TRY.
pub open spec fn handler_word(h: Handler) -> usize {
    (h.height + h.bci * 0x1_0000_0000) as usize
}

/// Word `k` of frame record `fi`.
pub open spec fn rec(mem: Seq<usize>, fi: int, k: usize) -> usize {
    mem[FRAME_WORDS * fi + k]
}

/// The frame records `mem[0..4 * frames.len()]` hold the frames, and the
/// handler words the handlers (one per frame at most).
pub open spec fn frames_rel(mem: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>) -> bool {
    &&& FRAME_WORDS * frames.len() <= mem.len()
    &&& forall|fi: int| 0 <= fi < frames.len() ==> #[trigger] rec(mem, fi, FRAME_METHOD) == frames[fi].method
    &&& forall|fi: int| 0 <= fi < frames.len() ==> #[trigger] rec(mem, fi, FRAME_RET) == frames[fi].ret
    &&& forall|fi: int| 0 <= fi < frames.len() ==> #[trigger] rec(mem, fi, FRAME_BASE) == frames[fi].base
    &&& tries.len() <= frames.len()
    &&& forall|x: int| 0 <= x < tries.len() ==> {
        &&& (#[trigger] tries[x]).frame < frames.len()
        &&& 0 < tries[x].height < 0x1_0000_0000
        &&& tries[x].bci < 0x1_0000_0000
        &&& rec(mem, tries[x].frame as int, FRAME_HANDLER) == handler_word(tries[x])
    }
    &&& forall|fi: int| 0 <= fi < frames.len() && #[trigger] rec(mem, fi, FRAME_HANDLER) != 0
            ==> exists|x: int| 0 <= x < tries.len() && tries[x].frame == fi
}

/// Record words lie below `FRAME_WORDS * n`.
pub proof fn lemma_rec_index(n: int, fi: int, k: usize)
    requires 0 <= fi < n, k < FRAME_WORDS,
    ensures 0 <= FRAME_WORDS * fi + k < FRAME_WORDS * n,
{
    assert(FRAME_WORDS * fi + k < FRAME_WORDS * n) by (nonlinear_arith)
        requires 0 <= fi < n, k < FRAME_WORDS;
}

/// The frame records depend only on `mem[0..FRAME_WORDS * frames.len()]`.
pub proof fn lemma_frames_rel_same(mem: Seq<usize>, mem2: Seq<usize>, frames: Seq<Frame>, tries: Seq<Handler>)
    requires
        frames_rel(mem, frames, tries),
        FRAME_WORDS * frames.len() <= mem2.len(),
        forall|i: int| 0 <= i < FRAME_WORDS * frames.len() ==> #[trigger] mem2[i] == mem[i],
    ensures frames_rel(mem2, frames, tries),
{
    let n = frames.len() as int;
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_METHOD) == frames[fi].method by {
        lemma_rec_index(n, fi, FRAME_METHOD);
        assert(rec(mem, fi, FRAME_METHOD) == frames[fi].method);
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_RET) == frames[fi].ret by {
        lemma_rec_index(n, fi, FRAME_RET);
        assert(rec(mem, fi, FRAME_RET) == frames[fi].ret);
    }
    assert forall|fi: int| 0 <= fi < n implies #[trigger] rec(mem2, fi, FRAME_BASE) == frames[fi].base by {
        lemma_rec_index(n, fi, FRAME_BASE);
        assert(rec(mem, fi, FRAME_BASE) == frames[fi].base);
    }
    assert forall|x: int| 0 <= x < tries.len() implies
        rec(mem2, (#[trigger] tries[x]).frame as int, FRAME_HANDLER) == handler_word(tries[x]) by {
        lemma_rec_index(n, tries[x].frame as int, FRAME_HANDLER);
    }
    assert forall|fi: int| 0 <= fi < n && #[trigger] rec(mem2, fi, FRAME_HANDLER) != 0
            implies exists|x: int| 0 <= x < tries.len() && tries[x].frame == fi by {
        lemma_rec_index(n, fi, FRAME_HANDLER);
        assert(rec(mem2, fi, FRAME_HANDLER) == rec(mem, fi, FRAME_HANDLER));
    }
}

/// Writes above the frame records keep them.
pub proof fn lemma_frames_rel_write(mem: Seq<usize>, i: int, v: usize, frames: Seq<Frame>, tries: Seq<Handler>)
    requires frames_rel(mem, frames, tries), FRAME_WORDS * frames.len() <= i < mem.len(),
    ensures frames_rel(mem.update(i, v), frames, tries),
{
    lemma_frames_rel_same(mem, mem.update(i, v), frames, tries);
}

} // verus!
