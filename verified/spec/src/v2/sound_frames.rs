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

//! Structural lemmas of the soundness proof: the invariant is stable
//! under heap growth, under changes above a frame, and under a change of
//! the top frame's slots that the stack maps describe.

use vstd::prelude::*;
use crate::types::*;
use crate::v2::types::*;
use crate::v2::spec::*;
use crate::v2::verifier::*;
use crate::v2::sound::*;
#[cfg(verus_only)]
use crate::spec_common::{class_id_ok, class_id_of, obj, obj_ok};

verus! {

/// The heap grows; classes and stack objects (as such) stay.
pub open spec fn heap_grows(h: Seq<HeapObj>, h2: Seq<HeapObj>) -> bool {
    &&& h.len() <= h2.len()
    &&& forall|i: int| 0 <= i < h.len() ==> {
        &&& (#[trigger] h2[i]).class_id == h[i].class_id
        &&& h[i].body is Stack2 ==> h2[i].body is Stack2
    }
}

/// The heap grows, and the fields of tasks the machine owns stay.
pub open spec fn heap_ext(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>) -> bool {
    &&& heap_grows(h, h2)
    &&& forall|i: int| 0 <= i < h.len() && h[i].class_id as int == task_class(p) ==>
            task_fields_kept(h[i], #[trigger] h2[i])
}

pub proof fn lemma_heap_ext_refl(p: Program2, h: Seq<HeapObj>)
    ensures heap_ext(p, h, h),
{
    assert forall|i: int| 0 <= i < h.len() && h[i].class_id as int == task_class(p) implies
        task_fields_kept(h[i], #[trigger] h[i]) by {
        match h[i].body {
            Body::Instance(f) => {},
            _ => {},
        }
    }
}

pub proof fn lemma_heap_ext_trans(p: Program2, h1: Seq<HeapObj>, h2: Seq<HeapObj>, h3: Seq<HeapObj>)
    requires heap_ext(p, h1, h2), heap_ext(p, h2, h3),
    ensures heap_ext(p, h1, h3),
{
    assert forall|i: int| 0 <= i < h1.len() implies {
        &&& (#[trigger] h3[i]).class_id == h1[i].class_id
        &&& h1[i].body is Stack2 ==> h3[i].body is Stack2
    } by {
        assert(h2[i].class_id == h1[i].class_id);
    }
    assert forall|i: int| 0 <= i < h1.len() && h1[i].class_id as int == task_class(p) implies
        task_fields_kept(h1[i], #[trigger] h3[i]) by {
        assert(h2[i].class_id == h1[i].class_id);
        assert(task_fields_kept(h1[i], h2[i]));
        assert(task_fields_kept(h2[i], h3[i]));
    }
}

pub proof fn lemma_kept_refl(o: HeapObj)
    ensures task_fields_kept(o, o),
{
    match o.body {
        Body::Instance(f) => {},
        _ => {},
    }
}

/// The running task keeps its stack when the heap is extended.
pub proof fn lemma_running_heap(p: Program2, s: State2, s2: State2)
    requires running_ok(p, s), heap_ext(p, s.heap, s2.heap), s2.task == s.task,
    ensures running_ok(p, s2),
{
    let t = s.task as int;
    assert(s2.heap[t].class_id == s.heap[t].class_id);
    assert(task_fields_kept(s.heap[t], s2.heap[t]));
    match s.heap[t].body {
        Body::Instance(f) => {
            match s2.heap[t].body {
                Body::Instance(f2) => {
                    assert(f2[0] == f[0]);
                    match f[0] {
                        Value::Obj(id) => { assert(s2.heap[id as int].body is Stack2); },
                        _ => {},
                    }
                },
                _ => {},
            }
        },
        _ => {},
    }
}

/// `heap_ext` without the tasks.
pub proof fn lemma_heap_ext_grows(p: Program2, h: Seq<HeapObj>, h2: Seq<HeapObj>)
    requires heap_ext(p, h, h2),
    ensures heap_grows(h, h2),
{}

pub proof fn lemma_good_mono(h: Seq<HeapObj>, h2: Seq<HeapObj>, v: Value)
    requires good(h, v), h.len() <= h2.len(),
    ensures good(h2, v),
{}

pub open spec fn with_heap(s: State2, h2: Seq<HeapObj>) -> State2 {
    State2 { heap: h2, ..s }
}

pub proof fn lemma_conf_heap(p: Program2, c: Cert, s: State2, h2: Seq<HeapObj>, fi: int, kf: Seq<Kind>, j: int, k: Kind, v: Value)
    requires conf(p, c, s, fi, kf, j, k, v), heap_grows(s.heap, h2),
    ensures conf(p, c, with_heap(s, h2), fi, kf, j, k, v),
{
    reveal(conf);
    reveal(pending_ok);
    reveal(good_ref);
    let s2 = with_heap(s, h2);
    assert(kinds_of(p, c, s2, fi) == kinds_of(p, c, s, fi));
    match k {
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    assert(context_frame(s2, fi, d as nat) == context_frame(s, fi, d as nat)) by {
                        lemma_context_frame_same(s, s2, fi, d as nat);
                    }
                    assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Token(false, Pending::Branch(f, bci, hb), _, _) => {
                    assert(kinds_of(p, c, s2, f as int) == kinds_of(p, c, s, f as int));
                    assert(frame_kinds_from(p, c, s2, fi, kf, f as int) == frame_kinds_from(p, c, s, fi, kf, f as int));
                    assert(fmethod(s2, f as int) == fmethod(s, f as int));
                    assert(fbase(s2, f as int) == fbase(s, f as int));
                },
                _ => {},
            }
        },
        _ => {},
    }
}

/// `context_frame` only reads the stack and the frames.
pub proof fn lemma_context_frame_same(s: State2, s2: State2, fi: int, d: nat)
    requires s2.stack == s.stack, s2.frames == s.frames,
    ensures context_frame(s2, fi, d) == context_frame(s, fi, d),
    decreases d,
{
    if d > 0 && 0 <= fi < s.frames.len() && 0 <= s.frames[fi].base < s.stack.len() {
        match s.stack[s.frames[fi].base as int] {
            Value::BlockRef(f, _) => if (f as int) < fi { lemma_context_frame_same(s, s2, f as int, (d - 1) as nat); },
            _ => {},
        }
    }
}

pub proof fn lemma_wf_task_heap(p: Program2, c: Cert, s: State2, h2: Seq<HeapObj>)
    requires wf_task(p, c, s), heap_grows(s.heap, h2),
    ensures wf_task(p, c, with_heap(s, h2)),
{
    reveal(wf_task);
    reveal(frame_ok);
    let s2 = with_heap(s, h2);
    assert forall|fi: int| 0 <= fi && fi + 1 < s2.frames.len() implies #[trigger] base_step(s2, fi) by {
        assert(base_step(s, fi));
    }
    assert forall|fi: int| 0 <= fi < s2.frames.len() implies #[trigger] frame_ok(p, c, s2, fi) by {
        assert(frame_ok(p, c, s, fi));
        assert(kinds_of(p, c, s2, fi) == kinds_of(p, c, s, fi));
        assert(try_frame(s2, fi) == try_frame(s, fi));
        assert forall|j: int| 0 <= j < slots(s2, fi) implies
            #[trigger] conf(p, c, s2, fi, kinds_of(p, c, s2, fi), j, kinds_of(p, c, s2, fi)[j], s2.stack[fbase(s2, fi) + j]) by {
            assert(conf(p, c, s, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[fbase(s, fi) + j]));
            lemma_conf_heap(p, c, s, h2, fi, kinds_of(p, c, s, fi), j, kinds_of(p, c, s, fi)[j], s.stack[fbase(s, fi) + j]);
        }
        let m = fmethod(s, fi);
        let i = info(p, m);
        if (i.kind == KIND_METHOD || i.kind == KIND_FIELD_ACCESSOR) && has_receiver_range(i) && arity(p, m) >= 1 {
            let r = s.stack[fbase(s, fi)];
            match r {
                Value::Obj(id) => {
                    assert(h2[id as int].class_id == s.heap[id as int].class_id);
                },
                _ => {},
            }
            assert(class_id_of(p1(p), as1(s2), r) == class_id_of(p1(p), as1(s), r));
        }
    }
}

/// Frames `0..=fi` look the same in `s` and `s2`: same frames (frame
/// `fi + 1`'s return address and base too, if `fi` is not the top), same
/// slots, same try blocks above them; the heap only grew.
pub open spec fn same_below(s: State2, s2: State2, fi: int) -> bool {
    &&& 0 <= fi && fi + 1 < s.frames.len() && fi + 1 < s2.frames.len()
    &&& forall|g: int| 0 <= g <= fi ==> #[trigger] s2.frames[g] == s.frames[g]
    &&& s2.frames[fi + 1].ret == s.frames[fi + 1].ret
    &&& s2.frames[fi + 1].base == s.frames[fi + 1].base
    &&& s.frames[fi + 1].base <= s.stack.len()
    &&& s2.frames[fi + 1].base <= s2.stack.len()
    &&& forall|x: int| 0 <= x < s.frames[fi + 1].base ==> #[trigger] s2.stack[x] == s.stack[x]
    &&& forall|g: int| 0 <= g <= fi ==> #[trigger] try_frame(s2, g) == try_frame(s, g)
    &&& heap_grows(s.heap, s2.heap)
}

pub proof fn lemma_same_below_down(s: State2, s2: State2, fi: int, g: int)
    requires same_below(s, s2, fi), 0 <= g <= fi, bases_ok(s),
    ensures same_below(s, s2, g),
{
    assert(s2.frames[g + 1] == s.frames[g + 1] || g + 1 == fi + 1);
    assert(s.frames[g + 1].base <= s.frames[fi + 1].base) by {
        lemma_bases_mono(s, g + 1, fi + 1);
    }
}

pub proof fn lemma_bases_mono(s: State2, a: int, b: int)
    requires bases_ok(s), 0 <= a <= b < s.frames.len(),
    ensures s.frames[a].base <= s.frames[b].base,
    decreases b - a,
{
    if a < b {
        assert(base_step(s, a));
        lemma_bases_mono(s, a + 1, b);
    }
}

pub proof fn lemma_base_le_len(s: State2, a: int)
    requires bases_ok(s), 0 <= a < s.frames.len(),
    ensures s.frames[a].base <= s.stack.len(),
{
    lemma_bases_mono(s, a, s.frames.len() - 1);
}

pub proof fn lemma_limit_below(s: State2, g: int, fi: int)
    requires bases_ok(s), 0 <= g < fi < s.frames.len(),
    ensures limit(s, g) <= fbase(s, fi), fbase(s, g) <= limit(s, g),
{
    lemma_bases_mono(s, g + 1, fi);
    assert(base_step(s, g));
}

/// The context chain from frame `fi` only reads frames `0..=fi`.
pub proof fn lemma_context_frame_below(s: State2, s2: State2, fi: int, top: int, d: nat)
    requires
        same_below(s, s2, top) || (fi <= top && same_below(s, s2, top)),
        0 <= fi <= top,
        bases_ok(s), bases_ok(s2),
    ensures context_frame(s2, fi, d) == context_frame(s, fi, d),
    decreases d,
{
    if d > 0 {
        assert(s2.frames[fi] == s.frames[fi]);
        lemma_limit_below(s, fi, top + 1);
        assert(limit(s2, fi) == limit(s, fi)) by {
            if fi < top { assert(s2.frames[fi + 1] == s.frames[fi + 1]); }
        }
        if slots(s, fi) >= 1 && 0 <= fbase(s, fi) < s.stack.len() {
            assert(s2.stack[fbase(s, fi)] == s.stack[fbase(s, fi)]);
            match s.stack[fbase(s, fi)] {
                Value::BlockRef(f, _) => if (f as int) < fi {
                    lemma_context_frame_below(s, s2, f as int, top, (d - 1) as nat);
                },
                _ => {},
            }
        }
    }
}

pub proof fn lemma_kinds_below(p: Program2, c: Cert, s: State2, s2: State2, f: int, fi: int)
    requires same_below(s, s2, fi), 0 <= f <= fi, bases_ok(s),
    ensures
        kinds_of(p, c, s2, f) == kinds_of(p, c, s, f),
        fmap(p, c, s2, f) == fmap(p, c, s, f),
        slots(s2, f) == slots(s, f),
        limit(s2, f) == limit(s, f),
        fbase(s2, f) == fbase(s, f),
        fmethod(s2, f) == fmethod(s, f),
        foff(p, s2, f) == foff(p, s, f),
        top_i(s2) != f, top_i(s) != f,
{
    assert(s2.frames[f] == s.frames[f]);
    if f < fi { assert(s2.frames[f + 1] == s.frames[f + 1]); }
}

/// A conforming slot of frame `fi` (not the top) still conforms when
/// frames `0..=fi` look the same.
/// A reference into frame `f <= fi` stays in range.
pub proof fn lemma_ref_ok_below(s: State2, s2: State2, fi: int, f: int, slot: int)
    requires same_below(s, s2, fi), 0 <= f <= fi, ref_ok(s, f, slot), bases_ok(s), bases_ok(s2),
    ensures ref_ok(s2, f, slot),
{
    assert(s2.frames[f] == s.frames[f]);
    if f < fi { assert(s2.frames[f + 1] == s.frames[f + 1]); }
    lemma_bases_mono(s2, f + 1, fi + 1);
}

pub proof fn lemma_conf_below(p: Program2, c: Cert, s: State2, s2: State2, fi: int, kf: Seq<Kind>, j: int, k: Kind, v: Value)
    requires
        conf(p, c, s, fi, kf, j, k, v),
        same_below(s, s2, fi),
        bases_ok(s), bases_ok(s2),
        0 <= j < slots(s, fi),
    ensures conf(p, c, s2, fi, kf, j, k, v),
{
    reveal(conf);
    reveal(good_ref);
    reveal(pending_ok);
    match k {
        Kind::Val => {},
        Kind::Method(_) => {},
        Kind::Block(d, sl) => {
            match v {
                Value::BlockRef(f, slot) => {
                    let f = f as int;
                    if d > 0 {
                        lemma_context_frame_below(s, s2, fi, fi, d as nat);
                        lemma_context_frame_lt(s, fi, d as nat);
                    }
                    assert(0 <= f <= fi);
                    lemma_kinds_below(p, c, s, s2, f, fi);
                    lemma_ref_ok_below(s, s2, fi, f, slot as int);
                    if d > 0 {
                        assert(good_ref(p, c, s2, f, slot as int) == good_ref(p, c, s, f, slot as int));
                    }
                },
                _ => {},
            }
        },
        Kind::Param => {
            match v {
                Value::BlockRef(f, slot) => {
                    lemma_kinds_below(p, c, s, s2, f as int, fi);
                    lemma_ref_ok_below(s, s2, fi, f as int, slot as int);
                    assert(good_ref(p, c, s2, f as int, slot as int) == good_ref(p, c, s, f as int, slot as int));
                },
                _ => {},
            }
        },
        Kind::Token => {
            match v {
                Value::Token(second, d, _, _) => {
                    lemma_kinds_below(p, c, s, s2, fi, fi);
                    if second {
                        lemma_limit_below(s, fi, fi + 1);
                        assert(s2.stack[fbase(s, fi) + j - 1] == s.stack[fbase(s, fi) + j - 1]);
                    }
                    match d {
                        Pending::Branch(f, bci, hb) => if !second {
                            if (f as int) < fi {
                                lemma_kinds_below(p, c, s, s2, f as int, fi);
                            } else if f as int == fi {
                                assert(s2.frames[fi] == s.frames[fi]);
                            }
                            assert(frame_kinds_from(p, c, s2, fi, kf, f as int) == frame_kinds_from(p, c, s, fi, kf, f as int));
                        },
                        _ => {},
                    }
                },
                _ => {},
            }
        },
    }
}

/// The context chain from a frame leads to a frame below it (or -1).
pub proof fn lemma_context_frame_lt(s: State2, fi: int, d: nat)
    requires d > 0, fi >= 0,
    ensures context_frame(s, fi, d) < fi,
    decreases d,
{
    reveal_with_fuel(context_frame, 2);
    if 0 <= fi < s.frames.len() && slots(s, fi) >= 1 && 0 <= fbase(s, fi) < s.stack.len() {
        match s.stack[fbase(s, fi)] {
            Value::BlockRef(f, _) => if (f as int) < fi {
                if d > 1 { lemma_context_frame_lt(s, f as int, (d - 1) as nat); }
            },
            _ => {},
        }
    }
}

/// Frame `fi` (not the top) of a well-formed task is still well formed
/// when frames `0..=fi` look the same.
pub proof fn lemma_frame_below(p: Program2, c: Cert, s: State2, s2: State2, fi: int)
    requires
        wf_task(p, c, s),
        same_below(s, s2, fi),
        bases_ok(s2),
    ensures frame_ok(p, c, s2, fi),
{
    reveal(wf_task);
    reveal(frame_ok);
    assert(frame_ok(p, c, s, fi));
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

} // verus!
