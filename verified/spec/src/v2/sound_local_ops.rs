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

//! The soundness of the steps of the `fam_local` opcodes: locals,
//! constants, (non-lazy) globals, POP, ALLOCATE, type checks, IDENTICAL,
//! branches and HALT. All of them only change the top frame's slots, the
//! heap (ALLOCATE) and the globals, or raise.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::bytecodes::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
use crate::v2::sound_instr::*;
use crate::v2::sound_upto::*;
use crate::v2::sound_raise::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, u16_at, u32_at, smi, smi_ok, byte, SMI_CLASS, elements, is_array};
#[cfg(verus_only)]
use crate::spec_helpers::smi_val;

verus! {

// ---------------------------------------------------------------------------
// Generic local steps.

/// The frame part of `local_step`.
pub open spec fn lframe0(p: Program2, c: Cert, s: State2, s2: State2, k2: Seq<Kind>) -> bool {
    let b = cur_b(s);
    let m = cur_m(s);
    &&& s2.frames == s.frames
    &&& s2.task == s.task
    &&& info(p, m).entry <= s2.bci
    &&& map_at(c, m, s2.bci - info(p, m).entry) == Some(k2)
    &&& s2.stack.len() == b + k2.len()
    &&& forall|x: int| 0 <= x < b ==> #[trigger] s2.stack[x] == s.stack[x]
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> k2.len() >= 1 && s2.stack[b] == s.stack[b])
    &&& heap_ext(p, s.heap, s2.heap)
}

/// A local step that keeps the bottom `q` slots of the top frame.
pub open spec fn lframe(p: Program2, c: Cert, s: State2, s2: State2, k2: Seq<Kind>, q: int) -> bool {
    let b = cur_b(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    &&& lframe0(p, c, s, s2, k2)
    &&& 0 <= q <= k.len()
    &&& q <= k2.len()
    &&& forall|x: int| 0 <= x < b + q ==> #[trigger] s2.stack[x] == s.stack[x]
    &&& forall|j: int| 0 <= j < q ==> #[trigger] k2[j] == k[j]
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> q >= 1)
    &&& heap_ok(p, c, s2.heap)
    &&& globals_ok(c, s2)
    &&& consts_ok(p, s2.heap)
}

#[verifier::spinoff_prover]
pub proof fn lemma_lgen(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, k2: Seq<Kind>, q: int)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        lframe(p, c, s, s2, k2, q),
        forall|j: int| q <= j < k2.len() ==>
            #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, top_i(s), k2, j, k2[j], s2.stack[cur_b(s) + j]),
        forall|j: int| q <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token ==>
            k2.subrange(0, j) == cur_k(p, c, s).subrange(0, j),
        forall|j: int| q <= j < k2.len() && (#[trigger] k2[j]) is Token ==> unchanged(p, c, s, s2, k2, j),
    ensures wf(p, c, s2),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let b = cur_b(s);
    let k = cur_k(p, c, s);
    assert(kinds_of(p, c, s2, t) == k2) by {
        assert(fmap(p, c, s2, t) == k2);
        assert(k2.subrange(0, k2.len() as int) =~= k2);
    }
    assert forall|j: int| 0 <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, t, kinds_of(p, c, s2, t), j, k2[j], s2.stack[b + j]) by {
        if j < q {
            assert(s2.stack[b + j] == s.stack[b + j]);
            assert(k2[j] == k[j]);
        }
    }
    assert forall|j: int| 0 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
        k2.subrange(0, j) == k.subrange(0, j) by {
        if j < q {
            assert forall|x: int| 0 <= x < j implies k2.subrange(0, j)[x] == k.subrange(0, j)[x] by {
                assert(k2[x] == k[x]);
            }
            assert(k2.subrange(0, j) =~= k.subrange(0, j));
        }
    }
    assert forall|j: int| 0 <= j < k2.len() && (#[trigger] k2[j]) is Token implies unchanged(p, c, s, s2, k2, j) by {
        if j < q {
            assert(s2.stack[b + j] == s.stack[b + j]);
            assert(k2[j] == k[j]);
        }
    }
    assert(local_step(p, c, s, s2, k2));
    lemma_local_step(p, c, trusted, s, s2, k2);
}

pub proof fn lemma_conf_val(p: Program2, c: Cert, s: State2, fi: int, kf: Seq<Kind>, j: int, v: Value)
    requires good(s.heap, v),
    ensures conf(p, c, s, fi, kf, j, Kind::Val, v),
{
    reveal(conf);
}

pub proof fn lemma_conf_method(p: Program2, c: Cert, s: State2, fi: int, kf: Seq<Kind>, j: int, t: int)
    ensures conf(p, c, s, fi, kf, j, Kind::Method(t), Value::Smi(t as i64)),
{
    reveal(conf);
}

/// A non-token slot of the top frame copied to slot `j2` of the new top
/// frame conforms: conformance of a reference only depends on the value,
/// the frames below and the block's own reference.
#[verifier::spinoff_prover]
pub proof fn lemma_conf_move(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, k2: Seq<Kind>, j1: int, j2: int)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        lframe0(p, c, s, s2, k2),
        0 <= j1 < cur_k(p, c, s).len(),
        0 <= j2 < k2.len(),
        k2[j2] == cur_k(p, c, s)[j1],
        !(k2[j2] is Token),
        s2.stack[cur_b(s) + j2] == s.stack[cur_b(s) + j1],
        j2 == 0 ==> !(pinned0(p, cur_m(s)) && arity(p, cur_m(s)) >= 1),
    ensures conf(p, c, s2, top_i(s), k2, j2, k2[j2], s2.stack[cur_b(s) + j2]),
{
    lemma_instr(p, c, trusted, s);
    reveal(conf);
    reveal(good_ref);
    let t = top_i(s);
    let b = cur_b(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let v = s.stack[b + j1];
    assert(frame_conf(p, c, s, t)) by { reveal(frame_ok); }
    assert(conf(p, c, s, t, k, j1, k[j1], v));
    let off2 = s2.bci - info(p, m).entry;
    lemma_map_instr(p, c, trusted, m, off2);
    assert(wf_kind(p, c, m, k2, j2));
    assert(bases_ok(s)) by { reveal(wf_task); }
    if t > 0 {
        lemma_local_same_below(p, c, s, s2, k2);
    }
    match k[j1] {
        Kind::Val => {},
        Kind::Method(_) => {},
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    if d == 0 {
                        assert(ref_ok(s2, f as int, slot as int));
                    } else {
                        lemma_outer_ref_in_block(p, c, trusted, m, k2, j2);
                        reveal_with_fuel(context_frame, 2);
                        lemma_context_frame_lt(s, t, d as nat);
                        let r = s.stack[b];
                        assert(s2.stack[b] == r);
                        assert(slots(s2, t) >= 1);
                        match r {
                            Value::BlockRef(f1, _) => {
                                if (f1 as int) < t {
                                    lemma_context_frame_below(s, s2, f1 as int, t - 1, (d - 1) as nat);
                                }
                            },
                            _ => {},
                        }
                        assert(context_frame(s2, t, d as nat) == context_frame(s, t, d as nat));
                        lemma_kinds_below(p, c, s, s2, f as int, t - 1);
                        lemma_ref_ok_below(s, s2, t - 1, f as int, slot as int);
                    }
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_kinds_below(p, c, s, s2, f as int, t - 1);
                    lemma_ref_ok_below(s, s2, t - 1, f as int, slot as int);
                },
                _ => {},
            }
        },
        Kind::Token => {},
    }
}

/// Pops `n` slots and pushes `v` of kind `kd`: a value, or a copy of the
/// non-token slot `j1`.
#[verifier::spinoff_prover]
pub proof fn lemma_pop_push(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, n: int, v: Value, kd: Kind, j1: int)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        0 <= n <= cur_k(p, c, s).len(),
        n == 0 || leaves0(p, cur_m(s), cur_k(p, c, s).len() as int, n),
        s2.frames == s.frames,
        s2.task == s.task,
        s2.heap == s.heap,
        s2.globals == s.globals,
        s2.stack == s.stack.subrange(0, s.stack.len() - n).push(v),
        info(p, cur_m(s)).entry <= s2.bci,
        map_at(c, cur_m(s), s2.bci - info(p, cur_m(s)).entry)
            == Some(cur_k(p, c, s).subrange(0, cur_k(p, c, s).len() - n).push(kd)),
        (is_val(kd) && good(s.heap, v) && (kd is Method ==> v == Value::Smi(kd->Method_0 as i64)))
            || (0 <= j1 < cur_k(p, c, s).len() && cur_k(p, c, s)[j1] == kd && !(kd is Token)
                && v == s.stack[cur_b(s) + j1]),
    ensures wf(p, c, s2),
{
    lemma_instr(p, c, trusted, s);
    let b = cur_b(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let q = h - n;
    let k2 = k.subrange(0, q).push(kd);
    lemma_heap_ext_refl(p, s.heap);
    assert(pinned0(p, m) && arity(p, m) >= 1 ==> q >= 1);
    assert(s2.stack[b + q] == v);
    assert forall|x: int| 0 <= x < b + q implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < q implies #[trigger] k2[j] == k[j] by {}
    assert(lframe0(p, c, s, s2, k2)) by {
        if pinned0(p, m) && arity(p, m) >= 1 {
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert(globals_ok(c, s2));
    assert(lframe(p, c, s, s2, k2, q));
    if is_val(kd) && good(s.heap, v) && (kd is Method ==> v == Value::Smi(kd->Method_0 as i64)) {
        if kd is Val {
            lemma_conf_val(p, c, s2, top_i(s), k2, q, v);
        } else {
            lemma_conf_method(p, c, s2, top_i(s), k2, q, kd->Method_0);
        }
    } else {
        lemma_conf_move(p, c, trusted, s, s2, k2, j1, q);
    }
    assert(conf(p, c, s2, top_i(s), k2, q, k2[q], s2.stack[b + q]));
    lemma_lgen(p, c, trusted, s, s2, k2, q);
}

/// Pops `n` slots (the globals may change).
#[verifier::spinoff_prover]
pub proof fn lemma_drop(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, n: int)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        0 <= n <= cur_k(p, c, s).len(),
        s2.frames == s.frames,
        s2.task == s.task,
        s2.heap == s.heap,
        globals_ok(c, s2),
        s2.stack == s.stack.subrange(0, s.stack.len() - n),
        info(p, cur_m(s)).entry <= s2.bci,
        map_at(c, cur_m(s), s2.bci - info(p, cur_m(s)).entry)
            == Some(cur_k(p, c, s).subrange(0, cur_k(p, c, s).len() - n)),
    ensures wf(p, c, s2),
{
    lemma_instr(p, c, trusted, s);
    let b = cur_b(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let q = h - n;
    let k2 = k.subrange(0, q);
    lemma_heap_ext_refl(p, s.heap);
    lemma_map_instr(p, c, trusted, m, s2.bci - info(p, m).entry);
    assert(shape_ok(p, c, m, k2));
    assert forall|x: int| 0 <= x < b + q implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < q implies #[trigger] k2[j] == k[j] by {}
    assert(lframe0(p, c, s, s2, k2)) by {
        if pinned0(p, m) && arity(p, m) >= 1 {
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert(lframe(p, c, s, s2, k2, q));
    lemma_lgen(p, c, trusted, s, s2, k2, q);
}

/// The top slot's value is good when its kind is a value kind.
pub proof fn lemma_top_good(p: Program2, c: Cert, trusted: bool, s: State2, n: int)
    requires accepts(p, c, trusted), wf(p, c, s), value_operands(cur_k(p, c, s), n + 1), 0 <= n,
    ensures has_slot(s, n), good(s.heap, at(s, n)), at(s, n) is Smi || at(s, n) is Obj,
{
    assert(is_val(top_kind(cur_k(p, c, s), n)));
    lemma_at_good(p, c, trusted, s, n);
}

// ---------------------------------------------------------------------------
// Locals.

#[verifier::spinoff_prover]
pub proof fn lemma_step_load_local(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == LOAD_LOCAL || cur_op(p, s) == LOAD_LOCAL_WIDE
            || (LOAD_LOCAL_0 <= cur_op(p, s) && cur_op(p, s) <= LOAD_LOCAL_5),
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let len = opcode_length2(op);
    let n = if op == LOAD_LOCAL { b1_of(p, m, off) } else if op == LOAD_LOCAL_WIDE { w1_of(p, m, off) } else { op - LOAD_LOCAL_0 };
    assert(step(p, s) == op_load_local(s, n, len)) by { reveal(step); }
    assert(n < h && !(top_kind(k, n) is Token));
    let kd = top_kind(k, n);
    assert(post(p, c, m, off, k, trusted) == Some(k.push(kd)));
    let s2 = goto(push(s, at(s, n)), s.bci + len);
    lemma_at_conf(p, c, trusted, s, n);
    assert(k.subrange(0, h - 0) =~= k);
    assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
    lemma_pop_push(p, c, trusted, s, s2, 0, at(s, n), kd, h - 1 - n);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_pop_load_local(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == POP_LOAD_LOCAL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let n = b1_of(p, m, off);
    assert(step(p, s) == op_pop_load_local(s, n)) by { reveal(step); }
    assert(n + 1 < h && !(top_kind(k, n + 1) is Token));
    let kd = top_kind(k, n + 1);
    assert(post(p, c, m, off, k, trusted) == Some(k.update(h - 1, kd)));
    assert(k.update(h - 1, kd) =~= k.subrange(0, h - 1).push(kd));
    let s2 = goto(put(s, 0, at(s, n + 1)), s.bci + 2);
    assert(s2.stack =~= s.stack.subrange(0, s.stack.len() - 1).push(at(s, n + 1)));
    lemma_at_conf(p, c, trusted, s, n + 1);
    lemma_pop_push(p, c, trusted, s, s2, 1, at(s, n + 1), kd, h - 2 - n);
}

/// STORE_LOCAL and STORE_LOCAL_POP.
#[verifier::spinoff_prover]
pub proof fn lemma_step_store_local(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == STORE_LOCAL || cur_op(p, s) == STORE_LOCAL_POP,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let h = k.len() as int;
    let n = b1_of(p, m, off);
    let i = h - 1 - n;
    let kv = top_kind(k, 0);
    let pop = op == STORE_LOCAL_POP;
    assert(1 <= n && n < h && writable(p, m, k, i, kv));
    let k1 = k.update(i, kv);
    let k2 = if pop { k1.drop_last() } else { k1 };
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    let s2 = if pop { goto(put(drop(s, 1), n - 1, at(s, 0)), s.bci + 2) } else { goto(put(s, n, at(s, 0)), s.bci + 2) };
    if pop {
        assert(step(p, s) == op_store_local_pop(s, n)) by { reveal(step); }
    } else {
        assert(step(p, s) == op_store_local(s, n)) by { reveal(step); }
    }
    assert(step(p, s) == Outcome2::Next(s2));
    assert(s2.stack.len() == b + k2.len());
    assert(s2.stack[b + i] == s.stack[b + h - 1]);
    assert forall|x: int| 0 <= x < b + h && x != b + i && (!pop || x < b + h - 1) implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < k2.len() && j != i implies #[trigger] k2[j] == k[j] by {}
    assert(k2[i] == kv);
    lemma_heap_ext_refl(p, s.heap);
    assert(lframe0(p, c, s, s2, k2)) by {
        if pinned0(p, m) && arity(p, m) >= 1 {
            assert(i != 0);
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert(lframe(p, c, s, s2, k2, i));
    lemma_conf_move(p, c, trusted, s, s2, k2, h - 1, i);
    assert forall|j: int| i <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, top_i(s), k2, j, k2[j], s2.stack[b + j]) by {
        if j > i {
            assert(s2.stack[b + j] == s.stack[b + j]);
            assert(k2[j] == k[j]);
        }
    }
    assert forall|j: int| i <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
        k2.subrange(0, j) == k.subrange(0, j) by {
        assert(j != i);
        assert(k[j] is Token);
        assert(below_token(k, i));
        assert(k[i] is Val && kv is Val);
        assert(k2.subrange(0, j) =~= k.subrange(0, j));
    }
    lemma_lgen(p, c, trusted, s, s2, k2, i);
}

// ---------------------------------------------------------------------------
// Constants.

/// Pushes a constant value.
#[verifier::spinoff_prover]
pub proof fn lemma_push_val(p: Program2, c: Cert, trusted: bool, s: State2, v: Value, len: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), good(s.heap, v),
        post(p, c, cur_m(s), cur_off(p, s), cur_k(p, c, s), trusted) == Some(cur_k(p, c, s).push(Kind::Val)),
        len == len_of(p, cur_m(s), cur_off(p, s)),
    ensures wf(p, c, goto(push(s, v), s.bci + len)),
{
    lemma_instr(p, c, trusted, s);
    let k = cur_k(p, c, s);
    assert(k.subrange(0, k.len() - 0) =~= k);
    assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
    lemma_pop_push(p, c, trusted, s, goto(push(s, v), s.bci + len), 0, v, Kind::Val, 0);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_load_literal(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == LOAD_LITERAL || cur_op(p, s) == LOAD_LITERAL_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let i = if op == LOAD_LITERAL { b1_of(p, m, off) } else { w1_of(p, m, off) };
    let len = opcode_length2(op);
    assert(step(p, s) == op_load_literal(p, s, i, len)) by { reveal(step); }
    assert(i < p.literals.len());
    assert(good(s.heap, p.literals[i]));
    lemma_push_val(p, c, trusted, s, p.literals[i], len);
}

/// LOAD_NULL, LOAD_SMI_0, LOAD_SMI_1, LOAD_SMI_U8, LOAD_SMI_U16, LOAD_SMI_U32.
#[verifier::spinoff_prover]
pub proof fn lemma_step_load_const(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == LOAD_NULL || cur_op(p, s) == LOAD_SMI_0 || cur_op(p, s) == LOAD_SMI_1
            || cur_op(p, s) == LOAD_SMI_U8 || cur_op(p, s) == LOAD_SMI_U16 || cur_op(p, s) == LOAD_SMI_U32,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let len = opcode_length2(op);
    let v = if op == LOAD_NULL { null2(p) }
        else if op == LOAD_SMI_0 { smi(0) }
        else if op == LOAD_SMI_1 { smi(1) }
        else if op == LOAD_SMI_U8 { smi(b1_of(p, m, off)) }
        else if op == LOAD_SMI_U16 { smi(w1_of(p, m, off)) }
        else { smi(u32_at(p1(p), s.bci + 1)) };
    assert(step(p, s) == next(push(s, v), len)) by { reveal(step); }
    assert(good(s.heap, v)) by { assert(good(s.heap, p.roots[0])); }
    lemma_push_val(p, c, trusted, s, v, len);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_load_smis_0(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == LOAD_SMIS_0,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let h = k.len() as int;
    let n = b1_of(p, m, off);
    assert(step(p, s) == op_load_smis_0(s, n)) by { reveal(step); }
    let k2 = k + Seq::new(n as nat, |i: int| Kind::Val);
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    let s2 = State2 { stack: s.stack + Seq::new(n as nat, |i: int| Value::Smi(0)), bci: (s.bci + 2) as usize, ..s };
    assert(step(p, s) == Outcome2::Next(s2));
    lemma_heap_ext_refl(p, s.heap);
    assert forall|x: int| 0 <= x < b + h implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < h implies #[trigger] k2[j] == k[j] by {}
    assert(lframe0(p, c, s, s2, k2)) by {
        if pinned0(p, cur_m(s)) && arity(p, cur_m(s)) >= 1 {
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert(lframe(p, c, s, s2, k2, h));
    assert forall|j: int| h <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, top_i(s), k2, j, k2[j], s2.stack[b + j]) by {
        assert(k2[j] == Kind::Val);
        assert(s2.stack[b + j] == Value::Smi(0));
        lemma_conf_val(p, c, s2, top_i(s), k2, j, Value::Smi(0));
    }
    lemma_lgen(p, c, trusted, s, s2, k2, h);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_load_method(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == LOAD_METHOD,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let t = u32_at(p1(p), s.bci + 1);
    assert(step(p, s) == op_load_method(p, s, t)) by { reveal(step); }
    assert(valid_method(p, t) && smi_ok(p1(p), t));
    let kd = Kind::Method(t);
    assert(post(p, c, m, off, k, trusted) == Some(k.push(kd)));
    let s2 = goto(push(s, smi(t)), s.bci + 5);
    assert(k.subrange(0, k.len() - 0) =~= k);
    assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
    lemma_pop_push(p, c, trusted, s, s2, 0, smi(t), kd, 0);
}

// ---------------------------------------------------------------------------
// Globals.

#[verifier::spinoff_prover]
pub proof fn lemma_step_load_global(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == LOAD_GLOBAL_VAR || cur_op(p, s) == LOAD_GLOBAL_VAR_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let g = if op == LOAD_GLOBAL_VAR { b1_of(p, m, off) } else { w1_of(p, m, off) };
    let len = opcode_length2(op);
    assert(step(p, s) == op_load_global(s, g, len)) by { reveal(step); }
    assert(g < c.global_count);
    assert(good(s.heap, s.globals[g]));
    lemma_push_val(p, c, trusted, s, s.globals[g], len);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_load_global_dynamic(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == LOAD_GLOBAL_VAR_DYNAMIC,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    assert(step(p, s) == op_load_global_dynamic(p, s)) by { reveal(step); }
    assert(value_operands(k, 1) && leaves0(p, m, h, 1));
    lemma_top_good(p, c, trusted, s, 0);
    match global_index(s, at(s, 0)) {
        None => {
            lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
        },
        Some(g) => {
            assert(good(s.heap, s.globals[g]));
            let s2 = goto(put(s, 0, s.globals[g]), s.bci + 1);
            assert(s2.stack =~= s.stack.subrange(0, s.stack.len() - 1).push(s.globals[g]));
            assert(k.update(h - 1, Kind::Val) =~= k.subrange(0, h - 1).push(Kind::Val));
            lemma_pop_push(p, c, trusted, s, s2, 1, s.globals[g], Kind::Val, 0);
        },
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_store_global(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == STORE_GLOBAL_VAR || cur_op(p, s) == STORE_GLOBAL_VAR_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let g = if op == STORE_GLOBAL_VAR { b1_of(p, m, off) } else { w1_of(p, m, off) };
    let len = opcode_length2(op);
    assert(step(p, s) == op_store_global(s, g, len)) by { reveal(step); }
    assert(g < c.global_count && value_operands(k, 1));
    lemma_top_good(p, c, trusted, s, 0);
    let s2 = goto(State2 { globals: s.globals.update(g, at(s, 0)), ..s }, s.bci + len);
    assert(globals_ok(c, s2)) by {
        assert forall|x: int| 0 <= x < s2.globals.len() implies good(s2.heap, #[trigger] s2.globals[x]) by {
            if x != g { assert(good(s.heap, s.globals[x])); }
        }
    }
    assert(k.subrange(0, k.len() - 0) =~= k);
    assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
    lemma_drop(p, c, trusted, s, s2, 0);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_store_global_dynamic(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == STORE_GLOBAL_VAR_DYNAMIC,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    assert(step(p, s) == op_store_global_dynamic(p, s)) by { reveal(step); }
    assert(value_operands(k, 2));
    lemma_top_good(p, c, trusted, s, 0);
    lemma_top_good(p, c, trusted, s, 1);
    match global_index(s, at(s, 1)) {
        None => {
            lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
        },
        Some(g) => {
            let s1 = drop(s, 2);
            let s2 = goto(State2 { globals: s1.globals.update(g, at(s, 0)), ..s1 }, s.bci + 1);
            assert(globals_ok(c, s2)) by {
                assert forall|x: int| 0 <= x < s2.globals.len() implies good(s2.heap, #[trigger] s2.globals[x]) by {
                    if x != g { assert(good(s.heap, s.globals[x])); }
                }
            }
            assert(pop_push(k, 2, None) == k.subrange(0, h - 2));
            lemma_drop(p, c, trusted, s, s2, 2);
        },
    }
}

// ---------------------------------------------------------------------------
// POP, ALLOCATE, IDENTICAL.

#[verifier::spinoff_prover]
pub proof fn lemma_step_pop(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == POP || cur_op(p, s) == POP_1,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let n = if op == POP { b1_of(p, m, off) } else { 1 };
    let len = opcode_length2(op);
    assert(step(p, s) == op_pop(s, n, len)) by { reveal(step); }
    assert(n <= k.len());
    lemma_drop(p, c, trusted, s, goto(drop(s, n), s.bci + len), n);
}

pub proof fn lemma_u16_bound(p: crate::types::Program, i: int)
    requires 0 <= i, i + 1 < p.bytecodes.len(),
    ensures 0 <= u16_at(p, i) < 0x10000,
{
    let a = byte(p, i);
    let b = byte(p, i + 1);
    assert(0 <= a < 256 && 0 <= b < 256);
    assert(0 <= a + 256 * b < 0x10000) by (nonlinear_arith) requires 0 <= a < 256 && 0 <= b < 256;
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_allocate(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == ALLOCATE || cur_op(p, s) == ALLOCATE_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let h = k.len() as int;
    let cl = if op == ALLOCATE { b1_of(p, m, off) } else { w1_of(p, m, off) };
    let len = opcode_length2(op);
    assert(step(p, s) == op_allocate(p, s, cl, len)) by { reveal(step); }
    assert(is_instance_class(p, cl) && ifc(p, cl) >= 0);
    if op == ALLOCATE_WIDE {
        lemma_u16_bound(p1(p), s.bci + 1);
    }
    assert(0 <= cl < 0x10000);
    let o = HeapObj {
        class_id: cl as u16,
        ro: false,
        body: Body::Instance(Seq::new(ifc(p, cl) as nat, |i: int| null2(p))),
    };
    let h2 = s.heap.push(o);
    let s2 = goto(push(alloc2(s, o), new_ref2(s)), s.bci + len);
    assert(step(p, s) == Outcome2::Next(s2));
    let k2 = k.push(Kind::Val);
    assert(post(p, c, m, off, k, trusted) == Some(k2));
    assert(good(s.heap, null2(p)));
    assert(basic_obj_ok(p, h2, o)) by {
        assert(o.class_id as int == cl);
        match o.body {
            Body::Instance(f) => {
                assert forall|i: int| 0 <= i < f.len() implies good(h2, #[trigger] f[i]) by {}
            },
            _ => {},
        }
    }
    assert(obj_ok(p, c, h2, o));
    lemma_heap_push(p, c, s.heap, o);
    lemma_globals_heap(c, s, h2);
    lemma_consts_heap(p, s.heap, h2);
    assert(globals_ok(c, s2));
    assert forall|x: int| 0 <= x < b + h implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < h implies #[trigger] k2[j] == k[j] by {}
    assert(lframe0(p, c, s, s2, k2)) by {
        if pinned0(p, m) && arity(p, m) >= 1 {
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert(lframe(p, c, s, s2, k2, h));
    assert(s2.stack[b + h] == new_ref2(s));
    lemma_conf_val(p, c, s2, top_i(s), k2, h, new_ref2(s));
    lemma_lgen(p, c, trusted, s, s2, k2, h);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_identical(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == IDENTICAL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    assert(value_operands(k, 2) && leaves0(p, m, h, 2));
    let r = boolean2(p, crate::spec_helpers::identical(as1(s), at(s, 1), at(s, 0)));
    assert(step(p, s) == binary_result(s, r)) by { reveal(step); }
    assert(good(s.heap, r)) by {
        assert(good(s.heap, p.roots[1]));
        assert(good(s.heap, p.roots[2]));
    }
    let s2 = goto(push(drop(s, 2), r), s.bci + 1);
    lemma_pop_push(p, c, trusted, s, s2, 2, r, Kind::Val, 0);
}

// ---------------------------------------------------------------------------
// Type checks.

/// A type check of a value never gets stuck in an accepted program.
pub proof fn lemma_typecheck(p: Program2, c: Cert, trusted: bool, s: State2, v: Value, index: int, nullable: bool, interface: bool)
    requires
        accepts(p, c, trusted), wf(p, c, s), good(s.heap, v), v is Smi || v is Obj,
        interface ==> 0 <= index < p.interface_check_offsets.len(),
        !interface ==> 0 <= 2 * index + 1 < p.class_check_ids.len(),
    ensures !(typecheck(p, s, v, index, nullable, interface) is Stuck),
{
    lemma_wf_parts(p, c, s);
    assert(tables_ok(p, c));
    if interface && !(nullable && v == null2(p)) {
        let sel = p.interface_check_offsets[index] as int;
        assert(class_count(p) + sel <= p.dispatch.len());
        let cid = class_id_of(p1(p), as1(s), v);
        match v {
            Value::Smi(_) => {
                assert(machine_class_ok(p, SMI_CLASS));
            },
            Value::Obj(id) => {
                reveal(heap_ok);
                assert(obj_ok(p, c, s.heap, s.heap[id as int]));
            },
            _ => {},
        }
        assert(0 <= cid < class_count(p));
        assert(dispatch_entry_ok(p, cid + sel));
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_is_as(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        IS_CLASS <= cur_op(p, s) && cur_op(p, s) <= AS_INTERFACE_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let len = opcode_length2(op);
    let enc = if op % 2 == 0 { b1_of(p, m, off) } else { w1_of(p, m, off) };
    let interface = op == IS_INTERFACE || op == IS_INTERFACE_WIDE || op == AS_INTERFACE || op == AS_INTERFACE_WIDE;
    let is_op = op <= IS_INTERFACE_WIDE;
    if is_op {
        assert(step(p, s) == op_is(p, s, enc, interface, len)) by { reveal(step); }
    } else {
        assert(step(p, s) == op_as(p, s, enc, interface, len)) by { reveal(step); }
    }
    assert(value_operands(k, 1) && (op > IS_INTERFACE_WIDE || leaves0(p, m, h, 1))
        && typecheck_index_ok(p, op, enc));
    lemma_top_good(p, c, trusted, s, 0);
    lemma_typecheck(p, c, trusted, s, at(s, 0), enc / 2, enc % 2 == 1, interface);
    let r = typecheck(p, s, at(s, 0), enc / 2, enc % 2 == 1, interface);
    if is_op {
        let v = if r is Yes { true2(p) } else { false2(p) };
        assert(good(s.heap, v)) by {
            assert(good(s.heap, p.roots[1]));
            assert(good(s.heap, p.roots[2]));
        }
        let s2 = goto(put(s, 0, v), s.bci + len);
        assert(step(p, s) == Outcome2::Next(s2));
        assert(s2.stack =~= s.stack.subrange(0, s.stack.len() - 1).push(v));
        assert(post(p, c, m, off, k, trusted) == Some(k.update(h - 1, Kind::Val)));
        assert(k.update(h - 1, Kind::Val) =~= k.subrange(0, h - 1).push(Kind::Val));
        lemma_pop_push(p, c, trusted, s, s2, 1, v, Kind::Val, 0);
    } else if r is Yes {
        assert(post(p, c, m, off, k, trusted) == Some(k));
        assert(k.subrange(0, k.len() - 0) =~= k);
        assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
        lemma_drop(p, c, trusted, s, goto(s, s.bci + len), 0);
    } else {
        lemma_raise_ok(p, c, trusted, s, AS_CHECK_FAILED);
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_as_local(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == AS_LOCAL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let enc = b1_of(p, m, off);
    assert(step(p, s) == op_as_local(p, s, enc)) by { reveal(step); }
    assert(enc / 32 < k.len() && is_val(top_kind(k, enc / 32)) && 2 * (enc % 32) + 1 < p.class_check_ids.len());
    lemma_at_good(p, c, trusted, s, enc / 32);
    lemma_typecheck(p, c, trusted, s, at(s, enc / 32), enc % 32, false, false);
    if typecheck(p, s, at(s, enc / 32), enc % 32, false, false) is Yes {
        assert(post(p, c, m, off, k, trusted) == Some(k));
        assert(k.subrange(0, k.len() - 0) =~= k);
        assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
        lemma_drop(p, c, trusted, s, goto(s, s.bci + 2), 0);
    } else {
        lemma_raise_ok(p, c, trusted, s, AS_CHECK_FAILED);
    }
}

// ---------------------------------------------------------------------------
// Branches and HALT.

/// The step of a branch, long or short (format note 22), at its decoded
/// distance `d`.
#[verifier::spinoff_prover]
proof fn lemma_step_is_branch(p: Program2, s: State2, d: int, target: int)
    requires
        instruction_ok(p, s),
        is_branch(cur_op(p, s)),
        is_short_branch(cur_op(p, s)) ==> d == byte2(p, s.bci + 1),
        !is_short_branch(cur_op(p, s)) ==> d == u16_at(p1(p), s.bci + 1),
        is_fwd_branch(cur_op(p, s)) ==> d > 0 && target == s.bci + d,
        !is_fwd_branch(cur_op(p, s)) ==> target == s.bci - d,
    ensures
        step(p, s) == op_branch(p, s, branch_kind(cur_op(p, s)), target, opcode_length2(cur_op(p, s))),
{
    reveal(step);
}

#[verifier::spinoff_prover]
#[verifier::rlimit(30)]
pub proof fn lemma_step_branch(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        (BRANCH <= cur_op(p, s) && cur_op(p, s) <= BRANCH_BACK_IF_NOT_NULL)
            || (BRANCH_S <= cur_op(p, s) && cur_op(p, s) <= BRANCH_BACK_S),
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    // A short branch (format note 22) has a one-byte distance.
    let d = branch_dist(p, m, off);
    let len = opcode_length2(op);
    let fwd = is_fwd_branch(op);
    let kind = branch_kind(op);
    let toff = branch_target(p, m, off);
    let target = info(p, m).entry + toff;
    assert(len == if is_short_branch(op) { 2int } else { 3int }) by { reveal_with_fuel(opcode_length2, 1); }
    assert(is_branch(op));
    assert(fwd ==> d > 0);
    assert(kind == 0 <==> is_uncond_branch(op));
    let kt = if kind == 0 { k } else { k.drop_last() };
    assert(map_at(c, m, toff) == Some(kt));
    lemma_map_bound(p, c, trusted, m, toff);
    assert(toff == if fwd { off + d } else { off - d });
    lemma_step_is_branch(p, s, d, target);
    if kind == 0 {
        assert(k.subrange(0, k.len() - 0) =~= k);
        assert(s.stack.subrange(0, s.stack.len() - 0) =~= s.stack);
        lemma_drop(p, c, trusted, s, goto(s, target), 0);
    } else {
        assert(value_operands(k, 1));
        assert(has_slot(s, 0));
        assert(k.drop_last() =~= k.subrange(0, h - 1));
        if branch_taken(p, kind, at(s, 0)) {
            lemma_drop(p, c, trusted, s, goto(drop(s, 1), target), 1);
        } else {
            assert(post(p, c, m, off, k, trusted) == Some(k.drop_last()));
            lemma_drop(p, c, trusted, s, goto(drop(s, 1), s.bci + len), 1);
        }
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_halt(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == HALT,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let code = b1_of(p, m, off);
    assert(step(p, s) == op_halt(p, s, code)) by { reveal(step); }
    assert(post(p, c, m, off, k, trusted) is Some);
    if code == 0 {
        lemma_push_val(p, c, trusted, s, smi(91), 2);
    } else if code == 1 {
        assert(value_operands(k, 1));
        lemma_top_good(p, c, trusted, s, 0);
        if !(at(s, 0) is Smi) {
            lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
        }
    } else if code == 2 {
        assert(has_slot(s, 0));
    }
}

// ---------------------------------------------------------------------------
// Loop steps (proposal, format note 19).

/// The taken branch of a loop step: the counter slot `lc` becomes `vc`, the
/// top is popped, a copy of the block slot `lb` and `v` are pushed.
#[verifier::spinoff_prover]
pub proof fn lemma_loop_taken(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, lc: int, lb: int, vc: Value, v: Value)
    requires
        accepts(p, c, trusted),
        wf(p, c, s),
        1 <= lc < cur_k(p, c, s).len(),
        1 <= lb < cur_k(p, c, s).len(),
        !(top_kind(cur_k(p, c, s), lb) is Token),
        writable(p, cur_m(s), cur_k(p, c, s), cur_k(p, c, s).len() - 1 - lc, Kind::Val),
        good(s.heap, vc),
        good(s.heap, v),
        s2.frames == s.frames,
        s2.task == s.task,
        s2.heap == s.heap,
        s2.globals == s.globals,
        s2.stack == drop(put(s, lc, vc), 1).stack.push(at(s, lb)).push(v),
        info(p, cur_m(s)).entry <= s2.bci,
        map_at(c, cur_m(s), s2.bci - info(p, cur_m(s)).entry) == Some(loop_kinds(cur_k(p, c, s), lc, lb)),
    ensures wf(p, c, s2),
{
    lemma_instr(p, c, trusted, s);
    let b = cur_b(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let ic = h - 1 - lc;
    let jb = h - 1 - lb;
    let k2 = loop_kinds(k, lc, lb);
    assert(s.stack.len() == b + h);
    assert(k2.len() == h + 1);
    assert(s2.stack.len() == b + h + 1);
    assert(s2.stack[b + ic] == vc);
    assert(at(s, lb) == s.stack[b + jb]);
    assert(s2.stack[b + h - 1] == s.stack[b + jb]);
    assert(s2.stack[b + h] == v);
    assert forall|x: int| 0 <= x < b + h - 1 && x != b + ic implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < h - 1 && j != ic implies #[trigger] k2[j] == k[j] by {}
    assert(k2[ic] == Kind::Val);
    assert(k2[h - 1] == k[jb]);
    assert(k2[h] == Kind::Val);
    lemma_heap_ext_refl(p, s.heap);
    assert(lframe0(p, c, s, s2, k2)) by {
        if pinned0(p, m) && arity(p, m) >= 1 {
            assert(ic != 0);
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert forall|x: int| 0 <= x < b + ic implies #[trigger] s2.stack[x] == s.stack[x] by {}
    assert forall|j: int| 0 <= j < ic implies #[trigger] k2[j] == k[j] by {}
    assert(globals_ok(c, s2));
    assert(lframe(p, c, s, s2, k2, ic));
    lemma_conf_val(p, c, s2, top_i(s), k2, ic, vc);
    lemma_conf_move(p, c, trusted, s, s2, k2, jb, h - 1);
    lemma_conf_val(p, c, s2, top_i(s), k2, h, v);
    assert forall|j: int| ic <= j < k2.len() implies
        #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, top_i(s), k2, j, k2[j], s2.stack[b + j]) by {
        if ic < j < h - 1 {
            assert(s2.stack[b + j] == s.stack[b + j]);
            assert(k2[j] == k[j]);
        }
    }
    assert forall|j: int| ic <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
        k2.subrange(0, j) == k.subrange(0, j) by {
        assert(j != ic);
        assert(j != h - 1);
        assert(k[j] is Token);
        assert(below_token(k, ic));
        assert(k[ic] is Val);
        assert(k2.subrange(0, j) =~= k.subrange(0, j));
    }
    lemma_lgen(p, c, trusted, s, s2, k2, ic);
}

/// LOOP_REPEAT and LOOP_ARRAY.
#[verifier::spinoff_prover]
pub proof fn lemma_step_loop(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), is_loop(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let len = opcode_length2(op);
    let w1 = w1_of(p, m, off);
    let n = bk_of(p, m, off, 3);
    let y = if op == LOOP_ARRAY { n + 3 } else { n + 2 };
    assert(loop_operands(p, m, off) == (n, n + 1, n + 2, y));
    assert(!is_terminator(op));
    assert(post(p, c, m, off, k, trusted) is Some);
    assert(loop_ok(p, m, k, n, n + 1, n + 2, y));
    assert(post(p, c, m, off, k, trusted) == Some(k.subrange(0, h - 1)));
    let toff = off - w1;
    let target = info(p, m).entry + toff;
    assert(map_at(c, m, toff) == Some(loop_kinds(k, n, n + 1)));
    lemma_map_bound(p, c, trusted, m, toff);
    assert(byte2(p, s.bci + 3) == n);
    assert(s.bci - w1 == target);
    lemma_at_good(p, c, trusted, s, n);
    lemma_at_good(p, c, trusted, s, n + 2);
    lemma_at_good(p, c, trusted, s, y);
    assert(info(p, m).entry <= target < info(p, m).end);
    let vc = at(s, n);
    if op == LOOP_REPEAT {
        assert(step(p, s) == op_loop_repeat(p, s, s.bci - w1, n, len)) by { reveal(step); }
        assert(loop_slots_ok(s, n, n + 1, n + 2, n + 2));
        if vc is Smi && at(s, n + 2) is Smi && smi_val(vc) < smi_val(at(s, n + 2)) {
            let i = smi_val(vc);
            let s2 = goto(push(push(drop(put(s, n, smi(i + 1)), 1), at(s, n + 1)), vc), target);
            assert(op_loop_repeat(p, s, target, n, len) == Outcome2::Next(s2));
            lemma_loop_taken(p, c, trusted, s, s2, n, n + 1, smi(i + 1), vc);
        } else {
            assert(op_loop_repeat(p, s, target, n, len) == next(drop(s, 1), len));
            lemma_drop(p, c, trusted, s, goto(drop(s, 1), s.bci + len), 1);
        }
    } else {
        assert(step(p, s) == op_loop_array(p, s, s.bci - w1, n, len)) by { reveal(step); }
        assert(loop_slots_ok(s, n, n + 1, n + 2, n + 3));
        if loop_array_go(s, n, n + 2, n + 3) {
            let i = smi_val(vc);
            let arr = at(s, n + 3);
            let v = elements(as1(s), arr)[i];
            crate::v2::sound_virtual::lemma_array_at(p, c, s, arr, elements(as1(s), arr).len() as int, i, false, smi(0));
            assert(good(s.heap, v));
            let s2 = goto(push(push(drop(put(s, n, smi(i + 1)), 1), at(s, n + 1)), v), target);
            assert(op_loop_array(p, s, target, n, len) == Outcome2::Next(s2));
            lemma_loop_taken(p, c, trusted, s, s2, n, n + 1, smi(i + 1), v);
        } else {
            assert(op_loop_array(p, s, target, n, len) == next(drop(s, 1), len));
            lemma_drop(p, c, trusted, s, goto(drop(s, 1), s.bci + len), 1);
        }
    }
}

// ---------------------------------------------------------------------------
// The family.

pub proof fn lemma_step_local(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), fam_local(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    let op = cur_op(p, s);
    if op == LOAD_LOCAL || op == LOAD_LOCAL_WIDE || (LOAD_LOCAL_0 <= op && op <= LOAD_LOCAL_5) {
        lemma_step_load_local(p, c, trusted, s);
    } else if op == POP_LOAD_LOCAL {
        lemma_step_pop_load_local(p, c, trusted, s);
    } else if op == STORE_LOCAL || op == STORE_LOCAL_POP {
        lemma_step_store_local(p, c, trusted, s);
    } else if op == LOAD_LITERAL || op == LOAD_LITERAL_WIDE {
        lemma_step_load_literal(p, c, trusted, s);
    } else if op == LOAD_NULL || op == LOAD_SMI_0 || op == LOAD_SMI_1 || op == LOAD_SMI_U8
        || op == LOAD_SMI_U16 || op == LOAD_SMI_U32 {
        lemma_step_load_const(p, c, trusted, s);
    } else if op == LOAD_SMIS_0 {
        lemma_step_load_smis_0(p, c, trusted, s);
    } else if op == LOAD_METHOD {
        lemma_step_load_method(p, c, trusted, s);
    } else if op == LOAD_GLOBAL_VAR || op == LOAD_GLOBAL_VAR_WIDE {
        lemma_step_load_global(p, c, trusted, s);
    } else if op == LOAD_GLOBAL_VAR_DYNAMIC {
        lemma_step_load_global_dynamic(p, c, trusted, s);
    } else if op == STORE_GLOBAL_VAR || op == STORE_GLOBAL_VAR_WIDE {
        lemma_step_store_global(p, c, trusted, s);
    } else if op == STORE_GLOBAL_VAR_DYNAMIC {
        lemma_step_store_global_dynamic(p, c, trusted, s);
    } else if op == POP || op == POP_1 {
        lemma_step_pop(p, c, trusted, s);
    } else if op == ALLOCATE || op == ALLOCATE_WIDE {
        lemma_step_allocate(p, c, trusted, s);
    } else if IS_CLASS <= op && op <= AS_INTERFACE_WIDE {
        lemma_step_is_as(p, c, trusted, s);
    } else if op == AS_LOCAL {
        lemma_step_as_local(p, c, trusted, s);
    } else if (BRANCH <= op && op <= BRANCH_BACK_IF_NOT_NULL) || (BRANCH_S <= op && op <= BRANCH_BACK_S) {
        lemma_step_branch(p, c, trusted, s);
    } else if op == IDENTICAL {
        lemma_step_identical(p, c, trusted, s);
    } else if is_loop(op) {
        lemma_step_loop(p, c, trusted, s);
    } else if op == HASH_FIND {
        crate::v2::sound_hash::lemma_step_hash_find(p, c, trusted, s);
    } else {
        assert(op == HALT);
        lemma_step_halt(p, c, trusted, s);
    }
}

} // verus!
