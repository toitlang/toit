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

//! Tail calls (INVOKE_STATIC_TAIL, INVOKE_LAMBDA_TAIL,
//! INVOKE_INITIALIZER_TAIL): replacing the top frame's method and slots
//! keeps the invariant when the new slots conform to the target's entry
//! kinds and its receiver is in its range.

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
use crate::v2::sound_unwind::*;
use crate::v2::sound_raise::*;
#[cfg(verus_only)]
use crate::spec_common::{u16_at, class_id_ok, class_id_of, is_instance, fields, is_array, elements, obj, obj_id};

verus! {

// ---------------------------------------------------------------------------
// Replacing the top frame.

/// The state after `replace_frame(p, s, t, args)`.
pub open spec fn tail_state(p: Program2, s: State2, t: int, args: Seq<Value>) -> State2 {
    State2 {
        stack: s.stack.subrange(0, base(s)) + args,
        frames: s.frames.update(top_index(s), Frame { method: t as usize, ..top(s) }),
        bci: info(p, t).entry,
        ..s
    }
}

// The refinement view of `replace_frame` (for the core's in-place move,
// `Machine::replace_frame(target, from, n, extra)`): the new arguments are
// `n` slots of the old frame from object-stack position `from`, then the
// captures. Nothing else in the tail-call steps needs restating: their
// checks are the core's in the same order, and the frame keeps `ret`, `base`
// and its try-block flag (format note 23). The core's `ensure_room` before
// the three opcodes is a resource point (`prim::grows_stack`).

/// The arguments of a tail call as the machine moves them.
pub open spec fn moved_args(s: State2, from: int, n: int, cap: Seq<Value>) -> Seq<Value> {
    s.stack.subrange(from, from + n) + cap
}

/// The three tail calls pass `moved_args`: INVOKE_STATIC_TAIL the top
/// `arity` slots, INVOKE_LAMBDA_TAIL the parameters after the lambda and
/// the captures, INVOKE_INITIALIZER_TAIL nothing.
pub proof fn lemma_tail_moved(s: State2, a: int, user: int, cap: Seq<Value>)
    requires 0 <= a <= s.stack.len(), 0 <= base(s), base(s) + 1 + user <= s.stack.len(), 0 <= user,
    ensures
        s.stack.subrange(s.stack.len() - a, s.stack.len() as int)
            == moved_args(s, s.stack.len() - a, a, Seq::empty()),
        s.stack.subrange(base(s) + 1, base(s) + 1 + user) + cap == moved_args(s, base(s) + 1, user, cap),
        Seq::<Value>::empty() == moved_args(s, s.stack.len() as int, 0, Seq::empty()),
{
    assert(s.stack.subrange(s.stack.len() - a, s.stack.len() as int) + Seq::empty()
        =~= s.stack.subrange(s.stack.len() - a, s.stack.len() as int));
    assert(s.stack.subrange(s.stack.len() as int, s.stack.len() as int) + Seq::<Value>::empty() =~= Seq::<Value>::empty());
}

/// `replace_frame` slot by slot: the slots below the frame stay, the moved
/// slots follow from the frame's base, then the captures.
pub proof fn lemma_replace_frame_slots(p: Program2, s: State2, t: int, from: int, n: int, cap: Seq<Value>)
    requires
        0 <= base(s) <= s.stack.len(), 0 <= from, 0 <= n, from + n <= s.stack.len(),
    ensures ({
        let s2 = tail_state(p, s, t, moved_args(s, from, n, cap));
        &&& replace_frame(p, s, t, moved_args(s, from, n, cap)) == Outcome2::Next(s2)
        &&& s2.stack.len() == base(s) + n + cap.len()
        &&& forall|i: int| 0 <= i < base(s) ==> #[trigger] s2.stack[i] == s.stack[i]
        &&& forall|i: int| 0 <= i < n ==> #[trigger] s2.stack[base(s) + i] == s.stack[from + i]
        &&& forall|j: int| 0 <= j < cap.len() ==> #[trigger] s2.stack[base(s) + n + j] == cap[j]
    }),
{
    let s2 = tail_state(p, s, t, moved_args(s, from, n, cap));
    assert forall|i: int| 0 <= i < n implies #[trigger] s2.stack[base(s) + i] == s.stack[from + i] by {}
    assert forall|j: int| 0 <= j < cap.len() implies #[trigger] s2.stack[base(s) + n + j] == cap[j] by {}
}

/// The new slots conform to the target's entry kinds and its receiver is
/// in its range.
pub open spec fn tail_args(p: Program2, c: Cert, s: State2, t: int, args: Seq<Value>) -> bool {
    let s2 = tail_state(p, s, t, args);
    &&& args.len() == arity(p, t)
    &&& forall|x: int| 0 <= x < arity(p, t) ==>
            #[trigger] conf(p, c, s2, top_i(s), entry_kinds(p, c, t), x, entry_kinds(p, c, t)[x], args[x])
    &&& receiver_ok(p, s2, top_i(s))
}

#[verifier::spinoff_prover]
pub proof fn lemma_tail_shape(p: Program2, c: Cert, trusted: bool, s: State2, t: int, args: Seq<Value>)
    requires accepts(p, c, trusted), wf(p, c, s), valid_method(p, t), args.len() == arity(p, t),
    ensures ({
        let s2 = tail_state(p, s, t, args);
        let t0 = top_i(s);
        let b = fbase(s, t0);
        &&& s.frames.len() > 0
        &&& bases_ok(s)
        &&& s2.frames.len() == s.frames.len()
        &&& top_i(s2) == t0
        &&& s2.heap == s.heap
        &&& s2.globals == s.globals
        &&& forall|g: int| 0 <= g < t0 ==> #[trigger] s2.frames[g] == s.frames[g]
        &&& s2.frames[t0].ret == s.frames[t0].ret
        &&& s2.frames[t0].base == s.frames[t0].base
        &&& s2.frames[t0].handler == s.frames[t0].handler
        &&& s2.frames[0].handler == s.frames[0].handler
        &&& fmethod(s2, t0) == t
        &&& fbase(s2, t0) == b
        &&& base(s) == b
        &&& 0 <= b <= s.stack.len()
        &&& s2.stack.len() == b + arity(p, t)
        &&& slots(s2, t0) == arity(p, t)
        &&& forall|x: int| 0 <= x < b ==> #[trigger] s2.stack[x] == s.stack[x]
        &&& forall|x: int| 0 <= x < arity(p, t) ==> #[trigger] s2.stack[b + x] == args[x]
        &&& bases_ok(s2)
        &&& (t0 > 0 ==> same_below(s, s2, t0 - 1))
    }),
{
    let s2 = tail_state(p, s, t, args);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    assert(p.methods.len() < 0x1000_0000);
    assert(s2.frames[t0] == Frame { method: t as usize, ..s.frames[t0] });
    assert(forall|g: int| 0 <= g < t0 ==> #[trigger] s2.frames[g] == s.frames[g]);
    assert(s2.stack =~= s.stack.subrange(0, b) + args);
    assert(forall|x: int| 0 <= x < arity(p, t) ==> #[trigger] s2.stack[b + x] == args[x]);
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s, fi));
        }
    }
    if t0 > 0 {
        lemma_base_le_len(s, t0);
        assert(same_below(s, s2, t0 - 1)) by {
            assert forall|g: int| 0 <= g <= t0 - 1 implies #[trigger] try_frame(s2, g) == try_frame(s, g) by {}
            lemma_heap_ext_refl(p, s.heap);
        }
    }
}

/// A tail call from a well-formed state.
#[verifier::spinoff_prover]
pub proof fn lemma_tail(p: Program2, c: Cert, trusted: bool, s: State2, t: int, args: Seq<Value>)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        valid_method(p, t), !dead_block(p, c, t),
        tail_args(p, c, s, t, args),
    ensures
        replace_frame(p, s, t, args) == Outcome2::Next(tail_state(p, s, t, args)),
        wf(p, c, tail_state(p, s, t, args)),
{
    let s2 = tail_state(p, s, t, args);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    lemma_wf_unw(p, c, trusted, s);
    lemma_tail_shape(p, c, trusted, s, t, args);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        if fi < t0 {
            assert(wf_task(p, c, s));
            lemma_same_below_down(s, s2, t0 - 1, fi);
            lemma_frame_below(p, c, s, s2, fi);
        } else {
            reveal(frame_ok);
            assert(fi == t0);
            assert(method_ok(p, c, t, trusted));
            assert(fbci(s2, t0) == info(p, t).entry);
            assert(foff(p, s2, t0) == 0);
            assert(map_at(c, t, 0) == Some(entry_kinds(p, c, t)));
            assert(fmap(p, c, s2, t0) == entry_kinds(p, c, t));
            assert(kinds_of(p, c, s2, t0) =~= entry_kinds(p, c, t));
            assert(frame_shape_ok(p, c, s2, t0));
            assert forall|j: int| 0 <= j < slots(s2, t0) implies
                #[trigger] conf(p, c, s2, t0, kinds_of(p, c, s2, t0), j, kinds_of(p, c, s2, t0)[j], s2.stack[fbase(s2, t0) + j]) by {
                assert(conf(p, c, s2, t0, entry_kinds(p, c, t), j, entry_kinds(p, c, t)[j], args[j]));
                assert(s2.stack[b + j] == args[j]);
            }
            assert(pinned_ok(p, s2, t0));
        }
    }
    assert(wf_task(p, c, s2)) by { reveal(wf_task); }
    assert(globals_ok(c, s2));
    assert(wf(p, c, s2)) by { reveal(wf); }
}

// ---------------------------------------------------------------------------
// Raising.
// ---------------------------------------------------------------------------
// INVOKE_STATIC_TAIL.

/// Argument `x` of an INVOKE_STATIC_TAIL conforms to the target's entry
/// kind in the new frame.
#[verifier::spinoff_prover]
pub proof fn lemma_static_tail_arg(p: Program2, c: Cert, trusted: bool, s: State2, t: int, x: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        cur_op(p, s) == INVOKE_STATIC_TAIL,
        t == dispatch_target(p, w1_of(p, cur_m(s), cur_off(p, s))),
        valid_method(p, t),
        info(p, t).kind != KIND_BLOCK,
        0 <= x < arity(p, t),
    ensures ({
        let n = arity(p, t);
        let args = s.stack.subrange(s.stack.len() - n, s.stack.len() as int);
        conf(p, c, tail_state(p, s, t, args), top_i(s), entry_kinds(p, c, t), x, entry_kinds(p, c, t)[x], args[x])
    }),
{
    lemma_instr(p, c, trusted, s);
    lemma_task_basics(p, c, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let n = arity(p, t);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    let args = s.stack.subrange(s.stack.len() - n, s.stack.len() as int);
    let s2 = tail_state(p, s, t, args);
    let ek = entry_kinds(p, c, t);
    assert(is_terminator(INVOKE_STATIC_TAIL));
    assert(terminator_ok(p, c, m, off, k));
    assert(args_ok(c, t, k, n));
    assert(arg_ok(c, t, k, n, x));
    let j = h - n + x;
    assert(!is_local_ref(k[j]));
    lemma_at_conf(p, c, trusted, s, n - 1 - x);
    let v = s.stack[b + j];
    assert(args[x] == v);
    assert(conf(p, c, s, t0, k, j, k[j], v));
    lemma_tail_shape(p, c, trusted, s, t, args);
    assert(ek[x] == if is_block_param(c, t, x) { Kind::Param } else { Kind::Val });
    if is_block_param(c, t, x) {
        reveal(conf);
        reveal(good_ref);
        match v {
            Value::BlockRef(f, slot) => {
                let f = f as int;
                match k[j] {
                    Kind::Block(d, sl) => {
                        assert(d > 0);
                        lemma_context_frame_lt(s, t0, d as nat);
                    },
                    _ => {},
                }
                assert(0 <= f < t0);
                lemma_ref_ok_below(s, s2, t0 - 1, f, slot as int);
                lemma_kinds_below(p, c, s, s2, f, t0 - 1);
                assert(good_ref(p, c, s2, f, slot as int) == good_ref(p, c, s, f, slot as int));
            },
            _ => {
                assert(false);
            },
        }
    } else {
        lemma_val_good(p, c, s, t0, k, j, k[j], v);
        reveal(conf);
    }
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_static_tail(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_STATIC_TAIL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let w1 = w1_of(p, m, off);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    assert(opcode_length2(INVOKE_STATIC_TAIL) == 3);
    assert(step(p, s) == op_invoke_static_tail(p, s, w1)) by { reveal(step); }
    assert(is_terminator(INVOKE_STATIC_TAIL));
    assert(terminator_ok(p, c, m, off, k));
    let t = dispatch_target(p, w1);
    let n = arity(p, t);
    assert(valid_method(p, t));
    assert(0 <= w1 < p.dispatch.len());
    assert(dispatch_entry_ok(p, w1));
    assert(info(p, t).kind == KIND_METHOD || info(p, t).kind == KIND_FIELD_ACCESSOR);
    assert(method_table_ok(p, c, t));
    assert(args_ok(c, t, k, n));
    if has_receiver_range(info(p, t)) {
        assert(n >= 1);
        assert(arg_ok(c, t, k, n, 0));
        assert(!is_block_param(c, t, 0));
        lemma_at_good(p, c, trusted, s, n - 1);
    }
    assert(receiver_check_ok(p, s, t));
    if receiver_fails(p, s, t) {
        assert(step(p, s) == raise(p, s, AS_CHECK_FAILED));
        lemma_raise_ok(p, c, trusted, s, AS_CHECK_FAILED);
        return;
    }
    let args = s.stack.subrange(s.stack.len() - n, s.stack.len() as int);
    let s2 = tail_state(p, s, t, args);
    assert(step(p, s) == replace_frame(p, s, t, args));
    lemma_tail_shape(p, c, trusted, s, t, args);
    assert forall|x: int| 0 <= x < arity(p, t) implies
        #[trigger] conf(p, c, s2, t0, entry_kinds(p, c, t), x, entry_kinds(p, c, t)[x], args[x]) by {
        lemma_static_tail_arg(p, c, trusted, s, t, x);
    }
    let i = info(p, t);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, t) >= 1 {
        let r = s2.stack[fbase(s2, t0)];
        assert(r == args[0]);
        assert(r == at(s, n - 1));
        assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
    }
    assert(receiver_ok(p, s2, t0));
    assert(tail_args(p, c, s, t, args));
    lemma_tail(p, c, trusted, s, t, args);
}

// ---------------------------------------------------------------------------
// INVOKE_LAMBDA_TAIL.

/// The captured values of a lambda are values.
pub proof fn lemma_captured_good(p: Program2, c: Cert, s: State2, recv: Value, cc: int, cap: Seq<Value>)
    requires
        heap_ok(p, c, s.heap),
        is_instance(as1(s), recv),
        fields(as1(s), recv).len() >= 2,
        captured(p, s, fields(as1(s), recv)[1], cc) == Some(cap),
    ensures
        cap.len() == cc,
        forall|i: int| 0 <= i < cap.len() ==> good(s.heap, #[trigger] cap[i]),
{
    reveal(heap_ok);
    let id = obj_id(recv);
    assert(obj_ok(p, c, s.heap, s.heap[id]));
    let a = fields(as1(s), recv)[1];
    assert(good(s.heap, a));
    if is_array(as1(s), a) {
        let id2 = obj_id(a);
        assert(obj_ok(p, c, s.heap, s.heap[id2]));
        assert(cap == elements(as1(s), a));
    } else {
        assert(cap == seq![a]);
    }
}

/// Plain values for a lambda (no block parameters, no receiver range
/// check) make the tail call's arguments.
#[verifier::spinoff_prover]
pub proof fn lemma_lambda_args(p: Program2, c: Cert, trusted: bool, s: State2, t: int, args: Seq<Value>)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        valid_method(p, t), info(p, t).kind == KIND_LAMBDA,
        args.len() == arity(p, t),
        forall|x: int| 0 <= x < args.len() ==> good(s.heap, #[trigger] args[x]),
    ensures tail_args(p, c, s, t, args),
{
    let s2 = tail_state(p, s, t, args);
    let t0 = top_i(s);
    lemma_tail_shape(p, c, trusted, s, t, args);
    assert(method_table_ok(p, c, t));
    assert(no_block_params(c, t));
    assert forall|x: int| 0 <= x < arity(p, t) implies
        #[trigger] conf(p, c, s2, t0, entry_kinds(p, c, t), x, entry_kinds(p, c, t)[x], args[x]) by {
        assert(!c.block_params[t][x]);
        assert(!is_block_param(c, t, x));
        assert(entry_kinds(p, c, t)[x] == Kind::Val);
        assert(good(s.heap, args[x]));
        reveal(conf);
    }
    assert(receiver_ok(p, s2, t0));
}

#[verifier::spinoff_prover]
pub proof fn lemma_step_lambda_tail(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_LAMBDA_TAIL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    let h = k.len() as int;
    let b = cur_b(s);
    assert(step(p, s) == op_invoke_lambda_tail(p, s)) by { reveal(step); }
    assert(is_terminator(INVOKE_LAMBDA_TAIL));
    assert(terminator_ok(p, c, m, off, k));
    let a = arity(p, m);
    assert(a == h && h >= 1);
    let recv = s.stack[b];
    if !is_instance(as1(s), recv) || fields(as1(s), recv).len() < 2 {
        lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
        return;
    }
    let mid = fields(as1(s), recv)[0];
    match mid {
        Value::Smi(mm) => {
            let t = mm as int;
            if !valid_method(p, t) || info(p, t).kind != KIND_LAMBDA {
                lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
                return;
            }
            let cc = info(p, t).aux as int;
            match captured(p, s, fields(as1(s), recv)[1], cc) {
                None => {
                    lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
                },
                Some(cap) => {
                    let user = arity(p, t) - cc;
                    if user < 0 {
                        lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
                    } else if a - 1 < user {
                        lemma_raise_ok(p, c, trusted, s, CODE_INVOCATION_FAILED);
                    } else {
                        let args = s.stack.subrange(b + 1, b + 1 + user) + cap;
                        assert(step(p, s) == replace_frame(p, s, t, args));
                        lemma_captured_good(p, c, s, recv, cc, cap);
                        assert forall|x: int| 0 <= x < args.len() implies good(s.heap, #[trigger] args[x]) by {
                            if x < user {
                                assert(args[x] == s.stack[b + 1 + x]);
                                assert(is_val(k[1 + x]));
                                assert(top_kind(k, h - 2 - x) == k[1 + x]);
                                lemma_at_good(p, c, trusted, s, h - 2 - x);
                            } else {
                                assert(args[x] == cap[x - user]);
                            }
                        }
                        lemma_lambda_args(p, c, trusted, s, t, args);
                        lemma_tail(p, c, trusted, s, t, args);
                    }
                },
            }
        },
        _ => {
            lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
        },
    }
}

// ---------------------------------------------------------------------------
// INVOKE_INITIALIZER_TAIL.

#[verifier::spinoff_prover]
pub proof fn lemma_step_initializer_tail(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), cur_op(p, s) == INVOKE_INITIALIZER_TAIL,
    ensures step_ok(p, c, s),
{
    lemma_instr(p, c, trusted, s);
    let m = cur_m(s);
    let off = cur_off(p, s);
    let k = cur_k(p, c, s);
    assert(step(p, s) == op_invoke_initializer_tail(p, s)) by { reveal(step); }
    assert(is_terminator(INVOKE_INITIALIZER_TAIL));
    assert(terminator_ok(p, c, m, off, k));
    assert(k.len() >= 1);
    assert(has_slot(s, 0));
    match at(s, 0) {
        Value::Smi(mm) => {
            let t = mm as int;
            if !valid_method(p, t) || info(p, t).kind != KIND_METHOD || arity(p, t) != 0 {
                lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
            } else {
                let args = Seq::<Value>::empty();
                assert(step(p, s) == replace_frame(p, s, t, args));
                lemma_tail_shape(p, c, trusted, s, t, args);
                assert(receiver_ok(p, tail_state(p, s, t, args), top_i(s)));
                assert(tail_args(p, c, s, t, args));
                lemma_tail(p, c, trusted, s, t, args);
            }
        },
        _ => {
            lemma_raise_ok(p, c, trusted, s, INVALID_PROGRAM);
        },
    }
}

// ---------------------------------------------------------------------------
// The family.

pub proof fn lemma_step_tail(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), fam_tail(cur_op(p, s)),
    ensures step_ok(p, c, s),
{
    let op = cur_op(p, s);
    if op == INVOKE_STATIC_TAIL {
        lemma_step_static_tail(p, c, trusted, s);
    } else if op == INVOKE_LAMBDA_TAIL {
        lemma_step_lambda_tail(p, c, trusted, s);
    } else {
        assert(op == INVOKE_INITIALIZER_TAIL);
        lemma_step_initializer_tail(p, c, trusted, s);
    }
}

} // verus!
