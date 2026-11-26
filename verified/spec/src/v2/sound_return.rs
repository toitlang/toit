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

//! Returns, the unwinding loop and raised exceptions.

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
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, smi, builtin, instance_field_count, EXCEPTION_CLASS};

verus! {

/// `wf_kind` only looks at the slots up to `j`.
pub proof fn lemma_wf_kind_prefix(p: Program2, c: Cert, m: int, k: Seq<Kind>, k2: Seq<Kind>, j: int)
    requires wf_kind(p, c, m, k, j), 0 <= j < k2.len(), j < k.len(), k2.subrange(0, j + 1) == k.subrange(0, j + 1),
    ensures wf_kind(p, c, m, k2, j),
{
    assert(k2[j] == k.subrange(0, j + 1)[j]);
    match k[j] {
        Kind::Block(d, i) => {
            if d == 0 && 0 <= i < j {
                assert(k2[i] == k.subrange(0, j + 1)[i]);
            }
        },
        _ => {},
    }
}

/// The state after popping the top frame `t`: frame `t - 1` (suspended in
/// `s`) is the top of `s1`, whose first `slots(s, t - 1)` slots are those
/// of `s` and whose stack is at least that long.
pub open spec fn popped(s: State2, s1: State2) -> bool {
    let t = top_i(s);
    &&& t >= 1
    &&& s1.frames == s.frames.drop_last()
    &&& s1.heap == s.heap
    &&& s1.globals == s.globals
    &&& s1.task == s.task
    &&& fbase(s, t) <= s1.stack.len()
    &&& forall|x: int| 0 <= x < fbase(s, t) ==> #[trigger] s1.stack[x] == s.stack[x]
}

pub proof fn lemma_popped_frames(p: Program2, c: Cert, s: State2, s1: State2, kt: Seq<Kind>)
    requires unw_ok(p, c, s, kt), popped(s, s1),
    ensures ({
        let t = top_i(s);
        let g = t - 1;
        &&& top_i(s1) == g
        &&& bases_ok(s1)
        &&& forall|h: int| 0 <= h <= g ==> #[trigger] s1.frames[h] == s.frames[h]
        &&& same_upto(s, s1, g, slots(s, g))
        &&& fbase(s1, g) + slots(s, g) == fbase(s, t)
        &&& (g > 0 ==> same_below(s, s1, g - 1))
        &&& forall|fi: int| 0 <= fi < g ==> #[trigger] frame_ok(p, c, s1, fi)
    }),
{
    let t = top_i(s);
    let g = t - 1;
    assert(frame_ok(p, c, s, g));
    assert(base_step(s, g));
    lemma_base_le_len(s, t);
    assert(bases_ok(s1)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s1.frames.len() implies #[trigger] base_step(s1, fi) by {
            assert(base_step(s, fi));
        }
    }
    assert forall|h: int| 0 <= h <= g implies #[trigger] s1.frames[h] == s.frames[h] by {}
    if g > 0 {
        assert(same_below(s, s1, g - 1)) by {
            assert forall|h: int| 0 <= h <= g - 1 implies #[trigger] try_frame(s1, h) == try_frame(s, h) by {}
            lemma_limit_below(s, g - 1, g);
            assert(base_step(s, g - 1));
        }
    }
    assert forall|fi: int| 0 <= fi < g implies #[trigger] frame_ok(p, c, s1, fi) by {
        assert(frame_ok(p, c, s, fi));
        lemma_same_below_down(s, s1, g - 1, fi);
        lemma_frame_below_unw(p, c, s, s1, fi);
    }
}

/// Popping the top frame of an unwinding state gives an unwinding state of
/// the frame below, with its kinds.
pub proof fn lemma_unw_pop(p: Program2, c: Cert, trusted: bool, s: State2, s1: State2, kt: Seq<Kind>)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        popped(s, s1),
        s1.stack.len() == fbase(s, top_i(s)),
    ensures unw_ok(p, c, s1, kinds_of(p, c, s, top_i(s) - 1)),
{
    let t = top_i(s);
    let g = t - 1;
    let k1 = kinds_of(p, c, s, g);
    let mg = fmethod(s, g);
    lemma_popped_frames(p, c, s, s1, kt);
    assert(frame_ok(p, c, s, g));
    reveal(frame_ok);
    let n = slots(s, g);
    assert(k1.len() == n);
    assert(s1.frames[0] == s.frames[0]);
    // The top frame's slots.
    lemma_map_instr(p, c, trusted, mg, foff(p, s, g));
    let kr = fmap(p, c, s, g);
    assert forall|j: int| 0 <= j < n implies #[trigger] wf_kind(p, c, mg, k1, j) by {
        assert(wf_kind(p, c, mg, kr, j));
        assert(k1.subrange(0, j + 1) =~= kr.subrange(0, j + 1));
        lemma_wf_kind_prefix(p, c, mg, kr, k1, j);
    }
    assert forall|j: int| 0 <= j < n implies
        #[trigger] conf(p, c, s1, g, k1, j, k1[j], s1.stack[fbase(s1, g) + j]) by {
        assert(conf(p, c, s, g, k1, j, k1[j], s.stack[fbase(s, g) + j]));
        assert(wf_kind(p, c, mg, k1, j));
        lemma_conf_upto(p, c, s, s1, g, n, k1, j, k1[j], s.stack[fbase(s, g) + j]);
    }
    let i = info(p, mg);
    if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, mg) >= 1 {
        assert(receiver_ok(p, s, g));
        assert(s1.stack[fbase(s, g)] == s.stack[fbase(s, g)]);
    }
}

/// `return_from` from an unwinding state.
pub proof fn lemma_return(p: Program2, c: Cert, trusted: bool, s: State2, kt: Seq<Kind>, v: Value)
    requires
        accepts(p, c, trusted),
        unw_ok(p, c, s, kt),
        good(s.heap, v),
        s.stack.len() < 0x7000_0000,
    ensures outcome_ok(p, c, return_from(p, s, v)),
{
    let t = top_i(s);
    if s.frames.len() == 1 {
        return;
    }
    let g = t - 1;
    let b = fbase(s, t);
    lemma_base_le_len(s, t);
    assert(s.frames[t] == top(s));
    if top(s).handler {
        // The caller is a TRY: its finally code runs.
        let s0 = pop_frame(s);
        assert(popped(s, s0));
        lemma_unw_pop(p, c, trusted, s, s0, kt);
        lemma_finally(p, c, trusted, s, kt, s0, kinds_of(p, c, s, g), None);
        assert(return_from(p, s, v) == enter_finally(p, s0, top(s).base as int, top(s).ret as int, None));
        return;
    }
    let s1 = State2 {
        stack: s.stack.subrange(0, b).push(v),
        frames: s.frames.drop_last(),
        bci: s.frames[t].ret,
        ..s
    };
    assert(popped(s, s1));
    lemma_popped_frames(p, c, s, s1, kt);
    let k1 = kinds_of(p, c, s, g);
    let mg = fmethod(s, g);
    assert(frame_ok(p, c, s, g));
    reveal(frame_ok);
    let n = slots(s, g);
    let kr = fmap(p, c, s, g);
    lemma_map_instr(p, c, trusted, mg, foff(p, s, g));
    // An ordinary return: the caller continues with the result.
    assert(return_from(p, s, v) == Outcome2::Next(s1));
    assert(!try_frame(s, g));
    assert(kr.len() == n + 1);
    assert(fmap(p, c, s1, g) == kr);
    assert(kinds_of(p, c, s1, g) =~= kr);
    assert forall|j: int| 0 <= j < kr.len() implies
        #[trigger] conf(p, c, s1, g, kinds_of(p, c, s1, g), j, kinds_of(p, c, s1, g)[j], s1.stack[fbase(s1, g) + j]) by {
        if j < n {
            assert(conf(p, c, s, g, k1, j, k1[j], s.stack[fbase(s, g) + j]));
            assert(wf_kind(p, c, mg, kr, j));
            assert(k1[j] == kr[j]);
            lemma_conf_upto(p, c, s, s1, g, n, k1, j, k1[j], s.stack[fbase(s, g) + j]);
            assert(kr.subrange(0, j) =~= k1.subrange(0, j));
            lemma_conf_kf(p, c, s1, g, k1, kr, j, k1[j], s.stack[fbase(s, g) + j]);
        } else {
            reveal(conf);
            assert(s1.stack[fbase(s1, g) + j] == v);
        }
    }
    assert(frame_ok(p, c, s1, g)) by {
        let i = info(p, mg);
        if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, mg) >= 1 {
            assert(receiver_ok(p, s, g));
            assert(s1.stack[fbase(s, g)] == s.stack[fbase(s, g)]);
        }
    }
    assert forall|fi: int| 0 <= fi < s1.frames.len() implies #[trigger] frame_ok(p, c, s1, fi) by {}
    assert(s1.frames[0] == s.frames[0]);
    assert(wf(p, c, s1)) by { reveal(wf); reveal(wf_task); }
}

/// An unwinding state stays one when slots are added above the known ones.
pub proof fn lemma_unw_extra(p: Program2, c: Cert, s: State2, s1: State2, kt: Seq<Kind>)
    requires
        unw_ok(p, c, s, kt),
        s1.frames == s.frames, s1.heap == s.heap, s1.globals == s.globals,
        s1.task == s.task,
        s.stack.len() <= s1.stack.len(), s1.stack.len() < 0x8000_0000,
        forall|x: int| 0 <= x < s.stack.len() ==> #[trigger] s1.stack[x] == s.stack[x],
    ensures unw_ok(p, c, s1, kt),
{
    let t = top_i(s);
    let b = fbase(s, t);
    assert(bases_ok(s1)) by {
        assert forall|fi: int| 0 <= fi && fi + 1 < s1.frames.len() implies #[trigger] base_step(s1, fi) by {
            assert(base_step(s, fi));
        }
    }
    if t > 0 {
        assert(same_below(s, s1, t - 1)) by {
            assert forall|g: int| 0 <= g <= t - 1 implies #[trigger] try_frame(s1, g) == try_frame(s, g) by {}
            lemma_base_le_len(s, t);
        }
    }
    assert forall|fi: int| 0 <= fi < t implies #[trigger] frame_ok(p, c, s1, fi) by {
        assert(frame_ok(p, c, s, fi));
        lemma_same_below_down(s, s1, t - 1, fi);
        lemma_frame_below_unw(p, c, s, s1, fi);
    }
    assert(same_upto(s, s1, t, kt.len() as int)) by {
        lemma_base_le_len(s, t);
    }
    assert forall|j: int| 0 <= j < kt.len() implies #[trigger] conf(p, c, s1, t, kt, j, kt[j], s1.stack[b + j]) by {
        assert(conf(p, c, s, t, kt, j, kt[j], s.stack[b + j]));
        assert(wf_kind(p, c, fmethod(s, t), kt, j));
        lemma_conf_upto(p, c, s, s1, t, kt.len() as int, kt, j, kt[j], s.stack[b + j]);
    }
    if kt.len() >= 1 {
        assert(s1.stack[b] == s.stack[b]);
    }
}

} // verus!
