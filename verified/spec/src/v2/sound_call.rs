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

//! Calls: pushing a frame keeps the invariant when the caller's map at the
//! return address describes the slots below the arguments and the
//! arguments conform to the callee's entry kinds.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
use crate::v2::sound_frames::*;
use crate::v2::sound_local::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of};

verus! {

pub open spec fn call_state(p: Program2, s1: State2, t: int, ret: int) -> State2 {
    call_state_h(p, s1, t, ret, false)
}

/// A call whose new frame is a try block (`is_try`, TRY) or not.
pub open spec fn call_state_h(p: Program2, s1: State2, t: int, ret: int, is_try: bool) -> State2 {
    State2 {
        frames: s1.frames.push(Frame { method: t as usize, ret: ret as usize, base: (s1.stack.len() - arity(p, t)) as usize, handler: is_try }),
        bci: info(p, t).entry,
        ..s1
    }
}

/// The state before the call (`s1`, derived from the well-formed state
/// `s` at the calling instruction) keeps the caller's slots below the
/// arguments, and the caller's map at `ret` describes them.
pub open spec fn call_pre(p: Program2, c: Cert, s: State2, s1: State2, t: int, ret: int, is_try: bool) -> bool {
    let t0 = top_i(s);
    let b = fbase(s, t0);
    let m = fmethod(s, t0);
    let k = kinds_of(p, c, s, t0);
    let nb = s1.stack.len() - arity(p, t);
    let keep = nb - b;
    &&& s1.frames == s.frames
    &&& s1.task == s.task
    &&& s1.stack.len() < 0x8000_0000
    &&& small(s)
    &&& heap_ext(p, s.heap, s1.heap)
    &&& heap_ok(p, c, s1.heap)
    &&& globals_ok(c, s1)
    &&& consts_ok(p, s1.heap)
    &&& valid_method(p, t)
    &&& !dead_block(p, c, t)
    &&& b <= nb
    &&& keep <= k.len()
    &&& forall|x: int| 0 <= x < nb ==> #[trigger] s1.stack[x] == s.stack[x]
    &&& info(p, m).entry <= ret
    &&& match map_at(c, m, ret - info(p, m).entry) {
        Some(kr) => {
            &&& kr.subrange(0, keep) == k.subrange(0, keep)
            &&& if is_try {
                kr.len() == keep + 4 && kr[keep] is Val && kr[keep + 1] is Token && kr[keep + 2] is Token && kr[keep + 3] is Val
            } else {
                kr.len() == keep + 1 && kr[keep] is Val
            }
        },
        None => false,
    }
    &&& (pinned0(p, m) && arity(p, m) >= 1 ==> keep >= 1)
}

/// The arguments conform to the callee's entry kinds and its receiver is
/// in its range.
pub open spec fn call_args(p: Program2, c: Cert, s1: State2, t: int, ret: int, is_try: bool) -> bool {
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let tn = top_i(s2);
    &&& forall|x: int| 0 <= x < arity(p, t) ==>
            #[trigger] conf(p, c, s2, tn, kinds_of(p, c, s2, tn), x, entry_kinds(p, c, t)[x], s2.stack[fbase(s2, tn) + x])
    &&& receiver_ok(p, s2, tn)
}

pub proof fn lemma_call_shape(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, t: int, ret: int, is_try: bool)
    requires accepts(p, c, trusted), wf(p, c, s), call_pre(p, c, s, s1, t, ret, is_try),
    ensures ({
        let s2 = call_state_h(p, s1, t, ret, is_try);
        let t0 = top_i(s);
        let nb = s1.stack.len() - arity(p, t);
        &&& top_i(s2) == t0 + 1
        &&& s2.frames.len() == s.frames.len() + 1
        &&& forall|g: int| 0 <= g <= t0 ==> #[trigger] s2.frames[g] == s.frames[g]
        &&& fbase(s2, t0 + 1) == nb
        &&& limit(s2, t0) == nb
        &&& slots(s2, t0) == nb - fbase(s, t0)
        &&& slots(s2, t0 + 1) == arity(p, t)
        &&& bases_ok(s2)
        &&& kinds_of(p, c, s2, t0) == kinds_of(p, c, s, t0).subrange(0, nb - fbase(s, t0))
        &&& try_frame(s2, t0) == is_try
        &&& forall|g: int| 0 <= g < t0 ==> #[trigger] try_frame(s2, g) == try_frame(s, g)
        &&& (t0 > 0 ==> same_below(s, s2, t0 - 1))
        &&& s2.frames[0] == s.frames[0]
    }),
{
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    let m = fmethod(s, t0);
    let k = kinds_of(p, c, s, t0);
    let nb = s1.stack.len() - arity(p, t);
    let keep = nb - b;
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    lemma_top_kinds(p, c, s);
    lemma_map_bound(p, c, trusted, m, ret - info(p, m).entry);
    assert(0 <= b <= nb < 0x8000_0000);
    let nf = Frame { method: t as usize, ret: ret as usize, base: (s1.stack.len() - arity(p, t)) as usize, handler: is_try };
    assert(s2.frames == s.frames.push(nf));
    assert(t0 + 1 == s.frames.len());
    assert(s2.frames[t0 + 1] == nf);
    assert(nf.base as int == nb);
    assert(s2.frames[t0 + 1].base == nb);
    assert(s2.frames[t0] == s.frames[t0]);
    assert(bases_ok(s2)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
            if fi + 1 < s.frames.len() {
                assert(base_step(s, fi));
            }
        }
    }
    let kr = map_at(c, m, ret - info(p, m).entry)->0;
    assert(fmap(p, c, s2, t0) == kr);
    assert(kinds_of(p, c, s2, t0) =~= kr.subrange(0, keep));
    // Try blocks: the new frame is one if the call is a TRY.
    assert forall|g: int| 0 <= g < t0 implies #[trigger] try_frame(s2, g) == try_frame(s, g) by {
        assert(s2.frames[g + 1] == s.frames[g + 1]);
    }
    if t0 > 0 {
        assert(same_below(s, s2, t0 - 1)) by {
            assert forall|g: int| 0 <= g <= t0 - 1 implies #[trigger] s2.frames[g] == s.frames[g] by {}
            assert forall|x: int| 0 <= x < s.frames[t0].base implies #[trigger] s2.stack[x] == s.stack[x] by {}
        }
    }
}

/// The caller's kept slots still conform.
pub proof fn lemma_call_caller_conf(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, t: int, ret: int, is_try: bool, j: int)
    requires
        accepts(p, c, trusted), wf(p, c, s), call_pre(p, c, s, s1, t, ret, is_try),
        0 <= j < s1.stack.len() - arity(p, t) - fbase(s, top_i(s)),
    ensures ({
        let s2 = call_state_h(p, s1, t, ret, is_try);
        let t0 = top_i(s);
        conf(p, c, s2, t0, kinds_of(p, c, s2, t0), j, kinds_of(p, c, s2, t0)[j], s2.stack[fbase(s2, t0) + j])
    }),
{
    reveal(conf);
    reveal(pending_ok);
    reveal(good_ref);
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    let m = fmethod(s, t0);
    let k = kinds_of(p, c, s, t0);
    let nb = s1.stack.len() - arity(p, t);
    let keep = nb - b;
    lemma_call_shape(p, c, trusted, s, s1, t, ret, is_try);
    lemma_wf_parts(p, c, s);
    lemma_top_kinds(p, c, s);
    lemma_task_basics(p, c, s);
    let v = s.stack[b + j];
    assert(s2.stack[b + j] == v);
    assert(kinds_of(p, c, s2, t0)[j] == k[j]);
    assert(conf(p, c, s, t0, kinds_of(p, c, s, t0), j, k[j], v)) by {
        reveal(wf);
        reveal(wf_task);
        reveal(frame_ok);
        assert(frame_ok(p, c, s, t0));
    }
    lemma_map_instr(p, c, trusted, m, foff(p, s, t0));
    assert(wf_kind(p, c, m, k, j));
    match k[j] {
        Kind::Val => {},
        Kind::Method(_) => {},
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    if d == 0 {
                        assert(ref_ok(s2, f as int, slot as int));
                    } else {
                        lemma_outer_ref_in_block(p, c, trusted, m, k, j);
                        assert(pinned_ok(p, s, t0)) by {
                            reveal(wf); reveal(wf_task); reveal(frame_ok);
                            assert(frame_ok(p, c, s, t0));
                        }
                        reveal_with_fuel(context_frame, 2);
                        lemma_context_frame_lt(s, t0, d as nat);
                        let r = s.stack[b];
                        assert(s2.stack[b] == r);
                        match r {
                            Value::BlockRef(f1, _) => {
                                if (f1 as int) < t0 {
                                    lemma_context_frame_below(s, s2, f1 as int, t0 - 1, (d - 1) as nat);
                                }
                            },
                            _ => {},
                        }
                        assert(context_frame(s2, t0, d as nat) == context_frame(s, t0, d as nat));
                        lemma_kinds_below(p, c, s, s2, f as int, t0 - 1);
                        lemma_ref_ok_below(s, s2, t0 - 1, f as int, slot as int);
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
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Token(second, d, _, _) => {
                    assert(kinds_of(p, c, s2, t0)[j - 1] == k[j - 1]);
                    if second {
                        assert(s2.stack[b + j - 1] == s.stack[b + j - 1]);
                    }
                    match d {
                        Pending::Branch(f, bci, hb) => if !second {
                            if (f as int) < t0 {
                                lemma_kinds_below(p, c, s, s2, f as int, t0 - 1);
                            } else {
                                let tt = map_at(c, m, bci as int - info(p, m).entry)->0;
                                assert(frame_kinds_from(p, c, s, t0, k, f as int) == k);
                                assert(frame_kinds_from(p, c, s2, t0, kinds_of(p, c, s2, t0), f as int) == kinds_of(p, c, s2, t0));
                                assert(tt == k.subrange(0, tt.len() as int));
                                assert(kinds_of(p, c, s2, t0).subrange(0, tt.len() as int) =~= k.subrange(0, tt.len() as int));
                            }
                        },
                        _ => {},
                    }
                },
                _ => {},
            }
        },
    }
}

pub proof fn lemma_call(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, t: int, ret: int, is_try: bool)
    requires
        accepts(p, c, trusted), wf(p, c, s),
        call_pre(p, c, s, s1, t, ret, is_try),
        call_args(p, c, s1, t, ret, is_try),
    ensures wf(p, c, call_state_h(p, s1, t, ret, is_try)),
{
    let s2 = call_state_h(p, s1, t, ret, is_try);
    let t0 = top_i(s);
    let b = fbase(s, t0);
    let m = fmethod(s, t0);
    let nb = s1.stack.len() - arity(p, t);
    let keep = nb - b;
    lemma_call_shape(p, c, trusted, s, s1, t, ret, is_try);
    lemma_wf_parts(p, c, s);
    lemma_task_basics(p, c, s);
    lemma_top_kinds(p, c, s);
    assert(frame_ok(p, c, s, t0)) by { reveal(wf_task); }
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        reveal(frame_ok);
        if fi < t0 {
            assert(wf_task(p, c, s)) by { reveal(wf); }
            lemma_same_below_down(s, s2, t0 - 1, fi);
            lemma_frame_below(p, c, s, s2, fi);
        } else if fi == t0 {
            lemma_map_bound(p, c, trusted, m, ret - info(p, m).entry);
            assert(s2.frames[t0 + 1].ret as int == ret);
            assert(fbci(s2, t0) == ret);
            assert(fmethod(s2, t0) == m);
            assert(foff(p, s2, t0) == ret - info(p, m).entry);
            assert(frame_shape_ok(p, c, s, t0));
            assert(frame_shape_ok(p, c, s2, t0));
            assert forall|j: int| 0 <= j < slots(s2, t0) implies
                #[trigger] conf(p, c, s2, t0, kinds_of(p, c, s2, t0), j, kinds_of(p, c, s2, t0)[j], s2.stack[fbase(s2, t0) + j]) by {
                lemma_call_caller_conf(p, c, trusted, s, s1, t, ret, is_try, j);
            }
            let i = info(p, m);
            if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
                let r = s.stack[b];
                assert(receiver_ok(p, s, t0));
                assert(s2.stack[b] == r);
                match r {
                    Value::Obj(id) => {
                        assert(s2.heap[id as int].class_id == s.heap[id as int].class_id);
                    },
                    _ => {},
                }
                assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
            }
            assert(receiver_ok(p, s2, t0));
        } else {
            assert(fi == t0 + 1);
            assert(method_ok(p, c, t, trusted));
            assert(fmethod(s2, fi) == t);
            assert(foff(p, s2, fi) == 0);
            assert(fmap(p, c, s2, fi) == entry_kinds(p, c, t));
            assert(kinds_of(p, c, s2, fi) =~= entry_kinds(p, c, t));
            assert(frame_shape_ok(p, c, s2, fi));
            assert forall|j: int| 0 <= j < slots(s2, fi) implies
                #[trigger] conf(p, c, s2, fi, kinds_of(p, c, s2, fi), j, kinds_of(p, c, s2, fi)[j], s2.stack[fbase(s2, fi) + j]) by {
                assert(conf(p, c, s2, fi, kinds_of(p, c, s2, fi), j, entry_kinds(p, c, t)[j], s2.stack[fbase(s2, fi) + j]));
            }
        }
    }
    assert(wf_task(p, c, s2)) by { reveal(wf_task); }
    lemma_running_heap(p, s, s2);
    assert(wf(p, c, s2)) by { reveal(wf); }
}

} // verus!
