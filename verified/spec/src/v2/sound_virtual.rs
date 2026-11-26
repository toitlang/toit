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

//! Soundness of the virtual calls and operators (opcodes 58..=80):
//! INVOKE_VIRTUAL(_WIDE), INVOKE_VIRTUAL_GET/SET with their field-accessor
//! fast paths, the operators with their fast paths, INVOKE_AT,
//! INVOKE_AT_PUT and INVOKE_SIZE.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
use crate::v2::sound_call::*;
use crate::v2::sound_instr::*;
use crate::v2::sound_upto::*;
use crate::v2::sound_heap::*;
use crate::v2::sound_raise::*;
use crate::spec_helpers::FastAt;
#[cfg(verus_only)]
use crate::spec_common::{
    class_id_ok, class_id_of, class_of_obj, u16_at, smi, builtin, obj, obj_id, is_instance,
    fields, is_array, elements, is_bytes, bytes, set_obj, new_double, SMI_CLASS, DOUBLE_CLASS,
};
#[cfg(verus_only)]
use crate::spec_helpers::{fast_at, array_at, bytes_at, cow_at, FAST_AT_FUEL, fast_size};

verus! {

// ---------------------------------------------------------------------------
// Steps that pop `n` operands and push a value.

pub open spec fn pp_state(s: State2, n: int, v: Value, h2: Seq<HeapObj>, len: int) -> State2 {
    State2 { heap: h2, stack: s.stack.subrange(0, s.stack.len() - n).push(v), bci: (s.bci + len) as usize, ..s }
}

/// The verifier's map after an instruction that pops `n` operands and
/// pushes a value.
pub open spec fn pp_map(p: Program2, c: Cert, s: State2, n: int, len: int) -> bool {
    let k = cur_k(p, c, s);
    &&& 0 <= n <= k.len()
    &&& leaves0(p, cur_m(s), k.len() as int, n)
    &&& 1 <= len <= 6
    &&& map_at(c, cur_m(s), cur_off(p, s) + len) == Some(pop_push(k, n, Some(Kind::Val)))
}

#[verifier::spinoff_prover]
pub proof fn lemma_pp_step(p: Program2, c: Cert, trusted: bool, s: State2, n: int, len: int, v: Value, h2: Seq<HeapObj>)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        pp_map(p, c, s, n, len),
        heap_ext(p, s.heap, h2), heap_ok(p, c, h2), good(h2, v),
    ensures wf(p, c, pp_state(s, n, v, h2, len)),
{
    lemma_instr(p, c, trusted, s);
    let s2 = pp_state(s, n, v, h2, len);
    let t = top_i(s);
    let b = fbase(s, t);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let keep = k.len() - n;
    let k2 = pop_push(k, n, Some(Kind::Val));
    assert(s2.bci as int - info(p, m).entry == cur_off(p, s) + len);
    assert(s2.stack.len() == b + k2.len());
    assert forall|x: int| 0 <= x < b implies #[trigger] s2.stack[x] == s.stack[x] by {}
    lemma_globals_heap(c, s, h2);
    lemma_consts_heap(p, s.heap, h2);
    assert forall|j: int| 0 <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, t, kinds_of(p, c, s2, t), j, k2[j], s2.stack[b + j]) by {
        if j < keep {
            assert(unchanged(p, c, s, s2, k2, j));
        } else {
            assert(j == keep);
            assert(k2[j] == Kind::Val);
            assert(s2.stack[b + j] == v);
            reveal(conf);
        }
    }
    assert forall|j: int| 0 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
        k2.subrange(0, j) == k.subrange(0, j) by {
        assert(j < keep);
        assert(k2.subrange(0, j) =~= k.subrange(0, j));
    }
    assert(local_step(p, c, s, s2, k2));
    lemma_local_step(p, c, trusted, s, s2, k2);
}

/// Boolean results are roots, hence values.
pub proof fn lemma_bool_good(p: Program2, h: Seq<HeapObj>, b: bool)
    requires consts_ok(p, h), crate::v2::exec::wf_program2(p),
    ensures good(h, boolean2(p, b)), good(h, false2(p)), good(h, true2(p)),
{
    assert(good(h, p.roots[1]));
    assert(good(h, p.roots[2]));
}

// ---------------------------------------------------------------------------
// Virtual calls.

/// A method found by virtual dispatch with selector `sel` for a call site
/// with `n` arguments.
pub open spec fn vfound(p: Program2, c: Cert, s: State2, t: int, r: int, n: int, len: int) -> bool {
    let k = cur_k(p, c, s);
    let recv = at(s, n - 1);
    &&& valid_method(p, t)
    &&& (info(p, t).kind == KIND_METHOD || info(p, t).kind == KIND_FIELD_ACCESSOR)
    &&& arity(p, t) == n
    &&& valid_method(p, r)
    &&& c.block_params[r] == c.block_params[t]
    &&& args_ok(c, r, k, n)
    &&& 1 <= n
    &&& class_id_ok(as1(s), recv)
    &&& (has_receiver_range(info(p, t)) ==>
            info(p, t).recv_start as int <= class_id_of(p1(p), as1(s), recv) < info(p, t).recv_end as int)
    &&& pp_map(p, c, s, n, len)
}

pub proof fn lemma_vcall_pre(p: Program2, c: Cert, trusted: bool, s: State2, t: int, r: int, n: int, len: int)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), vfound(p, c, s, t, r, n, len),
    ensures call_pre(p, c, s, s, t, s.bci + len, false),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let keep = k.len() - n;
    let kr = pop_push(k, n, Some(Kind::Val));
    lemma_heap_ext_refl(p, s.heap);
    assert((s.bci + len) - info(p, m).entry == cur_off(p, s) + len);
    assert(kr.subrange(0, keep) =~= k.subrange(0, keep));
}

/// Argument `x` of a virtual call conforms to the callee's entry kind.
#[verifier::spinoff_prover]
pub proof fn lemma_varg(p: Program2, c: Cert, trusted: bool, s: State2, t: int, r: int, n: int, len: int, x: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s), vfound(p, c, s, t, r, n, len),
        call_pre(p, c, s, s, t, s.bci + len, false),
        0 <= x < n,
    ensures ({
        let s2 = call_state(p, s, t, s.bci + len);
        let tn = top_i(s2);
        conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, entry_kinds(p, c, t)[x], s2.stack[fbase(s2, tn) + x])
    }),
{
    let ret = s.bci + len;
    let s2 = call_state(p, s, t, ret);
    let t0 = top_i(s);
    let tn = top_i(s2);
    let b = fbase(s, t0);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let keep = k.len() - n;
    let j = keep + x;
    lemma_instr(p, c, trusted, s);
    lemma_call_shape(p, c, trusted, s, s, t, ret, false);
    lemma_task_bases(p, c, s);
    assert(fbase(s2, tn) == b + keep);
    let v = s.stack[b + j];
    assert(s2.stack[fbase(s2, tn) + x] == v);
    lemma_at_conf(p, c, trusted, s, n - 1 - x);
    let kd = k[j];
    assert(top_kind(k, n - 1 - x) == kd);
    assert(at(s, n - 1 - x) == v);
    assert(conf(p, c, s, t0, k, j, kd, v));
    assert(arg_ok(c, r, k, n, x));
    assert(is_block_param(c, t, x) == is_block_param(c, r, x));
    assert(entry_kinds(p, c, t)[x] == (if is_block_param(c, t, x) { Kind::Param } else { Kind::Val }));
    if !is_block_param(c, t, x) {
        lemma_val_good(p, c, s, t0, k, j, kd, v);
        reveal(conf);
    } else {
        reveal(conf);
        assert(is_ref(kd));
        match kd {
            Kind::Block(d, i) => {
                match v {
                    Value::BlockRef(f, slot) => {
                        if d == 0 {
                            assert(f as int == t0);
                            assert(i < keep);
                            assert(ref_ok(s2, f as int, slot as int));
                            assert(wf_kind(p, c, m, k, j));
                            let k2 = kinds_of(p, c, s2, t0);
                            assert(k2 == k.subrange(0, keep));
                            assert(fbase(s2, t0) == b);
                            assert(fmethod(s2, t0) == m);
                            assert(block_slot(p, c, m, k2, i));
                            assert forall|i2: int| 0 <= i2 <= i && i2 < k2.len() implies #[trigger] ctx_ok_at(p, c, m, k2, i2) by {
                                assert(live_from(k, i2)) by {
                                    assert(match k[j] { Kind::Block(dd, ss) => dd == 0 && ss >= i2, _ => false });
                                }
                                assert(ctx_ok_at(p, c, m, k, i2));
                                assert(k2.subrange(0, i2 + 1) =~= k.subrange(0, i2 + 1));
                            }
                            reveal(good_ref);
                            assert(good_ref(p, c, s2, f as int, slot as int));
                        } else {
                            lemma_context_frame_lt(s, t0, d as nat);
                            assert(t0 > 0);
                            lemma_kinds_below(p, c, s, s2, f as int, t0 - 1);
                            lemma_ref_ok_below(s, s2, t0 - 1, f as int, slot as int);
                            reveal(good_ref);
                            assert(good_ref(p, c, s2, f as int, slot as int) == good_ref(p, c, s, f as int, slot as int));
                        }
                    },
                    _ => {},
                }
            },
            Kind::Param => {
                match v {
                    Value::BlockRef(f, slot) => {
                        lemma_kinds_below(p, c, s, s2, f as int, t0 - 1);
                        lemma_ref_ok_below(s, s2, t0 - 1, f as int, slot as int);
                        reveal(good_ref);
                        assert(good_ref(p, c, s2, f as int, slot as int) == good_ref(p, c, s, f as int, slot as int));
                    },
                    _ => {},
                }
            },
            _ => {},
        }
    }
}

pub proof fn lemma_vcall_found(p: Program2, c: Cert, trusted: bool, s: State2, t: int, r: int, n: int, len: int)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), vfound(p, c, s, t, r, n, len),
    ensures outcome_ok(p, c, call(p, s, t, s.bci + len)), call(p, s, t, s.bci + len) is Next,
{
    let ret = s.bci + len;
    lemma_instr(p, c, trusted, s);
    lemma_vcall_pre(p, c, trusted, s, t, r, n, len);
    let s2 = call_state(p, s, t, ret);
    let tn = top_i(s2);
    lemma_call_shape(p, c, trusted, s, s, t, ret, false);
    assert forall|x: int| 0 <= x < arity(p, t) implies
        #[trigger] conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, entry_kinds(p, c, t)[x], s2.stack[fbase(s2, tn) + x]) by {
        lemma_varg(p, c, trusted, s, t, r, n, len, x);
    }
    assert(s2.stack[fbase(s2, tn)] == at(s, n - 1));
    assert(receiver_ok(p, s2, tn));
    assert(call_args(p, c, s, t, ret, false));
    lemma_call(p, c, trusted, s, s, t, ret, false);
    assert(call(p, s, t, ret) == Outcome2::Next(s2));
}

/// Virtual dispatch from a well-formed state at a call site the verifier
/// accepted: never stuck; a found method fits the call site.
#[verifier::spinoff_prover]
pub proof fn lemma_dispatch(p: Program2, c: Cert, trusted: bool, s: State2, sel: int, n: int, len: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        sel_ok(p, c, sel, n, cur_k(p, c, s)),
        pp_map(p, c, s, n, len),
    ensures
        has_slot(s, n - 1),
        match find_method(p, s, at(s, n - 1), sel) {
            Lookup2::Stuck(_) => false,
            Lookup2::Missing => true,
            Lookup2::Found(t) => vfound(p, c, s, t, c.sel_rep[sel], n, len),
        },
{
    lemma_instr(p, c, trusted, s);
    let k = cur_k(p, c, s);
    let recv = at(s, n - 1);
    lemma_at_good(p, c, trusted, s, n - 1);
    let cid = class_id_of(p1(p), as1(s), recv);
    assert(0 <= cid < class_count(p)) by {
        match recv {
            Value::Obj(id) => {
                assert((id as int) < s.heap.len());
                reveal(heap_ok);
                assert(obj_ok(p, c, s.heap, s.heap[id as int]));
                assert(cid == s.heap[id as int].class_id as int);
            },
            _ => {
                assert(machine_class_ok(p, SMI_CLASS));
            },
        }
    }
    let index = cid + sel;
    assert(0 <= index < p.dispatch.len());
    assert(dispatch_entry_ok(p, index));
    let e = p.dispatch[index] as int;
    assert(class_id_ok(as1(s), recv));
    assert(sel >= 0);
    if e != -1 && valid_method(p, e) && info(p, e).selector as int == sel {
        let t = e;
        assert(method_table_ok(p, c, t));
        let r = c.sel_rep[sel];
        assert(index - info(p, t).selector as int == cid);
        assert(vfound(p, c, s, t, r, n, len));
        assert(find_method(p, s, recv, sel) == Lookup2::Found(t));
    } else {
        assert(find_method(p, s, recv, sel) == Lookup2::Missing);
    }
}

/// The call of a virtual dispatch: a raise or a call that keeps the
/// invariant.
pub proof fn lemma_vcall(p: Program2, c: Cert, trusted: bool, s: State2, sel: int, n: int, len: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        sel_ok(p, c, sel, n, cur_k(p, c, s)),
        pp_map(p, c, s, n, len),
    ensures
        has_slot(s, n - 1),
        match find_method(p, s, at(s, n - 1), sel) {
            Lookup2::Stuck(_) => false,
            Lookup2::Missing => outcome_ok(p, c, raise(p, s, LOOKUP_FAILED)) && !(raise(p, s, LOOKUP_FAILED) is Primitive),
            Lookup2::Found(t) => valid_method(p, t) && arity(p, t) == n
                && outcome_ok(p, c, call(p, s, t, s.bci + len)) && call(p, s, t, s.bci + len) is Next,
        },
{
    lemma_dispatch(p, c, trusted, s, sel, n, len);
    match find_method(p, s, at(s, n - 1), sel) {
        Lookup2::Stuck(_) => {},
        Lookup2::Missing => { lemma_raise_ok(p, c, trusted, s, LOOKUP_FAILED); },
        Lookup2::Found(t) => {
            lemma_vcall_found(p, c, trusted, s, t, c.sel_rep[sel], n, len);
        },
    }
}

pub open spec fn ok_np(p: Program2, c: Cert, o: Outcome2) -> bool {
    outcome_ok(p, c, o) && !(o is Primitive)
}

/// `invoke_virtual` at an accepted call site.
pub proof fn lemma_invoke_virtual(p: Program2, c: Cert, trusted: bool, s: State2, sel: int, n: int, len: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        sel_ok(p, c, sel, n, cur_k(p, c, s)),
        pp_map(p, c, s, n, len),
    ensures ok_np(p, c, invoke_virtual(p, s, sel, n, len)),
{
    lemma_vcall(p, c, trusted, s, sel, n, len);
}

/// The fallback of an operator: a virtual call, or a lookup failure for a
/// negative selector.
pub proof fn lemma_fallback(p: Program2, c: Cert, trusted: bool, s: State2, sel: int, n: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        value_operands(cur_k(p, c, s), n), 1 <= n,
        sel < 0 || sel_ok(p, c, sel, n, cur_k(p, c, s)),
        pp_map(p, c, s, n, 1),
    ensures ok_np(p, c, invoke_virtual(p, s, sel, n, 1)),
{
    if sel < 0 {
        lemma_instr(p, c, trusted, s);
        assert(is_val(top_kind(cur_k(p, c, s), n - 1)));
        lemma_at_good(p, c, trusted, s, n - 1);
        lemma_raise_ok(p, c, trusted, s, LOOKUP_FAILED);
    } else {
        lemma_invoke_virtual(p, c, trusted, s, sel, n, 1);
    }
}

// ---------------------------------------------------------------------------
// Fast paths.

/// A field of an instance is a value.
pub proof fn lemma_field_good(p: Program2, c: Cert, s: State2, inst: Value, f: int)
    requires heap_ok(p, c, s.heap), field_ok(s, inst, f),
    ensures good(s.heap, field(s, inst, f)),
{
    let id = obj_id(inst);
    reveal(heap_ok);
    assert(obj_ok(p, c, s.heap, s.heap[id]));
    assert(fields(as1(s), inst) == s.heap[id].body->Instance_0);
}

/// The heap after a fast-path store.
pub open spec fn put_ok(p: Program2, c: Cert, h: Seq<HeapObj>, h2: Seq<HeapObj>) -> bool {
    &&& heap_ok(p, c, h2)
    &&& heap_ext(p, h, h2)
    &&& h2.len() == h.len()
}

pub open spec fn fast_at_ok(p: Program2, c: Cert, s: State2, r: FastAt) -> bool {
    match r {
        FastAt::Get(v) => good(s.heap, v),
        FastAt::Put(s1, v) => put_ok(p, c, s.heap, s1.heap) && good(s.heap, v),
        _ => true,
    }
}

/// Replacing the body of an array or byte array.
pub proof fn lemma_replace_body(p: Program2, c: Cert, s: State2, id: int, o2: HeapObj)
    requires
        heap_ok(p, c, s.heap), 0 <= id < s.heap.len(),
        s.heap[id].body is Array || s.heap[id].body is Bytes,
        o2.class_id == s.heap[id].class_id,
        o2.body is Array || o2.body is Bytes,
        match o2.body { Body::Array(e) => forall|i: int| 0 <= i < e.len() ==> good(s.heap, #[trigger] e[i]), _ => true },
    ensures put_ok(p, c, s.heap, s.heap.update(id, o2)),
{
    reveal(heap_ok);
    assert(obj_ok(p, c, s.heap, s.heap[id]));
    assert(basic_obj_ok(p, s.heap, o2));
    lemma_heap_update(p, c, s.heap, id, o2);
}

pub proof fn lemma_array_at(p: Program2, c: Cert, s: State2, arr: Value, length: int, n: int, is_put: bool, value: Value)
    requires heap_ok(p, c, s.heap), good(s.heap, value), is_array(as1(s), arr), 0 <= n,
    ensures fast_at_ok(p, c, s, array_at(as1(s), arr, length, n, is_put, value)),
{
    let id = obj_id(arr);
    let e = elements(as1(s), arr);
    assert(e == s.heap[id].body->Array_0);
    reveal(heap_ok);
    assert(obj_ok(p, c, s.heap, s.heap[id]));
    if n < length && n < e.len() {
        if is_put {
            if !obj(as1(s), arr).ro {
                let o2 = HeapObj { body: Body::Array(e.update(n, value)), ..s.heap[id] };
                assert forall|i: int| 0 <= i < e.update(n, value).len() implies good(s.heap, #[trigger] e.update(n, value)[i]) by {
                    if i != n { assert(good(s.heap, e[i])); }
                }
                lemma_replace_body(p, c, s, id, o2);
            }
        } else {
            assert(good(s.heap, e[n]));
        }
    }
}

pub proof fn lemma_bytes_at(p: Program2, c: Cert, s: State2, ba: Value, n: int, is_put: bool, value: Value)
    requires heap_ok(p, c, s.heap), is_bytes(as1(s), ba),
    ensures fast_at_ok(p, c, s, bytes_at(as1(s), ba, n, is_put, value)),
{
    let id = obj_id(ba);
    if n < bytes(as1(s), ba).len() && is_put {
        match value {
            Value::Smi(v) => {
                if !obj(as1(s), ba).ro {
                    let b = (v as int) % 256;
                    let o2 = HeapObj { body: Body::Bytes(bytes(as1(s), ba).update(n, b as u8)), ..s.heap[id] };
                    lemma_replace_body(p, c, s, id, o2);
                }
            },
            _ => {},
        }
    }
}

pub proof fn lemma_cow_at(p: Program2, c: Cert, s: State2, cow: Value, n: int, is_put: bool, value: Value)
    requires heap_ok(p, c, s.heap),
    ensures fast_at_ok(p, c, s, cow_at(p1(p), as1(s), cow, n, is_put, value)),
{
    let f = fields(as1(s), cow);
    if f.len() >= 2 && is_bytes(as1(s), f[0]) {
        lemma_bytes_at(p, c, s, f[0], n, is_put, value);
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_fast_at(p: Program2, c: Cert, s: State2, recv: Value, arg: Value, is_put: bool, value: Value, fuel: nat)
    requires heap_ok(p, c, s.heap), good(s.heap, value),
    ensures fast_at_ok(p, c, s, fast_at(p1(p), as1(s), recv, arg, is_put, value, fuel)),
    decreases fuel,
{
    let s1 = as1(s);
    let pp = p1(p);
    match arg {
        Value::Smi(a) => {
            let n = a as int;
            if n < 0 {
            } else if is_instance(s1, recv) {
                let cid = class_of_obj(s1, recv);
                let f = fields(s1, recv);
                if cid == builtin(pp, crate::spec_common::LIST_CLASS) && f.len() < 2 {
                } else if cid == builtin(pp, crate::spec_common::LIST_CLASS) && is_array(s1, f[0]) {
                    match f[1] {
                        Value::Smi(size) => {
                            if !(size as int > elements(s1, f[0]).len()) {
                                lemma_array_at(p, c, s, f[0], size as int, n, is_put, value);
                            }
                        },
                        _ => {},
                    }
                } else if cid == builtin(pp, crate::spec_common::BYTE_ARRAY_SLICE_CLASS) {
                    if f.len() >= 3 {
                        match (f[1], f[2]) {
                            (Value::Smi(from), Value::Smi(to)) => {
                                let m = from as int + n;
                                if from < 0 || m >= to as int {
                                } else if is_bytes(s1, f[0]) {
                                    lemma_bytes_at(p, c, s, f[0], m, is_put, value);
                                } else if is_instance(s1, f[0]) {
                                    lemma_cow_at(p, c, s, f[0], m, is_put, value);
                                }
                            },
                            _ => {},
                        }
                    }
                } else if cid == builtin(pp, crate::spec_common::LARGE_ARRAY_CLASS) || cid == builtin(pp, crate::spec_common::LIST_CLASS) {
                    if f.len() >= 2 && fuel > 0 {
                        let la = if cid == builtin(pp, crate::spec_common::LARGE_ARRAY_CLASS) { recv } else { f[0] };
                        let vector = fields(s1, la)[1];
                        lemma_fast_at(p, c, s, vector, smi(n / crate::spec_common::ARRAYLET_SIZE), false, value, (fuel - 1) as nat);
                        match fast_at(pp, s1, vector, smi(n / crate::spec_common::ARRAYLET_SIZE), false, value, (fuel - 1) as nat) {
                            FastAt::Get(arraylet) => {
                                lemma_fast_at(p, c, s, arraylet, smi(n % crate::spec_common::ARRAYLET_SIZE), is_put, value, (fuel - 1) as nat);
                            },
                            _ => {},
                        }
                    }
                } else if cid == builtin(pp, crate::spec_common::BYTE_ARRAY_COW_CLASS) {
                    lemma_cow_at(p, c, s, recv, n, is_put, value);
                }
            } else if is_bytes(s1, recv) {
                lemma_bytes_at(p, c, s, recv, n, is_put, value);
            } else if is_array(s1, recv) {
                lemma_array_at(p, c, s, recv, elements(s1, recv).len() as int, n, is_put, value);
            }
        },
        _ => {},
    }
}

// ---------------------------------------------------------------------------
// Results of fast paths.

/// Popping `n` operands and pushing a value keeps the invariant.
pub proof fn lemma_pp_ok(p: Program2, c: Cert, trusted: bool, s: State2, n: int, len: int, v: Value, h2: Seq<HeapObj>)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        pp_map(p, c, s, n, len),
        heap_ext(p, s.heap, h2), heap_ok(p, c, h2), good(h2, v),
    ensures ok_np(p, c, Outcome2::Next(pp_state(s, n, v, h2, len))),
{
    lemma_pp_step(p, c, trusted, s, n, len, v, h2);
}

pub proof fn lemma_binres(p: Program2, c: Cert, trusted: bool, s: State2, r: Value)
    requires accepts(p, c, trusted), wf(p, c, s), pp_map(p, c, s, 2, 1), good(s.heap, r),
    ensures ok_np(p, c, binary_result(s, r)),
{
    lemma_instr(p, c, trusted, s);
    lemma_heap_ext_refl(p, s.heap);
    lemma_pp_ok(p, c, trusted, s, 2, 1, r, s.heap);
    assert(binary_result(s, r) == Outcome2::Next(pp_state(s, 2, r, s.heap, 1)));
}

/// The facts of an operator (INVOKE_EQ..INVOKE_AT_PUT) site.
pub open spec fn op_site(p: Program2, c: Cert, s: State2, op: u8) -> bool {
    let n = if op == INVOKE_AT_PUT { 3int } else { 2int };
    let sel = p.invoke_offsets[op - INVOKE_EQ] as int;
    &&& value_operands(cur_k(p, c, s), n)
    &&& (sel < 0 || sel_ok(p, c, sel, n, cur_k(p, c, s)))
    &&& pp_map(p, c, s, n, 1)
    &&& has_slot(s, n - 1)
    &&& binary_ok(s)
    &&& good(s.heap, at(s, 0)) && good(s.heap, at(s, 1)) && good(s.heap, at(s, n - 1))
    &&& ok_np(p, c, operator_fallback(p, s, op))
}

#[verifier::spinoff_prover]
pub proof fn lemma_op_site(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), INVOKE_EQ <= cur_op(p, s) <= INVOKE_AT_PUT,
    ensures op_site(p, c, s, cur_op(p, s)), opcode_length2(cur_op(p, s)) == 1,
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let n = if op == INVOKE_AT_PUT { 3int } else { 2int };
    let sel = p.invoke_offsets[op - INVOKE_EQ] as int;
    assert(opcode_length2(op) == 1);
    assert(post(p, c, m, off, k, trusted) == Some(pop_push(k, n, Some(Kind::Val))));
    assert(pp_map(p, c, s, n, 1));
    assert(is_val(top_kind(k, 0)) && is_val(top_kind(k, 1)) && is_val(top_kind(k, n - 1)));
    lemma_at_good(p, c, trusted, s, 0);
    lemma_at_good(p, c, trusted, s, 1);
    lemma_at_good(p, c, trusted, s, n - 1);
    lemma_fallback(p, c, trusted, s, sel, n);
}

// ---------------------------------------------------------------------------
// The opcodes.

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_virtual(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == INVOKE_VIRTUAL || cur_op(p, s) == INVOKE_VIRTUAL_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let len = opcode_length2(op);
    let n = if op == INVOKE_VIRTUAL { b1_of(p, m, off) + 1 } else { w1_of(p, m, off) + 1 };
    let sel = if op == INVOKE_VIRTUAL { u16_at(p1(p), s.bci + 2) } else { u16_at(p1(p), s.bci + 3) };
    assert(post(p, c, m, off, k, trusted) == Some(pop_push(k, n, Some(Kind::Val))));
    assert(sel_ok(p, c, sel, n, k));
    assert(pp_map(p, c, s, n, len));
    lemma_invoke_virtual(p, c, trusted, s, sel, n, len);
    assert(step(p, s) == invoke_virtual(p, s, sel, n, len)) by { reveal(step); }
}

/// INVOKE_VIRTUAL_GET's body (also INVOKE_SIZE's fallback).
pub proof fn lemma_vget(p: Program2, c: Cert, trusted: bool, s: State2, sel: int)
    requires accepts(p, c, trusted), wf(p, c, s), small(s),
        sel_ok(p, c, sel, 1, cur_k(p, c, s)), pp_map(p, c, s, 1, 3),
    ensures ok_np(p, c, op_invoke_virtual_get(p, s, sel))
        || (p.unchecked && op_invoke_virtual_get(p, s, sel) == Outcome2::Stuck(Stuck::FieldRange)),
{
    lemma_instr(p, c, trusted, s);
    lemma_vcall(p, c, trusted, s, sel, 1, 3);
    let recv = at(s, 0);
    match find_method(p, s, recv, sel) {
        Lookup2::Found(t) => {
            let f = info(p, t).aux as int;
            if info(p, t).kind == KIND_FIELD_ACCESSOR && field_readable(p, s, recv, f) {
                let v = field(s, recv, f);
                lemma_field_good(p, c, s, recv, f);
                lemma_heap_ext_refl(p, s.heap);
                lemma_pp_ok(p, c, trusted, s, 1, 3, v, s.heap);
                assert(put(s, 0, v).stack =~= pp_state(s, 1, v, s.heap, 3).stack);
                assert(next(put(s, 0, v), 3) == Outcome2::Next(pp_state(s, 1, v, s.heap, 3)));
            }
        },
        _ => {},
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_virtual_get(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s), cur_op(p, s) == INVOKE_VIRTUAL_GET,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let sel = w1_of(p, m, off);
    assert(post(p, c, m, off, k, trusted) == Some(k.update(k.len() - 1, Kind::Val)));
    assert(k.update(k.len() - 1, Kind::Val) =~= pop_push(k, 1, Some(Kind::Val)));
    assert(pp_map(p, c, s, 1, 3));
    lemma_vget(p, c, trusted, s, sel);
    assert(step(p, s) == op_invoke_virtual_get(p, s, sel)) by { reveal(step); }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_virtual_set(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s), cur_op(p, s) == INVOKE_VIRTUAL_SET,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let sel = w1_of(p, m, off);
    assert(post(p, c, m, off, k, trusted) == Some(pop_push(k, 2, Some(Kind::Val))));
    assert(pp_map(p, c, s, 2, 3));
    lemma_vcall(p, c, trusted, s, sel, 2, 3);
    let recv = at(s, 1);
    let v = at(s, 0);
    match find_method(p, s, recv, sel) {
        Lookup2::Found(t) => {
            let f = info(p, t).aux as int;
            if info(p, t).kind == KIND_FIELD_ACCESSOR && field_writable(p, s, recv, f) {
                assert(is_val(top_kind(k, 0)));
                lemma_at_good(p, c, trusted, s, 0);
                let s0 = drop(s, 2);
                assert(is_task_obj(p, s0, recv) == is_task_obj(p, s, recv));
                let s3 = set_field2(s0, recv, f, v);
                lemma_set_field2(p, c, s0, recv, f, v);
                lemma_pp_ok(p, c, trusted, s, 2, 3, v, s3.heap);
                assert(next(push(s3, v), 3) == Outcome2::Next(pp_state(s, 2, v, s3.heap, 3)));
            }
        },
        _ => {},
    }
    assert(step(p, s) == op_invoke_virtual_set(p, s, sel)) by { reveal(step); }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_eq(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_EQ,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_op_site(p, c, trusted, s);
    lemma_bool_good(p, s.heap, true);
    lemma_bool_good(p, s.heap, false);
    assert forall|b: bool| ok_np(p, c, #[trigger] binary_result(s, boolean2(p, b))) by {
        lemma_bool_good(p, s.heap, b);
        lemma_binres(p, c, trusted, s, boolean2(p, b));
    }
    lemma_binres(p, c, trusted, s, false2(p));
    assert(ok_np(p, c, op_invoke_eq(p, s)));
    assert(step(p, s) == op_invoke_eq(p, s)) by { reveal(step); }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_relational(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), INVOKE_LT <= cur_op(p, s) <= INVOKE_GTE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_op_site(p, c, trusted, s);
    let op = cur_op(p, s);
    assert forall|b: bool| ok_np(p, c, #[trigger] binary_result(s, boolean2(p, b))) by {
        lemma_bool_good(p, s.heap, b);
        lemma_binres(p, c, trusted, s, boolean2(p, b));
    }
    assert(ok_np(p, c, op_invoke_relational(p, s, op)));
    assert(step(p, s) == op_invoke_relational(p, s, op)) by { reveal(step); }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_arith(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), INVOKE_BIT_OR <= cur_op(p, s) <= INVOKE_MOD,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_op_site(p, c, trusted, s);
    let op = cur_op(p, s);
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    if are_smis_arith(p, s, op) {
        let r = smi(crate::spec_step::smi_arith(p1(p), op, crate::spec_helpers::smi_val(a0), crate::spec_helpers::smi_val(a1))->0);
        lemma_binres(p, c, trusted, s, r);
    } else if (op == INVOKE_ADD || op == INVOKE_SUB || op == INVOKE_MUL) && crate::spec_helpers::are_floats(as1(s), a0, a1) {
        let bits = crate::spec_step::float_arith(op, crate::spec_common::double_bits(as1(s), a0), crate::spec_common::double_bits(as1(s), a1));
        let o = new_double(as1(s), p1(p), bits);
        let h2 = s.heap.push(o);
        assert(machine_class_ok(p, DOUBLE_CLASS));
        assert(obj_ok(p, c, h2, o));
        lemma_heap_push(p, c, s.heap, o);
        lemma_pp_ok(p, c, trusted, s, 2, 1, new_ref2(s), h2);
        assert(binary_result(alloc2(s, o), new_ref2(s)) == Outcome2::Next(pp_state(s, 2, new_ref2(s), h2, 1)));
    }
    assert(ok_np(p, c, op_invoke_arith(p, s, op)));
    assert(step(p, s) == op_invoke_arith(p, s, op)) by { reveal(step); }
}

pub open spec fn are_smis_arith(p: Program2, s: State2, op: u8) -> bool {
    let a0 = at(s, 1);
    let a1 = at(s, 0);
    crate::spec_helpers::are_smis(a0, a1)
        && crate::spec_step::smi_arith(p1(p), op, crate::spec_helpers::smi_val(a0), crate::spec_helpers::smi_val(a1)) is Some
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_at(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_AT,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_op_site(p, c, trusted, s);
    lemma_fast_at(p, c, s, at(s, 1), at(s, 0), false, null2(p), FAST_AT_FUEL);
    match fast_at(p1(p), as1(s), at(s, 1), at(s, 0), false, null2(p), FAST_AT_FUEL) {
        FastAt::Get(v) => { lemma_binres(p, c, trusted, s, v); },
        _ => {},
    }
    assert(ok_np(p, c, op_invoke_at(p, s)));
    assert(step(p, s) == op_invoke_at(p, s)) by { reveal(step); }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_at_put(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_AT_PUT,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    lemma_op_site(p, c, trusted, s);
    lemma_fast_at(p, c, s, at(s, 2), at(s, 1), true, at(s, 0), FAST_AT_FUEL);
    match fast_at(p1(p), as1(s), at(s, 2), at(s, 1), true, at(s, 0), FAST_AT_FUEL) {
        FastAt::Put(s1, v) => {
            lemma_pp_ok(p, c, trusted, s, 3, 1, v, s1.heap);
            assert(next(push(drop(State2 { heap: s1.heap, ..s }, 3), v), 1) == Outcome2::Next(pp_state(s, 3, v, s1.heap, 1)));
        },
        _ => {},
    }
    assert(ok_np(p, c, op_invoke_at_put(p, s)));
    assert(step(p, s) == op_invoke_at_put(p, s)) by { reveal(step); }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_size(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s), cur_op(p, s) == INVOKE_SIZE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let sel = w1_of(p, m, off);
    assert(post(p, c, m, off, k, trusted) == Some(k.update(k.len() - 1, Kind::Val)));
    assert(k.update(k.len() - 1, Kind::Val) =~= pop_push(k, 1, Some(Kind::Val)));
    assert(pp_map(p, c, s, 1, 3));
    lemma_vget(p, c, trusted, s, sel);
    assert(has_slot(s, 0));
    match fast_size(p1(p), as1(s), at(s, 0)) {
        Some(n) => {
            let v = smi(n);
            lemma_heap_ext_refl(p, s.heap);
            lemma_pp_ok(p, c, trusted, s, 1, 3, v, s.heap);
            assert(put(s, 0, v).stack =~= pp_state(s, 1, v, s.heap, 3).stack);
            assert(next(put(s, 0, v), 3) == Outcome2::Next(pp_state(s, 1, v, s.heap, 3)));
        },
        None => {},
    }
    assert(step(p, s) == op_invoke_size(p, s, sel)) by { reveal(step); }
    // In the unchecked mode the getter's failed accessor is excluded by
    // `unchecked_ok` (the fallback is the whole step).
    assert(ok_np(p, c, op_invoke_size(p, s, sel)));
}

/// The virtual calls and operators.
pub proof fn lemma_step_virtual(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), unchecked_ok(p, s), fam_virtual(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    let op = cur_op(p, s);
    if op == INVOKE_VIRTUAL || op == INVOKE_VIRTUAL_WIDE {
        lemma_step_invoke_virtual(p, c, trusted, s);
    } else if op == INVOKE_VIRTUAL_GET {
        lemma_step_invoke_virtual_get(p, c, trusted, s);
    } else if op == INVOKE_VIRTUAL_SET {
        lemma_step_invoke_virtual_set(p, c, trusted, s);
    } else if op == INVOKE_EQ {
        lemma_step_invoke_eq(p, c, trusted, s);
    } else if INVOKE_LT <= op && op <= INVOKE_GTE {
        lemma_step_invoke_relational(p, c, trusted, s);
    } else if INVOKE_BIT_OR <= op && op <= INVOKE_MOD {
        lemma_step_invoke_arith(p, c, trusted, s);
    } else if op == INVOKE_AT {
        lemma_step_invoke_at(p, c, trusted, s);
    } else if op == INVOKE_AT_PUT {
        lemma_step_invoke_at_put(p, c, trusted, s);
    } else {
        assert(op == INVOKE_SIZE);
        lemma_step_invoke_size(p, c, trusted, s);
    }
}

} // verus!
