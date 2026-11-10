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

//! The unwinding opcodes: THROW, RETURN, RETURN_NULL, NON_LOCAL_RETURN,
//! NON_LOCAL_BRANCH, UNWIND.

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
use crate::v2::sound_instr::*;
use crate::v2::sound_ctx::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, u16_at, u32_at};

verus! {

/// Cutting the top frame of an unwinding state (without a handler at the
/// top) to its first `n` known slots.
pub proof fn lemma_unw_cut(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, n: int)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        !has_handler(s),
        0 <= n <= kt.len(),
        pinned0(p, fmethod(s, top_i(s))) && arity(p, fmethod(s, top_i(s))) >= 1 ==> n >= 1,
    ensures
        unw_ok(p, c, State2 { stack: s.stack.subrange(0, fbase(s, top_i(s)) + n), ..s }, kt.subrange(0, n)),
{
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    let s1 = State2 { stack: s.stack.subrange(0, b + n), ..s };
    let k1 = kt.subrange(0, n);
    lemma_base_le_len(s, t);
    assert(bases_ok(s1)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s1.frames.len() implies #[trigger] base_step(s1, fi) by {
            assert(base_step(s, fi));
        }
    }
    if t > 0 {
        assert(same_below(s, s1, t - 1)) by {
            assert forall|g: int| 0 <= g <= t - 1 implies #[trigger] try_frame(s1, g) == try_frame(s, g) by {
                assert(s1.tries == s.tries);
            }
        }
    }
    assert forall|fi: int| 0 <= fi < t implies #[trigger] frame_ok(p, c, s1, fi) by {
        assert(frame_ok(p, c, s, fi));
        lemma_same_below_down(s, s1, t - 1, fi);
        lemma_frame_below_unw(p, c, s, s1, fi);
    }
    assert forall|x: int| 0 <= x < s1.tries.len() implies #[trigger] handler_ok(s1, x) by {
        assert(handler_ok(s, x));
        if (s.tries[x].frame as int) < t { assert(try_ok(s, x)); }
    }
    assert(same_upto(s, s1, t, n));
    assert forall|j: int| 0 <= j < n implies #[trigger] conf(p, c, s1, t, k1, j, k1[j], s1.stack[b + j]) by {
        assert(conf(p, c, s, t, kt, j, kt[j], s.stack[b + j]));
        assert(wf_kind(p, c, m, kt, j));
        lemma_conf_upto(p, c, s, s1, t, n, kt, j, kt[j], s.stack[b + j]);
        assert(k1.subrange(0, j) =~= kt.subrange(0, j));
        lemma_conf_kf(p, c, s1, t, kt, k1, j, kt[j], s.stack[b + j]);
    }
    assert forall|j: int| 0 <= j < n implies #[trigger] wf_kind(p, c, m, k1, j) by {
        assert(wf_kind(p, c, m, kt, j));
        assert(k1.subrange(0, j + 1) =~= kt.subrange(0, j + 1));
        lemma_wf_kind_prefix(p, c, m, kt, k1, j);
    }
    if n >= 1 {
        assert(s1.stack[b] == s.stack[b]);
    }
    assert(!has_handler(s1));
}

/// THROW.
pub proof fn lemma_step_throw(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == THROW,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let k = cur_k(p, c, s);
    lemma_at_good(p, c, trusted, s, 0);
    let v = at(s, 0);
    assert(unw_arg_ok(p, c, s, k, Unwind::Throw(v))) by { reveal(pending_ok); }
    lemma_unwind_wf(p, c, trusted, s, Unwind::Throw(v));
    assert(step(p, s) == unwind(p, s, Unwind::Throw(v))) by { reveal(step); }
}

/// RETURN and RETURN_NULL.
pub proof fn lemma_step_return(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == RETURN || cur_op(p, s) == RETURN_NULL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let k = cur_k(p, c, s);
    lemma_wf_unw(p, c, trusted, s);
    if cur_op(p, s) == RETURN {
        lemma_at_good(p, c, trusted, s, 0);
        lemma_return(p, c, trusted, s, k, at(s, 0));
        assert(step(p, s) == return_from(p, s, at(s, 0))) by { reveal(step); }
    } else {
        assert(good(s.heap, p.roots[0]));
        lemma_return(p, c, trusted, s, k, null2(p));
        assert(step(p, s) == return_from(p, s, null2(p))) by { reveal(step); }
    }
}

/// NON_LOCAL_RETURN.
pub proof fn lemma_step_non_local_return(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == NON_LOCAL_RETURN,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let k = cur_k(p, c, s);
    lemma_at_good(p, c, trusted, s, 1);
    lemma_at_conf(p, c, trusted, s, 0);
    reveal(conf);
    let v = at(s, 1);
    match at(s, 0) {
        Value::BlockRef(f, slot) => {
            let d = top_kind(k, 0)->Block_0;
            lemma_context_frame_lt(s, t, d as nat);
            assert((f as int) < t);
            assert(block_ref(s, at(s, 0)) == Some((f as int, slot as int)));
            assert(op_non_local_return(p, s) == unwind(p, s, Unwind::Return(f, v)));
            assert(unw_arg_ok(p, c, s, k, Unwind::Return(f, v))) by { reveal(pending_ok); }
            lemma_unwind_wf(p, c, trusted, s, Unwind::Return(f, v));
        },
        _ => { assert(false); },
    }
    assert(step(p, s) == op_non_local_return(p, s)) by { reveal(step); }
}

/// NON_LOCAL_BRANCH.
pub proof fn lemma_step_non_local_branch(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == NON_LOCAL_BRANCH,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let hd = b1_of(p, m, off);
    let target = u32_at(p1(p), instr_at(p, m, off) + 2);
    lemma_at_conf(p, c, trusted, s, 0);
    assert(top_kind(k, 0) is Block);
    let d = top_kind(k, 0)->Block_0;
    let j = top_kind(k, 0)->Block_1;
    let om = ctx_method(c, m, d as nat);
    let fk = ctx_kinds(c, m, d as nat)->0;
    let tt = map_at(c, om, target)->0;
    assert(wf_task(p, c, s) && bases_ok(s)) by { reveal(wf); reveal(wf_task); }
    assert forall|g: int| 0 <= g <= t implies #[trigger] frame_ok(p, c, s, g) by { reveal(wf_task); }
    lemma_ctx_frame(p, c, trusted, s, t, d as nat);
    reveal(conf);
    match at(s, 0) {
        Value::BlockRef(f0, slot) => {
            let f = f0 as int;
            assert(f == context_frame(s, t, d as nat));
            assert(fmethod(s, f) == om);
            let kf = kinds_of(p, c, s, f);
            assert(kf.subrange(0, fk.len() as int) == fk);
            assert(block_ref(s, at(s, 0)) == Some((f, slot as int)));
            assert(slot as int == fbase(s, f) + j);
            lemma_map_bound(p, c, trusted, om, target);
            let nbci = (info(p, om).entry + target) as usize;
            let hb = (slot + 1 - hd) as usize;
            let u = Unwind::Branch(f as usize, nbci, hb);
            assert(op_non_local_branch(p, s, hd, target) == unwind(p, s, u));
            assert(unw_arg_ok(p, c, s, k, u)) by {
                reveal(pending_ok);
                assert(frame_kinds_from(p, c, s, t, k, f) == kf);
                assert(nbci as int - info(p, om).entry == target);
                assert(tt =~= kf.subrange(0, tt.len() as int)) by {
                    assert(tt == fk.subrange(0, j + 1 - hd));
                    assert forall|x: int| 0 <= x < tt.len() implies tt[x] == kf.subrange(0, tt.len() as int)[x] by {
                        assert(fk[x] == kf.subrange(0, fk.len() as int)[x]);
                    }
                }
            }
            lemma_unwind_wf(p, c, trusted, s, u);
        },
        _ => { assert(false); },
    }
    assert(step(p, s) == op_non_local_branch(p, s, hd, target)) by { reveal(step); }
}

/// UNWIND.
pub proof fn lemma_step_unwind_op(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == UNWIND,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let t = top_i(s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let h = k.len() as int;
    let k2 = k.subrange(0, h - 3);
    let s1 = drop(s, 3);
    assert(map_at(c, m, off + 1) == Some(k2));
    lemma_map_instr(p, c, trusted, m, off + 1);
    lemma_at_conf(p, c, trusted, s, 1);
    let token = at(s, 1);
    assert(step(p, s) == op_unwind(p, s)) by { reveal(step); }
    assert(s1.stack =~= s.stack.subrange(0, b + (h - 3)));
    if token == null2(p) {
        let s2 = goto(s1, s.bci + 1);
        assert(op_unwind(p, s) == Outcome2::Next(s2));
        assert(local_step(p, c, s, s2, k2)) by {
            lemma_wf_parts(p, c, s);
            lemma_heap_ext_refl(s.heap);
            assert forall|j: int| 0 <= j < k2.len() implies #[trigger] unchanged(p, c, s, s2, k2, j) by {}
            assert forall|j: int| 0 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
                k2.subrange(0, j) == k.subrange(0, j) by {
                assert(k2.subrange(0, j) =~= k.subrange(0, j));
            }
        }
        lemma_local_step(p, c, trusted, s, s2, k2);
    } else {
        reveal(conf);
        assert(token is Obj);
        let id = token->Obj_0;
        assert(s.heap[id as int].body is Pending);
        let u = s.heap[id as int].body->Pending_0;
        assert(op_unwind(p, s) == unwind(p, s1, u));
        lemma_wf_unw(p, c, trusted, s);
        lemma_unw_cut(p, c, trusted, s, k, h - 3);
        assert(unw_arg_ok(p, c, s1, k2, u)) by {
            reveal(pending_ok);
            assert(pending_ok(p, c, s, t, k, h - 2, u));
            match u {
                Unwind::Branch(f, nb, hb) => {
                    let fi = f as int;
                    let mf = fmethod(s, fi);
                    if fi < t {
                        assert(s1.frames == s.frames);
                        assert(kinds_of(p, c, s1, fi) == kinds_of(p, c, s, fi));
                    } else {
                        let tt = map_at(c, mf, nb as int - info(p, mf).entry)->0;
                        assert(tt.len() + 1 <= h - 2);
                        assert(k2.subrange(0, tt.len() as int) =~= k.subrange(0, tt.len() as int));
                    }
                },
                _ => {},
            }
        }
        lemma_unwind(p, c, trusted, s1, k2, u);
    }
}

/// The unwinding family.
pub proof fn lemma_step_unwind(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), fam_unwind(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    let op = cur_op(p, s);
    if op == THROW {
        lemma_step_throw(p, c, trusted, s);
    } else if op == RETURN || op == RETURN_NULL {
        lemma_step_return(p, c, trusted, s);
    } else if op == NON_LOCAL_RETURN {
        lemma_step_non_local_return(p, c, trusted, s);
    } else if op == NON_LOCAL_BRANCH {
        lemma_step_non_local_branch(p, c, trusted, s);
    } else {
        lemma_step_unwind_op(p, c, trusted, s);
    }
}

} // verus!
