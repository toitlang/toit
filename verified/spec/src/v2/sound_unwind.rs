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
//! `kt`; if the top frame has a handler, its finally code starts with
//! `kt` and the finally triple.

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

pub open spec fn handler_ok(s: State2, x: int) -> bool {
    let h = s.tries[x];
    &&& 0 <= h.frame as int <= top_i(s)
    &&& (x > 0 ==> s.tries[x - 1].frame < h.frame)
    &&& ((h.frame as int) < top_i(s) ==> try_ok(s, x))
}

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

pub open spec fn finally_kinds(kt: Seq<Kind>) -> Seq<Kind> {
    kt.push(Kind::Val).push(Kind::Token).push(Kind::Val)
}

pub open spec fn unw_ok(p: Program2, c: Cert, s: State2, kt: Seq<Kind>) -> bool {
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    &&& heap_ok(p, c, s.heap)
    &&& globals_ok(c, s)
    &&& consts_ok(p, s.heap)
    &&& running_ok(p, s)
    &&& fins_ok(s)
    &&& s.frames.len() > 0
    &&& bases_ok(s)
    &&& roomy(s)
    &&& forall|fi: int| 0 <= fi < t ==> #[trigger] frame_ok(p, c, s, fi)
    &&& forall|x: int| 0 <= x < s.tries.len() ==> #[trigger] handler_ok(s, x)
    &&& valid_method(p, m)
    &&& !dead_block(p, c, m)
    &&& b + kt.len() <= s.stack.len()
    &&& forall|j: int| 0 <= j < kt.len() ==> #[trigger] conf(p, c, s, t, kt, j, kt[j], s.stack[b + j])
    &&& forall|j: int| 0 <= j < kt.len() ==> #[trigger] wf_kind(p, c, m, kt, j)
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> kt.len() >= 1)
    &&& top_receiver_ok(p, s, kt.len() as int)
    &&& (has_handler(s) ==> {
            let h = s.tries.last();
            &&& h.height as int == b + kt.len()
            &&& info(p, m).entry <= h.bci
            &&& map_at(c, m, h.bci - info(p, m).entry) == Some(finally_kinds(kt))
        })
}

/// The unwinding `u` can complete from the top frame (a token there would
/// be at slot `kt.len() + 1`).
pub open spec fn unw_arg_ok(p: Program2, c: Cert, s: State2, kt: Seq<Kind>, u: Unwind) -> bool {
    &&& pending_ok(p, c, s, top_i(s), kt, kt.len() as int + 1, resume_of(u))
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

pub proof fn lemma_handlers_lt_top(s: State2, x: int)
    requires
        forall|y: int| 0 <= y < s.tries.len() ==> #[trigger] handler_ok(s, y),
        !has_handler(s), 0 <= x < s.tries.len(), s.frames.len() > 0,
    ensures (s.tries[x].frame as int) < top_i(s),
    decreases s.tries.len() - x,
{
    assert(handler_ok(s, x));
    if x + 1 < s.tries.len() {
        lemma_handlers_lt_top(s, x + 1);
        assert(handler_ok(s, x + 1));
    } else {
        assert(s.tries.last() == s.tries[x]);
    }
}

/// A frame with a handler has the last one, when the frames above have none.
pub proof fn lemma_last_handler(s: State2, g: int, x: int)
    requires
        forall|y: int| 0 <= y < s.tries.len() ==> #[trigger] handler_ok(s, y),
        0 <= x < s.tries.len(), s.tries[x].frame as int == g,
        forall|y: int| 0 <= y < s.tries.len() ==> (#[trigger] s.tries[y]).frame as int <= g,
    ensures x == s.tries.len() - 1,
{
    if x + 1 < s.tries.len() {
        assert(handler_ok(s, x + 1));
        assert(s.tries[x + 1].frame as int <= g);
    }
}

/// A well-formed state is an unwinding state of its top frame's kinds,
/// without a handler at the top.
pub proof fn lemma_wf_unw(p: Program2, c: Cert, trusted: bool, s: State2)
    requires accepts(p, c, trusted), wf(p, c, s), small(s),
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
// Entering finally code.

pub open spec fn finally_state(p: Program2, s: State2, h: Handler, uo: Option<Unwind>) -> State2 {
    match enter_finally(p, s, h, uo) {
        Outcome2::Next(s2) => s2,
        _ => s,
    }
}

pub proof fn lemma_finally(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, uo: Option<Unwind>)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        has_handler(s),
        match uo { Some(u) => unw_arg_ok(p, c, s, kt, u), None => true },
    ensures outcome_ok(p, c, enter_finally(p, s, s.tries.last(), uo)),
{
    let t = top_i(s);
    let b = fbase(s, t);
    let m = fmethod(s, t);
    let h = s.tries.last();
    let kf = finally_kinds(kt);
    let s1 = State2 { stack: s.stack.subrange(0, h.height as int), tries: s.tries.drop_last(), bci: h.bci, ..s };
    assert(base(s) <= h.height as int <= s.stack.len());
    // The records and the three pushed values.
    let (fins2, value, token, reason): (Seq<Fin>, Value, Value, Value) = match uo {
        None => (s.fins, null2(p), null2(p), smi(-1)),
        Some(w) => {
            (s.fins.push(Fin { frame: h.frame, height: h.height, resume: resume_of(w) }),
             value_of(p, w),
             smi(s.fins.len() as int),
             smi(match w { Unwind::Throw(_) => -2int, _ => -1int }))
        },
    };
    let s2 = State2 { fins: fins2, stack: s1.stack.push(value).push(token).push(reason), ..s1 };
    assert(enter_finally(p, s, h, uo) == Outcome2::Next(s2));
    assert(s2.heap == s.heap);
    lemma_heap_ext_refl(p, s.heap);
    lemma_globals_heap(c, s, s.heap);
    assert(running_ok(p, s2));
    // Frames.
    assert(s2.frames == s.frames);
    assert(s2.tries == s.tries.drop_last());
    assert(top_i(s2) == t);
    assert(s2.stack.len() == b + kt.len() + 3);
    assert(fmap(p, c, s2, t) == kf);
    assert(kinds_of(p, c, s2, t) =~= kf);
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            assert(base_step(s, fi));
        }
    }
    // Handlers below the top are unchanged; the top's is gone.
    assert forall|x: int| 0 <= x < s2.tries.len() implies ((#[trigger] s2.tries[x]).frame as int) < t by {
        assert(handler_ok(s, x));
        assert(handler_ok(s, x + 1));
        assert(s2.tries[x] == s.tries[x]);
        if x + 1 == s.tries.len() - 1 {}
        lemma_handler_increasing(s, x, s.tries.len() - 1);
    }
    assert(!try_frame(s2, t));
    if t > 0 {
        assert(same_below(s, s2, t - 1)) by {
            assert forall|g: int| 0 <= g <= t - 1 implies #[trigger] try_frame(s2, g) == try_frame(s, g) by {
                if try_frame(s, g) {
                    let x = choose|x: int| 0 <= x < s.tries.len() && (#[trigger] s.tries[x]).frame as int == g;
                    assert(x != s.tries.len() - 1);
                    assert(s2.tries[x] == s.tries[x]);
                }
                if try_frame(s2, g) {
                    let x = choose|x: int| 0 <= x < s2.tries.len() && (#[trigger] s2.tries[x]).frame as int == g;
                    assert(s2.tries[x] == s.tries[x]);
                }
            }
            assert forall|x: int| 0 <= x < s.frames[t].base implies #[trigger] s2.stack[x] == s.stack[x] by {}
        }
    }
    let mi = info(p, m);
    lemma_map_instr(p, c, trusted, m, h.bci - mi.entry);
    // The top frame.
    assert forall|j: int| 0 <= j < kf.len() implies
        #[trigger] conf(p, c, s2, t, kinds_of(p, c, s2, t), j, kinds_of(p, c, s2, t)[j], s2.stack[fbase(s2, t) + j]) by {
        if j < kt.len() {
            assert(conf(p, c, s, t, kt, j, kt[j], s.stack[b + j]));
            assert(wf_kind(p, c, m, kt, j));
            assert(same_upto(s, s2, t, kt.len() as int));
            lemma_conf_upto(p, c, s, s2, t, kt.len() as int, kt, j, kt[j], s.stack[b + j]);
            assert(kf.subrange(0, j) =~= kt.subrange(0, j));
            lemma_conf_kf(p, c, s2, t, kt, kf, j, kt[j], s.stack[b + j]);
            assert(s2.stack[b + j] == s.stack[b + j]);
        } else {
            reveal(conf);
            if j == kt.len() {
                assert(s2.stack[b + j] == value);
                assert(good(s.heap, null2(p)));
            } else if j == kt.len() + 1 {
                assert(s2.stack[b + j] == token);
                match uo {
                    None => {},
                    Some(w) => {
                        assert(s2.fins[s.fins.len() as int] == Fin { frame: h.frame, height: h.height, resume: resume_of(w) });
                        lemma_pending_finally(p, c, trusted, s, s2, kt, w);
                        assert(fin_ok(p, c, s2, t, kinds_of(p, c, s2, t), j, s.fins.len() as int));
                    },
                }
            } else {
                assert(s2.stack[b + j] == reason);
            }
        }
    }
    assert(frame_ok(p, c, s2, t)) by {
        reveal(frame_ok);
        assert(frame_shape_ok(p, c, s2, t));
        let r = s.stack[b];
        if (mi.kind == KIND_METHOD || mi.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(mi) && arity(p, m) >= 1 {
            assert(s2.stack[b] == r);
            match r {
                Value::Obj(id) => { assert(s2.heap[id as int].class_id == s.heap[id as int].class_id); },
                _ => {},
            }
            assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
        }
    }
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        if fi < t {
            lemma_same_below_down(s, s2, t - 1, fi);
            lemma_frame_below_unw(p, c, s, s2, fi);
        }
    }
    assert forall|x: int| 0 <= x < s2.tries.len() implies #[trigger] try_ok(s2, x) by {
        assert(handler_ok(s, x));
        assert(s2.tries[x] == s.tries[x]);
        assert((s.tries[x].frame as int) < t);
    }
    lemma_fins_finally(s, s2, uo);
    assert(wf(p, c, s2)) by { reveal(wf); reveal(wf_task); }
}

/// Entering a finally code keeps the records ordered: a new record of the
/// top frame is above the frame's other records (below the TRY).
pub proof fn lemma_fins_finally(s: State2, s2: State2, uo: Option<Unwind>)
    requires
        fins_ok(s), has_handler(s), s.frames.len() > 0,
        forall|z: int| 0 <= z < s.tries.len() ==> #[trigger] handler_ok(s, z),
        s2.frames == s.frames,
        s2.tries == s.tries.drop_last(),
        s2.fins == match uo {
            None => s.fins,
            Some(w) => s.fins.push(Fin { frame: s.tries.last().frame, height: s.tries.last().height, resume: resume_of(w) }),
        },
    ensures fins_ok(s2),
{
    let h = s.tries.last();
    let xl = s.tries.len() - 1;
    assert forall|x: int, k: int| 0 <= x < s2.tries.len() && 0 <= k < s2.fins.len()
        && (#[trigger] s2.fins[k]).frame == (#[trigger] s2.tries[x]).frame implies
        s2.fins[k].height < s2.tries[x].height by {
        assert(s2.tries[x] == s.tries[x]);
        if k < s.fins.len() {
            assert(s2.fins[k] == s.fins[k]);
        } else {
            lemma_handler_increasing(s, x, xl);
        }
    }
    assert forall|a: int, b: int| 0 <= a < b < s2.fins.len() implies fin_lt(#[trigger] s2.fins[a], #[trigger] s2.fins[b]) by {
        if b < s.fins.len() {
            assert(s2.fins[a] == s.fins[a] && s2.fins[b] == s.fins[b]);
        } else {
            assert(s2.fins[a] == s.fins[a]);
            assert(s.fins[a].frame < s.frames.len());
            if s.fins[a].frame == h.frame {
                assert(s.fins[a].height < s.tries[xl].height);
            }
        }
    }
}

pub proof fn lemma_handler_increasing(s: State2, x: int, y: int)
    requires
        forall|z: int| 0 <= z < s.tries.len() ==> #[trigger] handler_ok(s, z),
        0 <= x < y < s.tries.len(),
    ensures s.tries[x].frame < s.tries[y].frame,
    decreases y - x,
{
    assert(handler_ok(s, y));
    if x + 1 < y {
        lemma_handler_increasing(s, x, y - 1);
    }
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
    ensures pending_ok(p, c, s2, top_i(s), kinds_of(p, c, s2, top_i(s)), kt.len() as int + 1, resume_of(w)),
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
