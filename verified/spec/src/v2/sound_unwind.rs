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

//! Returns, entering finally code, the unwinding loop and raised
//! exceptions keep the invariant (or end the task).
//!
//! An unwinding state (`unw_ok`) is a state whose frames below the top are
//! well formed, and whose top frame's first slots conform to known kinds
//! `kt`. If the top frame is a try block, the frame below it is suspended
//! in its TRY (`frame_ok`): popping the try block enters its finally code
//! (`lemma_finally`).

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
use crate::v2::sound_upto::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, smi};

verus! {

/// The receiver condition of the top frame when its first `n` slots are
/// known.
pub open spec fn top_receiver_ok(p: Program2, s: State2, n: int) -> bool {
    let t = top_i(s);
    let m = fmethod(s, t);
    let i = info(p, m);
    ((i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1) ==> {
        let r = s.stack[fbase(s, t)];
        &&& n >= 1
        &&& class_id_ok(as1(s), r)
        &&& i.recv_start as int <= class_id_of(p1(p), as1(s), r) < i.recv_end as int
    }
}

/// The map of a finally code whose TRY had the kinds `kt`: the value, the
/// two token words and the reason above them (format note 23).
pub open spec fn finally_kinds(kt: Seq<Kind>) -> Seq<Kind> {
    kt.push(Kind::Val).push(Kind::Token).push(Kind::Token).push(Kind::Val)
}

pub open spec fn unw_ok(p: Program2, c: Cert, s: State2, kt: Seq<Kind>) -> bool {
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    &&& heap_ok(p, c, s.heap)
    &&& globals_ok(c, s)
    &&& consts_ok(p, s.heap)
    &&& running_ok(p, s)
    &&& s.frames.len() > 0
    &&& !s.frames[0].handler
    &&& bases_ok(s)
    &&& roomy(s)
    &&& forall|fi: int| 0 <= fi < t ==> #[trigger] frame_ok(p, c, s, fi)
    &&& valid_method(p, m)
    &&& !dead_block(p, c, m)
    &&& b + kt.len() <= s.stack.len()
    &&& forall|j: int| 0 <= j < kt.len() ==> #[trigger] conf(p, c, s, t, kt, j, kt[j], s.stack[b + j])
    &&& forall|j: int| 0 <= j < kt.len() ==> #[trigger] wf_kind(p, c, m, kt, j)
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> kt.len() >= 1)
    &&& top_receiver_ok(p, s, kt.len() as int)
}

/// The unwinding `u` can complete from the top frame (a token there would
/// have its first word at slot `kt.len() + 1`).
pub open spec fn unw_arg_ok(p: Program2, c: Cert, s: State2, kt: Seq<Kind>, u: Unwind) -> bool {
    &&& pending_ok(p, c, s, top_i(s), kt, kt.len() as int + 1, pending_of(Some(u)))
    &&& unwind_value_ok(s.heap, u)
}

/// The exception or return value of an unwinding is a value.
pub open spec fn unwind_value_ok(heap: Seq<HeapObj>, u: Unwind) -> bool {
    match u {
        Unwind::Throw(v) => good(heap, v),
        Unwind::Return(_, v) => good(heap, v),
        Unwind::Branch(_, _, _) => true,
    }
}

/// A well-formed state is an unwinding state of its top frame's kinds.
pub proof fn lemma_wf_unw(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s),
    ensures unw_ok(p, c, s, kinds_of(p, c, s, top_i(s))),
{
    let t = top_i(s);
    let kt = kinds_of(p, c, s, t);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    lemma_top_kinds(p, c, s);
    assert(frame_ok(p, c, s, t)) by { reveal(wf_task); }
    assert(!s.frames[0].handler) by { reveal(wf_task); }
    reveal(frame_ok);
    assert forall|fi: int| 0 <= fi < t implies #[trigger] frame_ok(p, c, s, fi) by { reveal(wf_task); }
    lemma_map_instr(p, c, trusted, fmethod(s, t), foff(p, s, t));
    assert forall|j: int| 0 <= j < kt.len() implies #[trigger] wf_kind(p, c, fmethod(s, t), kt, j) by {}
}

// ---------------------------------------------------------------------------
// Entering finally code.

/// The frame below a try block is suspended in its TRY: its map at the try
/// block's return bci is the finally code's, its kinds and the four slots.
pub proof fn lemma_try_frame_map(p: Program2, c: Cert, s: State2, g: int)
    requires frame_ok(p, c, s, g), bases_ok(s), 0 <= g, g + 1 < s.frames.len(), s.frames[g + 1].handler,
    ensures
        fmap(p, c, s, g) == finally_kinds(kinds_of(p, c, s, g)),
        foff(p, s, g) == s.frames[g + 1].ret - info(p, fmethod(s, g)).entry,
        map_at(c, fmethod(s, g), foff(p, s, g)) == Some(finally_kinds(kinds_of(p, c, s, g))),
{
    reveal(frame_ok);
    assert(try_frame(s, g));
    let k = fmap(p, c, s, g);
    let n = slots(s, g);
    assert(base_step(s, g));
    assert(k.len() == n + 4);
    let kf = finally_kinds(kinds_of(p, c, s, g));
    assert(kf.len() == k.len());
    assert forall|i: int| 0 <= i < k.len() implies k[i] == kf[i] by {
        if i < n {
            assert(kf[i] == kinds_of(p, c, s, g)[i]);
        } else if i == n {
            assert(k[n] is Val);
        } else if i == n + 1 || i == n + 2 {
            assert(k[i] is Token);
        } else {
            assert(k[n + 3] is Val);
        }
    }
    assert(fmap(p, c, s, g) =~= kf);
}

/// Entering the finally code of the frame below the try block on top of
/// `s` (`s1` is `s` with the try block popped, an unwinding state of the
/// frame's kinds `k1`), normally or with the unwinding `u`.
pub proof fn lemma_finally(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, s1: State2, k1: Seq<Kind>, uo: Option<Unwind>)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        s.frames.len() > 1,
        top(s).handler,
        s1 == pop_frame(s),
        k1 == kinds_of(p, c, s, top_i(s) - 1),
        unw_ok(p, c, s1, k1),
        match uo { Some(u) => unw_arg_ok(p, c, s1, k1, u), None => true },
    ensures outcome_ok(p, c, enter_finally(p, s1, top(s).base as int, top(s).ret as int, uo)),
{
    let t0 = top_i(s);
    let t = t0 - 1;
    let b = fbase(s1, t);
    let m = fmethod(s1, t);
    let hh = top(s).base as int;
    let hbci = top(s).ret as int;
    let kf = finally_kinds(k1);
    assert(s.frames[t0] == top(s));
    assert(frame_ok(p, c, s, t));
    lemma_try_frame_map(p, c, s, t);
    assert(fmethod(s, t) == m);
    assert(fbase(s, t) == b);
    let n = slots(s, t);
    assert(k1.len() == n) by { reveal(frame_ok); }
    assert(hh == b + k1.len());
    assert(s1.stack.len() == hh);
    assert(top_i(s1) == t);
    assert(base(s1) == b);
    let s1c = State2 { stack: s1.stack.subrange(0, hh), bci: hbci as usize, ..s1 };
    let d = pending_of(uo);
    let gu = t as usize;
    let tok_a = Value::Token(false, d, gu, hh as usize);
    let tok_b = Value::Token(true, d, gu, hh as usize);
    let value = value_of(p, uo);
    let reason = smi(reason_of(uo));
    let s2 = push(push(push(push(s1c, value), tok_a), tok_b), reason);
    assert(enter_finally(p, s1, hh, hbci, uo) == Outcome2::Next(s2));
    assert(s2.heap == s1.heap);
    lemma_heap_ext_refl(p, s1.heap);
    lemma_globals_heap(c, s1, s1.heap);
    assert(running_ok(p, s2));
    // Frames.
    assert(s2.frames == s1.frames);
    assert(top_i(s2) == t);
    assert(s2.stack.len() == b + k1.len() + 4);
    assert(info(p, m).entry <= hbci);
    assert(fmap(p, c, s2, t) == kf);
    assert(kinds_of(p, c, s2, t) =~= kf);
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s1, fi));
        }
    }
    assert(!try_frame(s2, t));
    if t > 0 {
        assert(same_below(s1, s2, t - 1)) by {
            assert forall|g: int| 0 <= g <= t - 1 implies #[trigger] try_frame(s2, g) == try_frame(s1, g) by {}
            assert forall|x: int| 0 <= x < s1.frames[t].base implies #[trigger] s2.stack[x] == s1.stack[x] by {}
        }
    }
    let mi = info(p, m);
    lemma_map_instr(p, c, trusted, m, hbci - mi.entry);
    // The top frame.
    assert forall|j: int| 0 <= j < kf.len() implies
        #[trigger] conf(p, c, s2, t, kinds_of(p, c, s2, t), j, kinds_of(p, c, s2, t)[j], s2.stack[fbase(s2, t) + j]) by {
        if j < k1.len() {
            assert(conf(p, c, s1, t, k1, j, k1[j], s1.stack[b + j]));
            assert(wf_kind(p, c, m, k1, j));
            assert(same_upto(s1, s2, t, k1.len() as int));
            lemma_conf_upto(p, c, s1, s2, t, k1.len() as int, k1, j, k1[j], s1.stack[b + j]);
            assert(kf.subrange(0, j) =~= k1.subrange(0, j));
            lemma_conf_kf(p, c, s2, t, k1, kf, j, k1[j], s1.stack[b + j]);
            assert(s2.stack[b + j] == s1.stack[b + j]);
        } else {
            reveal(conf);
            if j == k1.len() {
                assert(s2.stack[b + j] == value);
                assert(good(s1.heap, null2(p)));
            } else if j == k1.len() + 1 {
                assert(s2.stack[b + j] == tok_a);
                assert(kf[j - 1] == Kind::Val);
                match uo {
                    None => { reveal(pending_ok); },
                    Some(w) => {
                        lemma_pending_finally(p, c, trusted, s1, s2, k1, w);
                    },
                }
            } else if j == k1.len() + 2 {
                assert(s2.stack[b + j] == tok_b);
                assert(s2.stack[b + j - 1] == tok_a);
            } else {
                assert(s2.stack[b + j] == reason);
            }
        }
    }
    assert(frame_ok(p, c, s2, t)) by {
        reveal(frame_ok);
        assert(frame_shape_ok(p, c, s2, t));
        let r = s1.stack[b];
        if (mi.kind == KIND_METHOD || mi.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(mi) && arity(p, m) >= 1 {
            assert(s2.stack[b] == r);
            match r {
                Value::Obj(id) => { assert(s2.heap[id as int].class_id == s1.heap[id as int].class_id); },
                _ => {},
            }
            assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s1), r));
        }
    }
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        if fi < t {
            lemma_same_below_down(s1, s2, t - 1, fi);
            lemma_frame_below_unw(p, c, s1, s2, fi);
        }
    }
    assert(s2.frames[0] == s1.frames[0]);
    assert(wf(p, c, s2)) by { reveal(wf); reveal(wf_task); }
}

/// A lower frame of an unwinding state stays well formed (as in
/// `lemma_frame_below`, which needs a well-formed task).
pub proof fn lemma_frame_below_unw(p: Program2, c: Cert, s: State2, s2: State2, fi: int)
    requires
        frame_ok(p, c, s, fi),
        bases_ok(s),
        same_below(s, s2, fi),
        bases_ok(s2),
    ensures frame_ok(p, c, s2, fi),
{
    reveal(frame_ok);
    lemma_kinds_below(p, c, s, s2, fi, fi);
    assert(try_frame(s2, fi) == try_frame(s, fi));
    assert forall|j: int| 0 <= j < slots(s2, fi) implies
        #[trigger] conf(p, c, s2, fi, kinds_of(p, c, s2, fi), j, kinds_of(p, c, s2, fi)[j], s2.stack[fbase(s2, fi) + j]) by {
        assert(conf(p, c, s, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[fbase(s, fi) + j]));
        lemma_limit_below(s, fi, fi + 1);
        assert(s2.stack[fbase(s, fi) + j] == s.stack[fbase(s, fi) + j]);
        lemma_conf_below(p, c, s, s2, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[fbase(s, fi) + j]);
    }
    let m = fmethod(s, fi);
    let i = info(p, m);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
        let r = s.stack[fbase(s, fi)];
        lemma_limit_below(s, fi, fi + 1);
        assert(s2.stack[fbase(s, fi)] == r);
        match r {
            Value::Obj(id) => {
                assert(s2.heap[id as int].class_id == s.heap[id as int].class_id);
            },
            _ => {},
        }
        assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
    }
}

/// The token of the finally code holds the unwinding.
pub proof fn lemma_pending_finally(p: Program2, c: Cert, trusted: bool, s: State2, s2: State2, kt: Seq<Kind>, w: Unwind)
    requires
        unw_ok(p, c, s, kt),
        unw_arg_ok(p, c, s, kt, w),
        s2.frames == s.frames,
        top_i(s) > 0 ==> same_below(s, s2, top_i(s) - 1),
        kinds_of(p, c, s2, top_i(s)) == finally_kinds(kt),
    ensures pending_ok(p, c, s2, top_i(s), kinds_of(p, c, s2, top_i(s)), kt.len() as int + 1, pending_of(Some(w))),
{
    reveal(pending_ok);
    let t = top_i(s);
    let kf = finally_kinds(kt);
    match w {
        Unwind::Throw(v) => {},
        Unwind::Return(f, v) => {},
        Unwind::Branch(f, bci, hb) => {
            let f = f as int;
            if f < t {
                lemma_kinds_below(p, c, s, s2, f, t - 1);
            } else {
                let m = fmethod(s, t);
                let tt = map_at(c, m, bci as int - info(p, m).entry)->0;
                assert(kf.subrange(0, tt.len() as int) =~= kt.subrange(0, tt.len() as int));
            }
        },
    }
}

} // verus!
