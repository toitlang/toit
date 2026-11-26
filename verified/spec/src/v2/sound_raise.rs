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

//! The unwinding loop and raised exceptions keep the invariant (or end
//! the task).

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
use crate::v2::sound_upto::*;
use crate::v2::sound_unwind::*;
use crate::v2::sound_return::*;
#[cfg(verus_only)]
use crate::v2::sound_prim::lemma_prim_heap;
use crate::v2::prim::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, builtin, instance_field_count, EXCEPTION_CLASS};

verus! {

/// Unwinding never ends in a PRIMITIVE outcome or a raise.
pub proof fn lemma_unwind_not_prim(p: Program2, s: State2, u: Unwind)
    ensures !(unwind(p, s, u) is Primitive), !(unwind(p, s, u) is Raise),
    decreases s.frames.len(),
{
    if s.frames.len() == 0 {
    } else if top(s).base as int > s.stack.len() {
    } else if unw_target(u) == top_index(s) {
    } else if top(s).handler {
    } else {
        let s1 = pop_frame(s);
        assert(s1.frames.len() < s.frames.len());
        lemma_unwind_not_prim(p, s1, u);
    }
}

/// `lemma_raise`, also stating that a raise is not a PRIMITIVE outcome.
pub proof fn lemma_raise_ok(p: Program2, c: Cert, trusted: bool, s: State2, k: int)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), 0 <= k < 5,
    ensures outcome_ok(p, c, raise(p, s, k)), !(raise(p, s, k) is Primitive),
{
    lemma_raise(p, c, trusted, s, k);
}

/// An unwinding state stays one when the heap grows.
pub proof fn lemma_unw_heap(p: Program2, c: Cert, s: State2, kt: Seq<Kind>, h2: Seq<HeapObj>)
    requires
        unw_ok(p, c, s, kt),
        heap_ext(p, s.heap, h2),
        heap_ok(p, c, h2),
        h2.len() < 0x8000_0000,
    ensures unw_ok(p, c, with_heap(s, h2), kt),
{
    let s2 = with_heap(s, h2);
    let t = top_i(s);
    let b = fbase(s, t);
    lemma_globals_heap(c, s, h2);
    lemma_consts_heap(p, s.heap, h2);
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s, fi));
        }
    }
    if t > 0 {
        assert(same_below(s, s2, t - 1)) by {
            assert forall|g: int| 0 <= g <= t - 1 implies #[trigger] try_frame(s2, g) == try_frame(s, g) by {}
            lemma_base_le_len(s, t);
        }
    }
    assert forall|fi: int| 0 <= fi < t implies #[trigger] frame_ok(p, c, s2, fi) by {
        assert(frame_ok(p, c, s, fi));
        lemma_same_below_down(s, s2, t - 1, fi);
        lemma_frame_below_unw(p, c, s, s2, fi);
    }
    assert forall|j: int| 0 <= j < kt.len() implies #[trigger] conf(p, c, s2, t, kt, j, kt[j], s2.stack[b + j]) by {
        assert(conf(p, c, s, t, kt, j, kt[j], s.stack[b + j]));
        lemma_conf_heap(p, c, s, h2, t, kt, j, kt[j], s.stack[b + j]);
    }
    let m = fmethod(s, t);
    let i = info(p, m);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
        let r = s.stack[b];
        match r {
            Value::Obj(id) => { assert(h2[id as int].class_id == s.heap[id as int].class_id); },
            _ => {},
        }
        assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
    }
}

/// A non-local branch that reaches its frame: the top frame continues at
/// the target with its slots cut to the target's map, a prefix of its
/// known kinds.
pub proof fn lemma_cut_top(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, bci: usize, tt: Seq<Kind>)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        0 <= bci as int - info(p, fmethod(s, top_i(s))).entry,
        map_at(c, fmethod(s, top_i(s)), bci as int - info(p, fmethod(s, top_i(s))).entry) == Some(tt),
        tt.len() <= kt.len(),
        tt == kt.subrange(0, tt.len() as int),
    ensures
        wf(p, c, State2 { stack: s.stack.subrange(0, fbase(s, top_i(s)) + tt.len()), bci: bci, ..s }),
{
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    let n = tt.len() as int;
    let s2 = State2 { stack: s.stack.subrange(0, b + n), bci: bci, ..s };
    lemma_base_le_len(s, t);
    lemma_map_instr(p, c, trusted, m, bci as int - info(p, m).entry);
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s, fi));
        }
    }
    assert(!try_frame(s, t));
    if t > 0 {
        assert(same_below(s, s2, t - 1)) by {
            assert forall|g: int| 0 <= g <= t - 1 implies #[trigger] try_frame(s2, g) == try_frame(s, g) by {}
        }
    }
    assert(same_upto(s, s2, t, n));
    assert(fmap(p, c, s2, t) == tt);
    assert(kinds_of(p, c, s2, t) =~= tt);
    assert forall|j: int| 0 <= j < n implies
        #[trigger] conf(p, c, s2, t, kinds_of(p, c, s2, t), j, kinds_of(p, c, s2, t)[j], s2.stack[fbase(s2, t) + j]) by {
        assert(conf(p, c, s, t, kt, j, kt[j], s.stack[b + j]));
        assert(wf_kind(p, c, m, kt, j));
        assert(tt[j] == kt[j]);
        lemma_conf_upto(p, c, s, s2, t, n, kt, j, kt[j], s.stack[b + j]);
        assert(tt.subrange(0, j) =~= kt.subrange(0, j));
        lemma_conf_kf(p, c, s2, t, kt, tt, j, kt[j], s.stack[b + j]);
    }
    assert(frame_ok(p, c, s2, t)) by {
        reveal(frame_ok);
        let i = info(p, m);
        assert(shape_ok(p, c, m, tt));
        if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
            assert(s2.stack[b] == s.stack[b]);
        }
    }
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        if fi < t {
            assert(frame_ok(p, c, s, fi));
            lemma_same_below_down(s, s2, t - 1, fi);
            lemma_frame_below_unw(p, c, s, s2, fi);
        }
    }
    assert(wf(p, c, s2)) by { reveal(wf); reveal(wf_task); }
}

/// The unwinding `u` from an unwinding state: enters a finally code,
/// completes a non-local return or branch, or ends the task (an uncaught
/// exception).
pub proof fn lemma_unwind(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, u: Unwind)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        unw_arg_ok(p, c, s, kt, u),
        s.stack.len() < 0x7000_0000,
    ensures outcome_ok(p, c, unwind(p, s, u)), !(unwind(p, s, u) is Primitive),
    decreases s.frames.len(),
{
    lemma_unwind_not_prim(p, s, u);
    let t = top_i(s);
    let b = fbase(s, t);
    lemma_base_le_len(s, t);
    reveal(pending_ok);
    let s1 = pop_frame(s);
    if unw_target(u) == t {
        match u {
            Unwind::Return(f, v) => {
                lemma_return(p, c, trusted, s, kt, v);
            },
            Unwind::Branch(f, bci, hb) => {
                let m = fmethod(s, t);
                let tt = map_at(c, m, bci as int - info(p, m).entry)->0;
                assert(frame_kinds_from(p, c, s, t, kt, t) == kt);
                lemma_cut_top(p, c, trusted, s, kt, bci, tt);
                assert(unwind(p, s, u) == Outcome2::Next(State2 { stack: s.stack.subrange(0, b + tt.len()), bci: bci, ..s }));
            },
            Unwind::Throw(_) => {},
        }
        return;
    }
    if t == 0 {
        // Only an exception passes the bottom frame (a non-local return or
        // branch targets a frame at or below the top).
        assert(u is Throw);
        assert(!top(s).handler) by { assert(s.frames[0] == top(s)); }
        assert(unwind(p, s, u) == unwind(p, s1, u));
        assert(s1.frames.len() == 0);
        return;
    }
    // The top frame is popped.
    assert(t >= 1);
    assert(popped(s, s1));
    lemma_unw_pop(p, c, trusted, s, s1, kt);
    let g = t - 1;
    let k1 = kinds_of(p, c, s, g);
    lemma_popped_frames(p, c, s, s1, kt);
    assert(unw_arg_ok(p, c, s1, k1, u)) by {
        reveal(pending_ok);
        reveal(frame_ok);
        match u {
            Unwind::Branch(f, bci, hb) => {
                let fi = f as int;
                assert(fi < t);
                assert(s1.frames[fi] == s.frames[fi]);
                assert(fmethod(s1, fi) == fmethod(s, fi));
                assert(fbase(s1, fi) == fbase(s, fi));
                if fi < g {
                    lemma_upto_kinds(p, c, s, s1, g, slots(s, g), fi);
                }
                assert(frame_kinds_from(p, c, s1, g, k1, fi) == frame_kinds_from(p, c, s, t, kt, fi));
                if fi == g {
                    assert(frame_ok(p, c, s, g));
                    assert(k1.len() == slots(s, g));
                }
            },
            _ => {},
        }
    }
    if top(s).handler {
        // A try block: the finally code of the frame below starts.
        lemma_finally(p, c, trusted, s, kt, s1, k1, Some(u));
        assert(unwind(p, s, u) == enter_finally(p, s1, top(s).base as int, top(s).ret as int, Some(u)));
        return;
    }
    assert(unwind(p, s, u) == unwind(p, s1, u));
    lemma_unwind(p, c, trusted, s1, k1, u);
}

/// Throwing a new exception with value `v` and trace `tr` after the heap
/// grew to `h2` (one completion of a raise), from an unwinding state.
pub proof fn lemma_throw(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, h2: Seq<HeapObj>, v: Value, tr: Value)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        s.stack.len() < 0x7000_0000,
        good(s.heap, v),
        heap_extended(p, s.heap, h2),
        good(h2, tr),
    ensures final_ok(p, c, throw_exception(p, with_heap2(s, h2), v, tr)),
{
    let cid = builtin(p1(p), EXCEPTION_CLASS);
    assert(tables_ok(p, c));
    assert(is_field_class(p, cid) && ifc(p, cid) >= 2);
    lemma_prim_heap(p, c, s.heap, h2);
    lemma_unw_heap(p, c, s, kt, h2);
    let s1 = with_heap(s, h2);
    assert(with_heap2(s, h2) == s1);
    let o = exception_obj2(p, v, tr);
    let h3 = h2.push(o);
    assert(consts_ok(p, h2));
    assert(good(h2, null2(p)));
    assert(good(h2, v));
    assert(basic_obj_ok(p, h3, o)) by {
        match o.body {
            Body::Instance(f) => {
                assert forall|i: int| 0 <= i < f.len() implies good(h3, #[trigger] f[i]) by {}
            },
            _ => {},
        }
    }
    assert(obj_ok(p, c, h3, o));
    lemma_heap_push(p, c, h2, o);
    let s2 = alloc2(s1, o);
    assert(s2 == with_heap(s1, h3));
    lemma_unw_heap(p, c, s1, kt, h3);
    assert(unw_arg_ok(p, c, s2, kt, Unwind::Throw(new_ref2(s1)))) by { reveal(pending_ok); }
    lemma_unwind(p, c, trusted, s2, kt, Unwind::Throw(new_ref2(s1)));
    lemma_unwind_not_prim(p, s2, Unwind::Throw(new_ref2(s1)));
}

/// Throwing the out-of-memory error after the heap grew to `h2` (the other
/// completion of a raise, and the resource throws), from an unwinding
/// state.
pub proof fn lemma_throw_oom(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, h2: Seq<HeapObj>)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        s.stack.len() < 0x7000_0000,
        heap_extended(p, s.heap, h2),
    ensures final_ok(p, c, unwind(p, with_heap2(s, h2), Unwind::Throw(out_of_memory(p)))),
{
    lemma_prim_heap(p, c, s.heap, h2);
    lemma_unw_heap(p, c, s, kt, h2);
    let s1 = with_heap(s, h2);
    assert(with_heap2(s, h2) == s1);
    assert(crate::v2::exec::wf_program2(p));
    assert(consts_ok(p, h2));
    assert(good(h2, p.roots[ROOT_OUT_OF_MEMORY]));
    assert(unw_arg_ok(p, c, s1, kt, Unwind::Throw(out_of_memory(p)))) by { reveal(pending_ok); }
    lemma_unwind(p, c, trusted, s1, kt, Unwind::Throw(out_of_memory(p)));
    lemma_unwind_not_prim(p, s1, Unwind::Throw(out_of_memory(p)));
}

/// Every completion of raising `v` from an unwinding state is good.
pub proof fn lemma_raised(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, v: Value)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        s.stack.len() < 0x7000_0000,
        good(s.heap, v),
    ensures outcome_ok(p, c, Outcome2::Raise(s, v)),
{
    assert forall|o2: Outcome2| #[trigger] raised(p, s, v, o2) implies final_ok(p, c, o2) by {
        if raised_now(p, s, v, o2) {
            lemma_raised_now(p, c, trusted, s, kt, v, o2);
        } else {
            // The allocation collected first.
            reveal(raised_gc);
            let s2 = choose|s2: State2| #[trigger] crate::v2::gc::gc_steps(p, s, s2) && crate::v2::gc::kept(s.heap, v)
                && raised_now(p, s2, v, o2);
            crate::v2::gc::lemma_gc_steps_unw(p, c, s, kt, s2, v);
            lemma_raised_now(p, c, trusted, s2, kt, v, o2);
        }
    }
}

/// A completion of raising `v` from an unwinding state, without a
/// collection, is good.
proof fn lemma_raised_now(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, v: Value, o2: Outcome2)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        s.stack.len() < 0x7000_0000,
        good(s.heap, v),
        raised_now(p, s, v, o2),
    ensures final_ok(p, c, o2),
{
    if exists|h2: Seq<HeapObj>, trace: Value| heap_extended(p, s.heap, h2) && good(h2, trace)
        && o2 == #[trigger] throw_exception(p, with_heap2(s, h2), v, trace) {
        let (h2, trace) = choose|h2: Seq<HeapObj>, trace: Value| heap_extended(p, s.heap, h2) && good(h2, trace)
            && o2 == #[trigger] throw_exception(p, with_heap2(s, h2), v, trace);
        lemma_throw(p, c, trusted, s, kt, h2, v, trace);
    } else {
        let h2 = choose|h2: Seq<HeapObj>| heap_extended(p, s.heap, h2)
            && o2 == #[trigger] unwind(p, with_heap2(s, h2), Unwind::Throw(out_of_memory(p)));
        lemma_throw_oom(p, c, trusted, s, kt, h2);
    }
}

/// Raising a machine exception from an unwinding state.
pub proof fn lemma_raise_unw(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, k: int)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        s.stack.len() < 0x7000_0000,
        s.heap.len() < 0x7000_0000,
        0 <= k < 5,
    ensures outcome_ok(p, c, raise(p, s, k)), !(raise(p, s, k) is Primitive),
{
    assert(crate::v2::exec::wf_program2(p));
    assert(consts_ok(p, s.heap));
    assert(good(s.heap, p.literals[2 + k]));
    lemma_raised(p, c, trusted, s, kt, failure_value(p, k));
}

/// Raising a machine exception from a well-formed state.
pub proof fn lemma_raise(p: Program2, c: Cert, trusted: bool, s: State2, k: int)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), 0 <= k < 5,
    ensures outcome_ok(p, c, raise(p, s, k)), !(raise(p, s, k) is Primitive),
{
    lemma_wf_unw(p, c, trusted, s);
    lemma_raise_unw(p, c, trusted, s, kinds_of(p, c, s, top_i(s)), k);
}

/// Raising `v` from a well-formed state.
pub proof fn lemma_raise_value(p: Program2, c: Cert, trusted: bool, s: State2, v: Value)
    requires accepts(p, c, trusted), wf(p, c, s), small(s), good(s.heap, v),
    ensures outcome_ok(p, c, Outcome2::Raise(s, v)),
{
    lemma_wf_unw(p, c, trusted, s);
    lemma_raised(p, c, trusted, s, kinds_of(p, c, s, top_i(s)), v);
}

/// The reference interpreter's completion of a raise (`raise_null`: no
/// trace, no other allocation) is a completion.
pub proof fn lemma_raise_null(p: Program2, c: Cert, s: State2, k: int)
    requires crate::v2::exec::wf_program2(p), heap_ok(p, c, s.heap), consts_ok(p, s.heap), s.heap.len() < 0x4000_0000,
    ensures raised(p, s, failure_value(p, k), raise_null(p, s, k)),
{
    reveal(heap_ok);
    let h = s.heap;
    assert(prim_heap_ok(p, h, h)) by {
        assert forall|i: int| 0 <= i < h.len() && #[trigger] h[i].class_id as int == task_class(p) implies
            task_fields_kept(h[i], h[i]) by { lemma_kept_refl(h[i]); }
        assert forall|i: int| 0 <= i < h.len() implies basic_obj_ok(p, h, #[trigger] h[i]) by {
            assert(obj_ok(p, c, h, h[i]));
        }
    }
    assert(h.subrange(0, h.len() as int) =~= h);
    assert(with_heap2(s, h) == s);
    assert(good(h, null2(p)));
    assert(raise_null(p, s, k) == throw_exception(p, with_heap2(s, h), failure_value(p, k), null2(p)));
}

/// Unwinding from a well-formed state.
pub proof fn lemma_unwind_wf(p: Program2, c: Cert, trusted: bool, s: State2, u: Unwind)
    requires
        accepts(p, c, trusted), wf(p, c, s), small(s),
        unw_arg_ok(p, c, s, kinds_of(p, c, s, top_i(s)), u),
    ensures outcome_ok(p, c, unwind(p, s, u)), !(unwind(p, s, u) is Primitive),
{
    lemma_wf_unw(p, c, trusted, s);
    lemma_unwind(p, c, trusted, s, kinds_of(p, c, s, top_i(s)), u);
}

} // verus!
