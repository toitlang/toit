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

//! PRIMITIVE: the step leaves the state for its completions, and every
//! completion (oracle success and failure, a missing primitive, the task
//! primitives) keeps the invariant. Also the initial state.

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
use crate::v2::sound_unwind::*;
use crate::v2::sound_return::*;
use crate::v2::sound_raise::*;
use crate::v2::sound_heap::*;
use crate::v2::sound_instr::*;
use crate::v2::prim::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, u16_at, smi, builtin, instance_field_count, is_instance,
    fields, set_field, class_of_obj, obj, obj_id, STACK_CLASS, TASK_CLASS, ENTRY_MAIN, ENTRY_TASK};

verus! {

// ---------------------------------------------------------------------------
// Invariant pieces that only read the heap, stack, frames, handlers, bci.

pub open spec fn same_task(s: State2, s2: State2) -> bool {
    &&& s2.heap == s.heap
    &&& s2.stack == s.stack
    &&& s2.frames == s.frames
    &&& s2.tries == s.tries
    &&& s2.fins == s.fins
    &&& s2.bci == s.bci
}

pub proof fn lemma_conf_same(p: Program2, c: Cert, s: State2, s2: State2, fi: int, kf: Seq<Kind>, j: int, k: Kind, v: Value)
    requires conf(p, c, s, fi, kf, j, k, v), same_task(s, s2),
    ensures conf(p, c, s2, fi, kf, j, k, v),
{
    reveal(conf);
    reveal(pending_ok);
    reveal(good_ref);
    assert(kinds_of(p, c, s2, fi) == kinds_of(p, c, s, fi));
    match k {
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_context_frame_same(s, s2, fi, d as nat);
                    assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                    assert(fmethod(s2, fi) == fmethod(s, fi));
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Smi(kk) => if v != null2(p) {
                    match s.fins[kk as int].resume {
                        Resume::Branch(f, bci, hb) => {
                            assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                            assert(frame_kinds_from(p, c, s2, fi, kf, f as int) == frame_kinds_from(p, c, s, fi, kf, f as int));
                            assert(fmethod(s2, f as int) == fmethod(s, f as int));
                            assert(fbase(s2, f as int) == fbase(s, f as int));

                        },
                        _ => {},
                    }
                },
                _ => {},
            }
        },
        _ => {},
    }
}

/// The task invariant does not read the globals, the task or the task id.
pub proof fn lemma_wf_task_same(p: Program2, c: Cert, s: State2, s2: State2)
    requires wf_task(p, c, s), same_task(s, s2),
    ensures wf_task(p, c, s2),
{
    reveal(wf_task);
    reveal(frame_ok);
    assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
        assert(base_step(s, fi));
    }
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        assert(frame_ok(p, c, s, fi));
        assert(kinds_of(p, c, s2, fi) == kinds_of(p, c, s, fi));
        assert(try_frame(s2, fi) == try_frame(s, fi));
        assert forall|j: int| 0 <= j < slots(s2, fi) implies
            #[trigger] conf(p, c, s2, fi, kinds_of(p, c, s2, fi), j, kinds_of(p, c, s2, fi)[j], s2.stack[fbase(s2, fi) + j]) by {
            assert(conf(p, c, s, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[fbase(s, fi) + j]));
            lemma_conf_same(p, c, s, s2, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[fbase(s, fi) + j]);
        }
        let m = fmethod(s, fi);
        let i = info(p, m);
        if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
            let r = s.stack[fbase(s, fi)];
            assert(class_id_ok(as1(s2), r) == class_id_ok(as1(s), r));
            assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
        }
        assert(receiver_ok(p, s2, fi));
    }
    assert forall|x: int| 0 <= x < s2.tries.len() implies #[trigger] try_ok(s2, x) by {
        assert(try_ok(s, x));
    }
}

/// `lemma_wf_unw` for states that are only `roomy`.
pub proof fn lemma_wf_unw_roomy(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), roomy(s),
    ensures
        unw_ok(p, c, s, kinds_of(p, c, s, top_i(s))),
        !has_handler(s),
{
    let t = top_i(s);
    let kt = kinds_of(p, c, s, t);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    lemma_top_kinds(p, c, s);
    assert(frame_ok(p, c, s, t)) by { reveal(wf_task); }
    assert(fins_ok(s)) by { reveal(wf_task); }
    reveal(frame_ok);
    assert forall|fi: int| 0 <= fi < t implies #[trigger] frame_ok(p, c, s, fi) by { reveal(wf_task); }
    assert forall|x: int| 0 <= x < s.tries.len() implies #[trigger] handler_ok(s, x) by {
        assert(try_ok(s, x));
        if x > 0 { assert(try_ok(s, x - 1)); }
    }
    if has_handler(s) {
        assert(try_ok(s, s.tries.len() - 1));
    }
    lemma_map_instr(p, c, trusted, fmethod(s, t), foff(p, s, t));
    assert forall|j: int| 0 <= j < kt.len() implies #[trigger] wf_kind(p, c, fmethod(s, t), kt, j) by {}
}

// ---------------------------------------------------------------------------
// The PRIMITIVE instruction.

/// The verifier's facts at a PRIMITIVE.
#[verifier::spinoff_prover]
pub proof fn lemma_prim_facts(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), cur_op(p, s) == PRIMITIVE,
    ensures ({
        let m = cur_m(s);
        let off = cur_off(p, s);
        let k = cur_k(p, c, s);
        let module = p.bytecodes[s.bci + 1];
        let index = u16_at(p1(p), s.bci + 2);
        &&& s.bci + 4 <= p.bytecodes.len()
        &&& p.bytecodes.len() < 0x1000_0000
        &&& info(p, m).entry <= s.bci
        &&& off == s.bci - info(p, m).entry
        &&& map_at(c, m, off) == Some(k)
        &&& map_at(c, m, off + 4) == Some(k.push(Kind::Val))
        &&& k.len() == arity(p, m)
        &&& info(p, m).kind == KIND_METHOD
        &&& 0 <= index < 0x10000
        // The verifier's primitive table (`c.prim_arity`) gives the
        // primitive the method's arity.
        &&& (module as int) < c.prim_arity.len() && index < c.prim_arity[module as int].len()
        &&& c.prim_arity[module as int][index] == arity(p, m)
        &&& (module == 0 && index == PRIM_TASK_NEW ==> arity(p, m) == 1)
        &&& (module == 0 && index == PRIM_TASK_TRANSFER ==>
                arity(p, m) == 2 && k[0] is Val && k[1] is Val && !has_receiver_range(info(p, m)))
    }),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    assert(op_of(p, m, off) == PRIMITIVE);
    assert(opcode_length2(PRIMITIVE) == 4);
    assert(!is_terminator(PRIMITIVE));
    assert(post(p, c, m, off, k, trusted) is Some);
    assert(post(p, c, m, off, k, trusted) == Some(k.push(Kind::Val)));
    assert(instr_at(p, m, off) == s.bci);
}

/// Failure: the error is pushed and execution continues after the
/// PRIMITIVE (map `k.push(Val)`), with any grown heap.
pub proof fn lemma_failure(p: Program2, c: Cert, trusted: bool, s: State2, h2: Seq<HeapObj>, v: Value)
    requires
        accepts(p, c, trusted), wf(p, c, s), cur_op(p, s) == PRIMITIVE,
        heap_ok(p, c, h2), heap_ext(p, s.heap, h2), good(h2, v),
    ensures
        wf(p, c, goto(push(with_heap(s, h2), v), s.bci + 4)),
        outcome_ok(p, c, prim_failure(s, h2, v)),
{
    lemma_instr(p, c, trusted, s);
    lemma_prim_facts(p, c, trusted, s);
    let t = top_i(s);
    let b = cur_b(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let k2 = k.push(Kind::Val);
    let s2 = goto(push(with_heap(s, h2), v), s.bci + 4);
    assert(s2.bci as int == s.bci + 4);
    assert(s2.bci - info(p, m).entry == cur_off(p, s) + 4);
    lemma_globals_heap(c, s, h2);
    lemma_consts_heap(p, s.heap, h2);
    assert forall|j: int| 0 <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, t, kinds_of(p, c, s2, t), j, k2[j], s2.stack[b + j]) by {
        if j == k.len() {
            reveal(conf);
            assert(s2.stack[b + j] == v);
        } else {
            assert(k2[j] == k[j]);
            assert(s2.stack[b + j] == s.stack[b + j]);
        }
    }
    assert forall|j: int| 0 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
            k2.subrange(0, j) == k.subrange(0, j) by {
        assert(k2.subrange(0, j) =~= k.subrange(0, j));
    }
    assert(local_step(p, c, s, s2, k2));
    lemma_local_step(p, c, trusted, s, s2, k2);
    assert(prim_failure(s, h2, v) == Outcome2::Next(s2));
}

/// Success: the frame returns the result, with any grown heap (the state
/// may differ from `s` in the heap and the task bookkeeping).
pub proof fn lemma_success(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, v: Value)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        s1.stack == s.stack, s1.frames == s.frames, s1.tries == s.tries, s1.bci == s.bci,
        s1.globals == s.globals, s1.task == s.task, s1.fins == s.fins,
        heap_ext(p, s.heap, s1.heap), heap_ok(p, c, s1.heap), good(s1.heap, v),
        s1.heap.len() < 0x8000_0000,
    ensures outcome_ok(p, c, return_from(p, s1, v)),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let k = cur_k(p, c, s);
    lemma_globals_heap(c, s, s1.heap);
    lemma_consts_heap(p, s.heap, s1.heap);
    assert(globals_ok(c, s1));
    assert forall|j: int| 0 <= j < k.len() implies #[trigger] unchanged(p, c, s, s1, k, j) by {}
    assert forall|j: int| 0 <= j < k.len() && #[trigger] unchanged(p, c, s, s1, k, j) && k[j] is Token implies
            k.subrange(0, j) == k.subrange(0, j) by {}
    assert(local_step(p, c, s, s1, k));
    lemma_local_step(p, c, trusted, s, s1, k);
    lemma_wf_unw_roomy(p, c, trusted, s1);
    lemma_return(p, c, trusted, s1, kinds_of(p, c, s1, top_i(s1)), v);
}

/// What the oracle may do to the heap keeps it well formed.
pub proof fn lemma_prim_heap(p: Program2, c: Cert, h: Seq<HeapObj>, h2: Seq<HeapObj>)
    requires heap_ok(p, c, h), prim_heap_ok(p, h, h2),
    ensures heap_ok(p, c, h2), heap_ext(p, h, h2),
{
    assert(heap_grows(h, h2));
    assert(heap_ext(p, h, h2));
    reveal(heap_ok);
    assert forall|i: int| 0 <= i < h2.len() implies #[trigger] obj_ok(p, c, h2, h2[i]) by {
        assert(basic_obj_ok(p, h2, h2[i]));
        if i < h.len() && h[i].body is Stack2 {
            assert(obj_ok(p, c, h, h[i]));
            lemma_obj_ok_mono(p, c, h, h2, h[i]);
            assert(h2[i].body == h[i].body);
        }
        if h2[i].class_id as int == task_class(p) {
            assert(i < h.len());
            assert(h[i].class_id == h2[i].class_id);
            assert(obj_ok(p, c, h, h[i]));
            assert(task_obj_ok(h, h[i]));
            assert(task_fields_kept(h[i], h2[i]));
            match (h[i].body, h2[i].body) {
                (Body::Instance(f), Body::Instance(f2)) => {
                    match f[0] {
                        Value::Obj(j) => if (j as int) < h.len() && h[j as int].body is Stack2 {
                            assert(h2[j as int].body is Stack2);
                        },
                        _ => {},
                    }
                    assert(task_obj_ok(h2, h2[i]));
                },
                _ => {},
            }
        }
    }
}

pub proof fn lemma_oracle(p: Program2, c: Cert, trusted: bool, s: State2, h2: Seq<HeapObj>, v: Value)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == PRIMITIVE,
        prim_heap_ok(p, s.heap, h2), good(h2, v),
    ensures
        outcome_ok(p, c, prim_success(p, s, h2, v)),
        outcome_ok(p, c, prim_failure(s, h2, v)),
{
    lemma_wf_parts(p, c, s);
    lemma_prim_heap(p, c, s.heap, h2);
    lemma_success(p, c, trusted, s, with_heap(s, h2), v);
    lemma_failure(p, c, trusted, s, h2, v);
}

// ---------------------------------------------------------------------------
// New tasks.

pub proof fn lemma_consts_good(p: Program2, h: Seq<HeapObj>, i: int)
    requires consts_ok(p, h), 0 <= i < p.roots.len(),
    ensures good(h, p.roots[i]),
{}

/// Appending the stack object of a task that never ran and its task.
pub proof fn lemma_new_task_heap(p: Program2, c: Cert, trusted: bool, h: Seq<HeapObj>, w: Seq<Value>, ntid: int)
    requires
        accepts(p, c, trusted), heap_ok(p, c, h), consts_ok(p, h), h.len() < 0x8000_0000,
        w.len() <= 1, w.len() == 1 ==> good(h, w[0]),
    ensures ({
        let h2 = h.push(stack_obj2(p, w, Seq::empty(), Seq::empty(), Seq::empty(), 0)).push(new_task_obj2(p, h.len() as int, ntid));
        &&& heap_ok(p, c, h2)
        &&& heap_ext(p, h, h2)
        &&& h2.len() == h.len() + 2
    }),
{
    assert(tables_ok(p, c));
    assert(crate::v2::exec::wf_program2(p));
    let so = stack_obj2(p, w, Seq::empty(), Seq::empty(), Seq::empty(), 0);
    let h1 = h.push(so);
    let scl = builtin(p1(p), STACK_CLASS);
    assert(machine_class_ok(p, STACK_CLASS));
    assert(so.class_id as int == scl);
    assert(scl != task_class(p));
    assert(basic_obj_ok(p, h1, so));
    assert(obj_ok(p, c, h1, so));
    lemma_heap_push(p, c, h, so);
    let to = new_task_obj2(p, h.len() as int, ntid);
    let h2 = h1.push(to);
    let cid = builtin(p1(p), TASK_CLASS);
    assert(to.class_id as int == cid);
    lemma_consts_good(p, h, 0);
    assert(basic_obj_ok(p, h2, to)) by {
        let f = to.body->Instance_0;
        assert(f.len() == ifc(p, cid));
        assert forall|i: int| 0 <= i < f.len() implies good(h2, #[trigger] f[i]) by {}
    }
    assert(task_obj_ok(h2, to)) by {
        let f = to.body->Instance_0;
        assert(f.len() >= 2);
        assert(f[0] == Value::Obj(h.len() as usize));
        assert(f[1] == smi(ntid));
        assert(h2[h.len() as int] == so);
        assert(stack_ref(h2, f[0]));
    }
    assert(obj_ok(p, c, h2, to));
    lemma_heap_push(p, c, h1, to);
    lemma_heap_ext_trans(p, h, h1, h2);
}

pub proof fn lemma_task_new(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == PRIMITIVE,
        p.bytecodes[s.bci + 1] == 0, u16_at(p1(p), s.bci + 2) == PRIM_TASK_NEW,
    ensures outcome_ok(p, c, task_new_step(p, s, s.stack[fbase(s, top_i(s))])),
{
    lemma_instr(p, c, trusted, s);
    lemma_prim_facts(p, c, trusted, s);
    let code = s.stack[fbase(s, top_i(s))];
    assert(tables_ok(p, c));
    assert(crate::v2::exec::wf_program2(p));
    if !is_instance(as1(s), code) {
        lemma_consts_good(p, s.heap, 30);
        lemma_failure(p, c, trusted, s, s.heap, wrong_object_type(p));
        return;
    }
    assert(entry_ok(p, c, ENTRY_TASK, 1));
    let cid = builtin(p1(p), TASK_CLASS);
    assert(0 <= cid < p.class_bits.len() && instance_field_count(p1(p), cid) >= 2);
    lemma_new_task_heap(p, c, trusted, s.heap, seq![code], s.next_task_id as int);
    let h2 = s.heap.push(stack_obj2(p, seq![code], Seq::empty(), Seq::empty(), Seq::empty(), 0))
        .push(new_task_obj2(p, s.heap.len() as int, s.next_task_id as int));
    let s0 = State2 { next_task_id: (s.next_task_id + 1) as i64, ..s };
    let s1 = State2 { heap: h2, ..s0 };
    let task = Value::Obj((s.heap.len() + 1) as usize);
    lemma_success(p, c, trusted, s, s1, task);
    assert(task_new_step(p, s, code) == prim_success(p, s0, h2, task));
}

// ---------------------------------------------------------------------------
// Task transfer.

/// The heap after a transfer: the running task's state saved into its
/// stack object, and maybe its stack field cleared.
pub open spec fn detached_heap(p: Program2, s: State2, detach: Value) -> Seq<HeapObj> {
    let from = Value::Obj(s.task);
    if detach == true2(p) {
        s.heap.update(obj_id(from), HeapObj { body: Body::Instance(fields(as1(s), from).update(0, smi(0))), ..obj(as1(s), from) })
    } else {
        s.heap
    }
}

pub open spec fn saved_obj(s: State2) -> HeapObj {
    let from = Value::Obj(s.task);
    HeapObj { body: Body::Stack2(s.stack, s.frames, s.tries, s.fins, s.bci), ..obj(as1(s), task_stack_ref(s, from)) }
}

pub open spec fn transfer_ready(p: Program2, s: State2, to: Value, detach: Value) -> bool {
    let from = Value::Obj(s.task);
    &&& is_task(p, s, to)
    &&& (detach == true2(p) || detach == false2(p))
    &&& from != to
    &&& has_stack2(s, to)
    &&& resumable(s, to)
    &&& is_task(p, s, from)
    &&& has_stack2(s, from)
}

/// Detaching the running task's stack (its stack field becomes the smi 0)
/// keeps the heap well formed.
pub proof fn lemma_detach_heap(p: Program2, c: Cert, s: State2)
    requires heap_ok(p, c, s.heap), running_ok(p, s),
    ensures ({
        let hd = detached_heap(p, s, true2(p));
        &&& heap_ok(p, c, hd)
        &&& heap_grows(s.heap, hd)
        &&& hd.len() == s.heap.len()
        &&& forall|i: int| 0 <= i < hd.len() && i != s.task as int ==> #[trigger] hd[i] == s.heap[i]
    }),
{
    let t = s.task as int;
    let from = Value::Obj(s.task);
    let o = s.heap[t];
    let fs = fields(as1(s), from);
    let fs2 = fs.update(0, smi(0));
    let o2 = HeapObj { body: Body::Instance(fs2), ..o };
    let hd = s.heap.update(t, o2);
    assert(obj(as1(s), from) == o);
    assert(detached_heap(p, s, true2(p)) == hd);
    reveal(heap_ok);
    assert(obj_ok(p, c, s.heap, o));
    assert(heap_grows(s.heap, hd));
    assert forall|i: int| 0 <= i < hd.len() implies #[trigger] obj_ok(p, c, hd, hd[i]) by {
        if i != t {
            assert(obj_ok(p, c, s.heap, s.heap[i]));
            lemma_obj_ok_mono(p, c, s.heap, hd, s.heap[i]);
        } else {
            assert forall|j: int| 0 <= j < fs2.len() implies good(hd, #[trigger] fs2[j]) by {
                if j != 0 { assert(good(s.heap, fs[j])); }
            }
            assert(basic_obj_ok(p, hd, o2));
            assert(task_obj_ok(hd, o2));
        }
    }
}

/// The heap after the transfer is well formed: the saved state is a
/// well-formed task at its task_transfer.
#[verifier::spinoff_prover]
pub proof fn lemma_transfer_heap(p: Program2, c: Cert, trusted: bool, s: State2, to: Value, detach: Value)
    requires
        accepts(p, c, trusted), wf(p, c, s), cur_op(p, s) == PRIMITIVE,
        p.bytecodes[s.bci + 1] == 0, u16_at(p1(p), s.bci + 2) == PRIM_TASK_TRANSFER,
        transfer_ready(p, s, to, detach),
    ensures ({
        let from = Value::Obj(s.task);
        let fsid = obj_id(task_stack_ref(s, from));
        let hd = detached_heap(p, s, detach);
        let hf = hd.update(fsid, saved_obj(s));
        &&& heap_ok(p, c, hf)
        &&& heap_grows(s.heap, hf)
        &&& hf.len() == s.heap.len()
        &&& 0 <= fsid < s.heap.len()
        &&& s.heap[fsid].body is Stack2
        &&& s.heap[s.task as int].body is Instance
        &&& forall|i: int| 0 <= i < hf.len() && i != s.task as int && i != fsid ==> #[trigger] hf[i] == s.heap[i]
    }),
{
    lemma_instr(p, c, trusted, s);
    lemma_prim_facts(p, c, trusted, s);
    lemma_wf_parts(p, c, s);
    let from = Value::Obj(s.task);
    let fromid = s.task as int;
    let fsid = obj_id(task_stack_ref(s, from));
    let hd = detached_heap(p, s, detach);
    let saved = saved_obj(s);
    let hf = hd.update(fsid, saved);
    // The detached heap.
    if detach == true2(p) {
        lemma_detach_heap(p, c, s);
    } else {
        lemma_heap_ext_refl(p, s.heap);
    }
    assert(heap_ok(p, c, hd) && heap_grows(s.heap, hd) && hd.len() == s.heap.len());
    assert(forall|i: int| 0 <= i < hd.len() && i != fromid ==> #[trigger] hd[i] == s.heap[i]);
    assert(fsid != fromid);
    assert(hd[fsid] == s.heap[fsid]);
    assert(heap_grows(hd, hf));
    assert(heap_grows(s.heap, hf));
    // The saved state.
    let ss = susp_state(s.heap, s.stack, s.frames, s.tries, s.fins, s.bci);
    lemma_wf_task_same(p, c, s, ss);
    lemma_wf_task_heap(p, c, ss, hf);
    assert(with_heap(ss, hf) == susp_state(hf, s.stack, s.frames, s.tries, s.fins, s.bci));
    assert(at_transfer(p, susp_state(hf, s.stack, s.frames, s.tries, s.fins, s.bci)));
    reveal(heap_ok);
    assert(obj_ok(p, c, s.heap, s.heap[fsid]));
    assert(basic_obj_ok(p, hf, saved));
    assert(saved.class_id as int != task_class(p)) by {
        assert(obj_ok(p, c, s.heap, s.heap[fsid]));
    }
    assert(obj_ok(p, c, hf, saved));
    assert forall|i: int| 0 <= i < hf.len() implies #[trigger] obj_ok(p, c, hf, hf[i]) by {
        if i != fsid {
            assert(obj_ok(p, c, hd, hd[i]));
            lemma_obj_ok_mono(p, c, hd, hf, hd[i]);
        }
    }
}

/// The state of a new task after a transfer to it is well formed.
#[verifier::spinoff_prover]
pub proof fn lemma_resume_new(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, to: Value, words: Seq<Value>)
    requires
        accepts(p, c, trusted), wf(p, c, s), cur_op(p, s) == PRIMITIVE,
        p.bytecodes[s.bci + 1] == 0, u16_at(p1(p), s.bci + 2) == PRIM_TASK_TRANSFER,
        s2.frames == s.frames, s2.bci == s.bci, s2.globals == s.globals,
        heap_ok(p, c, s2.heap), heap_grows(s.heap, s2.heap),
        running_ok(p, State2 { task: obj_id(to) as usize, ..s2 }),
        good(s2.heap, to), words.len() >= 1, good(s2.heap, words[0]),
    ensures outcome_ok(p, c, resume(p, s2, to, words, Seq::empty(), Seq::empty(), Seq::empty(), 0)),
{
    lemma_instr(p, c, trusted, s);
    lemma_prim_facts(p, c, trusted, s);
    assert(tables_ok(p, c));
    assert(crate::v2::exec::wf_program2(p));
    let e = entry_method(p, ENTRY_TASK);
    assert(entry_ok(p, c, ENTRY_TASK, 1));
    let entry = info(p, e).entry;
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let hf = s2.heap;
    let r = State2 {
        stack: seq![words[0], to, false2(p), to],
        frames: seq![
            Frame { method: e as usize, ret: entry, base: 0 },
            Frame { method: top(s2).method, ret: (entry + 1) as usize, base: 1 },
        ],
        tries: Seq::empty(),
        fins: Seq::empty(),
        bci: (s2.bci + 4) as usize,
        task: obj_id(to) as usize,
        ..s2
    };
    assert(resume(p, s2, to, words, Seq::empty(), Seq::empty(), Seq::empty(), 0) == Outcome2::Next(r));
    lemma_wf_parts(p, c, s);
    lemma_globals_heap(c, s, hf);
    lemma_consts_heap(p, s.heap, hf);
    lemma_consts_good(p, hf, 2);
    assert(globals_ok(c, r));
    assert(bases_ok(r)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < r.frames.len() implies #[trigger] base_step(r, fi) by {}
    }
    assert(top(s2).method as int == m);
    // The entry frame.
    assert(entry + 1 < 0x1_0000_0000) by {
        lemma_map_bound(p, c, trusted, e, 1);
    }
    assert(foff(p, r, 0) == 1);
    assert(fmap(p, c, r, 0) == seq![Kind::Val, Kind::Val]);
    assert(!try_frame(r, 0));
    assert(kinds_of(p, c, r, 0) =~= seq![Kind::Val]);
    assert(frame_ok(p, c, r, 0)) by {
        reveal(frame_ok);
        reveal(conf);
        assert(frame_shape_ok(p, c, r, 0));
        assert forall|j: int| 0 <= j < slots(r, 0) implies
            #[trigger] conf(p, c, r, 0, kinds_of(p, c, r, 0), j, kinds_of(p, c, r, 0)[j], r.stack[fbase(r, 0) + j]) by {
            assert(j == 0);
        }
    }
    // The transferring frame: its map after the PRIMITIVE has three values.
    assert(foff(p, r, 1) == cur_off(p, s) + 4);
    assert(fmap(p, c, r, 1) == k.push(Kind::Val));
    assert(k.push(Kind::Val) =~= seq![Kind::Val, Kind::Val, Kind::Val]);
    assert(kinds_of(p, c, r, 1) =~= seq![Kind::Val, Kind::Val, Kind::Val]);
    assert(frame_ok(p, c, r, 1)) by {
        reveal(frame_ok);
        reveal(conf);
        assert(frame_shape_ok(p, c, r, 1));
        assert forall|j: int| 0 <= j < slots(r, 1) implies
            #[trigger] conf(p, c, r, 1, kinds_of(p, c, r, 1), j, kinds_of(p, c, r, 1)[j], r.stack[fbase(r, 1) + j]) by {
            assert(0 <= j < 3);
        }
    }
    assert(wf_task(p, c, r)) by {
        reveal(wf_task);
        assert forall|fi: int| 0 <= fi < r.frames.len() implies #[trigger] frame_ok(p, c, r, fi) by {
            if fi == 0 {} else { assert(fi == 1); }
        }
    }
    assert(wf(p, c, r)) by { reveal(wf); }
}

/// A suspended task resumes after its task_transfer with `to` pushed: the
/// failure completion of the saved state.
pub proof fn lemma_resume_susp(p: Program2, c: Cert, trusted: bool, s2: State2, to: Value,
    words: Seq<Value>, frames: Seq<Frame>, tries: Seq<Handler>, fins: Seq<Fin>, bci: usize)
    requires
        accepts(p, c, trusted),
        heap_ok(p, c, s2.heap), globals_ok(c, s2), consts_ok(p, s2.heap),
        running_ok(p, State2 { task: obj_id(to) as usize, ..s2 }),
        frames.len() > 0,
        susp_ok(p, c, s2.heap, words, frames, tries, fins, bci),
        good(s2.heap, to),
    ensures outcome_ok(p, c, resume(p, s2, to, words, frames, tries, fins, bci as int)),
{
    let hf = s2.heap;
    let r0 = State2 { stack: words, frames: frames, tries: tries, fins: fins, bci: bci, task: obj_id(to) as usize, ..s2 };
    lemma_wf_task_same(p, c, susp_state(hf, words, frames, tries, fins, bci), r0);
    assert(wf(p, c, r0)) by { reveal(wf); }
    assert(cur_op(p, r0) == PRIMITIVE);
    lemma_heap_ext_refl(p, hf);
    lemma_failure(p, c, trusted, r0, hf, to);
    assert(with_heap(r0, hf) == r0);
    assert(resume(p, s2, to, words, frames, tries, fins, bci as int) == prim_failure(r0, hf, to));
}

#[verifier::spinoff_prover]
pub proof fn lemma_transfer_main(p: Program2, c: Cert, trusted: bool, s: State2, to: Value, detach: Value)
    requires
        accepts(p, c, trusted), wf(p, c, s), cur_op(p, s) == PRIMITIVE,
        p.bytecodes[s.bci + 1] == 0, u16_at(p1(p), s.bci + 2) == PRIM_TASK_TRANSFER,
        transfer_ready(p, s, to, detach),
    ensures outcome_ok(p, c, task_transfer_step(p, s, to, detach)),
{
    lemma_instr(p, c, trusted, s);
    lemma_wf_parts(p, c, s);
    lemma_transfer_heap(p, c, trusted, s, to, detach);
    let from = Value::Obj(s.task);
    let fromid = s.task as int;
    let fs = task_stack_ref(s, from);
    let fsid = obj_id(fs);
    let saved = saved_obj(s);
    let hd = detached_heap(p, s, detach);
    let hf = hd.update(fsid, saved);
    let s1 = State2 { heap: s.heap.update(fsid, saved), ..s };
    assert(saved == HeapObj { body: Body::Stack2(s.stack, s.frames, s.tries, s.fins, s.bci), ..obj(as1(s), fs) });
    let s2 = if detach == true2(p) { State2 { heap: set_field(as1(s1), from, 0, smi(0)).heap, ..s1 } } else { s1 };
    assert(s2.heap =~= hf) by {
        if detach == true2(p) {
            assert(obj(as1(s1), from) == obj(as1(s), from));
            assert(fields(as1(s1), from) == fields(as1(s), from));
        }
    }
    assert(s2 == State2 { heap: hf, ..s });
    // The target's stack object.
    let toid = obj_id(to);
    assert(s.heap[toid].body is Instance);
    assert(toid != fsid && toid != fromid);
    assert(hf[toid] == s.heap[toid]);
    let ts = task_stack_ref(s, to);
    assert(task_stack_ref(s2, to) == ts);
    let tid = obj_id(ts);
    assert(s.heap[tid].body is Stack2);
    assert(tid != fromid);
    assert(0 <= tid < hf.len());
    let tobj = hf[tid];
    assert(obj(as1(s2), ts) == tobj);
    assert(running_ok(p, State2 { task: obj_id(to) as usize, ..s2 })) by {
        assert(s.heap[toid].class_id as int == task_class(p));
        if tid == fsid { assert(hf[tid] == saved); } else { assert(hf[tid] == s.heap[tid]); }
    }
    reveal(heap_ok);
    assert(obj_ok(p, c, hf, tobj));
    lemma_globals_heap(c, s, hf);
    lemma_consts_heap(p, s.heap, hf);
    assert(good(hf, to));
    match tobj.body {
        Body::Stack2(words, frames, tries, fins, bci) => {
            assert(task_transfer_step(p, s, to, detach) == resume(p, s2, to, words, frames, tries, fins, bci as int));
            if frames.len() == 0 {
                if tid == fsid {
                    assert(frames == s.frames);
                } else {
                    assert(tobj == s.heap[tid]);
                }
                assert(words.len() >= 1);
                lemma_resume_new(p, c, trusted, s, s2, to, words);
            } else {
                assert(globals_ok(c, s2));
                lemma_resume_susp(p, c, trusted, s2, to, words, frames, tries, fins, bci);
            }
        },
        _ => {
            if tid == fsid {} else { assert(tobj == s.heap[tid]); }
        },
    }
}

pub proof fn lemma_task_transfer(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == PRIMITIVE,
        p.bytecodes[s.bci + 1] == 0, u16_at(p1(p), s.bci + 2) == PRIM_TASK_TRANSFER,
    ensures outcome_ok(p, c, task_transfer_step(p, s,
        s.stack[fbase(s, top_i(s))], s.stack[fbase(s, top_i(s)) + 1])),
{
    lemma_instr(p, c, trusted, s);
    lemma_prim_facts(p, c, trusted, s);
    lemma_wf_parts(p, c, s);
    assert(crate::v2::exec::wf_program2(p));
    let to = s.stack[fbase(s, top_i(s))];
    let detach = s.stack[fbase(s, top_i(s)) + 1];
    let from = Value::Obj(s.task);
    if !is_task(p, s, to) || !(detach == true2(p) || detach == false2(p)) {
        lemma_consts_good(p, s.heap, 30);
        lemma_heap_ext_refl(p, s.heap);
        lemma_failure(p, c, trusted, s, s.heap, wrong_object_type(p));
    } else if from == to {
        lemma_heap_ext_refl(p, s.heap);
        lemma_failure(p, c, trusted, s, s.heap, to);
    } else if !is_task(p, s, from) || !has_stack2(s, from) || s.frames.len() == 0 {
        // The running task has its stack.
        assert(running_ok(p, s));
        lemma_task_basics(p, c, s);
        assert(false);
    } else if !has_stack2(s, to) || !resumable(s, to) {
        lemma_consts_good(p, s.heap, 12);
        lemma_heap_ext_refl(p, s.heap);
        lemma_failure(p, c, trusted, s, s.heap, p.roots[12]);
    } else {
        lemma_transfer_main(p, c, trusted, s, to, detach);
    }
}

// ---------------------------------------------------------------------------
// The family lemma.

pub proof fn lemma_completions(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == PRIMITIVE,
    ensures completions_ok(p, c, s, p.bytecodes[s.bci + 1], u16_at(p1(p), s.bci + 2) as u16),
{
    lemma_prim_facts(p, c, trusted, s);
    let module = p.bytecodes[s.bci + 1];
    let index = u16_at(p1(p), s.bci + 2) as u16;
    assert(index as int == u16_at(p1(p), s.bci + 2));
    assert forall|h2: Seq<HeapObj>, r: PrimRet| prim_default(p, s.heap, h2, r) implies
        outcome_ok(p, c, #[trigger] prim_complete(p, s, h2, r)) by {
        match r {
            PrimRet::Success(v) => { lemma_oracle(p, c, trusted, s, h2, v); },
            PrimRet::Failure(v) => { lemma_oracle(p, c, trusted, s, h2, v); },
            PrimRet::OutOfMemory(v) => { lemma_prim_oom(p, c, trusted, s, h2, v); },
        }
    }
    lemma_raise(p, c, trusted, s, PRIMITIVE_LOOKUP_FAILED);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    if module == 0 && index as int == PRIM_TASK_NEW {
        lemma_task_new(p, c, trusted, s);
    }
    if module == 0 && index as int == PRIM_TASK_TRANSFER {
        lemma_task_transfer(p, c, trusted, s);
    }
}

/// A primitive ran out of memory: its resource error is raised from the
/// grown heap.
pub proof fn lemma_prim_oom(p: Program2, c: Cert, trusted: bool, s: State2, h2: Seq<HeapObj>, v: Value)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        prim_heap_ok(p, s.heap, h2), resource_error(p, v),
    ensures outcome_ok(p, c, prim_complete(p, s, h2, PrimRet::OutOfMemory(v))),
{
    lemma_wf_unw(p, c, trusted, s);
    let kt = kinds_of(p, c, s, top_i(s));
    lemma_wf_parts(p, c, s);
    lemma_prim_heap(p, c, s.heap, h2);
    lemma_unw_heap(p, c, s, kt, h2);
    let s1 = with_heap(s, h2);
    assert(with_heap2(s, h2) == s1);
    assert(crate::v2::exec::wf_program2(p));
    assert(consts_ok(p, h2));
    assert(good(h2, v));
    lemma_raised(p, c, trusted, s1, kt, v);
}

pub proof fn lemma_step_prim(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), fam_prim(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_prim_facts(p, c, trusted, s);
    assert(cur_op(p, s) == PRIMITIVE);
    let module = p.bytecodes[s.bci + 1];
    let index = u16_at(p1(p), s.bci + 2) as u16;
    assert(frame_height(s) == arity(p, top(s).method as int));
    assert(step(p, s) == Outcome2::Primitive(s, module, index)) by {
        reveal(step);
    }
    lemma_completions(p, c, trusted, s);
}

// ---------------------------------------------------------------------------
// The initial state.

#[verifier::spinoff_prover]
pub proof fn lemma_initial(p: Program2, c: Cert, trusted: bool, heap0: Seq<HeapObj>, globals0: Seq<Value>)
    requires accepts(p, c, trusted), loaded_ok(p, c, heap0, globals0),
    ensures wf(p, c, crate::v2::prim::initial_state(p, heap0, globals0)),
            small(crate::v2::prim::initial_state(p, heap0, globals0)),
{
    let s = initial_state(p, heap0, globals0);
    assert(tables_ok(p, c));
    assert(crate::v2::exec::wf_program2(p));
    let e = entry_method(p, ENTRY_MAIN);
    assert(entry_ok(p, c, ENTRY_MAIN, 1));
    assert(method_ok(p, c, e, trusted));
    assert(method_table_ok(p, c, e));
    // The heap.
    assert(heap_ok(p, c, heap0)) by {
        reveal(heap_ok);
        assert forall|i: int| 0 <= i < heap0.len() implies #[trigger] obj_ok(p, c, heap0, heap0[i]) by {
            assert(basic_obj_ok(p, heap0, heap0[i]));
        }
    }
    lemma_new_task_heap(p, c, trusted, heap0, Seq::empty(), 0);
    assert(s.heap == heap0.push(stack_obj2(p, Seq::empty(), Seq::empty(), Seq::empty(), Seq::empty(), 0))
        .push(new_task_obj2(p, heap0.len() as int, 0)));
    lemma_globals_heap(c, State2 { heap: heap0, ..s }, s.heap);
    lemma_consts_heap(p, heap0, s.heap);
    assert(globals_ok(c, s));
    // The frame of __entry__main(task).
    let ek = entry_kinds(p, c, e);
    assert(!dead_block(p, c, e));
    assert(c.maps[e].len() > 0);
    assert(map_at(c, e, 0) == Some(ek));
    assert(!is_block_param(c, e, 0)) by {
        assert(no_block_params(c, e));
    }
    assert(ek =~= seq![Kind::Val]);
    assert(foff(p, s, 0) == 0);
    assert(fmap(p, c, s, 0) == ek);
    assert(kinds_of(p, c, s, 0) =~= seq![Kind::Val]);
    assert(bases_ok(s));
    assert(frame_ok(p, c, s, 0)) by {
        reveal(frame_ok);
        reveal(conf);
        assert(frame_shape_ok(p, c, s, 0));
        assert forall|j: int| 0 <= j < slots(s, 0) implies
            #[trigger] conf(p, c, s, 0, kinds_of(p, c, s, 0), j, kinds_of(p, c, s, 0)[j], s.stack[fbase(s, 0) + j]) by {
            assert(j == 0);
        }
    }
    assert(wf_task(p, c, s)) by {
        reveal(wf_task);
        assert forall|fi: int| 0 <= fi < s.frames.len() implies #[trigger] frame_ok(p, c, s, fi) by {
            assert(fi == 0);
        }
    }
    assert(wf(p, c, s)) by { reveal(wf); }
}

} // verus!
