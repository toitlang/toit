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

//! Soundness of the field accesses: LOAD_FIELD(_WIDE), (POP_)LOAD_FIELD_LOCAL,
//! STORE_FIELD(_WIDE/_POP), LOAD_FIELD_THIS, STORE_FIELD_THIS. Also the
//! generic helpers for steps that keep a prefix of the top frame's slots
//! (`lemma_simple_step`) and for raised machine exceptions.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
use crate::v2::sound_upto::*;
use crate::v2::sound_instr::*;
use crate::v2::sound_raise::*;
use crate::v2::sound_heap::*;
#[cfg(verus_only)]
use crate::spec_common::{is_instance, fields, obj, obj_id, class_id_ok, class_id_of, builtin, SMI_CLASS};

verus! {

// ---------------------------------------------------------------------------
// Generic helpers.

/// A step that raises a machine exception.
pub proof fn lemma_raise_step(p: Program2, c: Cert, trusted: bool, s: State2, k: int)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), 0 <= k < 5, step(p, s) == raise(p, s, k),
    ensures step_ok(p, c, s),
{
    lemma_raise(p, c, trusted, s, k);
}

/// A value conforms to `Val`.
pub proof fn lemma_conf_val(p: Program2, c: Cert, s: State2, fi: int, kf: Seq<Kind>, j: int, v: Value)
    requires good(s.heap, v),
    ensures conf(p, c, s, fi, kf, j, Kind::Val, v),
{
    reveal(conf);
}

/// A step that keeps the first `n` slots of the top frame (kinds and
/// values), replaces the others by conforming non-token slots, and leaves
/// the frames, handlers and globals alone (the heap may change).
pub open spec fn simple_step(p: Program2, c: Cert, s: State2, s2: State2, k2: Seq<Kind>, len: int, n: int) -> bool {
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    let k = kinds_of(p, c, s, t);
    &&& s2.frames == s.frames
    &&& s2.globals == s.globals
    &&& s2.task == s.task
    &&& 0 <= len
    &&& s2.bci as int == s.bci as int + len
    &&& map_at(c, m, foff(p, s, t) + len) == Some(k2)
    &&& s2.stack.len() == b + k2.len()
    &&& 0 <= n <= k.len() && n <= k2.len()
    &&& k2.subrange(0, n) == k.subrange(0, n)
    &&& forall|x: int| 0 <= x < b + n ==> #[trigger] s2.stack[x] == s.stack[x]
    &&& forall|j: int| n <= j < k2.len() ==>
            #[trigger] conf(p, c, s2, t, k2, j, k2[j], s2.stack[b + j]) && !(k2[j] is Token)
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> k2.len() >= 1 && (n >= 1 || s2.stack[b] == s.stack[b]))
    &&& heap_ext(p, s.heap, s2.heap)
    &&& heap_ok(p, c, s2.heap)
}

#[verifier::spinoff_prover]
pub proof fn lemma_simple_step(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, k2: Seq<Kind>, len: int, n: int)
    requires accepts(p, c, trusted), wf(p, c, s), simple_step(p, c, s, s2, k2, len, n),
    ensures wf(p, c, s2),
{
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    let k = kinds_of(p, c, s, t);
    lemma_wf_parts(p, c, s);
    lemma_top_kinds(p, c, s);
    lemma_task_bases(p, c, s);
    assert(top_i(s2) == t);
    assert(fbase(s2, t) == b);
    assert(foff(p, s2, t) == foff(p, s, t) + len);
    assert(fmap(p, c, s2, t) == k2);
    assert(slots(s2, t) == k2.len());
    assert(kinds_of(p, c, s2, t) =~= k2);
    assert forall|x: int| 0 <= x < b implies #[trigger] s2.stack[x] == s.stack[x] by {
        assert(s2.stack[x] == s.stack[x]);
    }
    assert forall|j: int| 0 <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, t, kinds_of(p, c, s2, t), j, k2[j], s2.stack[b + j]) by {
        if j < n {
            assert(k2[j] == k2.subrange(0, n)[j]);
            assert(k[j] == k.subrange(0, n)[j]);
            assert(s2.stack[b + j] == s.stack[b + j]);
        } else {
            assert(conf(p, c, s2, t, k2, j, k2[j], s2.stack[b + j]));
        }
    }
    assert forall|j: int| 0 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
        k2.subrange(0, j) == k.subrange(0, j) by {
        if j >= n {
            assert(conf(p, c, s2, t, k2, j, k2[j], s2.stack[b + j]));
            assert(!(k2[j] is Token));
        }
        assert(k2.subrange(0, j) =~= k2.subrange(0, n).subrange(0, j));
        assert(k.subrange(0, j) =~= k.subrange(0, n).subrange(0, j));
    }
    if pinned0(p, m) && arity(p, m) >= 1 && n >= 1 {
        assert(s2.stack[b] == s.stack[b]);
    }
    assert(globals_ok(c, s2)) by {
        assert forall|g: int| 0 <= g < s2.globals.len() implies good(s2.heap, #[trigger] s2.globals[g]) by {
            assert(good(s.heap, s.globals[g]));
        }
    }
    lemma_consts_heap(p, s.heap, s2.heap);
    assert(local_step(p, c, s, s2, k2));
    lemma_local_step(p, c, trusted, s, s2, k2);
}

// ---------------------------------------------------------------------------
// Fields.

/// A field of an instance in a well-formed heap is a value.
pub proof fn lemma_field_good(p: Program2, c: Cert, s: State2, inst: Value, f: int)
    requires heap_ok(p, c, s.heap), field_ok(s, inst, f),
    ensures good(s.heap, field(s, inst, f)),
{
    reveal(heap_ok);
    let id = obj_id(inst);
    assert(obj_ok(p, c, s.heap, s.heap[id]));
    let fs = fields(as1(s), inst);
    assert(good(s.heap, fs[f]));
}

/// `this` of a frame whose method passes `this_field_ok` has field `f`;
/// if it is a task, the method's receiver range includes the task class.
#[verifier::spinoff_prover]
pub proof fn lemma_this_ok(p: Program2, c: Cert, trusted: bool, s: State2, f: int)
    requires accepts(p, c, trusted), wf(p, c, s), this_field_ok(p, cur_m(s), f), 0 <= f,
    ensures this_ok(p, s, f),
        is_task_obj(p, s, s.stack[top(s).base as int]) ==> range_has_task(p, info(p, cur_m(s))),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let b = cur_b(s);
    reveal(frame_ok);
    assert(pinned_ok(p, s, t));
    assert(receiver_ok(p, s, t));
    let r = s.stack[b];
    let cl = class_id_of(p1(p), as1(s), r);
    let i = info(p, m);
    assert(fmethod(s, t) == m);
    assert(fbase(s, t) == b);
    assert(i.recv_start as int <= cl < i.recv_end as int);
    assert(is_field_class(p, cl) && f < ifc(p, cl));
    assert(tables_ok(p, c));
    assert(machine_class_ok(p, SMI_CLASS));
    match r {
        Value::Obj(id) => {
            reveal(heap_ok);
            assert(obj_ok(p, c, s.heap, s.heap[id as int]));
            assert(basic_obj_ok(p, s.heap, s.heap[id as int]));
        },
        _ => {},
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_load_field(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s),
        cur_op(p, s) == LOAD_FIELD || cur_op(p, s) == LOAD_FIELD_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let op = cur_op(p, s);
    let len = opcode_length2(op);
    let f = if op == LOAD_FIELD { b1_of(p, m, off) } else { w1_of(p, m, off) };
    let k2 = k.update(h - 1, Kind::Val);
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    lemma_at_good(p, c, trusted, s, 0);
    let inst = at(s, 0);
    assert(step(p, s) == op_load_field(p, s, f, len)) by { reveal(step); }
    if !field_readable(p, s, inst, f) {
        lemma_raise_step(p, c, trusted, s, INVALID_PROGRAM);
    } else {
        let v = field(s, inst, f);
        lemma_field_good(p, c, s, inst, f);
        let s2 = goto(put(s, 0, v), s.bci + len);
        lemma_conf_val(p, c, s2, t, k2, h - 1, v);
        assert(k2.subrange(0, h - 1) =~= k.subrange(0, h - 1));
        assert(simple_step(p, c, s, s2, k2, len, h - 1));
        lemma_simple_step(p, c, trusted, s, s2, k2, len, h - 1);
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_load_field_local(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s),
        cur_op(p, s) == LOAD_FIELD_LOCAL || cur_op(p, s) == POP_LOAD_FIELD_LOCAL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let op = cur_op(p, s);
    let len = opcode_length2(op);
    let b1 = b1_of(p, m, off);
    let pop = op == POP_LOAD_FIELD_LOCAL;
    let slot = if pop { b1 % 16 + 1 } else { b1 % 16 };
    let f = b1 / 16;
    let k2 = if pop { k.update(h - 1, Kind::Val) } else { k.push(Kind::Val) };
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    lemma_at_good(p, c, trusted, s, slot);
    let inst = at(s, slot);
    assert(step(p, s) == op_load_field_local(p, s, b1, pop)) by { reveal(step); }
    if !field_readable(p, s, inst, f) {
        lemma_raise_step(p, c, trusted, s, INVALID_PROGRAM);
    } else {
        let v = field(s, inst, f);
        lemma_field_good(p, c, s, inst, f);
        if pop {
            let s2 = goto(put(s, 0, v), s.bci + len);
            lemma_conf_val(p, c, s2, t, k2, h - 1, v);
            assert(k2.subrange(0, h - 1) =~= k.subrange(0, h - 1));
            assert(simple_step(p, c, s, s2, k2, len, h - 1));
            lemma_simple_step(p, c, trusted, s, s2, k2, len, h - 1);
        } else {
            let s2 = goto(push(s, v), s.bci + len);
            lemma_conf_val(p, c, s2, t, k2, h, v);
            assert(k2.subrange(0, h) =~= k.subrange(0, h));
            assert(simple_step(p, c, s, s2, k2, len, h));
            lemma_simple_step(p, c, trusted, s, s2, k2, len, h);
        }
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_store_field(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s),
        cur_op(p, s) == STORE_FIELD || cur_op(p, s) == STORE_FIELD_WIDE || cur_op(p, s) == STORE_FIELD_POP,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let op = cur_op(p, s);
    let len = opcode_length2(op);
    let f = if op == STORE_FIELD_WIDE { w1_of(p, m, off) } else { b1_of(p, m, off) };
    let keep = op != STORE_FIELD_POP;
    let k2 = if keep { pop_push(k, 2, Some(Kind::Val)) } else { pop_push(k, 2, None) };
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    lemma_at_good(p, c, trusted, s, 0);
    lemma_at_good(p, c, trusted, s, 1);
    let v = at(s, 0);
    let inst = at(s, 1);
    assert(step(p, s) == op_store_field(p, s, f, len, keep)) by { reveal(step); }
    if !field_writable(p, s, inst, f) {
        lemma_raise_step(p, c, trusted, s, INVALID_PROGRAM);
    } else {
        let s0 = drop(s, 2);
        assert(field_ok(s0, inst, f));
        assert(is_task_obj(p, s0, inst) == is_task_obj(p, s, inst));
        lemma_set_field2(p, c, s0, inst, f, v);
        let s1 = set_field2(s0, inst, f, v);
        assert(k2.subrange(0, h - 2) =~= k.subrange(0, h - 2));
        if keep {
            let s2 = goto(push(s1, v), s.bci + len);
            lemma_conf_val(p, c, s2, t, k2, h - 2, v);
            assert(simple_step(p, c, s, s2, k2, len, h - 2));
            lemma_simple_step(p, c, trusted, s, s2, k2, len, h - 2);
        } else {
            let s2 = goto(s1, s.bci + len);
            assert(simple_step(p, c, s, s2, k2, len, h - 2));
            lemma_simple_step(p, c, trusted, s, s2, k2, len, h - 2);
        }
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_load_field_this(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == LOAD_FIELD_THIS,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let len = 2int;
    let f = b1_of(p, m, off);
    let k2 = k.push(Kind::Val);
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(map_at(c, m, off + len) == Some(k2));
    lemma_this_ok(p, c, trusted, s, f);
    assert(step(p, s) == op_load_field_this(p, s, f)) by { reveal(step); }
    let inst = s.stack[top(s).base as int];
    let v = field(s, inst, f);
    lemma_field_good(p, c, s, inst, f);
    let s2 = goto(push(s, v), s.bci + len);
    lemma_conf_val(p, c, s2, t, k2, h, v);
    assert(k2.subrange(0, h) =~= k.subrange(0, h));
    assert(simple_step(p, c, s, s2, k2, len, h));
    lemma_simple_step(p, c, trusted, s, s2, k2, len, h);
}

#[verifier::spinoff_prover]
pub proof fn lemma_store_field_this(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s), cur_op(p, s) == STORE_FIELD_THIS,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let len = 2int;
    let f = b1_of(p, m, off);
    assert(post(p, c, m, off, k, trusted) == Some(k));
    assert(map_at(c, m, off + len) == Some(k));
    lemma_this_ok(p, c, trusted, s, f);
    lemma_at_good(p, c, trusted, s, 0);
    assert(step(p, s) == op_store_field_this(p, s, f)) by { reveal(step); }
    let inst = s.stack[top(s).base as int];
    if is_ro(s, inst) {
        lemma_raise_step(p, c, trusted, s, INVALID_PROGRAM);
    } else {
        let v = at(s, 0);
        lemma_set_field2(p, c, s, inst, f, v);
        let s2 = goto(set_field2(s, inst, f, v), s.bci + len);
        assert(k.subrange(0, h) =~= k.subrange(0, h));
        assert(simple_step(p, c, s, s2, k, len, h));
        lemma_simple_step(p, c, trusted, s, s2, k, len, h);
    }
}

pub proof fn lemma_step_field(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s), fam_field(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    let op = cur_op(p, s);
    if op == LOAD_FIELD || op == LOAD_FIELD_WIDE {
        lemma_load_field(p, c, trusted, s);
    } else if op == LOAD_FIELD_LOCAL || op == POP_LOAD_FIELD_LOCAL {
        lemma_load_field_local(p, c, trusted, s);
    } else if op == STORE_FIELD || op == STORE_FIELD_WIDE || op == STORE_FIELD_POP {
        lemma_store_field(p, c, trusted, s);
    } else if op == LOAD_FIELD_THIS {
        lemma_load_field_this(p, c, trusted, s);
    } else {
        lemma_store_field_this(p, c, trusted, s);
    }
}

} // verus!
