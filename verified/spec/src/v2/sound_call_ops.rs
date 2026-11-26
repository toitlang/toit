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

//! The call family: lazy globals, INVOKE_STATIC, INVOKE_BLOCK and TRY
//! keep the invariant (all calls go through `lemma_call`).

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
use crate::v2::sound_unwind::*;
use crate::v2::sound_return::*;
use crate::v2::sound_raise::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, smi, u16_at, RUN_GLOBAL_INITIALIZER};

verus! {

// ---------------------------------------------------------------------------
// Block references passed to a callee.

/// A reference to a block slot `i` of the caller (kind `Block(0, i)` at
/// slot `j`, below the arguments) is a good reference in the new state.
#[verifier::spinoff_prover]
pub proof fn lemma_good_ref_top(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, t: int, ret: int, is_try: bool, j: int, i: int)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        call_pre(p, c, s, s1, t, ret, is_try),
        0 <= j < kinds_of(p, c, s, top_i(s)).len(),
        kinds_of(p, c, s, top_i(s))[j] == Kind::Block(0, i),
        i < s1.stack.len() - arity(p, t) - fbase(s, top_i(s)),
    ensures ({
        let s2 = call_state_h(p, s1, t, ret, is_try);
        let t0 = top_i(s);
        let b = fbase(s, t0);
        &&& 0 <= i
        &&& ref_ok(s2, t0, b + i)
        &&& good_ref(p, c, s2, t0, b + i)
        &&& fbase(s2, t0) == b
        &&& fmethod(s2, t0) == fmethod(s, t0)
        &&& kinds_of(p, c, s2, t0)[i] == kinds_of(p, c, s, t0)[i]
        &&& block_slot(p, c, fmethod(s, t0), kinds_of(p, c, s, t0), i)
    }),
{
    reveal(good_ref);
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    let m = fmethod(s, t0);
    let k = kinds_of(p, c, s, t0);
    let nb = s1.stack.len() - arity(p, t);
    let keep = nb - b;
    lemma_call_shape(p, c, trusted, s, s1, t, ret, is_try);
    lemma_instr(p, c, trusted, s);
    let k2 = kinds_of(p, c, s2, t0);
    assert(k2 == k.subrange(0, keep));
    assert(wf_kind(p, c, m, k, j));
    assert(block_slot(p, c, m, k, i));
    assert(k2[i] == k[i]);
    assert(fmethod(s2, t0) == m);
    assert(fbase(s2, t0) == b);
    assert(block_slot(p, c, m, k2, i));
    assert forall|i2: int| 0 <= i2 <= i && i2 < k2.len() implies #[trigger] ctx_ok_at(p, c, m, k2, i2) by {
        assert(match k[j] { Kind::Block(d, sl) => d == 0 && sl >= i2, _ => false });
        assert(live_from(k, i2));
        assert(ctx_ok_at(p, c, m, k, i2));
        assert(k2[i2] == k[i2]);
        assert(k2.subrange(0, i2 + 1) =~= k.subrange(0, i2 + 1));
    }
    assert(ctx_ok_upto(p, c, m, k2, i));
    assert(s2.frames[t0 + 1].base as int == nb);
}

/// A good reference into a frame below the caller stays one.
#[verifier::spinoff_prover]
pub proof fn lemma_ref_below(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, t: int, ret: int, is_try: bool, f: int, slot: int)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        call_pre(p, c, s, s1, t, ret, is_try),
        0 <= f < top_i(s),
        ref_ok(s, f, slot),
        good_ref(p, c, s, f, slot),
    ensures ({
        let s2 = call_state_h(p, s1, t, ret, is_try);
        &&& ref_ok(s2, f, slot)
        &&& good_ref(p, c, s2, f, slot)
        &&& fbase(s2, f) == fbase(s, f)
        &&& fmethod(s2, f) == fmethod(s, f)
        &&& kinds_of(p, c, s2, f) == kinds_of(p, c, s, f)
    }),
{
    reveal(good_ref);
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let t0 = top_i(s);
    lemma_call_shape(p, c, trusted, s, s1, t, ret, is_try);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    lemma_kinds_below(p, c, s, s2, f, t0 - 1);
    lemma_ref_ok_below(s, s2, t0 - 1, f, slot);
    assert(s2.frames[f] == s.frames[f]);
}

/// A block argument (a reference kind at slot `j` of the caller) conforms
/// to a block parameter of the callee.
#[verifier::spinoff_prover]
pub proof fn lemma_arg_ref(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, t: int, ret: int, is_try: bool, j: int, x: int)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        call_pre(p, c, s, s1, t, ret, is_try),
        0 <= j < kinds_of(p, c, s, top_i(s)).len(),
        is_ref(kinds_of(p, c, s, top_i(s))[j]),
        match kinds_of(p, c, s, top_i(s))[j] {
            Kind::Block(d, i) => d == 0 ==> i < s1.stack.len() - arity(p, t) - fbase(s, top_i(s)),
            _ => true,
        },
        0 <= x < arity(p, t),
        s1.stack[s1.stack.len() - arity(p, t) + x] == s.stack[fbase(s, top_i(s)) + j],
    ensures ({
        let s2 = call_state_h(p, s1, t, ret, is_try);
        let tn = top_i(s2);
        conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, Kind::Param, s2.stack[fbase(s2, tn) + x])
    }),
{
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let t0 = top_i(s);
    let k = kinds_of(p, c, s, t0);
    let n = k.len() - 1 - j;
    lemma_call_shape(p, c, trusted, s, s1, t, ret, is_try);
    lemma_at_conf(p, c, trusted, s, n);
    let v = s.stack[fbase(s, t0) + j];
    assert(conf(p, c, s, t0, k, j, k[j], v));
    assert(s2.stack[fbase(s2, t0 + 1) + x] == v);
    reveal(conf);
    match k[j] {
        Kind::Block(d, i) => {
            match v {
                Value::BlockRef(f, slot) => {
                    if d == 0 {
                        lemma_good_ref_top(p, c, trusted, s, s1, t, ret, is_try, j, i);
                    } else {
                        lemma_context_frame_lt(s, t0, d as nat);
                        lemma_ref_below(p, c, trusted, s, s1, t, ret, is_try, f as int, slot as int);
                    }
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_ref_below(p, c, trusted, s, s1, t, ret, is_try, f as int, slot as int);
                },
                _ => {},
            }
        },
        _ => {},
    }
}

/// The slot `i` of frame `f` is a block slot: it holds its block method.
pub proof fn lemma_slot_method(p: Program2, c: Cert, trusted: bool, s: State2, f: int, i: int)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        0 <= f < s.frames.len(),
        block_slot(p, c, fmethod(s, f), kinds_of(p, c, s, f), i),
    ensures ({
        let tt = kind_method(kinds_of(p, c, s, f)[i]);
        &&& 0 <= i < slots(s, f)
        &&& 0 <= fbase(s, f) + i < s.stack.len()
        &&& s.stack[fbase(s, f) + i] == Value::Smi(tt as i64)
        &&& block_target(p, s, fbase(s, f) + i) == Some(tt)
        &&& valid_method(p, tt)
        &&& info(p, tt).kind == KIND_BLOCK
        &&& ctx_of(c, tt) is Some
        &&& ctx_of(c, tt)->0.outer == fmethod(s, f)
        &&& ctx_of(c, tt)->0.slot == i
    }),
{
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    reveal(wf_task);
    reveal(frame_ok);
    assert(frame_ok(p, c, s, f));
    let k = kinds_of(p, c, s, f);
    lemma_limit_le_len(s, f);
    assert(frame_shape_ok(p, c, s, f));
    assert(fmap(p, c, s, f).len() >= slots(s, f));
    assert(k.len() == slots(s, f));
    assert(conf(p, c, s, f, k, i, k[i], s.stack[fbase(s, f) + i]));
    reveal(conf);
    let tt = kind_method(k[i]);
    assert(p.methods.len() < 0x1000_0000);
    assert((tt as i64) as int == tt);
}

pub proof fn lemma_limit_le_len(s: State2, f: int)
    requires bases_ok(s), 0 <= f < s.frames.len(),
    ensures fbase(s, f) <= limit(s, f) <= s.stack.len(), 0 <= fbase(s, f),
{
    if f + 1 < s.frames.len() {
        lemma_limit_below(s, f, f + 1);
        lemma_base_le_len(s, f + 1);
    } else {
        lemma_base_le_len(s, f);
    }
}

// ---------------------------------------------------------------------------
// INVOKE_STATIC.

#[verifier::spinoff_prover]
pub proof fn lemma_invoke_static_call(p: Program2, c: Cert, trusted: bool, s: State2, t: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        valid_method(p, t),
        info(p, t).kind == KIND_METHOD || info(p, t).kind == KIND_FIELD_ACCESSOR,
        args_ok(c, t, cur_k(p, c, s), arity(p, t)),
        leaves0(p, cur_m(s), cur_k(p, c, s).len() as int, arity(p, t)),
        map_at(c, cur_m(s), cur_off(p, s) + 3) == Some(pop_push(cur_k(p, c, s), arity(p, t), Some(Kind::Val))),
        has_receiver_range(info(p, t)) ==> arity(p, t) >= 1 && class_id_ok(as1(s), at(s, arity(p, t) - 1)),
        !receiver_fails(p, s, t),
    ensures wf(p, c, call_state(p, s, t, s.bci + 3)),
{
    lemma_instr(p, c, trusted, s);
    let ret = s.bci + 3;
    let t0 = top_i(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let a = arity(p, t);
    let nb = s.stack.len() - a;
    let keep = nb - b;
    let kr = pop_push(k, a, Some(Kind::Val));
    lemma_heap_ext_refl(p, s.heap);
    assert(kr.subrange(0, keep) =~= k.subrange(0, keep));
    assert(ret - info(p, m).entry == cur_off(p, s) + 3);
    assert(call_pre(p, c, s, s, t, ret, false));
    let s2 = call_state(p, s, t, ret);
    lemma_call_shape(p, c, trusted, s, s, t, ret, false);
    let tn = t0 + 1;
    assert(fbase(s2, tn) == nb);
    assert forall|x: int| 0 <= x < a implies
        #[trigger] conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, entry_kinds(p, c, t)[x], s2.stack[fbase(s2, tn) + x]) by {
        assert(arg_ok(c, t, k, a, x));
        let j = keep + x;
        assert(s2.stack[nb + x] == s.stack[b + j]);
        if is_block_param(c, t, x) {
            assert(entry_kinds(p, c, t)[x] == Kind::Param);
            lemma_arg_ref(p, c, trusted, s, s, t, ret, false, j, x);
        } else {
            assert(entry_kinds(p, c, t)[x] == Kind::Val);
            lemma_at_good(p, c, trusted, s, a - 1 - x);
            reveal(conf);
        }
    }
    let i = info(p, t);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && a >= 1 {
        let r = s2.stack[fbase(s2, tn)];
        assert(r == at(s, a - 1));
        assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
    }
    assert(fmethod(s2, tn) == t);
    assert(receiver_ok(p, s2, tn));
    assert(call_args(p, c, s, t, ret, false));
    lemma_call(p, c, trusted, s, s, t, ret, false);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_static(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_STATIC,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let w1 = w1_of(p, m, off);
    let t = dispatch_target(p, w1);
    let a = arity(p, t);
    assert(opcode_length2(INVOKE_STATIC) == 3);
    assert(!is_terminator(INVOKE_STATIC));
    assert(post(p, c, m, off, k, trusted) is Some);
    assert(valid_method(p, t) && args_ok(c, t, k, a) && leaves0(p, m, k.len() as int, a));
    assert(map_at(c, m, off + 3) == Some(pop_push(k, a, Some(Kind::Val))));
    assert(step(p, s) == call_static(p, s, t, 3)) by { reveal(step); }
    assert(0 <= w1 < p.dispatch.len());
    assert(dispatch_entry_ok(p, w1));
    assert(info(p, t).kind == KIND_METHOD || info(p, t).kind == KIND_FIELD_ACCESSOR);
    assert(method_table_ok(p, c, t));
    if has_receiver_range(info(p, t)) {
        assert(!is_block_param(c, t, 0));
        assert(arg_ok(c, t, k, a, 0));
        lemma_at_good(p, c, trusted, s, a - 1);
    }
    if receiver_fails(p, s, t) {
        lemma_raise(p, c, trusted, s, AS_CHECK_FAILED);
    } else {
        lemma_invoke_static_call(p, c, trusted, s, t);
    }
}

// ---------------------------------------------------------------------------
// Lazy globals.

#[verifier::spinoff_prover]
pub proof fn lemma_lazy_call(p: Program2, c: Cert, trusted: bool, s: State2, g: int, len: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        0 <= g < s.globals.len(),
        len == 2 || len == 3,
        map_at(c, cur_m(s), cur_off(p, s) + len) == Some(cur_k(p, c, s).push(Kind::Val)),
    ensures
        outcome_ok(p, c, call_static(p, push(push(s, smi(g)), s.globals[g]), entry_method(p, RUN_GLOBAL_INITIALIZER), len)),
        !(call_static(p, push(push(s, smi(g)), s.globals[g]), entry_method(p, RUN_GLOBAL_INITIALIZER), len) is Primitive),
{
    lemma_instr(p, c, trusted, s);
    let e = entry_method(p, RUN_GLOBAL_INITIALIZER);
    let s1 = push(push(s, smi(g)), s.globals[g]);
    let ret = s.bci + len;
    let t0 = top_i(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    assert(entry_ok(p, c, RUN_GLOBAL_INITIALIZER, 2));
    assert(arity(p, e) == 2);
    assert(at(s1, 1) == smi(g));
    assert(receiver_check_ok(p, s1, e));
    if receiver_fails(p, s1, e) {
        lemma_wf_unw(p, c, trusted, s);
        lemma_unw_extra(p, c, s, s1, k);
        lemma_raise_unw(p, c, trusted, s1, k, AS_CHECK_FAILED);
        return;
    }
    let nb = s.stack.len() as int;
    let kr = k.push(Kind::Val);
    lemma_heap_ext_refl(p, s.heap);
    assert(s1.stack.len() - arity(p, e) == nb);
    assert(kr.subrange(0, k.len() as int) =~= k.subrange(0, k.len() as int));
    assert(ret - info(p, m).entry == cur_off(p, s) + len);
    assert(forall|x: int| 0 <= x < nb ==> #[trigger] s1.stack[x] == s.stack[x]);
    assert(globals_ok(c, s1));
    assert(call_pre(p, c, s, s1, e, ret, false));
    let s2 = call_state(p, s1, e, ret);
    lemma_call_shape(p, c, trusted, s, s1, e, ret, false);
    let tn = t0 + 1;
    assert(fbase(s2, tn) == nb);
    assert(good(s.heap, s.globals[g]));
    assert forall|x: int| 0 <= x < 2 implies
        #[trigger] conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, entry_kinds(p, c, e)[x], s2.stack[fbase(s2, tn) + x]) by {
        assert(!is_block_param(c, e, x)) by {
            assert(no_block_params(c, e));
            if 0 <= x < c.block_params[e].len() { assert(!c.block_params[e][x]); }
        }
        assert(entry_kinds(p, c, e)[x] == Kind::Val);
        reveal(conf);
    }
    let i = info(p, e);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) {
        let r = s2.stack[fbase(s2, tn)];
        assert(r == smi(g));
        assert(r == at(s1, 1));
    }
    assert(fmethod(s2, tn) == e);
    assert(receiver_ok(p, s2, tn));
    assert(call_args(p, c, s1, e, ret, false));
    lemma_call(p, c, trusted, s, s1, e, ret, false);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_lazy(p: Program2, c: Cert, trusted: bool, s: State2)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == LOAD_GLOBAL_VAR_LAZY || cur_op(p, s) == LOAD_GLOBAL_VAR_LAZY_WIDE,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let op = cur_op(p, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let len = opcode_length2(op);
    let g = if op == LOAD_GLOBAL_VAR_LAZY { b1_of(p, m, off) } else { w1_of(p, m, off) };
    assert(len == if op == LOAD_GLOBAL_VAR_LAZY { 2int } else { 3int });
    assert(!is_terminator(op));
    assert(post(p, c, m, off, k, trusted) is Some);
    assert(0 <= g < c.global_count);
    assert(map_at(c, m, off + len) == Some(k.push(Kind::Val)));
    assert(step(p, s) == op_load_global_lazy(p, s, g, len)) by { reveal(step); }
    assert(s.globals.len() == c.global_count);
    if is_lazy(p, s, s.globals[g]) {
        lemma_lazy_call(p, c, trusted, s, g, len);
    } else {
        let s2 = goto(push(s, s.globals[g]), s.bci + len);
        let k2 = k.push(Kind::Val);
        lemma_heap_ext_refl(p, s.heap);
        assert(good(s.heap, s.globals[g]));
        assert(s2.bci - info(p, m).entry == off + len);
        assert forall|j: int| 0 <= j < k2.len() implies
            #[trigger] unchanged(p, c, s, s2, k2, j) || conf(p, c, s2, top_i(s), kinds_of(p, c, s2, top_i(s)), j, k2[j], s2.stack[b + j]) by {
            if j == k.len() {
                assert(s2.stack[b + j] == s.globals[g]);
                reveal(conf);
            } else {
                assert(unchanged(p, c, s, s2, k2, j));
            }
        }
        assert forall|j: int| 0 <= j < k2.len() && #[trigger] unchanged(p, c, s, s2, k2, j) && k2[j] is Token implies
            k2.subrange(0, j) == k.subrange(0, j) by {
            assert(k2.subrange(0, j) =~= k.subrange(0, j));
        }
        assert(shape_ok(p, c, m, k));
        assert(local_step(p, c, s, s2, k2));
        lemma_local_step(p, c, trusted, s, s2, k2);
    }
}

// ---------------------------------------------------------------------------
// INVOKE_BLOCK.

/// The callee's own reference (entry kind `Block(1, ctx.slot)`) conforms.
#[verifier::spinoff_prover]
pub proof fn lemma_self_ref(p: Program2, c: Cert, s1: State2, t: int, ret: int, is_try: bool, f: int, slot: int)
    requires
        ({
            let s2 = call_state_h(p, s1, t, ret, is_try);
            let tn = top_i(s2);
            &&& 0 <= f < tn
            &&& s1.frames.len() >= 1
            &&& arity(p, t) >= 1
            &&& arity(p, t) <= s1.stack.len()
            &&& s1.stack.len() < 0x8000_0000
            &&& s1.frames.len() < 0x8000_0000
            &&& 0 <= slot < s1.stack.len()
            &&& ref_ok(s2, f, slot)
            &&& good_ref(p, c, s2, f, slot)
            &&& ctx_of(c, t) is Some
            &&& slot == fbase(s2, f) + ctx_of(c, t)->0.slot
            &&& kinds_of(p, c, s2, f)[ctx_of(c, t)->0.slot] == Kind::Method(t)
            &&& s1.stack[s1.stack.len() - arity(p, t)] == Value::BlockRef(f as usize, slot as usize)
            &&& valid_method(p, t)
            &&& p.methods.len() < 0x1000_0000
            &&& info(p, t).kind == KIND_BLOCK
        }),
    ensures ({
        let s2 = call_state_h(p, s1, t, ret, is_try);
        let tn = top_i(s2);
        conf(p, c, s2, tn, kinds_of(p, c, s2, tn), 0, entry_kinds(p, c, t)[0], s2.stack[fbase(s2, tn)])
    }),
{
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let tn = top_i(s2);
    let ctx = ctx_of(c, t)->0;
    assert(entry_kinds(p, c, t)[0] == Kind::Block(1, ctx.slot));
    assert(fbase(s2, tn) == s1.stack.len() - arity(p, t));
    assert(slots(s2, tn) == arity(p, t));
    assert(s2.stack[fbase(s2, tn)] == Value::BlockRef(f as usize, slot as usize));
    reveal_with_fuel(context_frame, 2);
    assert(context_frame(s2, tn, 1) == f);
    assert(fmethod(s2, tn) == t);
    reveal(conf);
}

#[verifier::spinoff_prover]
pub proof fn lemma_invoke_block_call(p: Program2, c: Cert, trusted: bool, s: State2, n: int, f: int, slot: int, tt: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        1 <= n <= cur_k(p, c, s).len(),
        value_operands(cur_k(p, c, s), n - 1),
        leaves0(p, cur_m(s), cur_k(p, c, s).len() as int, n),
        map_at(c, cur_m(s), cur_off(p, s) + 2) == Some(pop_push(cur_k(p, c, s), n, Some(Kind::Val))),
        at(s, n - 1) == Value::BlockRef(f as usize, slot as usize),
        0 <= f <= top_i(s),
        // The reference: a block slot of the caller below the arguments,
        // or a good reference into a lower frame.
        f == top_i(s) ==> slot - cur_b(s) < cur_k(p, c, s).len() - n
            && cur_k(p, c, s)[cur_k(p, c, s).len() - n] == Kind::Block(0, slot - cur_b(s)),
        f < top_i(s) ==> ref_ok(s, f, slot) && good_ref(p, c, s, f, slot),
        valid_method(p, tt),
        info(p, tt).kind == KIND_BLOCK,
        ctx_of(c, tt) is Some,
        ctx_of(c, tt)->0.outer == fmethod(s, f),
        ctx_of(c, tt)->0.slot == slot - fbase(s, f),
        kinds_of(p, c, s, f)[slot - fbase(s, f)] == Kind::Method(tt),
        arity(p, tt) <= n,
    ensures wf(p, c, call_state(p, drop(s, n - arity(p, tt)), tt, s.bci + 2)),
{
    lemma_instr(p, c, trusted, s);
    lemma_block_method(p, c, trusted, tt);
    let a = arity(p, tt);
    let s1 = drop(s, n - a);
    let ret = s.bci + 2;
    let t0 = top_i(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let h = k.len() as int;
    let nb = s.stack.len() - n;
    let keep = h - n;
    let kr = pop_push(k, n, Some(Kind::Val));
    lemma_heap_ext_refl(p, s.heap);
    assert(s1.stack.len() - a == nb);
    assert(nb - b == keep);
    assert(kr.subrange(0, keep) =~= k.subrange(0, keep));
    assert(ret - info(p, m).entry == cur_off(p, s) + 2);
    assert(forall|x: int| 0 <= x < nb ==> #[trigger] s1.stack[x] == s.stack[x]);
    assert(globals_ok(c, s1));
    assert(call_pre(p, c, s, s1, tt, ret, false));
    let s2 = call_state(p, s1, tt, ret);
    lemma_call_shape(p, c, trusted, s, s1, tt, ret, false);
    let tn = t0 + 1;
    assert(fbase(s2, tn) == nb);
    let ctx = ctx_of(c, tt)->0;
    // The callee's own reference.
    assert(s1.stack[nb] == at(s, n - 1));
    if f == t0 {
        let i = slot - b;
        lemma_good_ref_top(p, c, trusted, s, s1, tt, ret, false, h - n, i);
        assert(kinds_of(p, c, s2, f)[ctx.slot] == Kind::Method(tt));
    } else {
        lemma_ref_below(p, c, trusted, s, s1, tt, ret, false, f, slot);
    }
    lemma_self_ref(p, c, s1, tt, ret, false, f, slot);
    assert forall|x: int| 0 <= x < a implies
        #[trigger] conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, entry_kinds(p, c, tt)[x], s2.stack[fbase(s2, tn) + x]) by {
        if x > 0 {
            assert(entry_kinds(p, c, tt)[x] == Kind::Val);
            assert(is_val(top_kind(k, n - 1 - x)));
            lemma_at_good(p, c, trusted, s, n - 1 - x);
            assert(s2.stack[nb + x] == at(s, n - 1 - x));
            reveal(conf);
        }
    }
    assert(fmethod(s2, tn) == tt);
    assert(receiver_ok(p, s2, tn));
    assert(call_args(p, c, s1, tt, ret, false));
    lemma_call(p, c, trusted, s, s1, tt, ret, false);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_invoke_block(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_BLOCK,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let t0 = top_i(s);
    let h = k.len() as int;
    let n = b1_of(p, m, off);
    assert(opcode_length2(INVOKE_BLOCK) == 2);
    assert(!is_terminator(INVOKE_BLOCK));
    assert(post(p, c, m, off, k, trusted) is Some);
    assert(1 <= n <= h && is_ref(top_kind(k, n - 1)) && value_operands(k, n - 1) && leaves0(p, m, h, n));
    assert(match top_kind(k, n - 1) { Kind::Block(d, i) => d == 0 ==> i < h - n, _ => true });
    assert(map_at(c, m, off + 2) == Some(pop_push(k, n, Some(Kind::Val))));
    assert(step(p, s) == op_invoke_block(p, s, n)) by { reveal(step); }
    let jr = h - n;
    lemma_at_conf(p, c, trusted, s, n - 1);
    let v = at(s, n - 1);
    assert(top_kind(k, n - 1) == k[jr]);
    assert(conf(p, c, s, t0, k, jr, k[jr], v));
    lemma_task_basics(p, c, s);
    match v {
        Value::BlockRef(fu, su) => {
            let f = fu as int;
            let slot = su as int;
            assert(ref_ok(s, f, slot) && 0 <= f <= t0
                && (f == t0 ==> slot - b < h - n && k[jr] == Kind::Block(0, slot - b))
                && (f < t0 ==> good_ref(p, c, s, f, slot))) by {
                reveal(conf);
                match k[jr] {
                    Kind::Block(d, i) => {
                        if d != 0 {
                            lemma_context_frame_lt(s, t0, d as nat);
                        }
                    },
                    _ => {},
                }
            }
            assert(block_slot(p, c, fmethod(s, f), kinds_of(p, c, s, f), slot - fbase(s, f))) by {
                if f == t0 {
                    assert(wf_kind(p, c, m, k, jr));
                } else {
                    reveal(good_ref);
                }
            }
            lemma_slot_method(p, c, trusted, s, f, slot - fbase(s, f));
            let tt = kind_method(kinds_of(p, c, s, f)[slot - fbase(s, f)]);
            assert(block_ref(s, v) == Some((f, slot)));
            assert(block_target(p, s, slot) == Some(tt));
            if n < arity(p, tt) {
                lemma_raise(p, c, trusted, s, CODE_INVOCATION_FAILED);
            } else {
                lemma_invoke_block_call(p, c, trusted, s, n, f, slot, tt);
            }
        },
        _ => {
            assert(false) by { reveal(conf); }
        },
    }
}

// ---------------------------------------------------------------------------
// TRY.

#[verifier::spinoff_prover]
pub proof fn lemma_try_call(p: Program2, c: Cert, trusted: bool, s: State2, tt: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        1 <= cur_k(p, c, s).len(),
        block_slot(p, c, cur_m(s), cur_k(p, c, s), cur_k(p, c, s).len() - 1),
        ctx_ok_upto(p, c, cur_m(s), cur_k(p, c, s), cur_k(p, c, s).len() - 1),
        tt == kind_method(cur_k(p, c, s)[cur_k(p, c, s).len() - 1]),
        arity(p, tt) == 1,
        map_at(c, cur_m(s), cur_off(p, s) + 1) == Some(cur_k(p, c, s).push(Kind::Val).push(Kind::Token).push(Kind::Token).push(Kind::Val)),
    ensures ({
        let slot = s.stack.len() - 1;
        wf(p, c, call_state_h(p, push(s, Value::BlockRef(top_index(s) as usize, slot as usize)), tt, s.bci + 1, true))
    }),
{
    lemma_instr(p, c, trusted, s);
    let t0 = top_i(s);
    let m = cur_m(s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let h = k.len() as int;
    let slot = s.stack.len() - 1;
    let s1 = push(s, Value::BlockRef(top_index(s) as usize, slot as usize));
    let ret = s.bci + 1;
    let nb = s.stack.len() as int;
    assert(valid_method(p, tt) && ctx_of(c, tt) is Some);
    lemma_block_method(p, c, trusted, tt);
    let ctx = ctx_of(c, tt)->0;
    assert(ctx.outer == m && ctx.slot == h - 1);
    lemma_heap_ext_refl(p, s.heap);
    assert(s1.stack.len() - arity(p, tt) == nb);
    let kr = k.push(Kind::Val).push(Kind::Token).push(Kind::Token).push(Kind::Val);
    assert(kr.subrange(0, h) =~= k.subrange(0, h));
    assert(ret - info(p, m).entry == cur_off(p, s) + 1);
    assert(forall|x: int| 0 <= x < nb ==> #[trigger] s1.stack[x] == s.stack[x]);
    assert(globals_ok(c, s1));
    assert(call_pre(p, c, s, s1, tt, ret, true));
    let s2 = call_state_h(p, s1, tt, ret, true);
    lemma_call_shape(p, c, trusted, s, s1, tt, ret, true);
    let tn = t0 + 1;
    // The reference to the block's slot.
    let k2 = kinds_of(p, c, s2, t0);
    assert(k2 =~= k);
    assert(fbase(s2, t0) == b);
    assert(fmethod(s2, t0) == m);
    assert(s2.frames[t0] == s.frames[t0]);
    assert(s2.frames[t0 + 1].base as int == nb);
    assert(ref_ok(s2, t0, slot));
    assert(good_ref(p, c, s2, t0, slot)) by { reveal(good_ref); }
    assert(k2[ctx.slot] == Kind::Method(tt));
    assert(s1.stack[nb] == Value::BlockRef(t0 as usize, slot as usize));
    lemma_self_ref(p, c, s1, tt, ret, true, t0, slot);
    assert forall|x: int| 0 <= x < arity(p, tt) implies
        #[trigger] conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, entry_kinds(p, c, tt)[x], s2.stack[fbase(s2, tn) + x]) by {
        assert(x == 0);
    }
    assert(fmethod(s2, tn) == tt);
    assert(receiver_ok(p, s2, tn));
    assert(call_args(p, c, s1, tt, ret, true));
    lemma_call(p, c, trusted, s, s1, tt, ret, true);
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_try(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == TRY,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let b = cur_b(s);
    let t0 = top_i(s);
    let h = k.len() as int;
    assert(opcode_length2(TRY) == 1);
    assert(!is_terminator(TRY));
    assert(post(p, c, m, off, k, trusted) is Some);
    let tt = kind_method(k[h - 1]);
    assert(1 <= h && block_slot(p, c, m, k, h - 1) && arity(p, tt) == 1 && ctx_ok_upto(p, c, m, k, h - 1));
    assert(map_at(c, m, off + 1) == Some(k.push(Kind::Val).push(Kind::Token).push(Kind::Token).push(Kind::Val)));
    assert(step(p, s) == op_try(p, s)) by { reveal(step); }
    lemma_slot_method(p, c, trusted, s, t0, h - 1);
    assert(block_target(p, s, s.stack.len() - 1) == Some(tt));
    lemma_try_call(p, c, trusted, s, tt);
    let slot = s.stack.len() - 1;
    let s1 = push(s, Value::BlockRef(top_index(s) as usize, slot as usize));
    assert(call(p, s1, tt, s.bci + 1) == Outcome2::Next(call_state(p, s1, tt, s.bci + 1)));
    let cs = call_state(p, s1, tt, s.bci + 1);
    let ch = call_state_h(p, s1, tt, s.bci + 1, true);
    assert(flag_top(cs).frames =~= ch.frames);
    assert(flag_top(cs) == ch);
    assert(op_try(p, s) == Outcome2::Next(call_state_h(p, s1, tt, s.bci + 1, true)));
}

// ---------------------------------------------------------------------------
// The family.

pub proof fn lemma_step_call(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), fam_call(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    let op = cur_op(p, s);
    if op == LOAD_GLOBAL_VAR_LAZY || op == LOAD_GLOBAL_VAR_LAZY_WIDE {
        lemma_step_lazy(p, c, trusted, s);
    } else if op == INVOKE_STATIC {
        lemma_step_invoke_static(p, c, trusted, s);
    } else if op == INVOKE_BLOCK {
        lemma_step_invoke_block(p, c, trusted, s);
    } else {
        assert(op == TRY);
        lemma_step_try(p, c, trusted, s);
    }
}

} // verus!
